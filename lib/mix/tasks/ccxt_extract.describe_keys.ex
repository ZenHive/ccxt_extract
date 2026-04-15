defmodule Mix.Tasks.CcxtExtract.DescribeKeys do
  @shortdoc "Extract describe() top-level keys from all CCXT exchanges"

  @moduledoc """
  Extracts all top-level keys from every exchange's `describe()` via QuickBEAM.

  Records key names and JS value types per exchange. Skips aliases (they share
  describe() with their parent). Writes to `priv/discoveries/describe_keys.json`.

      mix ccxt_extract.describe_keys
      mix ccxt_extract.describe_keys --tier1 --dex
      mix ccxt_extract.describe_keys --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Tier inheritance expands roots to their
      full family.
    * `--exchange ID` — restrict to explicit exchange IDs (repeatable or
      comma-separated). Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`. The
  describe-extraction loop runs only for in-scope exchanges; the ID filter
  still walks the full CCXT class list once to resolve each class's `.id`,
  then the main `describe()` loop iterates the filtered subset.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting describe() keys from CCXT exchanges...")

    {:ok, exchanges} = CcxtExtract.DescribeKeys.extract(scope)

    all_keys = CcxtExtract.DescribeKeys.collect_all_keys(exchanges)

    CcxtExtract.DescribeKeys.write!(exchanges, tier_scope: tier_scope)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges extracted (aliases skipped).
      Unique keys: #{length(all_keys)}
    Output: priv/discoveries/describe_keys.json
    """)
  end
end
