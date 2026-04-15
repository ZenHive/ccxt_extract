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

  alias CcxtExtract.Scope
  alias CcxtExtract.TaskScope

  @switches TaskScope.scope_switches()

  @impl true
  def run(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    universe = TaskScope.load_universe()
    scope = TaskScope.resolve_scope!(opts, universe)
    tier_scope = Scope.to_manifest_value(opts)

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
