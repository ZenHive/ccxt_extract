defmodule Mix.Tasks.CcxtExtract.SignMethods do
  @shortdoc "Extract sign() method AST from CCXT TypeScript source"

  @moduledoc """
  Extracts the `sign()` method body as raw ESTree AST for every REST exchange.

  Parses TypeScript source files via OXC, finds the `sign()` method on each
  exchange class, and writes the complete method AST (parameters, return type,
  and full body) to `priv/discoveries/sign_methods.json`.

  Exchanges without a `sign()` method are included with `"sign": null`.

      mix ccxt_extract.sign_methods
      mix ccxt_extract.sign_methods --tier1 --dex
      mix ccxt_extract.sign_methods --exchange binance,deribit

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

    Mix.shell().info("Extracting sign() method AST from REST exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.SignMethod.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.SignMethod.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_sign = Enum.count(exchanges, & &1["sign"])
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_sign} with sign() method.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/sign_methods.json
    """)
  end
end
