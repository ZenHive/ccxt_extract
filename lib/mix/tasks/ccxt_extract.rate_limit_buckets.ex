defmodule Mix.Tasks.CcxtExtract.RateLimitBuckets do
  @shortdoc "Extract per-exchange rate-limit bucket configuration"

  @moduledoc """
  Extracts per-exchange rate-limit bucket configuration for every
  non-alias exchange via QuickBEAM.

  For each exchange, instantiates the CCXT class so the base
  `Exchange.initRestRateLimiter()` runs, then reads the resolved
  `rateLimit` / `rollingWindowSize` / `rateLimiterAlgorithm` /
  `tokenBucket` instance fields. Output captures the canonical
  request-rate throttle plus rolling-window metadata for exchanges
  (e.g. binance) that ride a longer window on top of the base
  throttle.

  Writes a single JSON file to `priv/discoveries/rate_limit_buckets.json`.
  Routes writes through `CcxtExtract.AggregateWriter` so scoped runs merge
  cleanly with the existing aggregate — out-of-scope entries are
  preserved, in-scope entries are replaced, `count` is recomputed from the
  final list.

  ## Usage

      mix ccxt_extract.rate_limit_buckets                     # full universe
      mix ccxt_extract.rate_limit_buckets --tier1 --dex       # tier1 + DEX
      mix ccxt_extract.rate_limit_buckets --exchange binance  # single exchange
      mix ccxt_extract.rate_limit_buckets --all               # explicit full run
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting rate_limit_buckets from CCXT exchanges...")

    {:ok, results} = CcxtExtract.RateLimitBuckets.extract(scope: scope)
    CcxtExtract.RateLimitBuckets.write!(results, scope: scope, tier_scope: tier_scope)

    Mix.shell().info("""
    Done. #{length(results)} exchanges extracted (aliases skipped).
    Output: priv/discoveries/rate_limit_buckets.json
    """)
  end
end
