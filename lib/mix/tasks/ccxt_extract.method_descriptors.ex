defmodule Mix.Tasks.CcxtExtract.MethodDescriptors do
  @shortdoc "Extract unified-method descriptors (TS signature + JSDoc) from CCXT source"

  @moduledoc """
  Extract one unified-method descriptor per CCXT unified method.

  Each descriptor fuses two complementary axes (both provenance `raw`):

    * the **TS signature** — ordered params with name, type, optional flag, and
      default value, plus the return type, read off the method AST; and
    * the **JSDoc overlay** — `@description` prose, per-`@param` prose,
      `@returns` shape, and `@throws {ErrorClass}` entries, recovered from a
      source slice before the method (OXC does not surface comments on the AST).

  Each descriptor also carries `source` — the byte-for-byte method definition
  slice — so it is self-verifying against the CCXT source. Descriptors are
  consumer-neutral; downstream clients map the ordered params to their own
  arg-shape convention. Missing JSDoc is honest: `description`/`errors` become
  `null` with an `unresolved_reason`.

  Writes to `priv/discoveries/method_descriptors.json`.

      mix ccxt_extract.method_descriptors
      mix ccxt_extract.method_descriptors --tier1 --dex
      mix ccxt_extract.method_descriptors --exchange binance,deribit

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Scoped runs merge into the existing
      aggregate: only in-scope entries are replaced; out-of-scope entries
      are preserved.
    * `--exchange ID` — restrict to explicit exchange IDs. Accepts repeated
      flags and comma-separated values. Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.MethodDescriptors
  alias CcxtExtract.TaskScope

  @impl true
  @spec run([String.t()]) :: :ok
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting unified-method descriptors from REST exchanges...")

    {:ok, all_exchanges, stats} = MethodDescriptors.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    MethodDescriptors.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_descriptors = Enum.count(exchanges, &(&1["descriptor_count"] > 0))
    total = Enum.sum(Enum.map(exchanges, & &1["descriptor_count"]))
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_descriptors} with descriptors (#{total} total).
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/method_descriptors.json
    """)
  end
end
