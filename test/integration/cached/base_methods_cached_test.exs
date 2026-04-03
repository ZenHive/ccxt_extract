defmodule CcxtExtract.Integration.Cached.BaseMethodsCachedTest do
  @moduledoc """
  Cached integration tests for base methods extraction.

  Uses the fixture at `test/fixtures/discoveries/_base_methods.json` to verify
  envelope structure, method counts, and known method signatures without
  requiring CCXT source.
  """
  use ExUnit.Case, async: true

  @fixture_path "test/fixtures/discoveries/_base_methods.json"

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    %{data: data}
  end

  describe "envelope structure" do
    test "has required top-level keys", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_binary(data["source_file"])
      assert is_integer(data["method_count"])
      assert is_map(data["by_category"])
      assert is_map(data["methods"])
    end

    test "source_file is base/Exchange.ts", %{data: data} do
      assert data["source_file"] == "base/Exchange.ts"
    end

    test "method_count matches methods map size", %{data: data} do
      assert data["method_count"] == map_size(data["methods"])
    end

    test "by_category counts sum to method_count", %{data: data} do
      total = data["by_category"] |> Map.values() |> Enum.sum()
      assert total == data["method_count"]
    end

    test "has parse and safe categories with field assignments", %{data: data} do
      assert data["by_category"]["parse"] > 70
      assert data["by_category"]["safe"] > 40
    end
  end

  describe "method structure" do
    test "all methods have required keys", %{data: data} do
      for {name, method} <- data["methods"] do
        assert method["name"] == name, "name mismatch for #{name}"
        assert method["category"] in ["parse", "safe"], "bad category for #{name}"
        assert is_list(method["params"]), "params not a list for #{name}"
        assert is_boolean(method["async"]), "async not boolean for #{name}"
        assert Map.has_key?(method, "return_type"), "missing return_type for #{name}"
        assert method["source"] in ["method_definition", "field_assignment"], "bad source for #{name}"
      end
    end

    test "params have name and type", %{data: data} do
      for {name, method} <- data["methods"],
          param <- method["params"] do
        assert is_binary(param["name"]), "param missing name in #{name}"
        assert Map.has_key?(param, "type"), "param missing type in #{name}"
      end
    end
  end

  describe "spot-check known methods" do
    test "parseOrder is a parse method with Dict param", %{data: data} do
      method = data["methods"]["parseOrder"]
      assert method, "parseOrder should exist"
      assert method["category"] == "parse"
      assert method["return_type"] == "Order"

      order_param = Enum.find(method["params"], &(&1["name"] == "order"))
      assert order_param["type"] == "Dict"
    end

    test "parseTicker exists with Market param", %{data: data} do
      method = data["methods"]["parseTicker"]
      assert method, "parseTicker should exist"
      assert method["category"] == "parse"

      market_param = Enum.find(method["params"], &(&1["name"] == "market"))
      assert market_param["type"] == "Market"
    end

    test "safeNumber is a safe method", %{data: data} do
      method = data["methods"]["safeNumber"]
      assert method, "safeNumber should exist"
      assert method["category"] == "safe"
      assert method["async"] == false
    end

    test "safeBool exists", %{data: data} do
      method = data["methods"]["safeBool"]
      assert method, "safeBool should exist"
      assert method["category"] == "safe"
    end

    test "safeValue is a field assignment", %{data: data} do
      method = data["methods"]["safeValue"]
      assert method, "safeValue should exist"
      assert method["source"] == "field_assignment"
      assert method["params"] == []
      assert method["return_type"] == nil
    end

    test "parseDate is a field assignment", %{data: data} do
      method = data["methods"]["parseDate"]
      assert method, "parseDate should exist"
      assert method["source"] == "field_assignment"
      assert method["category"] == "parse"
    end
  end
end
