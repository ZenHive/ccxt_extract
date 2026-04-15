defmodule Mix.Tasks.CcxtExtract.InterfaceSignatures do
  @shortdoc "Extract interface method signatures from CCXT abstract TypeScript files"

  @moduledoc """
  Extracts typed API method signatures from abstract interface declarations.

  Parses `priv/ccxt/ts/src/abstract/*.ts` via OXC, finds the `Exchange`
  interface in each file, and writes all method signatures (name, params,
  return type) to `priv/discoveries/interface_signatures.json`.

      mix ccxt_extract.interface_signatures
      mix ccxt_extract.interface_signatures --tier1 --dex
      mix ccxt_extract.interface_signatures --exchange binance

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

    Mix.shell().info("Extracting interface signatures from abstract exchange files...")

    {:ok, all_exchanges, stats} = CcxtExtract.InterfaceSignatures.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.InterfaceSignatures.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_sigs = Enum.count(exchanges, fn e -> e["interface_signature_count"] > 0 end)
    total_sigs = Enum.sum(Enum.map(exchanges, & &1["interface_signature_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_sigs} with signatures, #{total_sigs} total signatures.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/interface_signatures.json
    """)
  end
end
