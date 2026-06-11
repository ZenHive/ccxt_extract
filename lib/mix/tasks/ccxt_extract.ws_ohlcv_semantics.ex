defmodule Mix.Tasks.CcxtExtract.WsOhlcvSemantics do
  @shortdoc "Extract WebSocket OHLCV (candle) update semantics from CCXT WS source"

  @moduledoc """
  Extracts per-exchange WebSocket OHLCV-channel update semantics as raw facts
  for every WS exchange.

  Parses TypeScript source files in `pro/` via OXC and records, per exchange:
  `handleOHLCV` presence, the `replace_latest_then_append` update model (when
  `ArrayCacheByTimestamp` is used), the timeframe dimension key, the closed/
  confirm signal field, the cache constructor, and the `OHLCVLimit` cache-limit
  field/default. Output is written to `priv/discoveries/ws_ohlcv_semantics.json`.

      mix ccxt_extract.ws_ohlcv_semantics
      mix ccxt_extract.ws_ohlcv_semantics --tier1 --dex
      mix ccxt_extract.ws_ohlcv_semantics --exchange binance,deribit
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting WebSocket OHLCV semantics from WS exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.WsOhlcvSemantics.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.WsOhlcvSemantics.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_ohlcv = Enum.count(exchanges, &get_in(&1, ["ohlcv", "defined"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} WS exchanges scanned, #{with_ohlcv} define handleOHLCV.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_ohlcv_semantics.json
    """)
  end
end
