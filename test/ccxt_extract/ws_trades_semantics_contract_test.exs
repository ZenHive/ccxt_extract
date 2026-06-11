defmodule CcxtExtract.WsTradesSemanticsContractTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ContractTest
  alias CcxtExtract.WsTradesSemantics

  @base_observed %{}

  defp ws_exchange(id, trades_semantics) do
    %{"exchange" => %{"id" => id}, "websocket" => %{"trades_semantics" => trades_semantics}}
  end

  describe "check_websocket_trades_semantics_shape_valid/2" do
    test "no findings on the honest-empty none_record" do
      exchange = ws_exchange("restonly", WsTradesSemantics.none_record())
      assert ContractTest.check_websocket_trades_semantics_shape_valid(exchange, @base_observed) == []
    end

    test "no findings on a freshly-derived append record" do
      entry = %{
        "id" => "okx",
        "extends" => "okxRest",
        "trades" => %{
          "defined" => true,
          "update_model" => "append",
          "cache_type" => "ArrayCacheBySymbolById",
          "dedup_key" => "id",
          "cache_limit_field" => "tradesLimit",
          "cache_limit_default" => 1000,
          "unresolved" => []
        },
        "my_trades" => %{
          "defined" => false,
          "update_model" => nil,
          "cache_type" => nil,
          "dedup_key" => nil,
          "cache_limit_field" => nil,
          "cache_limit_default" => nil,
          "unresolved" => []
        }
      }

      exchange = ws_exchange("okx", WsTradesSemantics.build(entry, %{"okx" => entry}))
      assert ContractTest.check_websocket_trades_semantics_shape_valid(exchange, @base_observed) == []
    end

    test "no findings on an append record with unresolved (null) dedup_key" do
      entry = %{
        "id" => "binance",
        "extends" => "binanceRest",
        "trades" => %{
          "defined" => true,
          "update_model" => "append",
          "cache_type" => "ArrayCache",
          "dedup_key" => nil,
          "cache_limit_field" => "tradesLimit",
          "cache_limit_default" => nil,
          "unresolved" => [%{"reason" => "dedup_key_not_classifiable"}]
        },
        "my_trades" => %{
          "defined" => false,
          "update_model" => nil,
          "cache_type" => nil,
          "dedup_key" => nil,
          "cache_limit_field" => nil,
          "cache_limit_default" => nil,
          "unresolved" => []
        }
      }

      exchange = ws_exchange("binance", WsTradesSemantics.build(entry, %{"binance" => entry}))
      assert ContractTest.check_websocket_trades_semantics_shape_valid(exchange, @base_observed) == []
    end

    test "non-map trades_semantics is flagged" do
      [finding] =
        ContractTest.check_websocket_trades_semantics_shape_valid(
          ws_exchange("bad", "garbage"),
          @base_observed
        )

      assert finding.exchange == "bad"
      assert finding.invariant == "websocket_trades_semantics_shape_valid"
      assert finding.path == "websocket/trades_semantics"
      assert finding.message =~ "must be a map"
    end

    test "a missing required key is flagged" do
      record = Map.delete(WsTradesSemantics.none_record(), "cache_type")

      [finding] =
        ContractTest.check_websocket_trades_semantics_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert finding.message =~ "missing required key"
      assert finding.message =~ "cache_type"
    end

    test "an unexpected key is flagged" do
      record = Map.put(WsTradesSemantics.none_record(), "rogue", true)

      [finding] =
        ContractTest.check_websocket_trades_semantics_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert finding.message =~ "unexpected key"
      assert finding.message =~ "rogue"
    end

    test "out-of-vocabulary update_model is flagged" do
      record = Map.put(WsTradesSemantics.none_record(), "update_model", "bogus")

      findings =
        ContractTest.check_websocket_trades_semantics_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert Enum.any?(findings, &(&1.message =~ "update_model must be one of"))
    end

    test "update_model=none carrying cache metadata is flagged" do
      record = Map.put(WsTradesSemantics.none_record(), "cache_type", "ArrayCacheBySymbolById")

      [finding] =
        ContractTest.check_websocket_trades_semantics_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert finding.message =~ "update_model=none requires cache_type=null"
    end

    test "update_model=unknown must agree with unresolved_reason" do
      record =
        WsTradesSemantics.none_record()
        |> Map.put("update_model", "unknown")
        |> Map.put("trades_defined", true)
        |> Map.put("source", "pro_handle_trades")
        |> Map.put("unresolved_reason", nil)

      findings =
        ContractTest.check_websocket_trades_semantics_shape_valid(
          ws_exchange("bad", record),
          @base_observed
        )

      assert Enum.any?(findings, &(&1.message =~ "update_model=unknown must agree"))
    end
  end
end
