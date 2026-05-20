defmodule Mix.Tasks.CcxtExtract.RateLimitCosts do
  @shortdoc "Extract per-endpoint rate-limit costs for all CCXT exchanges"

  @moduledoc """
  Extracts per-endpoint rate-limit cost weights for every non-alias
  exchange via QuickBEAM.

  For each exchange, walks the resolved `describe().api` map, records the
  cost weight for every `<section>.<verb>.<endpoint>` entry. Cost can be
  a bare number (CCXT's most common shape) or an object containing a
  `cost` key plus weight-axis variants (`noCoin`, `noSymbol`, `byLimit`,
  …) — both shapes are normalized to a uniform
  `%{"cost" => number, "axes" => %{...}}` record per endpoint.

  Writes a single JSON file to `priv/discoveries/rate_limit_costs.json`.
  Routes writes through `CcxtExtract.AggregateWriter` so scoped runs
  merge cleanly with the existing aggregate — out-of-scope entries are
  preserved, in-scope entries are replaced, `count` and
  `total_endpoints` are recomputed from the final list.

  ## Usage

      mix ccxt_extract.rate_limit_costs                     # full universe
      mix ccxt_extract.rate_limit_costs --tier1 --dex       # priority families
      mix ccxt_extract.rate_limit_costs --exchange binance  # single exchange
      mix ccxt_extract.rate_limit_costs --all               # explicit full run
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting per-endpoint rate-limit costs from CCXT exchanges...")

    {:ok, results} = CcxtExtract.RateLimitCosts.extract(scope: scope)
    CcxtExtract.RateLimitCosts.write!(results, scope: scope, tier_scope: tier_scope)

    Mix.shell().info("""
    Done. #{length(results)} exchanges extracted (aliases skipped).
    Output: priv/discoveries/rate_limit_costs.json
    """)
  end
end
