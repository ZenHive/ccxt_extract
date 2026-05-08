defmodule Mix.Tasks.CcxtExtract.Update do
  @shortdoc "Re-extract all exchange data (setup → extractors → pipeline → validate → contract_test → analytics)"

  @moduledoc """
  Orchestrates a full re-extraction: updates CCXT sources, runs the pipeline,
  validates output, refreshes derived analytics, and reports what changed.

      mix ccxt_extract.update
      mix ccxt_extract.update --latest --output /tmp/ccxt_priv
      mix ccxt_extract.update --ccxt-version 4.5.45 --strict
      mix ccxt_extract.update --skip-setup --output /tmp/ccxt_priv

  ## Options

    * `--output DIR` — root directory for all writes (default: this project's
      `priv/`). Intermediates land at `<DIR>/discoveries/`, final per-exchange
      JSON at `<DIR>/output/`. This redirects every extractor, pipeline, and
      analytics write via `:priv_dir_override`, so zero files are mutated
      under this project's `priv/`. **Breaking change**: previously this
      flag controlled only the final output dir, so `--output /foo` placed
      JSON directly at `/foo/`. It is now at `/foo/output/`.
    * `--ccxt-version VERSION` — pin a specific CCXT version
    * `--latest` — force reinstall of the latest CCXT version
    * `--strict` — fail with non-zero exit on validation errors
    * `--skip-setup` — skip stages 1-3 (setup + all extractors), re-run only pipeline + validate + contract_test + analytics
    * `--tier1 --tier2 --tier3 --dex` — restrict scope to the named priority
      tiers (combinable). Scope-aware stages: pipeline (new), `load_markets`,
      and `contract_test`. Other extractors run full-universe; remaining
      stage fan-out is tracked as tasks 3–7 in `SCOPED-EXTRACTION-TASKS.md`.
    * `--exchange ID` — restrict scope to explicit exchange IDs. Repeatable
      and comma-separated (e.g. `--exchange binance,kraken`).
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.
    * `--force` — bypass the git-status safety rail. Without this, the task
      aborts when `priv/output/` or `priv/discoveries/` has uncommitted
      changes so a scoped re-run cannot silently delete in-flight work.
    * `--pretty` — emit per-exchange JSON with indentation (~2× size; default
      compact). Forwarded to the pipeline stage. Manifests, fixtures, and
      reports remain pretty-printed regardless of this flag.
    * `--schema-target N` — forwarded to the pipeline + validate stages.
      `3` (default) emits the v3 published shape; `4` emits the gated
      v4 reshape (Task 130).

  ## Stages

  1. **Setup** — install/update CCXT sources (`mix ccxt_extract.setup`)
  2. **QuickBEAM Extractors** — runtime values: exchange metadata, describe(), loadMarkets()
  3. **OXC Extractors** — AST parsing: classes, methods, sign, parse, ws, pagination, unified endpoints, overrides
  4. **Pipeline** — assemble per-exchange JSON (`mix ccxt_extract.pipeline`)
  5. **Validate** — schema + round-trip validation (`mix ccxt_extract.validate`)
  6. **Contract Tests** — cross-field semantic invariants (`mix ccxt_extract.contract_test`).
     Non-strict: prints report, does not halt the pipeline. Run with `--strict` directly
     (`mix ccxt_extract.contract_test --strict`) for CI / pre-commit use.
  7. **Analytics** — derived artifacts: coverage, summary, family analysis, method analysis,
     market validation, public exchanges. QuickBEAM-dependent analytics
     (describe_keys, describe_key_analysis) are skipped with `--skip-setup`.

  Each stage's failure halts subsequent stages. After all stages complete,
  a diff summary shows what changed compared to the previous extraction.
  """

  use Mix.Task

  @default_setup_task "ccxt_extract.setup"
  @default_pipeline_task "ccxt_extract.pipeline"
  @default_validate_task "ccxt_extract.validate"
  @default_contract_test_task "ccxt_extract.contract_test"

  @switches [
    output: :string,
    ccxt_version: :string,
    latest: :boolean,
    strict: :boolean,
    skip_setup: :boolean,
    tier1: :boolean,
    tier2: :boolean,
    tier3: :boolean,
    dex: :boolean,
    all: :boolean,
    exchange: :keep,
    force: :boolean,
    pretty: :boolean,
    schema_target: :integer
  ]

  @aliases [v: :ccxt_version]

  @impl true
  def run(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    with_priv_override(opts, fn -> do_run(opts) end)
  end

  # Wraps the run body in `:priv_dir_override` when `--output` is given, so
  # every `Paths.priv/1` and `Paths.out/1` call in any sub-stage lands under
  # the client's directory. Restores prior env (or deletes) on exit.
  defp with_priv_override(opts, fun) do
    case opts[:output] do
      nil ->
        fun.()

      path ->
        resolved = Path.expand(path)
        prior = Application.get_env(:ccxt_extract, :priv_dir_override)
        Application.put_env(:ccxt_extract, :priv_dir_override, resolved)

        try do
          fun.()
        after
          case prior do
            nil -> Application.delete_env(:ccxt_extract, :priv_dir_override)
            val -> Application.put_env(:ccxt_extract, :priv_dir_override, val)
          end
        end
    end
  end

  defp do_run(opts) do
    enforce_git_safety_rail!(opts)

    output_dir = CcxtExtract.Paths.out("output")
    manifest_path = Path.join(output_dir, "_manifest.json")

    Mix.shell().info("Starting full update...")
    start = System.monotonic_time(:millisecond)

    # Snapshot existing manifest before any changes
    old_manifest = read_manifest(manifest_path)

    # Stages 1-3: Setup + Extractors (skip when --skip-setup)
    if !opts[:skip_setup] do
      Mix.shell().info("\n── Stage 1: Setup ──")
      Mix.Task.rerun(task_override(:setup_task, @default_setup_task), build_setup_args(opts))

      Mix.shell().info("\n── Stage 2: QuickBEAM Extractors ──")
      run_quickbeam_extractors(opts)

      Mix.shell().info("\n── Stage 3: OXC Extractors ──")
      run_oxc_extractors(opts)
    end

    # Stage 4: Pipeline
    Mix.shell().info("\n── Stage 4: Pipeline ──")
    Mix.Task.rerun(task_override(:pipeline_task, @default_pipeline_task), build_pipeline_args(opts))

    # Stage 5: Validate
    Mix.shell().info("\n── Stage 5: Validate ──")
    Mix.Task.rerun(task_override(:validate_task, @default_validate_task), build_validate_args(opts))

    # Stage 6: Contract tests (non-strict — prints findings, never halts pipeline)
    Mix.shell().info("\n── Stage 6: Contract Tests ──")

    Mix.Task.rerun(
      task_override(:contract_test_task, @default_contract_test_task),
      build_contract_test_args(opts)
    )

    # Stage 7: Derived analytics
    Mix.shell().info("\n── Stage 7: Analytics ──")
    run_analytics(opts)

    # Diff summary
    new_manifest = read_manifest(manifest_path)
    elapsed = System.monotonic_time(:millisecond) - start

    Mix.shell().info("\n── Summary ──")
    report_diff(old_manifest, new_manifest)
    Mix.shell().info("Total time: #{format_elapsed(elapsed)}")
  end

  # Builds arg list for setup task
  defp build_setup_args(opts) do
    args = []
    args = if opts[:ccxt_version], do: ["--ccxt-version", opts[:ccxt_version] | args], else: args
    args = if opts[:latest], do: ["--latest" | args], else: args
    args
  end

  # Sub-stage arg builders. `--output` is NOT forwarded: sub-stages resolve
  # their output directory via `Paths.out/1`, which picks up the
  # `:priv_dir_override` set by `with_priv_override/2` at the update level.
  defp build_pipeline_args(opts) do
    args = []
    args = if opts[:strict], do: ["--strict" | args], else: args
    args = if opts[:force], do: ["--force" | args], else: args
    args = if opts[:pretty], do: ["--pretty" | args], else: args
    args = schema_target_args(opts) ++ args
    args ++ scope_args(opts)
  end

  defp build_validate_args(opts) do
    base = if opts[:strict], do: ["--strict"], else: []
    schema_target_args(opts) ++ base
  end

  defp schema_target_args(opts) do
    case opts[:schema_target] do
      nil -> []
      n when n in [3, 4] -> ["--schema-target", Integer.to_string(n)]
      other -> Mix.raise("Invalid --schema-target #{inspect(other)}; expected 3 or 4")
    end
  end

  # `--strict` is omitted by design: contract_test prints findings and keeps
  # the pipeline going. Run the task directly with `--strict` for CI.
  defp build_contract_test_args(opts), do: scope_args(opts)

  # QuickBEAM extractors — require JS runtime, some make live API calls.
  # Order matters: exchanges must run first (produces exchanges.json used by others).
  @default_quickbeam_extractors ~w(
    ccxt_extract.exchanges
    ccxt_extract.describe
    ccxt_extract.load_markets
    ccxt_extract.url_templates
    ccxt_extract.request_headers
    ccxt_extract.rate_limit_buckets
    ccxt_extract.signing_fixtures
  )

  defp run_quickbeam_extractors(opts) do
    for task <- task_override(:quickbeam_extractors, @default_quickbeam_extractors) do
      Mix.Task.rerun(task, scope_args(opts))
    end
  end

  # Full scope passthrough — pipeline accepts every scope selector.
  # Order: --all (if set), then --tier* in canonical order, then
  # --exchange VALUE per explicit ID (sorted).
  defp scope_args(opts) do
    all_flag = if opts[:all], do: ["--all"], else: []
    exchange_flags = opts |> exchange_ids() |> Enum.flat_map(&["--exchange", &1])

    all_flag ++ tier_flag_args(opts) ++ exchange_flags
  end

  defp tier_flag_args(opts) do
    [:tier1, :tier2, :tier3, :dex]
    |> Enum.filter(&Keyword.get(opts, &1))
    |> Enum.map(&"--#{&1}")
  end

  defp exchange_ids(opts) do
    opts
    |> Keyword.get_values(:exchange)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Abort early if `priv/output/` or `priv/discoveries/` contains uncommitted
  # changes. `--force` bypasses the rail for intentional re-runs over dirty
  # trees. Skipped when `--output` is set: external targets are not expected
  # to be git repos and would trip the rail spuriously.
  defp enforce_git_safety_rail!(opts) do
    cond do
      opts[:force] -> :ok
      opts[:output] -> :ok
      true -> do_enforce_git_safety_rail!()
    end
  end

  defp do_enforce_git_safety_rail! do
    dirty = collect_dirty_paths(safety_paths())

    if dirty != [] do
      listing = Enum.map_join(dirty, "\n", &"  #{&1}")

      Mix.raise("""
      Refusing to run: uncommitted changes detected in protected paths.

      #{listing}

      Commit or stash these files first, or re-run with --force to bypass
      the safety rail (you will lose any scoped-out files on deletion).
      """)
    end
  end

  defp collect_dirty_paths(paths), do: Enum.flat_map(paths, &dirty_lines_for/1)

  defp dirty_lines_for(path) do
    if File.dir?(path) do
      case CcxtExtract.ScopeCleanup.git_status_clean?(".", cd: path) do
        :ok -> []
        {:error, lines} -> Enum.map(lines, &"#{path}: #{&1}")
      end
    else
      []
    end
  end

  # Resolves the safety-rail paths, allowing tests to override via
  # `config :ccxt_extract, #{__MODULE__}, safety_paths: [...]`. Defaults to
  # the project's own write targets, computed at call time so tests that set
  # `:priv_dir_override` / `:priv_write_override` stay isolated from the
  # real `priv/`.
  defp safety_paths do
    configured =
      :ccxt_extract
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:safety_paths)

    configured || [CcxtExtract.Paths.priv("output"), CcxtExtract.Paths.priv("discoveries")]
  end

  # OXC-based extractors — fast AST parsing, no API calls.
  #
  # Each entry is `{task, :scoped | :unscoped}`:
  #   :scoped   — receives the full scope flag set (`--tier1 --dex ...`)
  #   :unscoped — invoked with `[]`; the extractor has no per-exchange
  #               dimension, so forwarding scope flags would be a silent
  #               lie (Honesty Rule). `base_methods` parses a single file
  #               (base/Exchange.ts) and is the canonical example.
  #
  # When adding a new extractor, pick the tag at the data definition site —
  # the destructure in `run_oxc_extractors/1` enforces that a choice is made.
  @default_oxc_extractors [
    {"ccxt_extract.classes", :scoped},
    {"ccxt_extract.methods", :scoped},
    {"ccxt_extract.sign_methods", :scoped},
    {"ccxt_extract.handle_errors", :scoped},
    {"ccxt_extract.parse_methods", :scoped},
    {"ccxt_extract.ws_methods", :scoped},
    {"ccxt_extract.interface_signatures", :scoped},
    {"ccxt_extract.pagination", :scoped},
    {"ccxt_extract.unified_endpoints", :scoped},
    {"ccxt_extract.request_defaults", :scoped},
    {"ccxt_extract.overrides", :scoped},
    {"ccxt_extract.base_methods", :unscoped},
    {"ccxt_extract.error_class_hierarchy", :unscoped}
  ]

  defp run_oxc_extractors(opts) do
    scope = scope_args(opts)

    for {task, mode} <- task_override(:oxc_extractors, @default_oxc_extractors) do
      args = if mode == :unscoped, do: [], else: scope
      Mix.Task.rerun(task, args)
    end
  end

  # Analytics that depend on QuickBEAM JS runtime.
  @default_quickbeam_analytics ~w(
    ccxt_extract.describe_keys
    ccxt_extract.describe_key_analysis
  )

  # Derived analytics — safe to run from cached discovery data only.
  # Order: family_analysis needs summary + describe data.
  @default_derived_analytics ~w(
    ccxt_extract.summary
    ccxt_extract.coverage
    ccxt_extract.method_analysis
    ccxt_extract.public_exchanges
    ccxt_extract.validate_markets
    ccxt_extract.family_analysis
  )

  # Threads scope flags through every analytic. All 8 analytic tasks accept the
  # canonical scope flag set (`--tier*/--all/--exchange`) — Honesty Rule, no
  # `:unscoped` carve-out (parallel to `run_oxc_extractors/1` where
  # `ccxt_extract.base_methods` legitimately ignores scope; no analytic does).
  defp run_analytics(opts) do
    scope = scope_args(opts)

    if !opts[:skip_setup] do
      for task <- task_override(:quickbeam_analytics, @default_quickbeam_analytics) do
        Mix.Task.rerun(task, scope)
      end
    end

    for task <- task_override(:derived_analytics, @default_derived_analytics) do
      Mix.Task.rerun(task, scope)
    end
  end

  # Returns test override for the given key, or the default.
  # Test-only overrides let orchestration be verified without running extraction.
  defp task_override(key, default) do
    :ccxt_extract
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  @doc "Reads and decodes a JSON manifest file, returning nil on failure."
  @spec read_manifest(Path.t()) :: map() | nil
  def read_manifest(path) do
    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, data} -> data
      {:error, _} -> nil
    end
  end

  @doc "Prints a summary comparing old and new extraction manifests."
  @spec report_diff(map() | nil, map() | nil) :: :ok
  def report_diff(nil, _new) do
    Mix.shell().info("First extraction — no previous data to compare.")
  end

  def report_diff(_old, nil) do
    Mix.shell().info("Warning: no manifest found after pipeline. Output may have failed.")
  end

  def report_diff(old, new) do
    report_version_change(old["ccxt_version"], new["ccxt_version"])
    report_exchange_change(old["exchanges"] || [], new["exchanges"] || [])
  end

  defp report_version_change(same, same), do: Mix.shell().info("CCXT version: #{same} (unchanged)")

  defp report_version_change(old, new), do: Mix.shell().info("CCXT: #{old} → #{new}")

  defp report_exchange_change(old_list, new_list) do
    added = Enum.sort(new_list -- old_list)
    removed = Enum.sort(old_list -- new_list)
    delta = length(new_list) - length(old_list)

    delta_str =
      cond do
        delta > 0 -> " (+#{delta})"
        delta < 0 -> " (#{delta})"
        true -> " (unchanged)"
      end

    Mix.shell().info("Exchanges: #{length(old_list)} → #{length(new_list)}#{delta_str}")

    if added != [], do: Mix.shell().info("  Added: #{Enum.join(added, ", ")}")
    if removed != [], do: Mix.shell().info("  Removed: #{Enum.join(removed, ", ")}")
  end

  defp format_elapsed(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_elapsed(ms), do: "#{Float.round(ms / 1_000, 1)}s"
end
