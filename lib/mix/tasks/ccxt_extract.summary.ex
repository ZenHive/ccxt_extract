defmodule Mix.Tasks.CcxtExtract.Summary do
  @shortdoc "Combine exchange metadata and class hierarchy into summary stats"

  @moduledoc """
  Reads `priv/discoveries/exchanges.json` (Task 2a) and
  `priv/discoveries/class_hierarchy.json` (Task 2b), computes aggregate
  statistics with family groupings, and writes the result.

  Writes output to `priv/discoveries/exchange_summary.json`.

      mix ccxt_extract.summary
      mix ccxt_extract.summary --tier1 --dex
      mix ccxt_extract.summary --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict the summary to the named
      priority tiers (combinable). Tier inheritance expands roots to their
      full family (e.g. `--tier1` includes the whole binance family).
    * `--exchange ID` — restrict to explicit exchange IDs (repeatable or
      comma-separated). Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`. The
  class inheritance tree and WS counterparts remain universe-wide (per
  `classes.ex` precedent) — only the `exchanges`, `classes`, and derived
  families/orphans reflect the scope.

  Requires both input files to exist. Run `mix ccxt_extract.exchanges` and
  `mix ccxt_extract.classes` first if they are missing.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Building exchange summary from discovery files...")

    case CcxtExtract.Summary.extract(scope) do
      {:ok, summary} ->
        CcxtExtract.Summary.write!(summary, tier_scope: tier_scope)
        print_summary(summary)

      {:error, {:missing_input, path}} ->
        Mix.raise("""
        Missing input file: #{path}

        Run these tasks first:
          mix ccxt_extract.exchanges    # generates exchanges.json
          mix ccxt_extract.classes      # generates class_hierarchy.json
        """)
    end
  end

  defp print_summary(summary) do
    counts = summary["counts"]
    ex = counts["exchanges"]
    cl = counts["classes"]
    families = summary["families"]

    top_families =
      families
      |> Enum.sort_by(&(-&1["total_members"]))
      |> Enum.take(10)
      |> Enum.map_join("\n", fn f ->
        ws = if f["has_ws"], do: "yes", else: " no"

        "  #{String.pad_trailing(f["root"], 20)} #{String.pad_leading(to_string(f["variant_count"]), 3)} variants  #{String.pad_leading(to_string(f["alias_count"]), 3)} aliases  WS: #{ws}"
      end)

    Mix.shell().info("""

    Exchange Summary
    ================
      Exchanges:  #{ex["total"]} total (#{ex["real"]} real, #{ex["aliases"]} aliases)
      Classes:    #{cl["total"]} total (#{cl["rest"]} REST, #{cl["ws"]} WS)
      Families:   #{counts["families"]}
      With WS:    #{counts["exchanges_with_ws"]}

    Top Exchange Families
    ---------------------
    #{top_families}

    Output: priv/discoveries/exchange_summary.json
    """)
  end
end
