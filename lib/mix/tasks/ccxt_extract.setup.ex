defmodule Mix.Tasks.CcxtExtract.Setup do
  @shortdoc "Install CCXT and verify extraction tools"

  @moduledoc """
  Sets up CCXT sources for extraction and verifies both tools work.

  1. Installs CCXT via `mix npm.install ccxt` (browser bundle for QuickBEAM)
  2. Checks that TypeScript source exists at `priv/ccxt/ts/src/` (for OXC parsing)
  3. Verifies QuickBEAM can load the browser bundle and count exchanges
  4. Verifies OXC can parse a TypeScript exchange file

      mix ccxt_extract.setup
  """

  use Mix.Task

  @bundle_path "node_modules/ccxt/dist/ccxt.browser.min.js"
  @npm_package_json "node_modules/ccxt/package.json"
  @ts_check_file "priv/ccxt/ts/src/binance.ts"
  @ts_package_json "priv/ccxt/package.json"
  @version_file "priv/ccxt_version.json"

  @impl true
  def run(_args) do
    install_npm_package()
    check_ts_source()
    versions = record_versions()
    verify_quickbeam()
    verify_oxc()

    Mix.shell().info("\nSetup complete. Both tools verified.")
    Mix.shell().info("CCXT version: #{versions["npm_version"]} (#{String.slice(versions["source_git_sha"], 0..6)})")
  end

  defp install_npm_package do
    if File.exists?(@bundle_path) do
      size_kb = @bundle_path |> File.stat!() |> Map.get(:size) |> div(1024)
      Mix.shell().info("CCXT browser bundle already installed (#{size_kb}KB), skipping npm install.")
    else
      Mix.shell().info("Installing CCXT via npm...")
      Mix.Task.run("npm.install", ["ccxt"])

      if !File.exists?(@bundle_path) do
        Mix.raise("npm install completed but #{@bundle_path} not found")
      end

      Mix.shell().info("CCXT browser bundle installed.")
    end
  end

  defp check_ts_source do
    if File.exists?(@ts_check_file) do
      # Check if it's a symlink or direct clone
      case File.lstat(@ts_check_file) do
        {:ok, %{type: :symlink}} ->
          Mix.shell().info("CCXT TypeScript source available (via symlink).")

        _ ->
          Mix.shell().info("CCXT TypeScript source available.")
      end
    else
      Mix.raise("""
      CCXT TypeScript source not found at priv/ccxt/ts/src/.

      Either symlink an existing checkout:
          ln -s /path/to/ccxt priv/ccxt

      Or clone via sparse checkout:
          git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt
          cd priv/ccxt && git sparse-checkout set ts/src
      """)
    end
  end

  defp record_versions do
    npm_version = @npm_package_json |> File.read!() |> Jason.decode!() |> Map.get("version")
    ts_version = @ts_package_json |> File.read!() |> Jason.decode!() |> Map.get("version")

    source_git_sha = resolve_git_sha()

    if npm_version != ts_version do
      Mix.shell().info("\nWARNING: Version mismatch! npm bundle: #{npm_version}, TS source: #{ts_version}")
    end

    versions = %{
      "npm_version" => npm_version,
      "source_version" => ts_version,
      "source_git_sha" => source_git_sha,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write!(@version_file, Jason.encode!(versions, pretty: true))
    Mix.shell().info("\nVersions recorded to #{@version_file}")
    versions
  end

  defp resolve_git_sha do
    # Follow symlink if priv/ccxt is one, otherwise use it directly
    ccxt_dir =
      case File.read_link("priv/ccxt") do
        {:ok, target} -> target
        _ -> Path.expand("priv/ccxt")
      end

    case System.cmd("git", ["rev-parse", "HEAD"], cd: ccxt_dir, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp verify_quickbeam do
    Application.ensure_all_started(:quickbeam)

    Mix.shell().info("\nVerifying QuickBEAM...")
    bundle = File.read!(@bundle_path)
    Mix.shell().info("Loading CCXT bundle (#{div(byte_size(bundle), 1024)}KB)...")

    {:ok, rt} = QuickBEAM.start()

    # self/window must reference globalThis so browser bundles attach to global scope
    QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
    QuickBEAM.set_global(rt, "navigator", %{"userAgent" => "QuickBEAM"})
    QuickBEAM.set_global(rt, "location", %{"protocol" => "https:"})

    {load_us, {:ok, _}} = :timer.tc(fn -> QuickBEAM.eval(rt, bundle) end)

    {:ok, count} =
      QuickBEAM.eval(rt, """
      Object.keys(ccxt).filter(k => {
        try { return typeof ccxt[k] === 'function' && k !== 'Exchange' && k !== 'Precise' && new ccxt[k]().id; }
        catch(e) { return false; }
      }).length
      """)

    QuickBEAM.stop(rt)

    Mix.shell().info("QuickBEAM: loaded CCXT in #{div(load_us, 1000)}ms, found #{count} exchanges.")

    if count < 100 do
      Mix.raise("Expected 100+ exchanges, got #{count}")
    end
  end

  defp verify_oxc do
    Mix.shell().info("\nVerifying OXC...")
    source = File.read!(@ts_check_file)

    {parse_us, {:ok, ast}} = :timer.tc(fn -> OXC.parse(source, "binance.ts") end)

    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))
    class = export.declaration
    class_name = if class.id, do: class.id.name, else: "anonymous"
    methods = Enum.filter(class.body.body, &(&1.type == "MethodDefinition"))

    Mix.shell().info(
      "OXC: parsed binance.ts in #{div(parse_us, 1000)}ms — #{class_name} with #{length(methods)} methods."
    )
  end
end
