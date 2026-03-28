defmodule Mix.Tasks.CcxtExtract.Setup do
  @shortdoc "Install CCXT and verify extraction tools"

  @moduledoc """
  Sets up CCXT sources for extraction and verifies both tools work.

  1. Installs CCXT via `mix npm.install ccxt` (browser bundle for QuickBEAM)
  2. Copies the browser bundle to `priv/ccxt_bundle.js`
  3. Checks that TypeScript source exists at `priv/ccxt/ts/src/` (for OXC parsing)
  4. Verifies QuickBEAM can load the browser bundle and count exchanges
  5. Verifies OXC can parse a TypeScript exchange file

      mix ccxt_extract.setup
  """

  use Mix.Task

  @npm_bundle "node_modules/ccxt/dist/ccxt.browser.min.js"
  @npm_package_json "node_modules/ccxt/package.json"
  @ts_check_file_rel "ccxt/ts/src/binance.ts"
  @ts_package_json_rel "ccxt/package.json"

  @impl true
  def run(_args) do
    install_npm_package()
    copy_bundle_to_priv()
    check_ts_source()
    versions = record_versions()
    verify_quickbeam()
    verify_oxc()

    Mix.shell().info("\nSetup complete. Both tools verified.")
    Mix.shell().info("CCXT version: #{versions["npm_version"]} (#{String.slice(versions["source_git_sha"], 0..6)})")
  end

  defp install_npm_package do
    if File.exists?(@npm_bundle) do
      size_kb = @npm_bundle |> File.stat!() |> Map.get(:size) |> div(1024)
      Mix.shell().info("CCXT browser bundle already installed (#{size_kb}KB), skipping npm install.")
    else
      Mix.shell().info("Installing CCXT via npm...")
      Mix.Task.run("npm.install", ["ccxt"])

      if !File.exists?(@npm_bundle) do
        Mix.raise("npm install completed but #{@npm_bundle} not found")
      end

      Mix.shell().info("CCXT browser bundle installed.")
    end
  end

  # Copy browser bundle from node_modules to priv/ so extraction works
  # via :code.priv_dir without depending on node_modules at runtime.
  defp copy_bundle_to_priv do
    dest = CcxtExtract.Paths.bundle()

    if File.exists?(dest) && File.stat!(@npm_bundle).size == File.stat!(dest).size do
      Mix.shell().info("Bundle already in priv/, skipping copy.")
    else
      File.cp!(@npm_bundle, dest)
      Mix.shell().info("Copied browser bundle to #{dest}")
    end
  end

  defp check_ts_source do
    ts_check_file = CcxtExtract.Paths.priv(@ts_check_file_rel)

    if File.exists?(ts_check_file) do
      case File.lstat(ts_check_file) do
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

    ts_package_json = CcxtExtract.Paths.priv(@ts_package_json_rel)

    ts_version =
      if File.exists?(ts_package_json) do
        ts_package_json |> File.read!() |> Jason.decode!() |> Map.get("version")
      else
        Mix.shell().info("\nWARNING: priv/ccxt/package.json not found — cannot verify TS source version.")
        Mix.shell().info("If using sparse checkout, add package.json: git sparse-checkout add package.json")
        "unknown"
      end

    source_git_sha = resolve_git_sha()

    if ts_version != "unknown" and npm_version != ts_version do
      Mix.shell().info("\nWARNING: Version mismatch! npm bundle: #{npm_version}, TS source: #{ts_version}")
    end

    versions = %{
      "npm_version" => npm_version,
      "source_version" => ts_version,
      "source_git_sha" => source_git_sha,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    version_file = CcxtExtract.Paths.version_file()
    File.write!(version_file, Jason.encode!(versions, pretty: true))
    Mix.shell().info("\nVersions recorded to #{version_file}")
    versions
  end

  defp resolve_git_sha do
    ccxt_dir = CcxtExtract.Paths.priv("ccxt")

    # Follow symlink if priv/ccxt is one
    ccxt_dir =
      case File.read_link(ccxt_dir) do
        {:ok, target} -> target
        _ -> ccxt_dir
      end

    case System.cmd("git", ["rev-parse", "HEAD"], cd: ccxt_dir, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp verify_quickbeam do
    Application.ensure_all_started(:quickbeam)

    Mix.shell().info("\nVerifying QuickBEAM...")
    bundle_path = CcxtExtract.Paths.bundle()
    bundle = File.read!(bundle_path)
    Mix.shell().info("Loading CCXT bundle (#{div(byte_size(bundle), 1024)}KB)...")

    {:ok, rt} = QuickBEAM.start()

    # self/window must reference globalThis so browser bundles attach to global scope
    # Uses JS eval to set globalThis identity — this is the documented QuickBEAM pattern
    # for loading browser bundles (vendor artifact, not user input).
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
    source = File.read!(CcxtExtract.Paths.priv(@ts_check_file_rel))

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
