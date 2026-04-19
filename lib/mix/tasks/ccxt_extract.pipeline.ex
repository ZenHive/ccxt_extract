defmodule Mix.Tasks.CcxtExtract.Pipeline do
  @shortdoc "Assemble per-exchange JSON files from all extraction outputs"

  @moduledoc """
  Reads all discovery data and assembles validated per-exchange JSON files
  conforming to the `exchange_v2.json` schema.

  Each output file combines runtime data (describe, markets) and structural
  data (class hierarchy, method ASTs, overrides) into a single JSON document.
  The output directory also includes `_manifest.json` and `exchange_v2.json`.

      mix ccxt_extract.pipeline
      mix ccxt_extract.pipeline --output /tmp/exchange_output
      mix ccxt_extract.pipeline --strict
      mix ccxt_extract.pipeline --tier1 --dex
      mix ccxt_extract.pipeline --exchange binance,deribit

  ## Options

    * `--output` — custom output directory (default: `priv/output`)
    * `--strict` — fail with non-zero exit if validation errors or missing per-exchange files
    * `--pretty` — emit per-exchange JSON with indentation (~2× size; default
      compact). Useful for human inspection during debugging. Manifests,
      fixtures, and reports remain pretty-printed regardless of this flag.
    * `--tier1 --tier2 --tier3 --dex` — restrict assembly to the named priority
      tiers (combinable). Tier membership resolves via
      `priv/priority_tiers.json` with family inheritance.
    * `--exchange ID` — restrict to explicit exchange IDs. Accepts repeated
      flags and comma-separated values (e.g. `--exchange binance,kraken`).
      Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.
    * `--force` — bypass the git-status safety rail (see below).

  When no scope flag is given, all known exchanges are assembled (same as
  `--all`). The active scope is stamped into `_manifest.json` as `tier_scope`.

  Per-exchange JSON files outside the active scope are deleted from the
  output directory. Narrowed-scope runs are gated by a git-status safety
  rail: if the target output directory (`--output` if given, otherwise
  `priv/output/`) has uncommitted changes, the task aborts with a list of
  dirty paths. Commit or stash first, or pass `--force` to bypass (you
  will lose any scoped-out files on deletion). Full-universe runs
  (`--all` or no scope flag) skip the check — they overwrite, never prune.
  """

  use Mix.Task

  alias CcxtExtract.Scope
  alias CcxtExtract.TaskScope

  @progress_interval 20

  @switches Keyword.merge(
              [output: :string, strict: :boolean, force: :boolean, pretty: :boolean],
              TaskScope.scope_switches()
            )

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

    universe = TaskScope.load_universe()
    scope = TaskScope.resolve_scope!(opts, universe)
    enforce_git_safety_rail!(opts, scope)
    tier_scope = Scope.to_manifest_value(opts)

    Mix.shell().info("Assembling per-exchange JSON from discovery data#{scope_suffix(opts)}...")
    start = System.monotonic_time(:millisecond)

    case CcxtExtract.Pipeline.extract(scope: scope) do
      {:ok, exchanges, stats} ->
        report_progress(exchanges)
        output_dir = opts[:output] || CcxtExtract.Paths.out("output")
        elapsed = System.monotonic_time(:millisecond) - start

        if opts[:strict] && has_data_issues?(stats) do
          report_results(exchanges, stats, output_dir, elapsed)
          Mix.raise("Pipeline completed with issues (strict mode). See above for details.")
        else
          CcxtExtract.Pipeline.write!(exchanges, output_dir,
            tier_scope: tier_scope,
            pretty: opts[:pretty] || false
          )

          report_results(exchanges, stats, output_dir, elapsed)
        end

      {:error, {:missing_input, path}} ->
        Mix.raise("Missing required input: #{path}")
    end
  end

  # Full-universe runs overwrite without pruning, so the rail has nothing
  # to protect. Narrowed-scope runs prune out-of-scope files; gate them on
  # a clean git tree (or `--force`) to prevent silent loss of in-flight work.
  defp enforce_git_safety_rail!(_opts, :all), do: :ok

  defp enforce_git_safety_rail!(opts, _scope) do
    if !opts[:force] do
      dirty = collect_dirty_paths(safety_paths(opts))

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

  # Protects whichever directory Pipeline.write!/3 is actually about to
  # prune — that is, `opts[:output]` if given, otherwise the canonical
  # default. Tests can override the list entirely via
  # `config :ccxt_extract, #{__MODULE__}, safety_paths: [...]`.
  defp safety_paths(opts) do
    override =
      :ccxt_extract
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:safety_paths)

    if is_list(override) do
      override
    else
      [opts[:output] || CcxtExtract.Paths.out("output")]
    end
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
