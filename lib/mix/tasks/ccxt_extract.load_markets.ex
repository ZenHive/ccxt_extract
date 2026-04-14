defmodule Mix.Tasks.CcxtExtract.LoadMarkets do
  @shortdoc "Extract loadMarkets() data from CCXT exchanges (live API calls)"

  @moduledoc """
  Calls `loadMarkets()` on each non-alias exchange via QuickBEAM and saves the
  market data as per-exchange JSON files.

  This makes real HTTP requests to exchange APIs — rate-limited with a configurable
  delay between each call. Most exchanges serve market data without authentication.

  Writes one JSON file per successful exchange to `priv/discoveries/load_markets/`
  and a manifest at `priv/discoveries/load_markets/_manifest.json`.

      mix ccxt_extract.load_markets
      mix ccxt_extract.load_markets --delay 500
      mix ccxt_extract.load_markets --concurrency 10
      mix ccxt_extract.load_markets --exchanges binance,dydx,bybit
      mix ccxt_extract.load_markets --tier1 --tier2 --dex
  """

  use Mix.Task

  alias CcxtExtract.Tiers

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args,
        strict: [
          delay: :integer,
          exchanges: :string,
          concurrency: :integer,
          tier1: :boolean,
          tier2: :boolean,
          tier3: :boolean,
          dex: :boolean
        ],
        aliases: [d: :delay, e: :exchanges, c: :concurrency]
      )

    validate_args!(opts, leftover, invalid)

    delay_ms = Keyword.get(opts, :delay)
    {extract_opts, tier_label} = build_extract_opts(opts)

    Mix.shell().info(header_line(tier_label, delay_ms))

    start_time = System.monotonic_time(:millisecond)
    {:ok, results} = CcxtExtract.LoadMarkets.extract(extract_opts)
    elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000

    CcxtExtract.LoadMarkets.write!(results)
    report_results(results, elapsed_s)
  end

  defp validate_args!(opts, leftover, invalid) do
    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)

      Mix.raise(
        "Unknown option(s): #{switches}. Supported: --delay, --exchanges, --concurrency, --tier1, --tier2, --tier3, --dex"
      )
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}. This task takes no positional arguments.")
    end

    if Keyword.get(opts, :exchanges) && Tiers.has_tier_flags?(opts) do
      Mix.raise("--exchanges and tier flags (--tier1/--tier2/--tier3/--dex) are mutually exclusive.")
    end
  end

  defp build_extract_opts(opts) do
    extract_opts =
      []
      |> maybe_put(:delay_ms, Keyword.get(opts, :delay))
      |> maybe_put(:concurrency, Keyword.get(opts, :concurrency))

    cond do
      Tiers.has_tier_flags?(opts) ->
        {exchanges, label} = Tiers.collect_tier_exchanges(opts)
        {Keyword.put(extract_opts, :exchanges, exchanges), label}

      ids_string = Keyword.get(opts, :exchanges) ->
        {Keyword.put(extract_opts, :exchanges, String.split(ids_string, ",")), nil}

      true ->
        {extract_opts, nil}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp header_line(tier_label, delay_ms) do
    tier_part = if tier_label, do: " [#{tier_label}]", else: ""
    delay_part = if delay_ms, do: " (delay: #{delay_ms}ms)", else: ""
    "Extracting loadMarkets() from CCXT exchanges#{tier_part}#{delay_part}..."
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
