defmodule Mix.Tasks.CcxtExtract.Overrides do
  @shortdoc "Extract method override data for derived CCXT exchanges"

  @moduledoc """
  Extracts method override data for every exchange that extends another exchange.

  Runs `Classes.extract/0` to get the class hierarchy, computes which methods
  are overridden vs. new vs. inherited for each derived class, then re-parses
  TypeScript source to extract full AST bodies for overridden and new methods.

  Exchanges that extend `Exchange` directly are excluded — all their methods
  are "new" by definition, which is not useful override data.

      mix ccxt_extract.overrides
      mix ccxt_extract.overrides --tier1 --dex
      mix ccxt_extract.overrides --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Scoped runs merge into the existing
      aggregate; out-of-scope entries are preserved.
    * `--exchange ID` — restrict to explicit exchange IDs. Typos fail
      loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`.

  Note: `Classes.extract/0` always runs over the full CCXT source tree
  (class hierarchy is universe-wide — see `CcxtExtract.Tiers` family
  inheritance). Scope filtering applies only to the output entries.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting method overrides for derived exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.Overrides.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.Overrides.write!(exchanges, scope: scope, tier_scope: tier_scope)

    class_error_count = length(stats.class_errors)
    override_error_count = length(stats.errors)

    if class_error_count > 0 do
      Mix.shell().error(
        "WARNING: #{class_error_count} class parse error(s) — hierarchy may be incomplete, some overrides could be misclassified as new methods."
      )
    end

    batch_stats = CcxtExtract.Overrides.write_stats(exchanges)

    Mix.shell().info("""
    Done. #{length(exchanges)} derived exchanges analyzed, \
    #{batch_stats["with_overrides"]} with overrides (#{batch_stats["total_overrides"]} total), \
    #{batch_stats["total_new_methods"]} new methods.
    #{if override_error_count > 0, do: "#{override_error_count} override parse error(s).", else: ""}
    Output: priv/discoveries/overrides.json
    """)
  end
end
