defmodule CcxtExtract.Integration.Cached.ParseMethodsCachedTest do
  @moduledoc """
  Structure tests for parse_methods.json — reads cached discovery output.
  Same assertions as ParseMethodsIntegrationTest but without OXC parsing.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir CcxtExtract.Paths.discoveries()
  @fixture_path Path.join(@fixtures_dir, "parse_methods.json")

  # Reference exchanges that should have parse methods
  @reference_exchanges ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex)

  # DEX exchanges
  @dex_exchanges ~w(hyperliquid aster lighter)

  # Common parse methods most exchanges should have
  @common_parse_methods ~w(parseTicker parseOrder parseTrade)

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_parse_methods"])
      assert is_integer(data["total_methods"])
      assert is_list(data["exchanges"])
    end

    test "counts are consistent", %{data: data} do
      assert data["count"] == length(data["exchanges"])

      actual_with_parse = Enum.count(data["exchanges"], fn e -> e["parse_method_count"] > 0 end)
      assert data["with_parse_methods"] == actual_with_parse

      actual_total = Enum.sum(Enum.map(data["exchanges"], & &1["parse_method_count"]))
      assert data["total_methods"] == actual_total
    end

    test "at least 100 exchanges extracted", %{data: data} do
      assert data["count"] >= 100
    end

    test "at least 95 exchanges have parse methods", %{data: data} do
      assert data["with_parse_methods"] >= 95
    end

    test "at least 1400 total parse methods", %{data: data} do
      assert data["total_methods"] >= 1400
    end
  end

  describe "exchange structure" do
    test "every exchange has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert is_binary(exchange["id"]), "missing id"
        assert is_binary(exchange["file"]), "missing file"
        assert is_map(exchange["parse_methods"]), "missing parse_methods on #{exchange["id"]}"
        assert is_integer(exchange["parse_method_count"]), "missing parse_method_count on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "missing class_name on #{exchange["id"]}"
      end
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "parse_method_count matches actual method count", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert exchange["parse_method_count"] == map_size(exchange["parse_methods"]),
               "Count mismatch on #{exchange["id"]}"
      end
    end

    test "exchanges with parse methods have complete data", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["parse_methods"] do
        assert is_list(data["params"]), "missing params on #{exchange["id"]}.#{name}"
        assert is_boolean(data["async"]), "missing async on #{exchange["id"]}.#{name}"
        assert is_integer(data["statements"]), "missing statements on #{exchange["id"]}.#{name}"
        assert is_map(data["body"]), "missing body on #{exchange["id"]}.#{name}"
      end
    end
  end

  # Reference exchanges must be present
  for exchange <- @reference_exchanges ++ @dex_exchanges do
    test "#{exchange} is present", %{by_id: by_id} do
      assert Map.has_key?(by_id, unquote(exchange)),
             "Reference exchange '#{unquote(exchange)}' missing"
    end
  end

  # Reference exchanges should have common parse methods
  for exchange <- @reference_exchanges do
    test "#{exchange} has common parse methods", %{by_id: by_id} do
      methods = by_id[unquote(exchange)]["parse_methods"]

      for method_name <- @common_parse_methods do
        assert Map.has_key?(methods, method_name),
               "Expected #{unquote(exchange)} to have #{method_name}"
      end
    end
  end

  describe "binance parse method details" do
    test "has substantial number of parse methods", %{by_id: by_id} do
      assert by_id["binance"]["parse_method_count"] >= 20
    end

    test "parseTicker has typical signature", %{by_id: by_id} do
      ticker = by_id["binance"]["parse_methods"]["parseTicker"]
      param_names = Enum.map(ticker["params"], & &1["name"])

      assert "ticker" in param_names || "response" in param_names
      assert ticker["statements"] >= 5
    end

    test "all parse methods are synchronous", %{by_id: by_id} do
      for {name, data} <- by_id["binance"]["parse_methods"] do
        assert data["async"] == false,
               "Expected binance.#{name} to be sync"
      end
    end
  end

  describe "body AST structure" do
    test "binance parseTicker body has type and nested statements", %{by_id: by_id} do
      body = by_id["binance"]["parse_methods"]["parseTicker"]["body"]

      assert is_map(body)
      assert is_binary(body["type"])
      assert is_list(body["body"])
      assert length(body["body"]) >= 5
    end

    test "body statements have type fields", %{by_id: by_id} do
      stmts = by_id["binance"]["parse_methods"]["parseTicker"]["body"]["body"]

      for stmt <- stmts do
        assert is_binary(stmt["type"]),
               "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["parse_methods"]["parseTicker"]["body"]

      assert is_integer(body["start"])
      assert is_integer(body["end"])
      assert body["end"] > body["start"]
    end
  end

  describe "all parse methods are synchronous" do
    test "no async parse methods across all exchanges", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["parse_methods"] do
        assert data["async"] == false,
               "#{exchange["id"]}.#{name} should be sync"
      end
    end
  end
end
