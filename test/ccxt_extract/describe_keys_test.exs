defmodule CcxtExtract.DescribeKeysTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.DescribeKeys

  describe "collect_all_keys/1" do
    test "collects unique keys across multiple exchanges" do
      exchanges = [
        %{"id" => "binance", "keys" => %{"id" => "string", "name" => "string", "has" => "object"}},
        %{"id" => "bybit", "keys" => %{"id" => "string", "urls" => "object", "has" => "object"}}
      ]

      assert DescribeKeys.collect_all_keys(exchanges) == ["has", "id", "name", "urls"]
    end

    test "returns empty list for no exchanges" do
      assert DescribeKeys.collect_all_keys([]) == []
    end

    test "handles exchanges with no keys" do
      exchanges = [%{"id" => "test", "keys" => %{}}]
      assert DescribeKeys.collect_all_keys(exchanges) == []
    end

    test "handles nil keys gracefully" do
      exchanges = [%{"id" => "test", "keys" => nil}]
      assert DescribeKeys.collect_all_keys(exchanges) == []
    end

    test "sorts keys alphabetically" do
      exchanges = [
        %{"id" => "test", "keys" => %{"z_key" => "string", "a_key" => "number", "m_key" => "boolean"}}
      ]

      assert DescribeKeys.collect_all_keys(exchanges) == ["a_key", "m_key", "z_key"]
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid envelope via write!/2", %{tmp_dir: tmp_dir} do
      exchanges = [
        %{"id" => "binance", "keys" => %{"id" => "string", "name" => "string", "has" => "object"}},
        %{"id" => "bybit", "keys" => %{"id" => "string", "urls" => "object"}}
      ]

      output_path = Path.join(tmp_dir, "describe_keys.json")

      assert :ok = DescribeKeys.write!(exchanges, output_path)
      assert File.exists?(output_path)

      parsed = output_path |> File.read!() |> Jason.decode!()

      assert parsed["count"] == 2
      assert is_binary(parsed["extracted_at"])
      assert parsed["all_keys"] == ["has", "id", "name", "urls"]
      assert length(parsed["exchanges"]) == 2

      binance = Enum.find(parsed["exchanges"], &(&1["id"] == "binance"))
      assert binance["keys"]["has"] == "object"
      assert binance["keys"]["name"] == "string"
    end
  end
end
