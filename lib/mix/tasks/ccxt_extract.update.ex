defmodule Mix.Tasks.CcxtExtract.Update do
  @shortdoc "Re-extract all exchange data (setup → extractors → pipeline → validate → analytics)"

  @moduledoc """
  Orchestrates a full re-extraction: updates CCXT sources, runs the pipeline,
  validates output, refreshes derived analytics, and reports what changed.

      mix ccxt_extract.update
      mix ccxt_extract.update --latest --output /tmp/exchanges
      mix ccxt_extract.update --ccxt-version 4.5.45 --strict
      mix ccxt_extract.update --skip-setup --output /tmp/exchanges

  ## Options

    * `--output DIR` — custom output directory (default: `priv/output`)
    * `--ccxt-version VERSION` — pin a specific CCXT version
    * `--latest` — force reinstall of the latest CCXT version
    * `--strict` — fail with non-zero exit on validation errors
    * `--skip-setup` — skip stages 1-3 (setup + all extractors), re-run only pipeline + validate + analytics

  ## Stages

  1. **Setup** — install/update CCXT sources (`mix ccxt_extract.setup`)
  2. **QuickBEAM Extractors** — runtime values: exchange metadata, describe(), loadMarkets()
  3. **OXC Extractors** — AST parsing: classes, methods, sign, parse, ws, pagination, unified endpoints, overrides
  4. **Pipeline** — assemble per-exchange JSON (`mix ccxt_extract.pipeline`)
  5. **Validate** — schema + round-trip validation (`mix ccxt_extract.validate`)
  6. **Analytics** — derived artifacts: coverage, summary, family analysis, method analysis,
     market validation, public exchanges. QuickBEAM-dependent analytics
     (describe_keys, describe_key_analysis) are skipped with `--skip-setup`.

  Each stage's failure halts subsequent stages. After all stages complete,
  a diff summary shows what changed compared to the previous extraction.
  """

  use Mix.Task

  @default_setup_task "ccxt_extract.setup"
  @default_pipeline_task "ccxt_extract.pipeline"
  @default_validate_task "ccxt_extract.validate"

  @switches [
    output: :string,
    ccxt_version: :string,
    latest: :boolean,
    strict: :boolean,
    skip_setup: :boolean
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

    output_dir = opts[:output] || CcxtExtract.Paths.priv("output")
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
      run_quickbeam_extractors()

      Mix.shell().info("\n── Stage 3: OXC Extractors ──")
      run_oxc_extractors()
    end

    # Stage 4: Pipeline
    Mix.shell().info("\n── Stage 4: Pipeline ──")
    Mix.Task.rerun(task_override(:pipeline_task, @default_pipeline_task), build_pipeline_args(opts))

    # Stage 5: Validate
    Mix.shell().info("\n── Stage 5: Validate ──")
    Mix.Task.rerun(task_override(:validate_task, @default_validate_task), build_validate_args(opts))

    # Stage 6: Derived analytics
    Mix.shell().info("\n── Stage 6: Analytics ──")
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

  # Builds arg list for pipeline task
  defp build_pipeline_args(opts) do
    args = []
    args = if opts[:output], do: ["--output", opts[:output] | args], else: args
    args = if opts[:strict], do: ["--strict" | args], else: args
    args
  end

  # Builds arg list for validate task
  defp build_validate_args(opts) do
    args = []
    args = if opts[:output], do: ["--output", opts[:output] | args], else: args
    args = if opts[:strict], do: ["--strict" | args], else: args
    args
  end

  # QuickBEAM extractors — require JS runtime, some make live API calls.
  # Order matters: exchanges must run first (produces exchanges.json used by others).
  @default_quickbeam_extractors ~w(
    ccxt_extract.exchanges
    ccxt_extract.describe
    ccxt_extract.load_markets
  )

  defp run_quickbeam_extractors do
    for task <- task_override(:quickbeam_extractors, @default_quickbeam_extractors) do
      Mix.Task.rerun(task, [])
    end
  end

  # OXC-based extractors — fast AST parsing, no API calls.
  @default_oxc_extractors ~w(
    ccxt_extract.classes
    ccxt_extract.methods
    ccxt_extract.sign_methods
    ccxt_extract.handle_errors
    ccxt_extract.parse_methods
    ccxt_extract.ws_methods
    ccxt_extract.interface_signatures
    ccxt_extract.pagination
    ccxt_extract.unified_endpoints
    ccxt_extract.overrides
    ccxt_extract.base_methods
  )

  defp run_oxc_extractors do
    for task <- task_override(:oxc_extractors, @default_oxc_extractors) do
      Mix.Task.rerun(task, [])
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

  defp run_analytics(opts) do
    if !opts[:skip_setup] do
      for task <- task_override(:quickbeam_analytics, @default_quickbeam_analytics) do
        Mix.Task.rerun(task, [])
      end
    end

    for task <- task_override(:derived_analytics, @default_derived_analytics) do
      Mix.Task.rerun(task, [])
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
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
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
