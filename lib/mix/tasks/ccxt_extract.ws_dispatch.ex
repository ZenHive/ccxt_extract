defmodule Mix.Tasks.CcxtExtract.WsDispatch do
  @shortdoc "Extract WebSocket channel → parse-handler dispatch tables from CCXT WS source"

  @moduledoc """
  Extracts per-exchange WebSocket dispatch tables as raw facts for every WS
  exchange.

  Parses TypeScript source files in `pro/` via OXC and records, per exchange,
  the `handleMessage` method: the discriminator fields read off the frame
  (literal `safeString`/`safeValue` lookup keys), the channel → `handle*`
  handler entries (from object-literal handler maps and if-chain `===`
  comparisons), and any unrecognized dispatch shapes. Output is written to
  `priv/discoveries/ws_dispatch.json`.

  Entries are inheritance-free — each records only what its own file's
  `handleMessage` states. `extends`-chain inheritance is resolved later by
  `CcxtExtract.WsDispatch.build/2` when the pipeline assembles the
  `websocket.dispatch` section.

      mix ccxt_extract.ws_dispatch
      mix ccxt_extract.ws_dispatch --tier1 --dex
      mix ccxt_extract.ws_dispatch --exchange binance,deribit

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

    Mix.shell().info("Extracting WebSocket dispatch tables from WS exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.WsDispatch.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.WsDispatch.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_handle = Enum.count(exchanges, &get_in(&1, ["handle_message", "defined"]))
    with_entries = Enum.count(exchanges, &(get_in(&1, ["handle_message", "entries"]) not in [nil, []]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} WS exchanges scanned, #{with_handle} define handleMessage(), #{with_entries} resolve a dispatch table.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_dispatch.json
    """)
  end
end
