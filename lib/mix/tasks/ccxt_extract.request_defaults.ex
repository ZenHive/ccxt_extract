defmodule Mix.Tasks.CcxtExtract.RequestDefaults do
  @shortdoc "Extract per-method default request body literals from CCXT exchange TypeScript files"

  @moduledoc """
  Extracts per-method default request body literals from exchange TypeScript source files.

  Parses `priv/ccxt/ts/src/*.ts` via OXC, walks each class method looking for
  `this.<httpVerb>()` call sites, traces the first argument back to a literal
  `ObjectExpression` (directly, via `this.extend`, or via a `const request = {...}`
  declarator in the same method), and writes per-exchange results to
  `priv/discoveries/request_defaults.json`.

      mix ccxt_extract.request_defaults
      mix ccxt_extract.request_defaults --tier1 --dex
      mix ccxt_extract.request_defaults --exchange hyperliquid

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

    Mix.shell().info("Extracting per-method default request bodies from exchange files...")

    {:ok, all_exchanges, stats} = CcxtExtract.RequestDefaults.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.RequestDefaults.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_defaults = Enum.count(exchanges, fn e -> e["request_defaults_method_count"] > 0 end)
    total_resolvable = Enum.sum(Enum.map(exchanges, & &1["request_defaults_resolvable_count"]))
    total_unresolved = Enum.sum(Enum.map(exchanges, & &1["request_defaults_unresolved_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_defaults} with request defaults.
    #{total_resolvable} resolvable entries, #{total_unresolved} unresolved entries.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/request_defaults.json
    """)
  end
end
