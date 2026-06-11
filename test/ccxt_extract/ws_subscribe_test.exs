defmodule CcxtExtract.WsSubscribeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsSubscribe

  # --- Raw-entry fixture builders ---

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class_name" => id,
        "file" => "#{id}.ts",
        "extends" => "#{id}Rest",
        "envelope" => envelope_absent(),
        "channels" => %{},
        "watch_method_count" => 0,
        "channel_template_count" => 0
      },
      overrides
    )
  end

  defp envelope_absent do
    %{
      "discriminant" => nil,
      "subscribe" => nil,
      "unsubscribe" => nil,
      "args_key" => nil,
      "subscribe_keys" => [],
      "unsubscribe_keys" => []
    }
  end

  defp envelope(opts) do
    %{
      "discriminant" => Keyword.fetch!(opts, :discriminant),
      "subscribe" => Keyword.get(opts, :subscribe),
      "unsubscribe" => Keyword.get(opts, :unsubscribe),
      "args_key" => Keyword.get(opts, :args_key),
      "subscribe_keys" => Keyword.get(opts, :subscribe_keys, []),
      "unsubscribe_keys" => Keyword.get(opts, :unsubscribe_keys, [])
    }
  end

  describe "build/2 — no WebSocket class" do
    test "nil entry yields the honest none_record" do
      assert WsSubscribe.build(nil, %{}) == WsSubscribe.none_record()
    end

    test "none_record is internally coherent" do
      r = WsSubscribe.none_record()
      assert r["mechanism"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_support"
      assert r["discriminant"] == nil
      assert r["subscribe_op"] == nil
      assert r["channels"] == %{}
      assert r["envelope_keys"] == []
      assert r["resolved_from"] == nil
      assert Enum.sort(Map.keys(r)) == Enum.sort(WsSubscribe.required_keys())
    end
  end

  describe "build/2 — Pro class without a classifiable subscribe envelope" do
    test "yields mechanism unknown tagged subscribe_not_classifiable, still carrying channels" do
      e = entry("deribit", %{"channels" => %{"watchTicker" => ["ticker.{symbol}"]}})
      r = WsSubscribe.build(e, %{"deribit" => e})

      assert r["mechanism"] == "unknown"
      assert r["source"] == "pro_watch"
      assert r["unresolved_reason"] == "subscribe_not_classifiable"
      assert r["discriminant"] == nil
      assert r["channels"] == %{"watchTicker" => ["ticker.{symbol}"]}
    end
  end

  describe "build/2 — envelope classification" do
    test "an op-discriminant subscribe object yields json_message" do
      e =
        entry("bybit", %{
          "envelope" =>
            envelope(
              discriminant: "op",
              subscribe: "subscribe",
              unsubscribe: "unsubscribe",
              args_key: "args",
              subscribe_keys: ["op", "req_id", "args"]
            ),
          "channels" => %{"watchTicker" => ["ticker:{symbol}"]}
        })

      r = WsSubscribe.build(e, %{"bybit" => e})

      assert r["mechanism"] == "json_message"
      assert r["discriminant"] == "op"
      assert r["subscribe_op"] == "subscribe"
      assert r["unsubscribe_op"] == "unsubscribe"
      assert r["args_key"] == "args"
      assert r["envelope_keys"] == ["op", "req_id", "args"]
      assert r["channels"] == %{"watchTicker" => ["ticker:{symbol}"]}
      assert r["source"] == "pro_watch"
      assert r["resolved_from"] == "self"
      assert is_nil(r["unresolved_reason"])
    end

    test "a method-discriminant subscribe object (binance SUBSCRIBE) yields json_message" do
      e =
        entry("binance", %{
          "envelope" =>
            envelope(
              discriminant: "method",
              subscribe: "SUBSCRIBE",
              unsubscribe: "UNSUBSCRIBE",
              args_key: "params",
              subscribe_keys: ["method", "params", "id"]
            )
        })

      r = WsSubscribe.build(e, %{"binance" => e})

      assert r["mechanism"] == "json_message"
      assert r["subscribe_op"] == "SUBSCRIBE"
      assert r["args_key"] == "params"
    end
  end

  describe "build/2 — extends-chain inheritance" do
    test "a child without an envelope inherits the parent's, tagged with the ancestor id" do
      parent =
        entry("binance", %{
          "envelope" => envelope(discriminant: "method", subscribe: "SUBSCRIBE", args_key: "params"),
          "channels" => %{"watchTicker" => ["{symbol}@ticker"]}
        })

      child = entry("binanceusdm", %{"extends" => "binance"})
      lookup = %{"binance" => parent, "binanceusdm" => child}

      r = WsSubscribe.build(child, lookup)

      assert r["mechanism"] == "json_message"
      assert r["subscribe_op"] == "SUBSCRIBE"
      assert r["resolved_from"] == "binance"
      assert r["channels"] == %{"watchTicker" => ["{symbol}@ticker"]}
    end

    test "the most-derived class wins on a channel-key collision" do
      parent = entry("base", %{"channels" => %{"watchTicker" => ["old"], "watchTrades" => ["t"]}})

      child =
        entry("variant", %{
          "extends" => "base",
          "envelope" => envelope(discriminant: "op", subscribe: "subscribe"),
          "channels" => %{"watchTicker" => ["new"]}
        })

      r = WsSubscribe.build(child, %{"base" => parent, "variant" => child})

      assert r["channels"] == %{"watchTicker" => ["new"], "watchTrades" => ["t"]}
      assert r["resolved_from"] == "self"
    end

    test "a cyclic extends chain terminates instead of looping forever" do
      a = entry("a", %{"extends" => "b"})
      b = entry("b", %{"extends" => "a", "envelope" => envelope(discriminant: "op", subscribe: "subscribe")})
      r = WsSubscribe.build(a, %{"a" => a, "b" => b})

      assert r["mechanism"] == "json_message"
      assert r["resolved_from"] == "b"
    end
  end

  describe "closed-vocabulary exposers" do
    test "vocabularies are stable and non-empty" do
      assert WsSubscribe.mechanisms() == ~w(json_message unknown none)
      assert WsSubscribe.sources() == ~w(pro_watch none)
      assert WsSubscribe.unresolved_reasons() == ~w(no_ws_support subscribe_not_classifiable)
    end

    test "every build/2 result carries exactly the required key set" do
      e = entry("ex", %{"envelope" => envelope(discriminant: "op", subscribe: "subscribe")})

      for record <- [
            WsSubscribe.build(e, %{"ex" => e}),
            WsSubscribe.build(entry("pub"), %{"pub" => entry("pub")}),
            WsSubscribe.none_record()
          ] do
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsSubscribe.required_keys())
      end
    end
  end

  describe "extract_from_ast/2 — envelope" do
    test "extracts an op-discriminant subscribe + unsubscribe envelope" do
      source = """
      export default class bx extends bxRest {
          async watchTopics (url, messageHashes, topics, params = {}) {
              const request = { 'op': 'subscribe', 'req_id': this.requestId (), 'args': topics };
              return await this.watchMultiple (url, messageHashes, request, messageHashes);
          }
          async unWatchTopics (url, topic, symbols, messageHashes, subMessageHashes, topics, params = {}) {
              const request = { 'op': 'unsubscribe', 'req_id': reqId, 'args': topics };
              return await this.watchMultiple (url, messageHashes, request, messageHashes);
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "bx.ts")
      e = WsSubscribe.extract_from_ast(ast, "bx.ts")
      env = e["envelope"]

      assert e["id"] == "bx"
      assert e["extends"] == "bxRest"
      assert env["discriminant"] == "op"
      assert env["subscribe"] == "subscribe"
      assert env["unsubscribe"] == "unsubscribe"
      assert env["args_key"] == "args"
      assert env["subscribe_keys"] == ["op", "req_id", "args"]
      assert env["unsubscribe_keys"] == ["op", "req_id", "args"]
    end

    test "extracts a method-discriminant SUBSCRIBE envelope (binance)" do
      source = """
      export default class bn extends bnRest {
          async watchMultiTickerHelper (params = {}) {
              const request = { 'method': 'SUBSCRIBE', 'params': subParams, 'id': requestId };
              return await this.watch (url, messageHash, request, messageHash);
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "bn.ts")
      env = WsSubscribe.extract_from_ast(ast, "bn.ts")["envelope"]

      assert env["discriminant"] == "method"
      assert env["subscribe"] == "SUBSCRIBE"
      assert env["args_key"] == "params"
    end

    test "resolves the JSON-RPC namespaced public/subscribe verb (deribit)" do
      source = """
      export default class dx extends dxRest {
          async watchPublic (messageHash, channel, params = {}) {
              const request = { 'jsonrpc': '2.0', 'method': 'public/subscribe', 'params': { 'channels': [ channel ] }, 'id': this.requestId () };
              return await this.watch (url, messageHash, request, messageHash);
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "dx.ts")
      env = WsSubscribe.extract_from_ast(ast, "dx.ts")["envelope"]

      assert env["discriminant"] == "method"
      assert env["subscribe"] == "public/subscribe"
    end

    test "resolves an identifier-valued op through a local const binding" do
      source = """
      export default class ox extends oxRest {
          async subscribe (channel, params = {}) {
              const operation = 'subscribe';
              const request = { 'op': operation, 'args': args };
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "ox.ts")
      env = WsSubscribe.extract_from_ast(ast, "ox.ts")["envelope"]

      assert env["discriminant"] == "op"
      assert env["subscribe"] == "subscribe"
    end

    test "a class with no subscribe object reports an honest absence" do
      source = """
      export default class plain extends plainRest {
          describe () { return this.deepExtend (super.describe (), { 'has': { 'ws': true } }); }
      }
      """

      {:ok, ast} = OXC.parse(source, "plain.ts")
      env = WsSubscribe.extract_from_ast(ast, "plain.ts")["envelope"]

      assert env["discriminant"] == nil
      assert env["subscribe"] == nil
      assert env["subscribe_keys"] == []
    end
  end

  describe "extract_from_ast/2 — channel templates" do
    test "resolves a dotted concat channel template with a market-id placeholder" do
      source = """
      export default class bk extends bkRest {
          async watchOrderBook (symbol, params = {}) {
              const topic = 'book.' + market['id'] + '.raw';
              const request = { 'op': 'subscribe', 'args': [ topic ] };
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "bk.ts")
      channels = WsSubscribe.extract_from_ast(ast, "bk.ts")["channels"]

      assert channels["watchOrderBook"] == ["book.{symbol}.raw"]
    end

    test "resolves a colon-joined symbol concat and a timeframe placeholder" do
      source = """
      export default class hp extends hpRest {
          async watchTrades (symbol, params = {}) {
              const hash = 'trade:' + symbol;
              const candle = 'candle:' + timeframe + ':' + symbol;
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "hp.ts")
      channels = WsSubscribe.extract_from_ast(ast, "hp.ts")["channels"]

      assert channels["watchTrades"] == ["candle:{timeframe}:{symbol}", "trade:{symbol}"]
    end

    test "captures an object channel-property literal (okx style)" do
      source = """
      export default class ok extends okRest {
          async watchTradesForSymbols (symbols, params = {}) {
              const topic = { 'channel': 'trades', 'instId': marketId };
              const request = { 'op': 'subscribe', 'args': [ topic ] };
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "ok.ts")
      channels = WsSubscribe.extract_from_ast(ast, "ok.ts")["channels"]

      assert channels["watchTradesForSymbols"] == ["trades"]
    end

    test "captures a safeString channel default" do
      source = """
      export default class by extends byRest {
          async watchTicker (symbol, params = {}) {
              const options = this.safeValue (this.options, 'watchTicker', {});
              let topic = this.safeString (options, 'name', 'tickers');
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "by.ts")
      channels = WsSubscribe.extract_from_ast(ast, "by.ts")["channels"]

      assert channels["watchTicker"] == ["tickers"]
    end

    test "a local-variable-seeded channel concat is omitted, not guessed" do
      source = """
      export default class lv extends lvRest {
          async watchTicker (symbol, params = {}) {
              const mh = channel + ':' + helper ();
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "lv.ts")
      channels = WsSubscribe.extract_from_ast(ast, "lv.ts")["channels"]

      refute Map.has_key?(channels, "watchTicker")
    end

    test "extract_from_ast/2 output feeds build/2 end-to-end" do
      source = """
      export default class ex extends exRest {
          async watchOrderBook (symbol, params = {}) {
              const topic = 'book.' + market['id'] + '.raw';
              const request = { 'op': 'subscribe', 'args': [ topic ] };
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "ex.ts")
      e = WsSubscribe.extract_from_ast(ast, "ex.ts")
      r = WsSubscribe.build(e, %{"ex" => e})

      assert r["mechanism"] == "json_message"
      assert r["subscribe_op"] == "subscribe"
      assert r["channels"]["watchOrderBook"] == ["book.{symbol}.raw"]
    end
  end
end
