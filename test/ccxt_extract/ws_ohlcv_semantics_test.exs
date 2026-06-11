defmodule CcxtExtract.WsOhlcvSemanticsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsOhlcvSemantics

  defp entry(id, overrides) do
    Map.merge(
      %{
        "id" => id,
        "class_name" => id,
        "file" => "#{id}.ts",
        "extends" => "#{id}Rest",
        "ohlcv" => ohlcv_absent()
      },
      overrides
    )
  end

  defp ohlcv_absent do
    %{
      "defined" => false,
      "update_model" => nil,
      "timeframe_key" => nil,
      "closed_signal" => nil,
      "cache_type" => nil,
      "cache_limit_field" => nil,
      "cache_limit_default" => nil,
      "unresolved" => []
    }
  end

  defp ohlcv(opts) do
    %{
      "defined" => true,
      "update_model" => Keyword.get(opts, :update_model, "replace_latest_then_append"),
      "timeframe_key" => Keyword.get(opts, :timeframe_key),
      "closed_signal" => Keyword.get(opts, :closed_signal),
      "cache_type" => Keyword.get(opts, :cache_type, "ArrayCacheByTimestamp"),
      "cache_limit_field" => Keyword.get(opts, :cache_limit_field, "OHLCVLimit"),
      "cache_limit_default" => Keyword.get(opts, :cache_limit_default, 1000),
      "unresolved" => Keyword.get(opts, :unresolved, [])
    }
  end

  describe "build/2 — no WebSocket class" do
    test "nil entry yields the honest none_record" do
      assert WsOhlcvSemantics.build(nil, %{}) == WsOhlcvSemantics.none_record()
    end

    test "none_record is internally coherent" do
      r = WsOhlcvSemantics.none_record()

      assert r["update_model"] == "none"
      assert r["ohlcv_defined"] == false
      assert r["timeframe_key"] == nil
      assert r["closed_signal"] == nil
      assert r["cache_type"] == nil
      assert r["cache_limit_field"] == nil
      assert r["cache_limit_default"] == nil
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_support"
      assert Enum.sort(Map.keys(r)) == Enum.sort(WsOhlcvSemantics.required_keys())
    end
  end

  describe "build/2 — ohlcv handler present" do
    test "replace_latest_then_append with closed_signal and timeframe_key" do
      e = entry("bybit", %{"ohlcv" => ohlcv(closed_signal: "confirm", timeframe_key: nil)})
      r = WsOhlcvSemantics.build(e, %{"bybit" => e})

      assert r["update_model"] == "replace_latest_then_append"
      assert r["ohlcv_defined"] == true
      assert r["closed_signal"] == "confirm"
      assert r["timeframe_key"] == nil
      assert r["cache_type"] == "ArrayCacheByTimestamp"
      assert r["cache_limit_field"] == "OHLCVLimit"
      assert r["cache_limit_default"] == 1000
      assert r["resolved_from"] == "self"
      assert r["source"] == "pro_handle_ohlcv"
      assert is_nil(r["unresolved_reason"])
    end

    test "binance-style with 'i' and 'x'" do
      e = entry("binance", %{"ohlcv" => ohlcv(timeframe_key: "i", closed_signal: "x")})
      r = WsOhlcvSemantics.build(e, %{"binance" => e})

      assert r["timeframe_key"] == "i"
      assert r["closed_signal"] == "x"
    end

    test "unrecognized ohlcv handler shape is preserved as unresolved" do
      e =
        entry("oddex", %{
          "ohlcv" =>
            ohlcv(
              update_model: "unknown",
              cache_type: nil,
              timeframe_key: nil,
              closed_signal: nil,
              cache_limit_field: nil,
              unresolved: [%{"reason" => "cache_not_classifiable"}]
            )
        })

      r = WsOhlcvSemantics.build(e, %{"oddex" => e})

      assert r["update_model"] == "unknown"
      assert r["unresolved"] == [%{"reason" => "cache_not_classifiable"}]
      assert r["unresolved_reason"] == "ohlcv_not_classifiable"
    end
  end
end
