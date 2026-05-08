defmodule Mix.Tasks.CcxtExtract.RequestHeaders do
  @shortdoc "Extract per-exchange user-agent + default HTTP headers"

  @moduledoc """
  Extracts per-exchange `userAgent` and default `headers` for every
  non-alias exchange via QuickBEAM.

  For each exchange, instantiates the CCXT class to trigger the
  `deepExtend(super.describe(), {...})` merge in the base Exchange
  constructor, then reads the resolved `userAgent` and `headers` instance
  fields. Output is an always-emit wrapper — `user_agent` is null and
  `default_headers` is `{}` for the ~90% of exchanges that don't override.

  Writes a single JSON file to `priv/discoveries/request_headers.json`.
  Routes writes through `CcxtExtract.AggregateWriter` so scoped runs merge
  cleanly with the existing aggregate — out-of-scope entries are preserved,
  in-scope entries are replaced, `count` is recomputed from the final list.

  ## Usage

      mix ccxt_extract.request_headers                     # full universe
      mix ccxt_extract.request_headers --tier1 --dex       # tier1 + DEX
      mix ccxt_extract.request_headers --exchange binance  # single exchange
      mix ccxt_extract.request_headers --all               # explicit full run
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting request_headers from CCXT exchanges...")

    {:ok, results} = CcxtExtract.RequestHeaders.extract(scope: scope)
    CcxtExtract.RequestHeaders.write!(results, scope: scope, tier_scope: tier_scope)

    Mix.shell().info("""
    Done. #{length(results)} exchanges extracted (aliases skipped).
    Output: priv/discoveries/request_headers.json
    """)
  end
end
