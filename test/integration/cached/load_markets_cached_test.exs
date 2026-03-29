defmodule CcxtExtract.Integration.Cached.LoadMarketsCachedTest do
  @moduledoc """
  Structure tests for load_markets/*.json — reads cached discovery output.
  Validates whatever data exists from previous extraction runs.
  Does not require a full extraction — works with partial results.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @discoveries_dir Path.expand("../../fixtures/discoveries", __DIR__)
  @manifest_path Path.join(@discoveries_dir, "load_markets/_manifest.json")

  setup_all do
    manifest = @manifest_path |> File.read!() |> Jason.decode!()
    load_markets_dir = Path.join(@discoveries_dir, "load_markets")

    # Load all available succeeded exchange files for structure verification
    sample_results =
      Enum.map(manifest["succeeded"], fn id ->
        load_markets_dir
        |> Path.join("#{id}.json")
        |> File.read!()
        |> Jason.decode!()
      end)

    %{manifest: manifest, sample_results: sample_results, load_markets_dir: load_markets_dir}
  end

  describe "manifest structure" do
    test "has expected fields", %{manifest: manifest} do
      assert is_integer(manifest["succeeded_count"])
      assert is_integer(manifest["failed_count"])
      assert is_list(manifest["succeeded"])
      assert is_list(manifest["failed"])
      assert is_binary(manifest["extracted_at"])
    end

    test "succeeded count matches list length", %{manifest: manifest} do
      assert manifest["succeeded_count"] == length(manifest["succeeded"])
    end

    test "failed count matches list length", %{manifest: manifest} do
      assert manifest["failed_count"] == length(manifest["failed"])
    end

    test "at least one exchange succeeded", %{manifest: manifest} do
      assert manifest["succeeded_count"] >= 1,
             "Expected at least 1 succeeded exchange, got #{manifest["succeeded_count"]}"
    end
  end

  describe "per-exchange file structure" do
    test "files exist for all succeeded exchanges", %{manifest: manifest, load_markets_dir: dir} do
      for id <- manifest["succeeded"] do
        path = Path.join(dir, "#{id}.json")
        assert File.exists?(path), "Expected file for #{id}"
      end
    end

    test "exchange files have correct structure", %{sample_results: results} do
      for result <- results do
        assert is_binary(result["id"]), "id should be a string"
        assert is_map(result["markets"]), "markets should be a map for #{result["id"]}"
        assert is_integer(result["market_count"]), "market_count should be an integer for #{result["id"]}"
        assert result["market_count"] > 0, "#{result["id"]} should have at least 1 market"

        assert result["market_count"] == map_size(result["markets"]),
               "market_count should match map size for #{result["id"]}"
      end
    end

    test "markets contain expected core fields", %{sample_results: results} do
      for result <- results do
        {_symbol, market} = Enum.at(result["markets"], 0)

        assert is_binary(market["symbol"]), "#{result["id"]}: market should have string symbol"
        assert is_binary(market["id"]), "#{result["id"]}: market should have string id"
        assert market["base"] != nil, "#{result["id"]}: market should have base currency"
        assert market["quote"] != nil, "#{result["id"]}: market should have quote currency"
      end
    end

    test "markets have precision and limits", %{sample_results: results} do
      for result <- results do
        {_symbol, market} = Enum.at(result["markets"], 0)

        assert is_map(market["precision"]),
               "#{result["id"]}: market should have precision map"

        assert is_map(market["limits"]),
               "#{result["id"]}: market should have limits map"
      end
    end
  end
end
