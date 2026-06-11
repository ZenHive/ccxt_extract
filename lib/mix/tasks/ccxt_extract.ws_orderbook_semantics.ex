defmodule Mix.Tasks.CcxtExtract.WsOrderbookSemantics do
  @shortdoc "Extract WebSocket orderbook snapshot/delta semantics from CCXT WS source"

  @moduledoc """
  Extracts per-exchange WebSocket orderbook snapshot/delta semantics as raw
  facts for every WS exchange.

  Parses TypeScript source files in `pro/` via OXC and records, per exchange,
  the orderbook handler methods: the snapshot/delta discriminator comparisons
  (`safeString` key + `===` literal), the integer-accessor sequence/ordering
  keys, the checksum field + `crc32` algorithm hint, and whether the handler
  applies deltas incrementally and/or resets the book. Output is written to
  `priv/discoveries/ws_orderbook_semantics.json`.

  Entries are inheritance-free — each records only what its own file's
  orderbook handlers state. `extends`-chain inheritance is resolved later by
  `CcxtExtract.WsOrderbookSemantics.build/2` when the pipeline assembles the
  `websocket.orderbook_semantics` section.

      mix ccxt_extract.ws_orderbook_semantics
      mix ccxt_extract.ws_orderbook_semantics --tier1 --dex
      mix ccxt_extract.ws_orderbook_semantics --exchange binance,deribit

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

    Mix.shell().info("Extracting WebSocket orderbook semantics from WS exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.WsOrderbookSemantics.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.WsOrderbookSemantics.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_handler = Enum.count(exchanges, &get_in(&1, ["orderbook", "defined"]))
    with_checksum = Enum.count(exchanges, &(get_in(&1, ["orderbook", "checksum", "present"]) == true))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} WS exchanges scanned, #{with_handler} define an orderbook handler, #{with_checksum} carry a checksum.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_orderbook_semantics.json
    """)
  end
end
