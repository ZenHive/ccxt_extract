defmodule CcxtExtract.Integration.Cached.MethodsCachedTest do
  @moduledoc """
  Structure tests for methods_rest.json and methods_ws.json — reads cached discovery output.
  Same assertions as MethodsIntegrationTest but without OXC parsing.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir Path.expand("../../fixtures/discoveries", __DIR__)
  @rest_path Path.join(@fixtures_dir, "methods_rest.json")
  @ws_path Path.join(@fixtures_dir, "methods_ws.json")

  # Reference exchanges from CLAUDE.md — {id, min_method_count}
  @rest_expectations [
    {"binance", 166},
    {"bybit", 139},
    {"okx", 131},
    {"deribit", 68},
    {"coinbaseexchange", 42},
    {"kraken", 67},
    {"kucoin", 138},
    {"gate", 125},
    {"htx", 109},
    {"bitmex", 66},
    {"hyperliquid", 109},
    {"aster", 71},
    {"lighter", 58}
  ]

  @ws_expectations [
    {"binance", 10},
    {"bybit", 10},
    {"okx", 10},
    {"deribit", 10},
    {"kraken", 10},
    {"kucoin", 10},
    {"gate", 10},
    {"htx", 10},
    {"bitmex", 10}
  ]

  @binance_required_methods ~w(describe fetchTicker sign fetchBalance fetchOHLCV createOrder)

  setup_all do
    rest_data = @rest_path |> File.read!() |> Jason.decode!()
    ws_data = @ws_path |> File.read!() |> Jason.decode!()

    %{rest: rest_data["exchanges"], ws: ws_data["exchanges"]}
  end

  describe "REST structure" do
    test "every exchange has methods with full detail", %{rest: rest} do
      for exchange <- rest do
        assert is_binary(exchange["id"]), "missing id"
        assert is_binary(exchange["file"]), "missing file"
        assert is_integer(exchange["method_count"]), "missing method_count for #{exchange["id"]}"
        assert is_list(exchange["methods"]), "missing methods for #{exchange["id"]}"

        if exchange["method_count"] > 0 do
          method = hd(exchange["methods"])
          assert Map.has_key?(method, "name"), "method missing name in #{exchange["id"]}"
          assert Map.has_key?(method, "async"), "method missing async in #{exchange["id"]}"
          assert Map.has_key?(method, "params"), "method missing params in #{exchange["id"]}"
          assert Map.has_key?(method, "return_type"), "method missing return_type in #{exchange["id"]}"
          assert Map.has_key?(method, "statements"), "method missing statements in #{exchange["id"]}"
        end
      end
    end

    test "params include name and type fields", %{rest: rest} do
      binance = Enum.find(rest, &(&1["id"] == "binance"))
      assert binance, "binance not found in REST data"

      fetch_ticker = Enum.find(binance["methods"], &(&1["name"] == "fetchTicker"))
      assert fetch_ticker, "fetchTicker not found on binance"
      assert fetch_ticker["params"] != [], "fetchTicker should have params"

      for param <- fetch_ticker["params"] do
        assert Map.has_key?(param, "name"), "param missing name"
        assert Map.has_key?(param, "type"), "param missing type key"
      end
    end
  end

  # Parameterized REST method count tests
  for {id, min_methods} <- @rest_expectations do
    test "#{id} REST has >= #{min_methods} methods", %{rest: rest} do
      exchange = Enum.find(rest, &(&1["id"] == unquote(id)))
      assert exchange, "#{unquote(id)} not found in REST data"

      assert exchange["method_count"] >= unquote(min_methods),
             "#{unquote(id)} has #{exchange["method_count"]} methods, expected >= #{unquote(min_methods)}"
    end
  end

  # Binance must have specific known methods
  for method_name <- @binance_required_methods do
    test "binance REST has #{method_name} method", %{rest: rest} do
      binance = Enum.find(rest, &(&1["id"] == "binance"))
      method_names = Enum.map(binance["methods"], & &1["name"])

      assert unquote(method_name) in method_names,
             "binance missing required method: #{unquote(method_name)}"
    end
  end

  describe "WS structure" do
    test "WS exchanges have methods with full detail", %{ws: ws} do
      assert ws != [], "expected at least some WS exchanges"

      for exchange <- ws do
        assert is_binary(exchange["id"]), "missing id"
        assert is_integer(exchange["method_count"]), "missing method_count for #{exchange["id"]}"
        assert is_list(exchange["methods"]), "missing methods for #{exchange["id"]}"
      end
    end
  end

  # Parameterized WS method count tests
  for {id, min_methods} <- @ws_expectations do
    test "#{id} WS has >= #{min_methods} methods", %{ws: ws} do
      exchange = Enum.find(ws, &(&1["id"] == unquote(id)))
      assert exchange, "#{unquote(id)} not found in WS data"

      assert exchange["method_count"] >= unquote(min_methods),
             "#{unquote(id)} has #{exchange["method_count"]} methods, expected >= #{unquote(min_methods)}"
    end
  end

  describe "type annotation coverage" do
    test "at least some REST methods have type annotations", %{rest: rest} do
      all_params =
        rest
        |> Enum.flat_map(& &1["methods"])
        |> Enum.flat_map(& &1["params"])

      typed_params = Enum.count(all_params, & &1["type"])
      total_params = length(all_params)

      assert typed_params > 0,
             "expected some typed parameters, found 0 out of #{total_params}"
    end

    test "at least some REST methods have return types", %{rest: rest} do
      all_methods = Enum.flat_map(rest, & &1["methods"])
      with_return_type = Enum.count(all_methods, & &1["return_type"])

      assert with_return_type > 0,
             "expected some methods with return types, found 0 out of #{length(all_methods)}"
    end

    test "generic return types preserve type arguments", %{rest: rest} do
      binance = Enum.find(rest, &(&1["id"] == "binance"))
      assert binance, "binance not found in REST data"

      fetch_ticker = Enum.find(binance["methods"], &(&1["name"] == "fetchTicker"))
      assert fetch_ticker, "fetchTicker not found in binance methods"

      assert fetch_ticker["return_type"] == "Promise<Ticker>",
             "expected Promise<Ticker>, got #{inspect(fetch_ticker["return_type"])}"
    end
  end
end
