defmodule CcxtExtract.MethodsIntegrationTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Methods

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 60_000

  # Reference exchanges from CLAUDE.md — {id, min_method_count}
  # Breaking on CCXT update is intentional: forces review of what changed
  @rest_expectations [
    {"binance", 165},
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

  # Methods that must exist on binance (smoke test for extraction correctness)
  @binance_required_methods ~w(describe fetchTicker sign fetchBalance fetchOHLCV createOrder)

  # Run extraction once per type
  setup_all do
    {:ok, rest_exchanges, rest_stats} = Methods.extract(:rest)
    {:ok, ws_exchanges, ws_stats} = Methods.extract(:ws)

    %{
      rest: rest_exchanges,
      rest_stats: rest_stats,
      ws: ws_exchanges,
      ws_stats: ws_stats
    }
  end

  describe "extract(:rest)" do
    test "parses all files without errors", %{rest: rest, rest_stats: stats} do
      assert stats.errors == [],
             "Expected zero parse errors, got #{length(stats.errors)}: #{inspect(stats.errors)}"

      # All REST files should be accounted for
      total_files = length(Path.wildcard(Path.join(CcxtExtract.Paths.ts_src(), "*.ts")))
      total_accounted = length(rest) + length(stats.skipped) + length(stats.errors)
      assert total_accounted == total_files
    end

    test "every exchange has methods with full detail", %{rest: rest} do
      for exchange <- rest do
        assert is_binary(exchange["id"]), "missing id"
        assert is_binary(exchange["file"]), "missing file"
        assert is_integer(exchange["method_count"]), "missing method_count for #{exchange["id"]}"
        assert is_list(exchange["methods"]), "missing methods for #{exchange["id"]}"

        # Spot-check method structure on exchanges with methods
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
      assert binance, "binance not found in REST extraction"

      # fetchTicker has params — check they have structure
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
      assert exchange, "#{unquote(id)} not found in REST extraction"

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

  describe "extract(:ws)" do
    test "parses all WS files without errors", %{ws: ws, ws_stats: stats} do
      assert stats.errors == [],
             "Expected zero WS parse errors, got #{length(stats.errors)}: #{inspect(stats.errors)}"

      total_files = length(Path.wildcard(Path.join(CcxtExtract.Paths.ts_src(), "pro/*.ts")))
      total_accounted = length(ws) + length(stats.skipped) + length(stats.errors)
      assert total_accounted == total_files
    end

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
      assert exchange, "#{unquote(id)} not found in WS extraction"

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
      # fetchTicker returns Promise<Ticker> in CCXT TS source — verify generics aren't truncated
      binance = Enum.find(rest, &(&1["id"] == "binance"))
      assert binance, "binance not found in REST extraction"

      fetch_ticker = Enum.find(binance["methods"], &(&1["name"] == "fetchTicker"))
      assert fetch_ticker, "fetchTicker not found in binance methods"

      assert fetch_ticker["return_type"] == "Promise<Ticker>",
             "expected Promise<Ticker>, got #{inspect(fetch_ticker["return_type"])}"
    end

    test "array generic types are preserved", %{rest: rest} do
      binance = Enum.find(rest, &(&1["id"] == "binance"))
      assert binance, "binance not found in REST extraction"

      # fetchTickers returns Promise<Tickers> — verify any generic is preserved
      fetch_tickers = Enum.find(binance["methods"], &(&1["name"] == "fetchTickers"))

      if fetch_tickers && fetch_tickers["return_type"] do
        assert fetch_tickers["return_type"] =~ ~r/^Promise<.+>$/,
               "expected Promise<...>, got #{inspect(fetch_tickers["return_type"])}"
      end
    end
  end
end
