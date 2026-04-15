defmodule Mix.Tasks.CcxtExtract.Pipeline do
  @shortdoc "Assemble per-exchange JSON files from all extraction outputs"

  @moduledoc """
  Reads all discovery data and assembles validated per-exchange JSON files
  conforming to the `exchange_v1.json` schema.

  Each output file combines runtime data (describe, markets) and structural
  data (class hierarchy, method ASTs, overrides) into a single JSON document.
  The output directory also includes `_manifest.json` and `exchange_v1.json`.

      mix ccxt_extract.pipeline
      mix ccxt_extract.pipeline --output /tmp/exchange_output
      mix ccxt_extract.pipeline --strict
      mix ccxt_extract.pipeline --tier1 --dex
      mix ccxt_extract.pipeline --exchange binance,deribit

  ## Options

    * `--output` — custom output directory (default: `priv/output`); per-exchange
      JSON files outside the active scope are deleted automatically
    * `--strict` — fail with non-zero exit if validation errors or missing per-exchange files
    * `--tier1 --tier2 --tier3 --dex` — restrict assembly to the named priority
      tiers (combinable). Tier membership resolves via
      `priv/priority_tiers.json` with family inheritance.
    * `--exchange ID` — restrict to explicit exchange IDs. Accepts repeated
      flags and comma-separated values (e.g. `--exchange binance,kraken`).
      Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  When no scope flag is given, all known exchanges are assembled (same as
  `--all`). The active scope is stamped into `_manifest.json` as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.Scope

  @progress_interval 20

  @switches [
    output: :string,
    strict: :boolean,
    tier1: :boolean,
    tier2: :boolean,
    tier3: :boolean,
    dex: :boolean,
    all: :boolean,
    exchange: :keep
  ]

  @impl true
  def run(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    universe = load_universe()
    scope = resolve_scope!(opts, universe)
    tier_scope = Scope.to_manifest_value(opts)

    Mix.shell().info("Assembling per-exchange JSON from discovery data#{scope_suffix(opts)}...")
    start = System.monotonic_time(:millisecond)

    case CcxtExtract.Pipeline.extract(scope: scope) do
      {:ok, exchanges, stats} ->
        report_progress(exchanges)
        output_dir = opts[:output] || CcxtExtract.Paths.priv("output")
        CcxtExtract.Pipeline.write!(exchanges, output_dir, tier_scope: tier_scope)

        elapsed = System.monotonic_time(:millisecond) - start
        has_issues = report_results(exchanges, stats, output_dir, elapsed)

        if opts[:strict] && has_issues do
          Mix.raise("Pipeline completed with issues (strict mode). See above for details.")
        end

      {:error, {:missing_input, path}} ->
        Mix.raise("Missing required input: #{path}")
    end
  end

  defp load_universe do
    path = Path.join(CcxtExtract.Paths.priv("discoveries"), "exchanges.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"exchanges" => exchanges}} when is_list(exchanges) ->
            Enum.map(exchanges, & &1["id"])

          _ ->
            Mix.raise("Corrupt #{path}: expected top-level \"exchanges\" list")
        end

      {:error, _} ->
        Mix.raise("Missing #{path}. Run `mix ccxt_extract.exchanges` first.")
    end
  end

  defp resolve_scope!(opts, universe) do
    case Scope.resolve(opts, universe) do
      {:ok, _ids, :all} ->
        :all

      {:ok, ids, {:scoped, label}} ->
        Mix.shell().info("Scope: #{label}")
        MapSet.new(ids)

      {:error, {:unknown_exchange, bad_ids, suggestions}} ->
        Mix.raise(format_unknown_exchange(bad_ids, suggestions))

      {:error, {:all_with_narrowing, conflicting}} ->
        flags = Enum.map_join(conflicting, ", ", &"--#{&1}")
        Mix.raise("--all conflicts with narrowing flag(s): #{flags}")
    end
  end

  defp format_unknown_exchange(bad_ids, suggestions) do
    bad_ids
    |> Enum.map_join("\n", fn id ->
      case Map.get(suggestions, id, []) do
        [] -> "  • #{id} (no close matches)"
        matches -> "  • #{id} (did you mean: #{Enum.join(matches, ", ")}?)"
      end
    end)
    |> then(&"Unknown --exchange ID(s):\n#{&1}")
  end

  defp scope_suffix(opts) do
    case Scope.to_manifest_value(opts) do
      "all" -> ""
      scoped -> " (scope: #{Enum.join(scoped, ", ")})"
    end
  end

  defp report_progress(exchanges) do
    total = length(exchanges)

    if total > @progress_interval do
      Mix.shell().info("  Assembled #{total} exchanges.")
    end
  end

  # Returns true if there are issues (for --strict mode)
  defp report_results(exchanges, stats, output_dir, elapsed) do
    validation_line =
      if stats.validation_errors == [],
        do: "All exchanges passed validation.",
        else: "#{length(stats.validation_errors)} validation error(s)."

    detail_lines =
      [
        stat_line("Missing discovery files", stats.missing_files, &Enum.join(&1, ", ")),
        stat_line("Missing per-exchange files", stats.missing_entries, &format_missing_entries/1),
        stat_line("Corrupt discovery entries", stats.corrupt_entries, &format_missing_entries/1),
        stat_line("Orphan artifacts", stats.orphan_entries, &format_missing_entries/1),
        stat_line("ID mismatches", stats.id_mismatch_entries, &format_missing_entries/1)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Mix.shell().info("""
    Done in #{elapsed}ms. #{length(exchanges)} exchanges assembled.
    #{validation_line}
    #{detail_lines}
    Output: #{output_dir}/
    """)

    has_data_issues?(stats)
  end

  defp stat_line(_label, [], _formatter), do: nil
  defp stat_line(label, entries, formatter), do: "#{label} (#{length(entries)}): #{formatter.(entries)}"

  defp has_data_issues?(stats) do
    stats.validation_errors != [] or stats.missing_entries != [] or
      stats.corrupt_entries != [] or stats.orphan_entries != [] or
      stats.id_mismatch_entries != []
  end

  @max_displayed_entries 10

  defp format_missing_entries(entries) do
    displayed = Enum.take(entries, @max_displayed_entries)
    suffix = if length(entries) > @max_displayed_entries, do: ", ...", else: ""
    Enum.join(displayed, ", ") <> suffix
  end
end
