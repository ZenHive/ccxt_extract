defmodule Mix.Tasks.CcxtExtract.WsHeartbeat do
  @shortdoc "Extract WebSocket heartbeat (ping/pong) config from CCXT WS source"

  @moduledoc """
  Extracts per-exchange WebSocket heartbeat configuration as raw facts for
  every WS exchange.

  Parses TypeScript source files in `pro/` via OXC and records, per exchange:
  the `ping()` method (presence, return shape, decoded payload), the
  `pong`/`handlePong`/`handlePing` method presence, the `describe().streaming`
  block (`keepAlive`, `maxPingPongMisses`), and the `extends` superclass.
  Output is written to `priv/discoveries/ws_heartbeat.json`.

  Entries are inheritance-free — each records only what its own file states.
  `extends`-chain inheritance is resolved later by `CcxtExtract.WsHeartbeat.build/2`
  when the pipeline assembles the `websocket.heartbeat` section.

      mix ccxt_extract.ws_heartbeat
      mix ccxt_extract.ws_heartbeat --tier1 --dex
      mix ccxt_extract.ws_heartbeat --exchange binance,deribit

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Scoped runs merge into the existing
      aggregate; out-of-scope entries are preserved.
    * `--exchange ID` — restrict to explicit exchange IDs. Typos fail
      loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting WebSocket heartbeat config from WS exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.WsHeartbeat.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.WsHeartbeat.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_ping = Enum.count(exchanges, &get_in(&1, ["ping", "defined"]))
    with_streaming = Enum.count(exchanges, &get_in(&1, ["streaming", "present"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} WS exchanges scanned, #{with_ping} define ping(), #{with_streaming} carry a streaming block.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_heartbeat.json
    """)
  end
end
