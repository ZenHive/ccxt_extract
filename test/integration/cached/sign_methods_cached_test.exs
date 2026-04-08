defmodule CcxtExtract.Integration.Cached.SignMethodsCachedTest do
  @moduledoc """
  Structure tests for sign_methods.json — reads cached discovery output.
  Same assertions as SignMethodIntegrationTest but without OXC parsing.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir CcxtExtract.Paths.discoveries()
  @fixture_path Path.join(@fixtures_dir, "sign_methods.json")

  # Reference exchanges that should have sign()
  @exchanges_with_sign ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex)

  # DEX exchanges
  @dex_exchanges ~w(hyperliquid aster lighter)

  # Standard sign() parameter names
  @standard_param_names ~w(path api method params headers body)

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_sign"])
      assert is_list(data["exchanges"])
    end

    test "counts are consistent", %{data: data} do
      assert data["count"] == length(data["exchanges"])
      actual_with_sign = Enum.count(data["exchanges"], & &1["sign"])
      assert data["with_sign"] == actual_with_sign
    end

    test "at least 100 exchanges extracted", %{data: data} do
      assert data["count"] >= 100
    end

    test "at least 95 exchanges have sign()", %{data: data} do
      assert data["with_sign"] >= 95
    end
  end

  describe "exchange structure" do
    test "every exchange has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert is_binary(exchange["id"]), "missing id"
        assert is_binary(exchange["file"]), "missing file"
        assert Map.has_key?(exchange, "sign"), "missing sign key on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "missing class_name on #{exchange["id"]}"
      end
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "exchanges with sign have complete data", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["sign"] do
        sign = exchange["sign"]
        assert is_list(sign["params"]), "missing params on #{exchange["id"]}"
        assert is_boolean(sign["async"]), "missing async on #{exchange["id"]}"
        assert is_integer(sign["statements"]), "missing statements on #{exchange["id"]}"
        assert is_map(sign["body"]), "missing body on #{exchange["id"]}"
      end
    end
  end

  # Reference exchanges must be present
  for exchange <- @exchanges_with_sign ++ @dex_exchanges do
    test "#{exchange} is present", %{by_id: by_id} do
      assert Map.has_key?(by_id, unquote(exchange)),
             "Reference exchange '#{unquote(exchange)}' missing"
    end
  end

  # Exchanges that should have sign()
  for exchange <- @exchanges_with_sign do
    test "#{exchange} has non-null sign data", %{by_id: by_id} do
      assert by_id[unquote(exchange)]["sign"],
             "Expected #{unquote(exchange)} to have sign() method"
    end
  end

  describe "binance sign() details" do
    test "has standard 6 parameters", %{by_id: by_id} do
      params = by_id["binance"]["sign"]["params"]
      param_names = Enum.map(params, & &1["name"])

      assert length(params) == 6
      assert param_names == @standard_param_names
    end

    test "has substantial complexity", %{by_id: by_id} do
      assert by_id["binance"]["sign"]["statements"] >= 8
    end

    test "is synchronous", %{by_id: by_id} do
      assert by_id["binance"]["sign"]["async"] == false
    end
  end

  describe "body AST structure" do
    test "binance body has type and nested statements", %{by_id: by_id} do
      body = by_id["binance"]["sign"]["body"]

      assert is_map(body)
      assert is_binary(body["type"])
      assert is_list(body["body"])
      assert length(body["body"]) >= 8
    end

    test "body statements have type fields", %{by_id: by_id} do
      stmts = by_id["binance"]["sign"]["body"]["body"]

      for stmt <- stmts do
        assert is_binary(stmt["type"]),
               "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["sign"]["body"]

      assert is_integer(body["start"])
      assert is_integer(body["end"])
      assert body["end"] > body["start"]
    end
  end

  describe "all sign() methods are synchronous" do
    test "no async sign methods", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["sign"] do
        assert exchange["sign"]["async"] == false,
               "#{exchange["id"]} sign() should be sync"
      end
    end
  end
end
