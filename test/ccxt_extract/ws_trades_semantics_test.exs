defmodule CcxtExtract.WsTradesSemanticsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsTradesSemantics

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class_name" => id,
        "file" => "#{id}.ts",
        "extends" => "#{id}Rest",
        "trades" => trades_absent(),
        "my_trades" => trades_absent()
      },
      overrides
    )
  end

  defp trades_absent do
    %{
      "defined" => false,
      "update_model" => nil,
      "cache_type" => nil,
      "dedup_key" => nil,
      "cache_limit_field" => nil,
      "cache_limit_default" => nil,
      "unresolved" => []
    }
  end

  defp trades(opts) do
    %{
      "defined" => true,
      "update_model" => Keyword.get(opts, :update_model, "append"),
      "cache_type" => Keyword.get(opts, :cache_type, "ArrayCacheBySymbolById"),
      "dedup_key" => Keyword.get(opts, :dedup_key, "id"),
      "cache_limit_field" => Keyword.get(opts, :cache_limit_field, "tradesLimit"),
      "cache_limit_default" => Keyword.get(opts, :cache_limit_default),
      "unresolved" => Keyword.get(opts, :unresolved, [])
    }
  end

  describe "build/2 — no WebSocket class" do
    test "nil entry yields the honest none_record" do
      assert WsTradesSemantics.build(nil, %{}) == WsTradesSemantics.none_record()
    end

    test "none_record is internally coherent" do
      r = WsTradesSemantics.none_record()

      assert r["update_model"] == "none"
      assert r["trades_defined"] == false
      assert r["cache_type"] == nil
      assert r["dedup_key"] == nil
      assert r["cache_limit_field"] == nil
      assert r["cache_limit_default"] == nil
      assert r["my_trades"]["defined"] == false
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_support"
      assert Enum.sort(Map.keys(r)) == Enum.sort(WsTradesSemantics.required_keys())
    end
  end

  describe "build/2 — public trades" do
    test "append-only trades are projected with cache metadata" do
      e = entry("bybit", %{"trades" => trades(dedup_key: "T", cache_limit_default: 1000)})
      r = WsTradesSemantics.build(e, %{"bybit" => e})

      assert r["update_model"] == "append"
      assert r["trades_defined"] == true
      assert r["cache_type"] == "ArrayCacheBySymbolById"
      assert r["dedup_key"] == "T"
      assert r["cache_limit_field"] == "tradesLimit"
      assert r["cache_limit_default"] == 1000
      assert r["resolved_from"] == "self"
      assert r["source"] == "pro_handle_trades"
      assert is_nil(r["unresolved_reason"])
    end

    test "unrecognized trades handler shape is preserved as unresolved" do
      e =
        entry("oddex", %{
          "trades" =>
            trades(
              update_model: "unknown",
              cache_type: nil,
              dedup_key: nil,
              cache_limit_field: nil,
              unresolved: [%{"reason" => "cache_not_classifiable"}]
            )
        })

      r = WsTradesSemantics.build(e, %{"oddex" => e})

      assert r["update_model"] == "unknown"
      assert r["unresolved"] == [%{"reason" => "cache_not_classifiable"}]
      assert r["unresolved_reason"] == "trades_not_classifiable"
    end

    test "a WS class without trades yields none tagged no_ws_trades" do
      e = entry("hyperliquid")
      r = WsTradesSemantics.build(e, %{"hyperliquid" => e})

      assert r["update_model"] == "none"
      assert r["trades_defined"] == false
      assert r["unresolved_reason"] == "no_ws_trades"
    end
  end

  describe "build/2 — myTrades" do
    test "private myTrades channel is carried with its own limit" do
      e =
        entry("binance", %{
          "trades" => trades(cache_limit_field: "tradesLimit"),
          "my_trades" =>
            trades(
              cache_type: "ArrayCacheBySymbolById",
              dedup_key: "id",
              cache_limit_field: "myTradesLimit",
              cache_limit_default: 1000
            )
        })

      r = WsTradesSemantics.build(e, %{"binance" => e})

      assert r["my_trades"] == %{
               "defined" => true,
               "cache_type" => "ArrayCacheBySymbolById",
               "dedup_key" => "id",
               "cache_limit_field" => "myTradesLimit",
               "cache_limit_default" => 1000
             }
    end
  end

  describe "build/2 — extends-chain inheritance" do
    test "a child without handleTrades inherits the parent's record" do
      parent = entry("binance", %{"trades" => trades(dedup_key: "t")})
      child = entry("binanceusdm", %{"extends" => "binance"})
      lookup = %{"binance" => parent, "binanceusdm" => child}

      r = WsTradesSemantics.build(child, lookup)

      assert r["update_model"] == "append"
      assert r["resolved_from"] == "binance"
      assert r["dedup_key"] == "t"
    end

    test "a child that defines its own handleTrades resolves as self" do
      parent = entry("base", %{"trades" => trades(dedup_key: "parent")})
      child = entry("variant", %{"extends" => "base", "trades" => trades(dedup_key: "child")})

      r = WsTradesSemantics.build(child, %{"base" => parent, "variant" => child})

      assert r["resolved_from"] == "self"
      assert r["dedup_key"] == "child"
    end
  end

  describe "closed-vocabulary exposers" do
    test "vocabularies are stable" do
      assert WsTradesSemantics.update_models() == ~w(append replace snapshot unknown none)
      assert WsTradesSemantics.sources() == ~w(pro_handle_trades none)

      assert WsTradesSemantics.unresolved_reasons() ==
               ~w(no_ws_support no_ws_trades trades_not_classifiable)

      assert WsTradesSemantics.unresolved_entry_reasons() ==
               ~w(cache_not_classifiable dedup_key_not_classifiable update_model_not_classifiable)
    end
  end

  describe "extract_from_ast/2" do
    test "extracts append cache metadata from handleTrades" do
      source = """
      export default class bx extends bxRest {
          handleTrades (client, message) {
              const trades = this.parseTrades (message['data']);
              const stored = this.safeValue (this.trades, symbol);
              const limit = this.safeInteger (this.options, 'tradesLimit', 1000);
              const cache = new ArrayCacheBySymbolById (limit);
              this.trades[symbol] = cache;
              for (let i = 0; i < trades.length; i++) {
                  const trade = trades[i];
                  const id = this.safeString (trade, 'T');
                  cache.append (trade);
              }
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "bx.ts")
      e = WsTradesSemantics.extract_from_ast(ast, "bx.ts")
      trades = e["trades"]

      assert e["id"] == "bx"
      assert e["extends"] == "bxRest"
      assert trades["defined"] == true
      assert trades["update_model"] == "append"
      assert trades["cache_type"] == "ArrayCacheBySymbolById"
      assert trades["dedup_key"] == "T"
      assert trades["cache_limit_field"] == "tradesLimit"
      assert trades["cache_limit_default"] == 1000
      assert trades["unresolved"] == []
    end

    test "extracts private myTrades with myTradesLimit" do
      source = """
      export default class pv extends pvRest {
          handleMyTrade (client, message) {
              const trades = this.parseTrades (message['data']);
              const limit = this.safeInteger (this.options, 'myTradesLimit', 500);
              const cache = new ArrayCacheBySymbolById (limit);
              for (let i = 0; i < trades.length; i++) {
                  const trade = trades[i];
                  const id = this.safeString (trade, 'id');
                  cache.append (trade);
              }
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "pv.ts")
      my_trades = WsTradesSemantics.extract_from_ast(ast, "pv.ts")["my_trades"]

      assert my_trades["defined"] == true
      assert my_trades["cache_type"] == "ArrayCacheBySymbolById"
      assert my_trades["dedup_key"] == "id"
      assert my_trades["cache_limit_field"] == "myTradesLimit"
      assert my_trades["cache_limit_default"] == 500
    end

    test "a class with no trades handlers reports honest absence" do
      source = """
      export default class plain extends plainRest {
          watchTicker (symbol, params = {}) { return this.watch (symbol, params); }
      }
      """

      {:ok, ast} = OXC.parse(source, "plain.ts")
      e = WsTradesSemantics.extract_from_ast(ast, "plain.ts")

      assert e["trades"]["defined"] == false
      assert e["my_trades"]["defined"] == false
    end
  end
end
