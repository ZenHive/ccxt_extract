defmodule Mix.Tasks.CcxtExtract.UrlTemplates do
  @shortdoc "Extract URL templates for all CCXT exchanges"

  @moduledoc """
  Extracts URL templates for every non-alias exchange via QuickBEAM.

  For each exchange, calls `sign()` with a sample endpoint from each API
  section to capture the fully resolved URL, revealing path prefixes not
  visible in `describe()` data alone.

  Writes a single JSON file to `priv/discoveries/url_templates.json`.

      mix ccxt_extract.url_templates
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Extracting URL templates from all CCXT exchanges...")

    {:ok, results} = CcxtExtract.UrlTemplates.extract()
    CcxtExtract.UrlTemplates.write!(results)

    Mix.shell().info("""
    Done. #{length(results)} exchanges extracted (aliases skipped).
    Output: priv/discoveries/url_templates.json
    """)
  end
end
