defmodule Mix.Tasks.CcxtExtract.WsTradesSemantics do
  @shortdoc "Extract WebSocket trades update semantics from CCXT WS source"

  @moduledoc """
  Extracts per-exchange WebSocket trades-channel update semantics as raw facts
  for every WS exchange.

  Parses TypeScript source files in `pro/` via OXC and records, per exchange:
  `handleTrade(s)` / `handleMyTrade(s)` presence, append/replace/snapshot
  update model, cache constructor type, deduplication id key, and the
  `tradesLimit` / `myTradesLimit` option read. Output is written to
  `priv/discoveries/ws_trades_semantics.json`.

      mix ccxt_extract.ws_trades_semantics
      mix ccxt_extract.ws_trades_semantics --tier1 --dex
      mix ccxt_extract.ws_trades_semantics --exchange binance,deribit
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting WebSocket trades semantics from WS exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.WsTradesSemantics.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.WsTradesSemantics.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_trades = Enum.count(exchanges, &get_in(&1, ["trades", "defined"]))
    with_my_trades = Enum.count(exchanges, &get_in(&1, ["my_trades", "defined"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} WS exchanges scanned, #{with_trades} define handleTrade(s), #{with_my_trades} define private myTrades handlers.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_trades_semantics.json
    """)
  end
end
