# Live trading data from an exchange via CCXT JS running on the BEAM
#
# Note: Uses QuickBEAM to run CCXT's JavaScript runtime in-process.
# QuickBEAM.call auto-awaits Promises, so no sleep polling needed.
#
# Usage: mix run examples/4_quickbeam_fetch_ticker.exs [exchange] [symbol]
# Default: binance BTC/USDT:USDT

args = System.argv()
exchange = Enum.at(args, 0) || "binance"
symbol = Enum.at(args, 1) || "BTC/USDT:USDT"

bundle_path = "node_modules/ccxt/dist/ccxt.browser.min.js"

if !File.exists?(bundle_path) do
  IO.puts("CCXT browser bundle not found. Run: mix npm.install ccxt")
  System.halt(1)
end

bundle = File.read!(bundle_path)
{:ok, rt} = QuickBEAM.start()

# Browser global stubs — self and window must reference globalThis directly
QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
QuickBEAM.set_global(rt, "navigator", %{"userAgent" => "QuickBEAM"})
QuickBEAM.set_global(rt, "location", %{"protocol" => "https:"})

IO.puts("Loading CCXT...")
{load_us, {:ok, _}} = :timer.tc(fn -> QuickBEAM.call(rt, "eval", [bundle]) end)
IO.puts("CCXT loaded in #{div(load_us, 1000)}ms")

# Create exchange and define helper functions
QuickBEAM.call(rt, "eval", [
  """
  globalThis.ex = new ccxt['#{exchange}']();

  globalThis.doLoadMarkets = async function() {
    await ex.loadMarkets();
    return Object.keys(ex.markets).length;
  };

  globalThis.doFetchTicker = async function(sym) {
    const t = await ex.fetchTicker(sym);
    return JSON.stringify({
      symbol: t.symbol, last: t.last, bid: t.bid, ask: t.ask,
      high: t.high, low: t.low, volume: t.baseVolume,
      datetime: t.datetime, timestamp: t.timestamp
    });
  };
  """
])

IO.puts("Loading markets...")
{markets_us, {:ok, count}} = :timer.tc(fn -> QuickBEAM.call(rt, "doLoadMarkets", []) end)
IO.puts("#{count} markets loaded in #{div(markets_us, 1000)}ms\n")

IO.puts("Fetching #{symbol}...")
{ticker_us, {:ok, json}} = :timer.tc(fn -> QuickBEAM.call(rt, "doFetchTicker", [symbol]) end)
ticker = Jason.decode!(json)

IO.puts("#{ticker["symbol"]} @ #{ticker["datetime"]}")
IO.puts("  Last:   $#{ticker["last"]}")
IO.puts("  Bid:    $#{ticker["bid"]}")
IO.puts("  Ask:    $#{ticker["ask"]}")
IO.puts("  High:   $#{ticker["high"]}")
IO.puts("  Low:    $#{ticker["low"]}")
IO.puts("  Volume: #{ticker["volume"]}")
IO.puts("  Latency: #{div(ticker_us, 1000)}ms")

QuickBEAM.stop(rt)
