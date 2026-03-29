defmodule CcxtExtract.DescribeIntegrationTest do
  use ExUnit.Case, async: true

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Describe

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 120_000

  # Reference exchanges from CLAUDE.md
  @all_reference ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid aster lighter)

  # Keys that every exchange's describe() must have (universal per DISCOVERIES.md)
  @universal_keys ~w(id name has urls api)

  # Keys that are common (>90% of exchanges)
  # Note: version is only ~81% (20 exchanges have no explicit version per DISCOVERIES.md)
  @common_keys ~w(certified countries exceptions fees options precisionMode requiredCredentials timeframes)

  # Run extraction once for the module — QuickBEAM boot is ~13s
  # Also extract exchange list here to avoid a second QuickBEAM boot in the "no alias" test
  setup_all do
    {:ok, results} = Describe.extract()
    {:ok, all_exchanges} = CcxtExtract.Exchanges.extract()
    %{results: results, all_exchanges: all_exchanges}
  end

  describe "extract/0" do
    test "extracts 90+ exchanges (aliases skipped)", %{results: results} do
      assert length(results) >= 90,
             "Expected 90+ non-alias exchanges, got #{length(results)}"
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

    test "function sentinels are preserved", %{results: results} do
      # exceptions.exact values are error class constructors — should be __function:*
      binance = Enum.find(results, &(&1["id"] == "binance"))
      assert binance, "binance should be present"

      exceptions = get_in(binance, ["describe", "exceptions", "exact"])

      assert is_map(exceptions),
             "binance.exceptions.exact should be a map, got: #{inspect(exceptions)}"

      assert map_size(exceptions) > 0,
             "binance.exceptions.exact should not be empty"

      has_func_sentinel? =
        exceptions
        |> Map.values()
        |> Enum.any?(&(is_binary(&1) and String.starts_with?(&1, "__function:")))

      assert has_func_sentinel?,
             "Expected function sentinels in binance.exceptions.exact, got none"
    end

    test "undefined sentinels are preserved where expected", %{results: results} do
      # Some describe() values are undefined in JS — our prepare() converts to "__undefined"
      all_json =
        Enum.map_join(results, fn r -> Jason.encode!(r["describe"]) end)

      assert String.contains?(all_json, "__undefined"),
             "Expected at least some __undefined sentinels across all exchanges"
    end
  end

  describe "write!/1" do
    @tag :tmp_dir
    test "writes per-exchange files and manifest", %{results: results, tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "describe")

      # Call the actual function under test
      Describe.write!(results, output_dir)

      # Verify manifest
      manifest =
        output_dir
        |> Path.join("_manifest.json")
        |> File.read!()
        |> Jason.decode!()

      assert manifest["count"] == length(results)
      assert length(manifest["exchanges"]) == length(results)
      assert is_binary(manifest["extracted_at"])

      # Verify a sample exchange file
      binance = output_dir |> Path.join("binance.json") |> File.read!() |> Jason.decode!()
      assert binance["id"] == "binance"
      assert is_map(binance["describe"])
      assert is_binary(binance["extracted_at"])

      # Verify file count: one per exchange + manifest
      file_count = output_dir |> File.ls!() |> length()
      assert file_count == length(results) + 1
    end
  end

  describe "mix ccxt_extract.describe" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.Describe)

      assert output =~ "Extracting full describe()"
      assert output =~ "Done."
      assert output =~ "exchanges extracted"
      assert output =~ "Output: priv/discoveries/describe/"
    end
  end
end
