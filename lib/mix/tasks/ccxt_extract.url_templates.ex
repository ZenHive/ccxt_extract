defmodule Mix.Tasks.CcxtExtract.UrlTemplates do
  @shortdoc "Extract URL templates for all CCXT exchanges"

  @moduledoc """
  Extracts URL templates for every non-alias exchange via QuickBEAM.

  For each exchange, calls `sign()` with a sample endpoint from each API
  section to capture the fully resolved URL, revealing path prefixes not
  visible in `describe()` data alone.

  Writes a single JSON file to `priv/discoveries/url_templates.json`.
  Routes writes through `CcxtExtract.AggregateWriter` so scoped runs merge
  cleanly with the existing aggregate — out-of-scope entries are preserved,
  in-scope entries are replaced, `count` is recomputed from the final list.

  ## Usage

      mix ccxt_extract.url_templates                     # full universe
      mix ccxt_extract.url_templates --tier1 --dex       # tier1 + DEX
      mix ccxt_extract.url_templates --exchange binance  # single exchange
      mix ccxt_extract.url_templates --all               # explicit full run
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting URL templates from CCXT exchanges...")

    {:ok, results} = CcxtExtract.UrlTemplates.extract(scope: scope)
    CcxtExtract.UrlTemplates.write!(results, scope: scope, tier_scope: tier_scope)

    Mix.shell().info("""
    Done. #{length(results)} exchanges extracted (aliases skipped).
    Output: priv/discoveries/url_templates.json
    """)
  end
end
