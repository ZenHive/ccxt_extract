defmodule Mix.Tasks.CcxtExtract.RawBroadcast do
  @shortdoc "Detect non-unified raw blockchain-broadcast endpoints via OXC"

  @moduledoc """
  Scans every exchange's TypeScript source for blockchain-broadcast signals
  and writes them to `priv/discoveries/raw_broadcast.json`.

  For each exchange the pass records DEX signing-library imports, EIP-712
  typed-data builder usage, and the async methods that (transitively) reach a
  signed-payload broadcast helper (`signL1Action`, `signUserSignedAction`,
  `signEIP712`, `starknetSign`, `createSignedRequest`). The pipeline promotes
  these methods into `transaction_classification` with `on_chain: true` and
  `transactional: true` (see `CcxtExtract.RawBroadcast`).

  Exchanges with no detected signal are omitted from the output.

      mix ccxt_extract.raw_broadcast
      mix ccxt_extract.raw_broadcast --dex
      mix ccxt_extract.raw_broadcast --exchange hyperliquid,paradex,grvt

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
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Scanning exchange method bodies for raw broadcast endpoints...")

    {:ok, all_exchanges, stats} = CcxtExtract.RawBroadcast.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.RawBroadcast.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_broadcast = Enum.count(exchanges, &(map_size(&1["broadcast_methods"]) > 0))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges with broadcast/signing signals (#{with_broadcast} with broadcast methods).
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/raw_broadcast.json
    """)
  end
end
