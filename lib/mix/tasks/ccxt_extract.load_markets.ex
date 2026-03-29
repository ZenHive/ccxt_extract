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
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, leftover, invalid} =
      OptionParser.parse(args,
        strict: [delay: :integer, exchanges: :string, concurrency: :integer],
        aliases: [d: :delay, e: :exchanges, c: :concurrency]
      )

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}. Supported: --delay, --exchanges, --concurrency")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}. This task takes no positional arguments.")
    end

    delay_ms = Keyword.get(opts, :delay)
    concurrency = Keyword.get(opts, :concurrency)

    extract_opts = if delay_ms, do: [delay_ms: delay_ms], else: []
    extract_opts = if concurrency, do: Keyword.put(extract_opts, :concurrency, concurrency), else: extract_opts

    extract_opts =
      case Keyword.get(opts, :exchanges) do
        nil -> extract_opts
        ids_string -> Keyword.put(extract_opts, :exchanges, String.split(ids_string, ","))
      end

    Mix.shell().info(
      "Extracting loadMarkets() from CCXT exchanges#{if delay_ms, do: " (delay: #{delay_ms}ms)", else: ""}..."
    )

    start_time = System.monotonic_time(:millisecond)
    {:ok, results} = CcxtExtract.LoadMarkets.extract(extract_opts)
    elapsed_s = (System.monotonic_time(:millisecond) - start_time) / 1_000

    CcxtExtract.LoadMarkets.write!(results)

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
