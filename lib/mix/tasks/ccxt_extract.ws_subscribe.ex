defmodule Mix.Tasks.CcxtExtract.WsSubscribe do
  @shortdoc "Extract WebSocket subscribe/unsubscribe message shape + channel templates from CCXT WS source"

  @moduledoc """
  Extracts per-exchange WebSocket subscribe / unsubscribe message shape and
  per-method channel-name templates as raw facts for every WS exchange.

  Parses TypeScript source files in `pro/` via OXC and records, per exchange:
  the subscribe/unsubscribe frame envelope (the discriminant key, the
  subscribe and unsubscribe verbs, the channel-list carrier key, and the
  top-level keys of each request object) plus, per `watch*` method, the
  statically-resolvable channel-name templates (e.g. `"book.{symbol}.raw"`,
  `"tickers"`). Output is written to `priv/discoveries/ws_subscribe.json`.

  Entries are inheritance-free — each records only what its own file states.
  `extends`-chain inheritance is resolved later by
  `CcxtExtract.WsSubscribe.build/2` when the pipeline assembles the
  `websocket.subscribe` section.

      mix ccxt_extract.ws_subscribe
      mix ccxt_extract.ws_subscribe --tier1 --dex
      mix ccxt_extract.ws_subscribe --exchange binance,deribit

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

    Mix.shell().info("Extracting WebSocket subscribe/unsubscribe shapes from WS exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.WsSubscribe.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.WsSubscribe.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_envelope = Enum.count(exchanges, &(not is_nil(get_in(&1, ["envelope", "discriminant"]))))
    with_channels = Enum.count(exchanges, &(map_size(&1["channels"]) > 0))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} WS exchanges scanned, #{with_envelope} classify a subscribe envelope, #{with_channels} carry channel templates.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_subscribe.json
    """)
  end
end
