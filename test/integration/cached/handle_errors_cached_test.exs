defmodule CcxtExtract.Integration.Cached.HandleErrorsCachedTest do
  @moduledoc """
  Structure tests for handle_errors.json — reads cached discovery output.
  Same assertions as HandleErrorsIntegrationTest but without OXC parsing.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir Path.expand("../../fixtures/discoveries", __DIR__)
  @fixture_path Path.join(@fixtures_dir, "handle_errors.json")

  # Reference exchanges that should have handleErrors()
  @exchanges_with_handle_errors ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex)

  # DEX exchanges
  @dex_exchanges ~w(hyperliquid aster lighter)

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_handle_errors"])
      assert is_list(data["exchanges"])
    end

    test "counts are consistent", %{data: data} do
      assert data["count"] == length(data["exchanges"])
      actual_with_he = Enum.count(data["exchanges"], & &1["handle_errors"])
      assert data["with_handle_errors"] == actual_with_he
    end

    test "at least 100 exchanges extracted", %{data: data} do
      assert data["count"] >= 100
    end

    test "majority have handleErrors()", %{data: data} do
      assert data["with_handle_errors"] >= 80
    end
  end

  describe "exchange structure" do
    test "every exchange has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert is_binary(exchange["id"]), "missing id"
        assert is_binary(exchange["file"]), "missing file"
        assert Map.has_key?(exchange, "handle_errors"), "missing handle_errors key on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "missing class_name on #{exchange["id"]}"
        assert Map.has_key?(exchange, "exceptions"), "missing exceptions on #{exchange["id"]}"
        assert Map.has_key?(exchange, "http_exceptions"), "missing http_exceptions on #{exchange["id"]}"
      end
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "exchanges with handleErrors have complete data", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["handle_errors"] do
        he = exchange["handle_errors"]
        assert is_list(he["params"]), "missing params on #{exchange["id"]}"
        assert is_boolean(he["async"]), "missing async on #{exchange["id"]}"
        assert is_integer(he["statements"]), "missing statements on #{exchange["id"]}"
        assert is_map(he["body"]), "missing body on #{exchange["id"]}"
      end
    end
  end

  # Reference exchanges must be present
  for exchange <- @exchanges_with_handle_errors ++ @dex_exchanges do
    test "#{exchange} is present", %{by_id: by_id} do
      assert Map.has_key?(by_id, unquote(exchange)),
             "Reference exchange '#{unquote(exchange)}' missing"
    end
  end

  # Exchanges that should have handleErrors()
  for exchange <- @exchanges_with_handle_errors do
    test "#{exchange} has non-null handleErrors data", %{by_id: by_id} do
      assert by_id[unquote(exchange)]["handle_errors"],
             "Expected #{unquote(exchange)} to have handleErrors() method"
    end
  end

  describe "binance handleErrors() details" do
    test "has parameters", %{by_id: by_id} do
      params = by_id["binance"]["handle_errors"]["params"]
      assert length(params) >= 2
    end

    test "has substantial complexity", %{by_id: by_id} do
      assert by_id["binance"]["handle_errors"]["statements"] >= 3
    end

    test "is synchronous", %{by_id: by_id} do
      assert by_id["binance"]["handle_errors"]["async"] == false
    end
  end

  describe "describe exceptions" do
    test "exceptions and http_exceptions are map or nil for every exchange", %{exchanges: exchanges} do
      for exchange <- exchanges do
        exc = exchange["exceptions"]
        http_exc = exchange["http_exceptions"]

        assert is_map(exc) or is_nil(exc),
               "#{exchange["id"]} exceptions should be map or nil, got: #{inspect(exc)}"

        assert is_map(http_exc) or is_nil(http_exc),
               "#{exchange["id"]} http_exceptions should be map or nil, got: #{inspect(http_exc)}"
      end
    end

    test "binance has exceptions with exact/broad keys", %{by_id: by_id} do
      exc = by_id["binance"]["exceptions"]

      assert is_map(exc)
      assert Map.has_key?(exc, "exact") || Map.has_key?(exc, "broad")
    end

    test "binance has httpExceptions with HTTP status codes", %{by_id: by_id} do
      http_exc = by_id["binance"]["http_exceptions"]

      assert is_map(http_exc)

      assert Map.has_key?(http_exc, "400") ||
               Map.has_key?(http_exc, "401") ||
               Map.has_key?(http_exc, "403")
    end
  end

  describe "body AST structure" do
    test "binance body has type and nested statements", %{by_id: by_id} do
      body = by_id["binance"]["handle_errors"]["body"]

      assert is_map(body)
      assert is_binary(body["type"])
      assert is_list(body["body"])
      assert length(body["body"]) >= 3
    end

    test "body statements have type fields", %{by_id: by_id} do
      stmts = by_id["binance"]["handle_errors"]["body"]["body"]

      for stmt <- stmts do
        assert is_binary(stmt["type"]),
               "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["handle_errors"]["body"]

      assert is_integer(body["start"])
      assert is_integer(body["end"])
      assert body["end"] > body["start"]
    end
  end

  describe "all handleErrors() methods are synchronous" do
    test "no async handleErrors methods", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["handle_errors"] do
        assert exchange["handle_errors"]["async"] == false,
               "#{exchange["id"]} handleErrors() should be sync"
      end
    end
  end
end
