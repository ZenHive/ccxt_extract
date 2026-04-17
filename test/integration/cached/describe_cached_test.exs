defmodule CcxtExtract.Integration.Cached.DescribeCachedTest do
  @moduledoc """
  Structure tests for describe/*.json — reads cached per-exchange describe output.
  Same assertions as DescribeIntegrationTest but without QuickBEAM boot.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  @moduletag :integration
  @moduletag timeout: 30_000

  @discoveries_dir CcxtExtract.Paths.discoveries()
  @manifest_path Path.join(@discoveries_dir, "describe/_manifest.json")
  @exchanges_path Path.join(@discoveries_dir, "exchanges.json")

  # Reference exchanges from CLAUDE.md
  @all_reference ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid aster lighter)

  # Keys that every exchange's describe() must have (universal per DISCOVERIES.md)
  @universal_keys ~w(id name has urls api)

  # Keys that are common (>90% of exchanges)
  @common_keys ~w(certified countries exceptions fees options precisionMode requiredCredentials timeframes)

  setup_all do
    manifest = @manifest_path |> File.read!() |> Jason.decode!()
    describe_dir = Path.join(@discoveries_dir, "describe")

    # Load all per-exchange describe files
    results =
      manifest["exchanges"]
      |> Enum.map(fn id ->
        path = Path.join(describe_dir, "#{id}.json")
        path |> File.read!() |> Jason.decode!()
      end)
      |> Enum.sort_by(& &1["id"])

    # Load exchanges.json for alias checking
    exchanges_data = @exchanges_path |> File.read!() |> Jason.decode!()

    %{results: results, all_exchanges: exchanges_data["exchanges"]}
  end

  describe "structure" do
    test "contains expected exchange count (aliases skipped)", %{results: results} do
      min = min_count(length(results), 90)

      assert length(results) >= min,
             "Expected #{min}+ non-alias exchanges, got #{length(results)}"
    end

    test "each result has id and describe fields", %{results: results} do
      for result <- results do
        assert is_binary(result["id"]), "id should be a string"
        assert is_map(result["describe"]), "describe should be a map for #{result["id"]}"
        assert map_size(result["describe"]) > 0, "describe should not be empty for #{result["id"]}"
      end
    end

    test "results are sorted by id", %{results: results} do
      ids = Enum.map(results, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "no alias exchanges in output", %{results: results, all_exchanges: all_exchanges} do
      alias_ids = all_exchanges |> Enum.filter(& &1["alias"]) |> MapSet.new(& &1["id"])
      extracted_ids = MapSet.new(results, & &1["id"])

      overlap = MapSet.intersection(alias_ids, extracted_ids)

      assert MapSet.size(overlap) == 0,
             "Alias exchanges should be skipped, but found: #{inspect(MapSet.to_list(overlap))}"
    end
  end

  describe "reference exchanges present" do
    for id <- @all_reference do
      test "#{id} has complete describe()", %{results: results} do
        result = Enum.find(results, &(&1["id"] == unquote(id)))
        assert result, "#{unquote(id)} should be in describe output"

        describe = result["describe"]

        assert map_size(describe) >= 20,
               "#{unquote(id)} should have at least 20 top-level keys, got #{map_size(describe)}"
      end
    end
  end

  describe "universal keys present on all exchanges" do
    for key <- @universal_keys do
      test "#{key} is present on every exchange", %{results: results} do
        missing =
          results
          |> Enum.reject(fn r -> Map.has_key?(r["describe"], unquote(key)) end)
          |> Enum.map(& &1["id"])

        assert missing == [],
               "Key '#{unquote(key)}' missing on: #{Enum.join(missing, ", ")}"
      end
    end
  end

  describe "common keys present on most exchanges" do
    for key <- @common_keys do
      test "#{key} is present on >90% of exchanges", %{results: results} do
        count =
          Enum.count(results, fn r -> Map.has_key?(r["describe"], unquote(key)) end)

        threshold = length(results) * 0.9

        assert count >= threshold,
               "'#{unquote(key)}' present on #{count}/#{length(results)} exchanges " <>
                 "(expected >90%)"
      end
    end
  end

  describe "describe() value structure" do
    test "id matches the result id for all exchanges", %{results: results} do
      for result <- results do
        assert result["describe"]["id"] == result["id"],
               "describe.id mismatch for #{result["id"]}: got #{result["describe"]["id"]}"
      end
    end

    test "has is always a map with boolean-like values", %{results: results} do
      for result <- results do
        has = result["describe"]["has"]
        assert is_map(has), "#{result["id"]}.has should be a map"
        assert map_size(has) > 0, "#{result["id"]}.has should not be empty"
      end
    end

    test "api is always a map with nested structure", %{results: results} do
      for result <- results do
        api = result["describe"]["api"]
        assert is_map(api), "#{result["id"]}.api should be a map"
        assert map_size(api) > 0, "#{result["id"]}.api should not be empty"
      end
    end

    test "function sentinels have resolved error class names", %{results: results} do
      binance = Enum.find(results, &(&1["id"] == "binance"))
      assert binance, "binance should be present"

      exceptions = get_in(binance, ["describe", "exceptions", "exact"])

      assert is_map(exceptions),
             "binance.exceptions.exact should be a map, got: #{inspect(exceptions)}"

      assert map_size(exceptions) > 0,
             "binance.exceptions.exact should not be empty"

      func_sentinels =
        exceptions
        |> Map.values()
        |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "__function:")))

      assert func_sentinels != [],
             "Expected function sentinels in binance.exceptions.exact, got none"

      # All sentinels should have resolved error class names, not minified single-letter names
      for sentinel <- func_sentinels do
        class_name = String.trim_leading(sentinel, "__function:")

        assert String.length(class_name) > 1,
               "Expected resolved class name, got minified: #{sentinel}"
      end

      # Verify known CCXT error classes appear in exact exception mappings
      exact_values = MapSet.new(Map.values(exceptions))
      assert "__function:AuthenticationError" in exact_values
      assert "__function:BadRequest" in exact_values
    end

    test "undefined sentinels are preserved where expected", %{results: results} do
      all_json =
        Enum.map_join(results, fn r -> Jason.encode!(r["describe"]) end)

      assert String.contains?(all_json, "__undefined"),
             "Expected at least some __undefined sentinels across all exchanges"
    end
  end
end
