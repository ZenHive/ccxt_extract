defmodule CcxtExtract.WsDispatchTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsDispatch

  # --- Raw-entry fixture builders ---

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class_name" => id,
        "file" => "#{id}.ts",
        "extends" => "#{id}Rest",
        "handle_message" => hm_absent()
      },
      overrides
    )
  end

  defp hm_absent do
    %{"defined" => false, "discriminators" => [], "entries" => [], "unresolved" => []}
  end

  defp hm(opts) do
    %{
      "defined" => true,
      "discriminators" => Keyword.get(opts, :discriminators, []),
      "entries" => Keyword.get(opts, :entries, []),
      "unresolved" => Keyword.get(opts, :unresolved, [])
    }
  end

  defp pair(channel, handler), do: %{"channel" => channel, "handler" => handler}

  describe "build/2 — no WebSocket class" do
    test "nil entry yields the honest none_record" do
      assert WsDispatch.build(nil, %{}) == WsDispatch.none_record()
    end

    test "none_record is internally coherent" do
      r = WsDispatch.none_record()
      assert r["kind"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_support"
      assert r["handle_message_defined"] == false
      assert r["entries"] == []
      assert r["discriminators"] == []
      assert is_nil(r["resolved_from"])
      assert Enum.sort(Map.keys(r)) == Enum.sort(WsDispatch.required_keys())
    end
  end

  describe "build/2 — Pro class without handleMessage()" do
    test "a WS class lacking handleMessage is kind none tagged no_ws_dispatch" do
      e = entry("hyperliquid")
      r = WsDispatch.build(e, %{"hyperliquid" => e})

      assert r["kind"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_dispatch"
      assert r["handle_message_defined"] == false
      assert is_nil(r["resolved_from"])
    end
  end

  describe "build/2 — dispatch classification" do
    test "a handler-map table with entries yields routed/self" do
      e = entry("bybit", %{"handle_message" => hm(discriminators: ["topic"], entries: [pair("kline", "handleOHLCV")])})
      r = WsDispatch.build(e, %{"bybit" => e})

      assert r["kind"] == "routed"
      assert r["entries"] == [pair("kline", "handleOHLCV")]
      assert r["discriminators"] == ["topic"]
      assert r["source"] == "pro_handle_message"
      assert r["resolved_from"] == "self"
      assert is_nil(r["unresolved_reason"])
    end

    test "partial resolution keeps the routed kind and carries the unresolved findings" do
      handle = hm(entries: [pair("trade", "handleTrades")], unresolved: [%{"reason" => "computed_channel_key"}])
      e = entry("ex", %{"handle_message" => handle})
      r = WsDispatch.build(e, %{"ex" => e})

      assert r["kind"] == "routed"
      assert r["unresolved"] == [%{"reason" => "computed_channel_key"}]
      assert is_nil(r["unresolved_reason"])
    end

    test "handleMessage defined but no resolvable entry yields opaque" do
      e = entry("phemex", %{"handle_message" => hm(entries: [])})
      r = WsDispatch.build(e, %{"phemex" => e})

      assert r["kind"] == "opaque"
      assert r["handle_message_defined"] == true
      assert r["entries"] == []
      assert r["unresolved_reason"] == "dispatch_not_classifiable"
      assert r["resolved_from"] == "self"
    end
  end

  describe "build/2 — extends-chain inheritance" do
    test "a child without handleMessage inherits the parent's table, tagged with the ancestor id" do
      parent = entry("binance", %{"handle_message" => hm(discriminators: ["e"], entries: [pair("trade", "handleTrade")])})
      child = entry("binanceusdm", %{"extends" => "binance"})
      lookup = %{"binance" => parent, "binanceusdm" => child}

      r = WsDispatch.build(child, lookup)

      assert r["kind"] == "routed"
      assert r["resolved_from"] == "binance"
      assert r["entries"] == [pair("trade", "handleTrade")]
      assert r["discriminators"] == ["e"]
    end

    test "a child that defines its own handleMessage resolves as self, not the parent" do
      parent = entry("base", %{"handle_message" => hm(entries: [pair("a", "handleA")])})
      child = entry("variant", %{"extends" => "base", "handle_message" => hm(entries: [pair("b", "handleB")])})
      r = WsDispatch.build(child, %{"base" => parent, "variant" => child})

      assert r["resolved_from"] == "self"
      assert r["entries"] == [pair("b", "handleB")]
    end

    test "a cyclic extends chain terminates instead of looping forever" do
      a = entry("a", %{"extends" => "b"})
      b = entry("b", %{"extends" => "a", "handle_message" => hm(entries: [pair("c", "handleC")])})
      r = WsDispatch.build(a, %{"a" => a, "b" => b})

      assert r["kind"] == "routed"
      assert r["resolved_from"] == "b"
    end
  end

  describe "closed-vocabulary exposers" do
    test "vocabularies are stable" do
      assert WsDispatch.kinds() == ~w(routed opaque none)
      assert WsDispatch.sources() == ~w(pro_handle_message none)
      assert WsDispatch.unresolved_reasons() == ~w(no_ws_support no_ws_dispatch dispatch_not_classifiable)
      assert WsDispatch.unresolved_entry_reasons() == ~w(computed_channel_key spread_property non_handler_value)
    end

    test "every build/2 result carries exactly the required key set" do
      e = entry("ex", %{"handle_message" => hm(entries: [pair("x", "handleX")])})

      for record <- [WsDispatch.build(e, %{"ex" => e}), WsDispatch.none_record()] do
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsDispatch.required_keys())
      end
    end
  end

  describe "extract_from_ast/2 — object-literal handler map" do
    test "extracts channel→handler entries and the safeValue discriminator" do
      source = """
      export default class bx extends bxRest {
          handleMessage (client, message) {
              const methods = {
                  'orderbook': this.handleOrderBook,
                  'kline': this.handleOHLCV,
              };
              const topic = this.safeString (message, 'topic');
              const method = this.safeValue (methods, topic);
              if (method !== undefined) {
                  method.call (this, client, message);
              }
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "bx.ts")
      e = WsDispatch.extract_from_ast(ast, "bx.ts")
      hm = e["handle_message"]

      assert e["id"] == "bx"
      assert e["extends"] == "bxRest"
      assert hm["defined"] == true
      assert pair("orderbook", "handleOrderBook") in hm["entries"]
      assert pair("kline", "handleOHLCV") in hm["entries"]
      assert hm["discriminators"] == ["topic"]
      assert hm["unresolved"] == []
    end

    test "a spread property and a computed key land in unresolved, not entries" do
      source = """
      export default class sp extends spRest {
          handleMessage (client, message) {
              const methods = {
                  ...this.baseMethods,
                  [dynamicKey]: this.handleDynamic,
                  'trade': this.handleTrades,
              };
              const method = this.safeValue (methods, this.safeString (message, 'e'));
              method.call (this, client, message);
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "sp.ts")
      hm = WsDispatch.extract_from_ast(ast, "sp.ts")["handle_message"]

      assert pair("trade", "handleTrades") in hm["entries"]
      reasons = Enum.map(hm["unresolved"], & &1["reason"])
      assert "spread_property" in reasons
      assert "computed_channel_key" in reasons
      assert hm["discriminators"] == ["e"]
    end

    test "a non-handler map value yields a non_handler_value finding" do
      source = """
      export default class nh extends nhRest {
          handleMessage (client, message) {
              const methods = {
                  'depth': this.handleOrderBook,
                  'meta': this.parseMeta,
              };
              const method = this.safeValue (methods, this.safeString (message, 'channel'));
              method.call (this, client, message);
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "nh.ts")
      hm = WsDispatch.extract_from_ast(ast, "nh.ts")["handle_message"]

      assert hm["entries"] == [pair("depth", "handleOrderBook")]
      assert %{"reason" => "non_handler_value"} in hm["unresolved"]
    end
  end

  describe "extract_from_ast/2 — if/switch chain" do
    test "extracts === channel comparisons that call a handler directly" do
      source = """
      export default class ic extends icRest {
          handleMessage (client, message) {
              const topic = this.safeString (message, 'topic');
              if (topic === 'kline') {
                  this.handleOHLCV (client, message);
              } else if (topic === 'trade' || topic === 'trades') {
                  this.handleTrades (client, message);
              }
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "ic.ts")
      hm = WsDispatch.extract_from_ast(ast, "ic.ts")["handle_message"]

      assert pair("kline", "handleOHLCV") in hm["entries"]
      assert pair("trade", "handleTrades") in hm["entries"]
      assert pair("trades", "handleTrades") in hm["entries"]
      assert hm["discriminators"] == ["topic"]
    end

    test "duplicate entries across map and if-chain deduplicate" do
      source = """
      export default class du extends duRest {
          handleMessage (client, message) {
              const methods = { 'pong': this.handlePong };
              const topic = this.safeString (message, 'topic');
              this.safeValue (methods, topic);
              if (topic === 'pong') {
                  this.handlePong (client, message);
              }
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "du.ts")
      hm = WsDispatch.extract_from_ast(ast, "du.ts")["handle_message"]

      assert hm["entries"] == [pair("pong", "handlePong")]
    end

    test "extracts switch cases, including fall-through channel aliases" do
      source = """
      export default class sw extends swRest {
          handleMessage (client, message) {
              const topic = this.safeString (message, 'topic');
              switch (topic) {
                  case 'ticker':
                      this.handleTicker (client, message);
                      break;
                  case 'trade':
                  case 'trades':
                      this.handleTrades (client, message);
                      break;
                  default:
                      this.handleMessageDefault (client, message);
              }
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "sw.ts")
      hm = WsDispatch.extract_from_ast(ast, "sw.ts")["handle_message"]

      assert pair("ticker", "handleTicker") in hm["entries"]
      assert pair("trade", "handleTrades") in hm["entries"]
      assert pair("trades", "handleTrades") in hm["entries"]
      refute Enum.any?(hm["entries"], &(&1["handler"] == "handleMessageDefault"))
      assert hm["discriminators"] == ["topic"]
    end
  end

  describe "extract_from_ast/2 — honest absence" do
    test "a class with no handleMessage reports defined false and empty facts" do
      source = """
      export default class plain extends plainRest {
          watchTicker (symbol, params = {}) { return this.watch (symbol, params); }
      }
      """

      {:ok, ast} = OXC.parse(source, "plain.ts")
      hm = WsDispatch.extract_from_ast(ast, "plain.ts")["handle_message"]

      assert hm["defined"] == false
      assert hm["entries"] == []
      assert hm["discriminators"] == []
      assert hm["unresolved"] == []
    end

    test "extract_from_ast/2 output feeds build/2 end-to-end" do
      source = """
      export default class ex extends exRest {
          handleMessage (client, message) {
              const methods = { 'ticker': this.handleTicker };
              this.safeValue (methods, this.safeString (message, 'channel'));
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "ex.ts")
      e = WsDispatch.extract_from_ast(ast, "ex.ts")
      r = WsDispatch.build(e, %{"ex" => e})

      assert r["kind"] == "routed"
      assert r["entries"] == [pair("ticker", "handleTicker")]
      assert r["discriminators"] == ["channel"]
    end
  end
end
