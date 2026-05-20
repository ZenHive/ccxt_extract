defmodule Mix.Tasks.CcxtExtract.LoadMarkets do
  @shortdoc "Extract loadMarkets() data from CCXT exchanges (live API calls)"

  @moduledoc """
  Calls `loadMarkets()` on each non-alias exchange via QuickBEAM and saves
  the market data as per-exchange JSON files.

  This makes real HTTP requests to exchange APIs — rate-limited with a
  configurable delay between each call. Most exchanges serve market data
  without authentication.

  Writes one JSON file per succeeded exchange to
  `priv/discoveries/load_markets/` and a manifest at
  `priv/discoveries/load_markets/_manifest.json`.

  ## Usage

      mix ccxt_extract.load_markets                               # full universe
      mix ccxt_extract.load_markets --tier1 --dex                 # tiers
      mix ccxt_extract.load_markets --exchange binance --exchange bybit
      mix ccxt_extract.load_markets --all                         # explicit full run
      mix ccxt_extract.load_markets --delay 500
      mix ccxt_extract.load_markets --concurrency 10

  Scoped runs preserve out-of-scope per-exchange files and failed
  manifest entries from prior runs; only `--all` or no scope flag
  reasserts the full universe and prunes stale files.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @extra_switches [delay: :integer, concurrency: :integer]
  @aliases [d: :delay, c: :concurrency]

  @impl true
  def run(args) do
    {scope, tier_scope, opts} = TaskScope.parse_and_resolve!(args, @extra_switches, @aliases)

    delay_ms = Keyword.get(opts, :delay)
    extract_opts = build_extract_opts(opts, scope)

    Mix.shell().info(header_line(scope, delay_ms))

    start_time = System.monotonic_time(:millisecond)
    {:ok, results} = CcxtExtract.LoadMarkets.extract(extract_opts)
    elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000

    CcxtExtract.LoadMarkets.write!(results, scope: scope, tier_scope: tier_scope)
    report_results(results, elapsed_s)
  end

  defp build_extract_opts(opts, scope) do
    []
    |> maybe_put(:delay_ms, Keyword.get(opts, :delay))
    |> maybe_put(:concurrency, Keyword.get(opts, :concurrency))
    |> maybe_put_scope(scope)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_scope(opts, :all), do: opts
  defp maybe_put_scope(opts, %MapSet{} = scope), do: Keyword.put(opts, :exchanges, Enum.sort(scope))

  defp header_line(scope, delay_ms) do
    scope_part =
      case scope do
        :all -> ""
        %MapSet{} = s -> " [#{MapSet.size(s)} exchanges]"
      end

    delay_part = if delay_ms, do: " (delay: #{delay_ms}ms)", else: ""
    "Extracting loadMarkets() from CCXT exchanges#{scope_part}#{delay_part}..."
  end

  defp report_results(results, elapsed_s) do
    succeeded = length(results["succeeded"])
    failed = length(results["failed"])

    Mix.shell().info("""
    Done in #{Float.round(elapsed_s, 1)}s.
      Succeeded: #{succeeded} exchanges
      Failed: #{failed} exchanges
      Output: priv/discoveries/load_markets/ (one file per exchange + _manifest.json)
    """)

    if failed > 0 do
      failed_ids = Enum.map_join(results["failed"], ", ", & &1["id"])
      Mix.shell().info("  Failed exchanges: #{failed_ids}")
    end
  end
end
