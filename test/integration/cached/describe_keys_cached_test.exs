defmodule CcxtExtract.Integration.Cached.DescribeKeysCachedTest do
  @moduledoc """
  Structure tests for describe_keys.json — reads cached discovery output.
  Same assertions as DescribeKeysIntegrationTest but without QuickBEAM boot.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir Path.expand("../../fixtures/discoveries", __DIR__)
  @discovery_path Path.join(@fixtures_dir, "describe_keys.json")
  @exchanges_path Path.join(@fixtures_dir, "exchanges.json")

  # Reference exchanges from CLAUDE.md — all should appear (none are aliases)
  @all_reference ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid aster lighter)

  # Keys that every CCXT exchange's describe() should have
  @universal_keys ~w(id name has urls api)

  setup_all do
    data = @discovery_path |> File.read!() |> Jason.decode!()
    exchanges_data = @exchanges_path |> File.read!() |> Jason.decode!()

    %{
      exchanges: data["exchanges"],
      all_keys: data["all_keys"],
      all_exchanges: exchanges_data["exchanges"]
    }
  end

  describe "structure" do
    test "contains 90+ exchanges (aliases skipped)", %{exchanges: exchanges} do
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

  describe "all_keys aggregation" do
    test "aggregates keys across all exchanges", %{all_keys: all_keys} do
      assert length(all_keys) >= 10, "Expected at least 10 unique keys"
      assert all_keys == Enum.sort(all_keys), "all_keys should be sorted"
      assert "id" in all_keys
      assert "name" in all_keys
      assert "has" in all_keys
      assert "urls" in all_keys
      assert "api" in all_keys
    end
  end
end
