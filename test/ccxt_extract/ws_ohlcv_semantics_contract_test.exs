defmodule CcxtExtract.WsOhlcvSemanticsContractTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ContractTest
  alias CcxtExtract.WsOhlcvSemantics

  @base_observed %{}

  defp ws_exchange(id, ohlcv_semantics) do
    %{"exchange" => %{"id" => id}, "websocket" => %{"ohlcv_semantics" => ohlcv_semantics}}
  end

  describe "check_websocket_ohlcv_semantics_shape_valid/2" do
    test "no findings on the honest-empty none_record" do
      exchange = ws_exchange("restonly", WsOhlcvSemantics.none_record())
      assert ContractTest.check_websocket_ohlcv_semantics_shape_valid(exchange, @base_observed) == []
    end

    test "no findings on a freshly-derived replace_latest_then_append record" do
      entry = %{
        "id" => "bybit",
        "extends" => "bybitRest",
        "ohlcv" => %{
          "defined" => true,
          "update_model" => "replace_latest_then_append",
          "timeframe_key" => nil,
          "closed_signal" => "confirm",
          "cache_type" => "ArrayCacheByTimestamp",
          "cache_limit_field" => "OHLCVLimit",
          "cache_limit_default" => 1000,
          "unresolved" => []
        }
      }

      exchange = ws_exchange("bybit", WsOhlcvSemantics.build(entry, %{"bybit" => entry}))
      assert ContractTest.check_websocket_ohlcv_semantics_shape_valid(exchange, @base_observed) == []
    end

    test "no findings on a binance-style record with timeframe_key and closed 'x'" do
      entry = %{
        "id" => "binance",
        "extends" => "binanceRest",
        "ohlcv" => %{
          "defined" => true,
          "update_model" => "replace_latest_then_append",
          "timeframe_key" => "i",
          "closed_signal" => "x",
          "cache_type" => "ArrayCacheByTimestamp",
          "cache_limit_field" => "OHLCVLimit",
          "cache_limit_default" => 1000,
          "unresolved" => []
        }
      }

      exchange = ws_exchange("binance", WsOhlcvSemantics.build(entry, %{"binance" => entry}))
      assert ContractTest.check_websocket_ohlcv_semantics_shape_valid(exchange, @base_observed) == []
    end
  end
end
