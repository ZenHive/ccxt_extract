defmodule CcxtExtract.DescribeKeysIntegrationTest do
  use ExUnit.Case, async: true

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.DescribeKeys

  @moduletag :integration
  @moduletag timeout: 120_000

  # Reference exchanges from CLAUDE.md — all should appear (none are aliases)
  @all_reference ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid aster lighter)

  # Keys that every CCXT exchange's describe() should have
  @universal_keys ~w(id name has urls api)

  # Run extraction once for the module — QuickBEAM boot is ~13s
  # Also extract all exchanges here to avoid a second QuickBEAM boot in the "no alias" test
  setup_all do
    {:ok, exchanges} = DescribeKeys.extract()
    {:ok, all_exchanges} = CcxtExtract.Exchanges.extract()
    %{exchanges: exchanges, all_exchanges: all_exchanges}
  end

  describe "extract/0" do
    test "extracts 90+ exchanges (aliases skipped)", %{exchanges: exchanges} do
      assert length(exchanges) >= 90,
             "Expected 90+ non-alias exchanges, got #{length(exchanges)}"
    end

    test "each exchange has id and keys fields", %{exchanges: exchanges} do
      for ex <- exchanges do
        assert is_binary(ex["id"]), "id should be a string, got: #{inspect(ex["id"])}"
        assert is_map(ex["keys"]), "keys should be a map for #{ex["id"]}"
        assert map_size(ex["keys"]) > 0, "keys should not be empty for #{ex["id"]}"
      end
    end

    test "key value types are valid JS type strings", %{exchanges: exchanges} do
      valid_types = ~w(string number boolean object array null function undefined)

      for ex <- exchanges, {key, type} <- ex["keys"] do
        assert type in valid_types,
               "#{ex["id"]}.#{key} has invalid type #{inspect(type)}"
      end
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "no alias exchanges in output", %{exchanges: exchanges, all_exchanges: all_exchanges} do
      alias_ids = all_exchanges |> Enum.filter(& &1["alias"]) |> MapSet.new(& &1["id"])
      extracted_ids = MapSet.new(exchanges, & &1["id"])

      overlap = MapSet.intersection(alias_ids, extracted_ids)

      assert MapSet.size(overlap) == 0,
             "Alias exchanges should be skipped, but found: #{inspect(MapSet.to_list(overlap))}"
    end
  end

  describe "reference exchanges present" do
    for id <- @all_reference do
      test "#{id} is present with keys", %{exchanges: exchanges} do
        ex = Enum.find(exchanges, &(&1["id"] == unquote(id)))
        assert ex, "#{unquote(id)} should be in describe_keys output"
        assert map_size(ex["keys"]) >= 5, "#{unquote(id)} should have at least 5 keys"
      end
    end
  end

  describe "universal keys present on all exchanges" do
    for key <- @universal_keys do
      test "#{key} is present on every exchange", %{exchanges: exchanges} do
        missing =
          exchanges
          |> Enum.reject(fn ex -> Map.has_key?(ex["keys"], unquote(key)) end)
          |> Enum.map(& &1["id"])

        assert missing == [],
               "Key '#{unquote(key)}' missing on: #{Enum.join(missing, ", ")}"
      end
    end
  end

  describe "key type consistency" do
    test "id is always a string type", %{exchanges: exchanges} do
      for ex <- exchanges do
        assert ex["keys"]["id"] == "string",
               "#{ex["id"]}.id should be type 'string', got '#{ex["keys"]["id"]}'"
      end
    end

    test "has is always an object type", %{exchanges: exchanges} do
      for ex <- exchanges do
        assert ex["keys"]["has"] == "object",
               "#{ex["id"]}.has should be type 'object', got '#{ex["keys"]["has"]}'"
      end
    end
  end

  describe "collect_all_keys/1" do
    test "aggregates keys across all exchanges", %{exchanges: exchanges} do
      all_keys = DescribeKeys.collect_all_keys(exchanges)

      assert length(all_keys) >= 10, "Expected at least 10 unique keys"
      assert all_keys == Enum.sort(all_keys), "all_keys should be sorted"
      assert "id" in all_keys
      assert "name" in all_keys
      assert "has" in all_keys
      assert "urls" in all_keys
      assert "api" in all_keys
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with metadata envelope", %{exchanges: exchanges, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "describe_keys.json")

      assert :ok = DescribeKeys.write!(exchanges, output_path)
      assert File.exists?(output_path)

      parsed = output_path |> File.read!() |> Jason.decode!()

      assert is_binary(parsed["extracted_at"])
      assert parsed["count"] == length(exchanges)
      assert is_list(parsed["all_keys"])
      assert length(parsed["all_keys"]) >= 10
      assert length(parsed["exchanges"]) == length(exchanges)
    end
  end

  describe "mix ccxt_extract.describe_keys" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.DescribeKeys)

      assert output =~ "Extracting describe() keys"
      assert output =~ "Done."
      assert output =~ "exchanges extracted"
      assert output =~ "Unique keys:"
      assert output =~ "Output: priv/discoveries/describe_keys.json"
    end
  end
end
