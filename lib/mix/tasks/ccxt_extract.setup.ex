defmodule Mix.Tasks.CcxtExtract.Setup do
  @shortdoc "Install CCXT and verify extraction tools"

  @moduledoc """
  Sets up CCXT sources for extraction and verifies both tools work.

  1. Installs CCXT via `mix npm.install ccxt` (browser bundle for QuickBEAM)
  2. Copies the browser bundle to `priv/ccxt_bundle.js`
  3. Ensures TypeScript source exists at `priv/ccxt/ts/src/` (for OXC parsing).
     Auto-sparse-clones `https://github.com/ccxt/ccxt.git` (with `ts/src` +
     `package.json`) into `priv/ccxt` when missing — fresh clones and CI alike
     get a working corpus without manual setup. Skip the auto-clone with
     `--no-clone` or `CCXT_EXTRACT_SKIP_CLONE=1`.
  4. Verifies QuickBEAM can load the browser bundle and count exchanges
  5. Verifies OXC can parse a TypeScript exchange file

  ## Options

    * `--ccxt-version VERSION` — Pin a specific CCXT version (e.g., `4.5.45`).
      Without this flag, installs the latest version.
    * `--latest` — Force reinstall of the latest version, even if a bundle
      already exists. Useful in CI to ensure up-to-date extractions.
    * `--no-clone` — Opt out of auto-cloning `priv/ccxt` when missing. Setup
      will fail with the legacy "missing source" error instead. The env var
      `CCXT_EXTRACT_SKIP_CLONE=1` has the same effect.

  ## Examples

      mix ccxt_extract.setup
      mix ccxt_extract.setup --ccxt-version 4.5.45
      mix ccxt_extract.setup --latest
      mix ccxt_extract.setup --no-clone
  """

  use Mix.Task

  @npm_bundle "node_modules/ccxt/dist/ccxt.browser.min.js"
  @npm_package_json "node_modules/ccxt/package.json"
  @ts_check_file_rel "ccxt/ts/src/binance.ts"
  @ts_package_json_rel "ccxt/package.json"
  @ccxt_repo_url "https://github.com/ccxt/ccxt.git"
  @ccxt_sparse_paths ~w(ts/src package.json)

  # --latest forces reinstall even when bundle exists (ensures actual latest).
  # --ccxt-version pins a specific version and verifies after install.
  # --no-clone opts out of auto-cloning priv/ccxt when missing.
  @switches [ccxt_version: :string, latest: :boolean, no_clone: :boolean]
  @aliases [v: :ccxt_version]

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    pinned_version = Keyword.get(opts, :ccxt_version)
    force_latest? = Keyword.get(opts, :latest, false)

    version_sensitive? = pinned_version != nil or force_latest?

    check_ts_source(opts)
    update_ts_source(pinned_version, force_latest?)
    install_npm_package(pinned_version, force_latest?)
    copy_bundle_to_priv()
    verify_installed_version(pinned_version)
    versions = record_versions(version_sensitive?)
    verify_quickbeam()
    verify_oxc()

    Mix.shell().info("\nSetup complete. Both tools verified.")
    Mix.shell().info("CCXT version: #{versions["npm_version"]} (#{String.slice(versions["source_git_sha"], 0..6)})")
  end

  # Installs CCXT npm package. When pinned_version is provided, installs that
  # exact version (always re-installs to ensure correctness). When force_latest?
  # is true, always reinstalls even if bundle exists (ensures actual latest).
  # Otherwise installs latest only if not already present.
  defp install_npm_package(nil, false = _force_latest?) do
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

  defp install_npm_package(nil, true = _force_latest?) do
    Mix.shell().info("Updating CCXT to latest via npm...")
    # npm.install updates package.json to latest version from registry.
    # npm.update re-resolves the lockfile and actually installs the new version.
    # Both steps needed: install alone won't update the lockfile, update alone
    # won't bump the version specifier in package.json.
    Mix.Task.rerun("npm.install", ["ccxt"])
    Mix.Task.rerun("npm.update", ["ccxt"])

    if !File.exists?(@npm_bundle) do
      Mix.raise("npm install completed but #{@npm_bundle} not found")
    end

    Mix.shell().info("CCXT latest browser bundle installed.")
  end

  defp install_npm_package(version, _force_latest?) do
    Mix.shell().info("Installing CCXT version #{version} via npm...")
    Mix.Task.rerun("npm.install", ["ccxt@#{version}"])
    Mix.Task.rerun("npm.update", ["ccxt"])

    if !File.exists?(@npm_bundle) do
      Mix.raise("npm install completed but #{@npm_bundle} not found")
    end

    Mix.shell().info("CCXT #{version} browser bundle installed.")
  end

  # When a specific version was requested, verify the installed package matches.
  defp verify_installed_version(nil), do: :ok

  defp verify_installed_version(expected) do
    installed = @npm_package_json |> File.read!() |> Jason.decode!() |> Map.get("version")

    if installed != expected do
      Mix.raise("Version mismatch: requested #{expected} but npm installed #{installed}")
    end
  end

  # Copy browser bundle from node_modules to priv/ so extraction works
  # via :code.priv_dir without depending on node_modules at runtime.
  defp copy_bundle_to_priv do
    dest = CcxtExtract.Paths.out_bundle()

    if File.exists?(dest) && File.stat!(@npm_bundle).size == File.stat!(dest).size do
      Mix.shell().info("Bundle already in priv/, skipping copy.")
    else
      File.cp!(@npm_bundle, dest)
      Mix.shell().info("Copied browser bundle to #{dest}")
    end
  end

  # Verify priv/ccxt/ts/src/ is present. When missing, sparse-clone
  # the upstream CCXT repo (matching what harness.yml's leading
  # comment promised the `setup` alias would do). Honor the explicit
  # opt-out via --no-clone or CCXT_EXTRACT_SKIP_CLONE=1, in which
  # case we fall back to the legacy "missing source" raise.
  defp check_ts_source(opts) do
    ts_check_file = CcxtExtract.Paths.priv(@ts_check_file_rel)

    cond do
      File.exists?(ts_check_file) ->
        announce_existing_source(ts_check_file)

      opt_out_auto_clone?(opts) ->
        raise_missing_ts_source!()

      true ->
        auto_clone_ts_source!()

        if File.exists?(ts_check_file) do
          announce_existing_source(ts_check_file)
        else
          raise_missing_ts_source!()
        end
    end
  end

  defp announce_existing_source(ts_check_file) do
    case File.lstat(ts_check_file) do
      {:ok, %{type: :symlink}} ->
        Mix.shell().info("CCXT TypeScript source available (via symlink).")

      _ ->
        Mix.shell().info("CCXT TypeScript source available.")
    end
  end

  defp opt_out_auto_clone?(opts) do
    Keyword.get(opts, :no_clone, false) or System.get_env("CCXT_EXTRACT_SKIP_CLONE") == "1"
  end

  # Sparse clone of github.com/ccxt/ccxt → priv/ccxt with only the
  # paths extraction needs. Mirrors the manual instructions in the
  # legacy raise message but as live behavior so fresh clones and CI
  # both work without an extra setup step.
  defp auto_clone_ts_source! do
    # Resolve via `Paths.out/1` (write helper) rather than `priv/1`.
    # The two paths agree in normal runs but the write helper honors
    # `:priv_write_override`, which integration tests use to redirect
    # writes into a tmp dir while reads still hit the committed corpus.
    # The `paths_rw_split` contract-test invariant flags the read-side
    # helper bleeding into a write call site.
    ccxt_dir = CcxtExtract.Paths.out("ccxt")

    if File.exists?(ccxt_dir) do
      Mix.raise("""
      priv/ccxt exists but TypeScript source is not present at #{@ts_check_file_rel}.
      Inspect the directory manually — auto-clone refuses to overwrite an
      existing path. Fix or remove it, then re-run `mix ccxt_extract.setup`.
      """)
    end

    File.mkdir_p!(Path.dirname(ccxt_dir))

    Mix.shell().info("Sparse-cloning CCXT TypeScript source into #{ccxt_dir}...")

    clone_args =
      ["clone", "--depth", "1", "--filter=blob:none", "--sparse", @ccxt_repo_url, ccxt_dir]

    case System.cmd("git", clone_args, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(String.trim(output))

      {output, _} ->
        Mix.raise("""
        git clone failed. Re-run with `--no-clone` and bootstrap manually if
        network access is unavailable.

        #{String.trim(output)}
        """)
    end

    # `--no-cone` lets us mix files (`package.json`) and directories
    # (`ts/src`) in the pattern set. Newer git rejects file paths in
    # cone mode without `--skip-checks`; no-cone is the future-proof
    # form (cone mode itself is the post-2.27 default; we explicitly
    # opt out for this one repo).
    sparse_args = ["sparse-checkout", "set", "--no-cone" | @ccxt_sparse_paths]

    case System.cmd("git", sparse_args, cd: ccxt_dir, stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info("CCXT TypeScript source cloned (sparse: #{Enum.join(@ccxt_sparse_paths, " ")}).")

      {output, _} ->
        Mix.raise("git sparse-checkout failed: #{String.trim(output)}")
    end
  end

  @spec raise_missing_ts_source!() :: no_return()
  defp raise_missing_ts_source! do
    Mix.raise("""
    CCXT TypeScript source not found at priv/ccxt/ts/src/.

    Either symlink an existing checkout:
        ln -s /path/to/ccxt priv/ccxt

    Or clone via sparse checkout (include package.json for version verification):
        git clone --depth 1 --sparse #{@ccxt_repo_url} priv/ccxt
        cd priv/ccxt && git sparse-checkout set --no-cone #{Enum.join(@ccxt_sparse_paths, " ")}
    """)
  end

  # Updates the TS source git repo to match the requested version.
  # --latest: git pull to get newest commit on current branch.
  # --ccxt-version X: fetch tag vX and check it out.
  # No flag: skip (existing behavior).
  defp update_ts_source(nil, false), do: :ok

  defp update_ts_source(nil, true) do
    case resolve_ccxt_dir() do
      {:ok, dir} ->
        Mix.shell().info("Updating TS source to latest...")
        # If on detached HEAD (e.g. after --ccxt-version tag checkout),
        # checkout the default branch first so pull has a tracking branch.
        ensure_on_branch(dir)

        case System.cmd("git", ["pull", "--ff-only"], cd: dir, stderr_to_stdout: true) do
          {output, 0} -> Mix.shell().info(String.trim(output))
          {output, _} -> Mix.raise("git pull failed: #{String.trim(output)}")
        end

      :not_git ->
        Mix.raise("priv/ccxt is not a git repo — cannot update TS source with --latest")
    end
  end

  defp update_ts_source(version, _force_latest?) do
    case resolve_ccxt_dir() do
      {:ok, dir} ->
        tag = "v#{version}"
        Mix.shell().info("Updating TS source to #{tag}...")

        with {_, 0} <-
               System.cmd("git", ["fetch", "origin", "tag", tag, "--depth", "1"], cd: dir, stderr_to_stdout: true),
             {_, 0} <- System.cmd("git", ["checkout", tag], cd: dir, stderr_to_stdout: true) do
          Mix.shell().info("TS source checked out at #{tag}.")
        else
          {output, _} ->
            Mix.raise("Could not checkout #{tag}: #{String.trim(output)}")
        end

      :not_git ->
        Mix.raise("priv/ccxt is not a git repo — cannot checkout version #{version}")
    end
  end

  # Resolves the real path of priv/ccxt, following symlinks.
  # Returns {:ok, dir} if it's a git repo, :not_git otherwise.
  # Handles worktrees/submodules where .git is a file (not a directory).
  defp resolve_ccxt_dir do
    ccxt_dir = CcxtExtract.Paths.priv("ccxt")

    ccxt_dir =
      case File.read_link(ccxt_dir) do
        {:ok, target} ->
          if Path.type(target) == :relative do
            ccxt_dir |> Path.dirname() |> Path.join(target) |> Path.expand()
          else
            target
          end

        _ ->
          ccxt_dir
      end

    # .git can be a directory (normal repo) or a file (worktree/submodule)
    if File.exists?(Path.join(ccxt_dir, ".git")) do
      {:ok, ccxt_dir}
    else
      :not_git
    end
  end

  # If HEAD is detached (e.g. after tag checkout), switch back to the default
  # branch so git pull has a tracking branch. Detects default via remote HEAD.
  defp ensure_on_branch(dir) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: dir, stderr_to_stdout: true) do
      {"HEAD\n", 0} ->
        # Detached — find default branch name from remote
        default = resolve_default_branch(dir)
        Mix.shell().info("Switching from detached HEAD to #{default}...")
        System.cmd("git", ["checkout", default], cd: dir, stderr_to_stdout: true)

      _ ->
        :ok
    end
  end

  defp resolve_default_branch(dir) do
    case System.cmd("git", ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], cd: dir, stderr_to_stdout: true) do
      {ref, 0} -> ref |> String.trim() |> String.replace_prefix("origin/", "")
      _ -> "master"
    end
  end

  # version_sensitive? is true when --latest or --ccxt-version was used,
  # meaning the user explicitly requested version sync. Mismatches are fatal.
  defp record_versions(version_sensitive?) do
    npm_version = @npm_package_json |> File.read!() |> Jason.decode!() |> Map.get("version")

    ts_package_json = CcxtExtract.Paths.priv(@ts_package_json_rel)

    ts_version =
      if File.exists?(ts_package_json) do
        ts_package_json |> File.read!() |> Jason.decode!() |> Map.get("version")
      else
        if version_sensitive? do
          Mix.raise("priv/ccxt/package.json not found — cannot verify TS source version matches npm")
        end

        Mix.shell().info("\nWARNING: priv/ccxt/package.json not found — cannot verify TS source version.")
        Mix.shell().info("If using sparse checkout, add package.json: git sparse-checkout add package.json")
        "unknown"
      end

    source_git_sha = resolve_git_sha()

    if ts_version != "unknown" and npm_version != ts_version do
      if version_sensitive? do
        Mix.raise("Version mismatch: npm bundle #{npm_version} != TS source #{ts_version}")
      end

      Mix.shell().info("\nWARNING: Version mismatch! npm bundle: #{npm_version}, TS source: #{ts_version}")
    end

    versions = %{
      "npm_version" => npm_version,
      "source_version" => ts_version,
      "source_git_sha" => source_git_sha,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    version_file = CcxtExtract.Paths.out_version_file()
    File.write!(version_file, Jason.encode!(versions, pretty: true))
    Mix.shell().info("\nVersions recorded to #{version_file}")
    versions
  end

  defp resolve_git_sha do
    case resolve_ccxt_dir() do
      {:ok, dir} ->
        case System.cmd("git", ["rev-parse", "HEAD"], cd: dir, stderr_to_stdout: true) do
          {sha, 0} -> String.trim(sha)
          _ -> "unknown"
        end

      :not_git ->
        "unknown"
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

    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))
    class = export.declaration
    class_name = if class.id, do: class.id.name, else: "anonymous"
    methods = Enum.filter(class.body.body, &(&1.type == :method_definition))

    Mix.shell().info(
      "OXC: parsed binance.ts in #{div(parse_us, 1000)}ms — #{class_name} with #{length(methods)} methods."
    )
  end
end
