defmodule CcxtExtract.LoadMarketsIntegrationTest do
  use ExUnit.Case, async: true

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.LoadMarkets

  @moduletag :integration
  # Network calls — generous timeout
  @moduletag timeout: 600_000

  # Smoke test subset — exchanges known to succeed from the full run.
  # Chosen to cover different families and sizes.
  @smoke_exchanges ~w(binance bybit okx kraken dydx)

  # Known permanent failure categories from full extraction runs (2026-03-29).
  # These are legitimate failures, not bugs:
  #   alpaca — requires apiKey credential
  #   btcbox — trading suspended (901)
  #   bullish, delta, mercado, oxfun — 403 Forbidden (geo-blocked / WAF)
  # Transient failures (vary between runs):
  #   coinbaseexchange — User-Agent header required (intermittent)
  #   lighter — 503 Service Unavailable (intermittent)
  @known_permanent_failures ~w(alpaca btcbox bullish delta mercado oxfun)

  # Run a small extraction once for the module — hits real APIs
  setup_all do
    {:ok, results} = LoadMarkets.extract(exchanges: @smoke_exchanges, delay_ms: 300)
    %{results: results}
  end

  describe "extract/1" do
    test "returns succeeded and failed lists", %{results: results} do
      assert is_list(results["succeeded"])
      assert is_list(results["failed"])

      total = length(results["succeeded"]) + length(results["failed"])
      assert total == length(@smoke_exchanges)
    end

    test "most smoke exchanges succeed", %{results: results} do
      # All 5 smoke exchanges are known to work. Allow 1 transient failure.
      assert length(results["succeeded"]) >= 4,
             "Expected at least 4/#{length(@smoke_exchanges)} to succeed, " <>
               "got #{length(results["succeeded"])}. " <>
               "Failed: #{inspect(Enum.map(results["failed"], & &1["id"]))}"
    end

    test "succeeded results have correct structure", %{results: results} do
      for result <- results["succeeded"] do
        assert is_binary(result["id"]), "id should be a string"
        assert is_map(result["markets"]), "markets should be a map for #{result["id"]}"
        assert is_integer(result["market_count"]), "market_count should be an integer for #{result["id"]}"
        assert result["market_count"] > 0, "#{result["id"]} should have at least 1 market"

        assert result["market_count"] == map_size(result["markets"]),
               "market_count should match map size for #{result["id"]}"
      end
    end

    test "failed results have id and error", %{results: results} do
      for result <- results["failed"] do
        assert is_binary(result["id"]), "failed entry should have string id"
        assert is_binary(result["error"]), "failed entry should have string error for #{result["id"]}"
      end
    end
  end

  describe "market data structure" do
    test "markets contain expected core fields", %{results: results} do
      for result <- results["succeeded"] do
        # Check first market of each exchange
        {_symbol, market} = Enum.at(result["markets"], 0)

        assert is_binary(market["symbol"]), "#{result["id"]}: market should have string symbol"
        assert is_binary(market["id"]), "#{result["id"]}: market should have string id"
        assert market["base"] != nil, "#{result["id"]}: market should have base currency"
        assert market["quote"] != nil, "#{result["id"]}: market should have quote currency"
      end
    end

    test "binance has many markets", %{results: results} do
      binance = Enum.find(results["succeeded"], &(&1["id"] == "binance"))

      if binance do
        assert binance["market_count"] >= 100,
               "binance should have at least 100 markets, got #{binance["market_count"]}"
      else
        flunk("binance should succeed but failed: #{inspect(Enum.find(results["failed"], &(&1["id"] == "binance")))}")
      end
    end

    test "markets have precision and limits", %{results: results} do
      for result <- results["succeeded"] do
        {_symbol, market} = Enum.at(result["markets"], 0)

        # CCXT markets include precision and limits maps
        assert is_map(market["precision"]),
               "#{result["id"]}: market should have precision map"

        assert is_map(market["limits"]),
               "#{result["id"]}: market should have limits map"
      end
    end
  end

  describe "known failures" do
    test "known permanent failure list is documented" do
      # This test exists to make the known failures visible and intentional.
      # If a known failure starts succeeding, remove it from @known_permanent_failures.
      assert length(@known_permanent_failures) == 6,
             "Update @known_permanent_failures if the failure list changes"
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes per-exchange files and manifest", %{results: results, tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "load_markets")

      LoadMarkets.write!(results, output_dir)

      # Verify manifest
      manifest =
        output_dir
        |> Path.join("_manifest.json")
        |> File.read!()
        |> Jason.decode!()

      assert manifest["succeeded_count"] == length(results["succeeded"])
      assert manifest["failed_count"] == length(results["failed"])
      assert is_list(manifest["succeeded"])
      assert is_list(manifest["failed"])
      assert is_binary(manifest["extracted_at"])

      # Verify per-exchange files exist for each succeeded exchange
      for result <- results["succeeded"] do
        path = Path.join(output_dir, "#{result["id"]}.json")
        assert File.exists?(path), "Expected file for #{result["id"]}"

        data = path |> File.read!() |> Jason.decode!()
        assert data["id"] == result["id"]
        assert is_map(data["markets"])
        assert is_integer(data["market_count"])
        assert is_binary(data["extracted_at"])
      end

      # Verify no files for failed exchanges
      for result <- results["failed"] do
        path = Path.join(output_dir, "#{result["id"]}.json")
        refute File.exists?(path), "Should not write file for failed exchange #{result["id"]}"
      end

      # File count: one per succeeded exchange + manifest
      file_count = output_dir |> File.ls!() |> length()
      assert file_count == length(results["succeeded"]) + 1
    end

    @tag :tmp_dir
    test "cleans stale files from previous runs", %{results: results, tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "load_markets_stale")
      File.mkdir_p!(output_dir)

      stale_path = Path.join(output_dir, "stale_exchange.json")
      File.write!(stale_path, "{}")

      LoadMarkets.write!(results, output_dir)

      refute File.exists?(stale_path), "Stale files should be cleaned up"
    end
  end

  describe "mix ccxt_extract.load_markets" do
    test "runs task with --exchanges filter" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.LoadMarkets, ["--exchanges", "dydx"])

      assert output =~ "Extracting loadMarkets()"
      assert output =~ "Done in"
      assert output =~ "Succeeded:"
      assert output =~ "Output: priv/discoveries/load_markets/"
    end
  end
end
