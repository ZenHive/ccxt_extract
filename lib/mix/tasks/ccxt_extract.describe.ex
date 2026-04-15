defmodule Mix.Tasks.CcxtExtract.Describe do
  @shortdoc "Extract complete describe() for all CCXT exchanges"

  @moduledoc """
  Extracts the full `describe()` output for every non-alias exchange via QuickBEAM.

  Writes one JSON file per exchange to `priv/discoveries/describe/` and a manifest
  at `priv/discoveries/describe/_manifest.json`.

  ## Usage

      mix ccxt_extract.describe                     # full universe
      mix ccxt_extract.describe --tier1 --dex       # tier1 + DEX
      mix ccxt_extract.describe --exchange binance  # single exchange
      mix ccxt_extract.describe --all               # explicit full run

  Scoped runs preserve out-of-scope per-exchange files from prior runs; only
  `--all` or no scope flag reasserts the full universe and prunes stale files.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting full describe() from CCXT exchanges...")

    {:ok, results} = CcxtExtract.Describe.extract(scope: scope)
    CcxtExtract.Describe.write!(results, scope: scope, tier_scope: tier_scope)

    Mix.shell().info("""
    Done. #{length(results)} exchanges extracted (aliases skipped).
    Output: priv/discoveries/describe/ (one file per exchange + _manifest.json)
    """)
  end
end
