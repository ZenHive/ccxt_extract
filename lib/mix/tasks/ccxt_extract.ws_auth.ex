defmodule Mix.Tasks.CcxtExtract.WsAuth do
  @shortdoc "Extract WebSocket authentication-flow config from CCXT WS source"

  @moduledoc """
  Extracts per-exchange WebSocket authentication flow as raw facts for
  every WS exchange.

  Parses TypeScript source files in `pro/` via OXC and records, per exchange,
  the `authenticate` method: presence, `async`/arity, the `this.<credential>`
  reads, whether it sends a message over the socket, whether it touches a
  `listenKey`, and the sign-in request object literal (`op`/`method`
  discriminant + top-level keys). Output is written to
  `priv/discoveries/ws_auth.json`.

  Entries are inheritance-free — each records only what its own file's
  `authenticate` method states. `extends`-chain inheritance is resolved
  later by `CcxtExtract.WsAuth.build/2` when the pipeline assembles the
  `websocket.auth` section.

      mix ccxt_extract.ws_auth
      mix ccxt_extract.ws_auth --tier1 --dex
      mix ccxt_extract.ws_auth --exchange binance,deribit

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

    Mix.shell().info("Extracting WebSocket authentication flow from WS exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.WsAuth.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.WsAuth.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_auth = Enum.count(exchanges, &get_in(&1, ["authenticate", "defined"]))
    with_message = Enum.count(exchanges, &is_map(get_in(&1, ["authenticate", "message"])))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} WS exchanges scanned, #{with_auth} define authenticate(), #{with_message} build a sign-in message.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/ws_auth.json
    """)
  end
end
