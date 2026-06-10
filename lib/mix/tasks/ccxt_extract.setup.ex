defmodule Mix.Tasks.CcxtExtract.Setup do
  @shortdoc "Install CCXT and verify extraction tools"

  @moduledoc """
  Sets up CCXT sources for extraction and verifies both tools work.

  1. Installs CCXT via `mix npm.install ccxt` (browser bundle for QuickBEAM)
  2. Copies the browser bundle to `priv/ccxt_bundle.js`
  3. Ensures TypeScript source exists at `priv/ccxt/ts/src/` (for OXC parsing).
     Auto-sparse-clones `https://github.com/ccxt/ccxt.git` (narrowed to
     `ts/src`) into `priv/ccxt` when missing — fresh clones and CI alike get
     a working corpus without manual setup. Skip the auto-clone with
     `--no-clone` or `CCXT_EXTRACT_SKIP_CLONE=1`.
  4. Verifies QuickBEAM can load the browser bundle and count exchanges
  5. Verifies OXC can parse a TypeScript exchange file

  ## Options

    * `--ccxt-version VERSION` — Pin a specific CCXT version (e.g., `4.5.45`).
      Without this flag, installs the latest version.
    * `--latest` — Force reinstall of the latest version, even if a bundle
      already exists. Useful in CI to ensure up-to-date extractions.
    * `--no-clone` — Opt out of auto-cloning `priv/ccxt` when missing. Setup
      will fail with the legacy "missing source" message instead. The env
      var `CCXT_EXTRACT_SKIP_CLONE=1` has the same effect.

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
  @default_ccxt_repo_url "https://github.com/ccxt/ccxt.git"

  # --latest forces reinstall even when bundle exists (ensures actual latest).
  # --ccxt-version pins a specific version and verifies after install.
  # --no-clone opts out of auto-cloning a missing priv/ccxt.
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

    # Skip the copy only when the dest bundle is byte-identical to the npm
    # one. The prior same-*size* heuristic let a same-size bundle from a
    # different CCXT version slip through stale — and since `record_versions/1`
    # hashes this file as the drift baseline, a stale bundle would poison
    # `Pipeline.check_version_drift!/1` (Task 114).
    if File.exists?(dest) &&
         CcxtExtract.Pipeline.bundle_sha256(@npm_bundle) ==
           CcxtExtract.Pipeline.bundle_sha256(dest) do
      Mix.shell().info("Bundle already in priv/, skipping copy.")
    else
      File.cp!(@npm_bundle, dest)
      Mix.shell().info("Copied browser bundle to #{dest}")
    end
  end

  @doc """
  Verifies `priv/ccxt/ts/src/` is present, auto-cloning a sparse checkout of
  the CCXT GitHub repo when it is not.

  The pinned version comes from `priv/ccxt_version.json` (`source_version`,
  falling back to `npm_version`). A `--ccxt-version X.Y.Z` opt overrides it.
  When `--latest` is supplied, the version pin is intentionally skipped so
  the clone targets the default branch (subsequent `update_ts_source/2` does
  the `git pull --ff-only`).

  ## Opt-out

  When the user explicitly opts out, this falls through to the legacy
  "missing source" error instead of cloning:

    * `--no-clone` flag (parsed by `run/1`).
    * `CCXT_EXTRACT_SKIP_CLONE=1` env var.

  Exposed as a public function (rather than `defp`) so the test suite can
  drive the auto-clone helper without standing up the full setup pipeline
  (npm install + QuickBEAM + OXC).
  """
  @spec check_ts_source(keyword()) :: :ok
  def check_ts_source(opts \\ []) do
    ts_check_file = CcxtExtract.Paths.priv(@ts_check_file_rel)

    cond do
      File.exists?(ts_check_file) ->
        announce_existing_source(ts_check_file)

      opt_out_auto_clone?(opts) ->
        raise_missing_ts_source!()

      true ->
        # --latest needs a tracking branch for the subsequent `git pull --ff-only`,
        # so skip the version pin entirely; otherwise we'd clone with `--branch
        # v<recorded>` and leave a detached HEAD that `update_ts_source(nil, true)`
        # cannot fast-forward.
        pinned_version =
          cond do
            Keyword.get(opts, :latest, false) -> nil
            v = Keyword.get(opts, :ccxt_version) -> v
            true -> read_pinned_version()
          end

        auto_clone_ts_source!(pinned_version)

        if File.exists?(ts_check_file) do
          announce_existing_source(ts_check_file)
        else
          Mix.raise(
            "Auto-clone completed but #{ts_check_file} is still missing — sparse-checkout may have excluded ts/src."
          )
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

  @doc """
  Returns `true` when the user opted out of auto-cloning.

  Honors the `--no-clone` flag (parsed into `opts` as `no_clone: true`) or
  `CCXT_EXTRACT_SKIP_CLONE` set to `"1"` / `"true"`.
  """
  @spec opt_out_auto_clone?(keyword()) :: boolean()
  def opt_out_auto_clone?(opts) do
    Keyword.get(opts, :no_clone, false) or
      System.get_env("CCXT_EXTRACT_SKIP_CLONE") in ["1", "true"]
  end

  @spec raise_missing_ts_source!() :: no_return()
  defp raise_missing_ts_source! do
    Mix.raise("""
    CCXT TypeScript source not found at priv/ccxt/ts/src/.

    Auto-clone is disabled (--no-clone or CCXT_EXTRACT_SKIP_CLONE=1).

    Either symlink an existing checkout:
        ln -s /path/to/ccxt priv/ccxt

    Or clone via sparse checkout:
        git clone --depth 1 --sparse https://github.com/ccxt/ccxt.git priv/ccxt
        cd priv/ccxt && git sparse-checkout set ts/src
    """)
  end

  @doc """
  Sparse-clones the CCXT GitHub repo into `priv/ccxt`, narrowed to `ts/src`.

  When `pinned_version` is supplied, clones with `--branch v<version>` so a
  fresh-clone setup matches the version recorded in
  `priv/ccxt_version.json` instead of drifting to whatever `main` currently
  is. With `nil`, falls back to the default branch.

  Raises `Mix.Error` if either the clone or the sparse-checkout narrowing
  step fails.
  """
  @spec auto_clone_ts_source!(String.t() | nil) :: :ok
  def auto_clone_ts_source!(pinned_version \\ nil) do
    ccxt_dir = CcxtExtract.Paths.out("ccxt")
    url = ccxt_repo_url()

    File.mkdir_p!(Path.dirname(ccxt_dir))

    # The cond in check_ts_source/1 already routed to announce_existing_source/1
    # when ts_check_file existed, so any surviving ccxt_dir here is a stale
    # half-populated checkout (failed sparse-checkout, mid-flight network drop,
    # etc.). Letting `git clone` abort on "destination exists" surfaces a
    # cryptic error; remove cleanly so the retry succeeds.
    if File.exists?(ccxt_dir) do
      File.rm_rf!(ccxt_dir)
    end

    Mix.shell().info(
      "CCXT TypeScript source missing — auto-cloning #{describe_clone_target(url, pinned_version)} into #{ccxt_dir}..."
    )

    clone_args = build_clone_args(url, ccxt_dir, pinned_version)

    case System.cmd("git", clone_args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _exit} ->
        Mix.raise("""
        Failed to auto-clone CCXT into #{ccxt_dir}:
        #{String.trim(output)}

        Resolve manually (see README), or skip the auto-clone with
        --no-clone / CCXT_EXTRACT_SKIP_CLONE=1.
        """)
    end

    case System.cmd("git", ["sparse-checkout", "set", "ts/src"],
           cd: ccxt_dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _exit} ->
        Mix.raise("""
        git sparse-checkout failed in #{ccxt_dir}:
        #{String.trim(output)}
        """)
    end

    Mix.shell().info("CCXT TypeScript source cloned (sparse: ts/src).")
    :ok
  end

  defp describe_clone_target(url, nil), do: "#{url} (default branch)"
  defp describe_clone_target(url, version), do: "#{url} at v#{version}"

  @doc """
  Builds the `git clone` argv list used by `auto_clone_ts_source!/1`.

  With `version: nil` produces a `--depth 1 --sparse` clone of the default
  branch. With a binary version produces `--depth 1 --branch v<version>
  --sparse`. Pure — no IO, kept testable to pin the exact argv shape.
  """
  @spec build_clone_args(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def build_clone_args(url, dir, nil) do
    ["clone", "--depth", "1", "--sparse", url, dir]
  end

  def build_clone_args(url, dir, version) when is_binary(version) do
    ["clone", "--depth", "1", "--branch", "v#{version}", "--sparse", url, dir]
  end

  @doc """
  Reads the CCXT source-version pin from `priv/ccxt_version.json`.

  Returns the `source_version` when populated, falling back to `npm_version`.
  Returns `nil` when the file is absent or unreadable — on a truly fresh
  clone where the file hasn't been committed yet, the auto-clone path falls
  back to the default branch.
  """
  @spec read_pinned_version(String.t() | nil) :: String.t() | nil
  def read_pinned_version(version_file \\ nil) do
    path = version_file || CcxtExtract.Paths.version_file()

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{} = data} <- Jason.decode(body) do
      Map.get(data, "source_version") || Map.get(data, "npm_version")
    else
      _ -> nil
    end
  end

  # Configurable for tests — production calls hit GitHub.
  defp ccxt_repo_url do
    Application.get_env(:ccxt_extract, :ccxt_repo_url, @default_ccxt_repo_url)
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
  @spec record_versions(boolean()) :: map()
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

    # Hash the browser bundle `copy_bundle_to_priv/0` just wrote.
    # `Pipeline.check_version_drift!/1` verifies this at pipeline entry,
    # turning a swapped/stale bundle into a loud failure (Task 114).
    bundle_sha256 = CcxtExtract.Pipeline.bundle_sha256(CcxtExtract.Paths.out_bundle())

    versions = %{
      "npm_version" => npm_version,
      "source_version" => ts_version,
      "source_git_sha" => source_git_sha,
      "bundle_sha256" => bundle_sha256,
      "recorded_at" => CcxtExtract.Clock.timestamp(:recorded_at)
    }

    version_file = CcxtExtract.Paths.out_version_file()
    File.write!(version_file, Jason.encode!(CcxtExtract.AstNormalize.to_encodable(versions), pretty: true))
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
