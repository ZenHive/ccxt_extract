defmodule Mix.Tasks.CcxtExtract.DescribeKeys do
  @shortdoc "Extract describe() top-level keys from all CCXT exchanges"

  @moduledoc """
  Extracts all top-level keys from every exchange's `describe()` via QuickBEAM.

  Records key names and JS value types per exchange. Skips aliases (they share
  describe() with their parent). Writes to `priv/discoveries/describe_keys.json`.

      mix ccxt_extract.describe_keys
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Extracting describe() keys from CCXT exchanges...")

    {:ok, exchanges} = CcxtExtract.DescribeKeys.extract()

    all_keys = CcxtExtract.DescribeKeys.collect_all_keys(exchanges)

    CcxtExtract.DescribeKeys.write!(exchanges)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges extracted (aliases skipped).
      Unique keys: #{length(all_keys)}
    Output: priv/discoveries/describe_keys.json
    """)
  end
end
