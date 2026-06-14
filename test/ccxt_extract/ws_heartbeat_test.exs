defmodule CcxtExtract.WsHeartbeatTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsHeartbeat

  # --- Raw-entry fixture builder ---

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class_name" => id,
        "file" => "#{id}.ts",
        "extends" => "#{id}Rest",
        "ping" => %{"defined" => false, "shape" => nil, "return_value" => nil},
        "pong_methods" => %{"pong" => false, "handlePong" => false, "handlePing" => false},
        "streaming" => %{
          "present" => false,
          "keep_alive_ms" => nil,
          "max_ping_pong_misses" => nil,
          "has_ping_property" => false
        }
      },
      overrides
    )
  end

  defp streaming(opts) do
    %{
      "present" => true,
      "keep_alive_ms" => Keyword.get(opts, :keep_alive_ms),
      "max_ping_pong_misses" => Keyword.get(opts, :max_ping_pong_misses),
      "has_ping_property" => Keyword.get(opts, :has_ping_property, false)
    }
  end

  defp string_ping(value),
    do: %{
      "defined" => true,
      "shape" => "string",
      "return_value" => %{"value" => value, "kind" => "literal", "reason" => nil}
    }

  defp object_ping(value, kind),
    do: %{"defined" => true, "shape" => "object", "return_value" => %{"value" => value, "kind" => kind, "reason" => nil}}

  describe "close_ancestor_entries/2" do
    test "pulls missing WS extends-chain ancestors from the full extract result" do
      parent = entry("binance", %{"streaming" => streaming(keep_alive_ms: 180_000)})
      child = entry("binanceusdm", %{"extends" => "binance"})
      all = [parent, child]

      closed = WsHeartbeat.close_ancestor_entries([child], all)

      assert Enum.sort(Enum.map(closed, & &1["id"])) == ["binance", "binanceusdm"]
    end

    test "does not duplicate entries already in the scoped set" do
      parent = entry("binance", %{"streaming" => streaming(keep_alive_ms: 180_000)})
      child = entry("binanceusdm", %{"extends" => "binance"})
      all = [parent, child]

      closed = WsHeartbeat.close_ancestor_entries([parent, child], all)

      assert length(closed) == 2
      assert Enum.sort(Enum.map(closed, & &1["id"])) == ["binance", "binanceusdm"]
    end

    test "walks multi-level WS chains" do
      root = entry("root", %{"streaming" => streaming(keep_alive_ms: 60_000)})
      mid = entry("mid", %{"extends" => "root"})
      leaf = entry("leaf", %{"extends" => "mid"})
      all = [root, mid, leaf]

      closed = WsHeartbeat.close_ancestor_entries([leaf], all)

      assert Enum.sort(Enum.map(closed, & &1["id"])) == ["leaf", "mid", "root"]
    end

    test "stops when extends names a class outside the WS lookup" do
      child = entry("variant", %{"extends" => "variantRest"})
      all = [child]

      assert WsHeartbeat.close_ancestor_entries([child], all) == [child]
    end
  end

  describe "expand_scope_with_ancestors/3 and close_scoped_extraction/3" do
    test "expand_scope_with_ancestors unions ancestor ids into the write scope" do
      parent = entry("binance", %{"streaming" => streaming(keep_alive_ms: 180_000)})
      child = entry("binanceusdm", %{"extends" => "binance"})
      all = [parent, child]
      scope = MapSet.new(["binanceusdm"])

      expanded = WsHeartbeat.expand_scope_with_ancestors(scope, [child], all)

      assert MapSet.equal?(expanded, MapSet.new(["binance", "binanceusdm"]))
    end

    test "close_scoped_extraction/3 is a no-op for :all scope" do
      child = entry("binanceusdm", %{"extends" => "binance"})
      all = [entry("binance"), child]

      assert WsHeartbeat.close_scoped_extraction([child], all, :all) == {[child], :all}
    end

    test "scoped extraction enables correct build/2 inheritance after closure" do
      parent = entry("binance", %{"streaming" => streaming(keep_alive_ms: 180_000)})
      child = entry("binanceusdm", %{"extends" => "binance"})
      all = [parent, child]

      {closed, _scope} = WsHeartbeat.close_scoped_extraction([child], all, MapSet.new(["binanceusdm"]))
      lookup = Map.new(closed, &{&1["id"], &1})
      r = WsHeartbeat.build(child, lookup)

      assert r["keep_alive_ms"] == 180_000
      assert r["keep_alive_resolved_from"] == "binance"
      refute r["source"] == "base_default"
    end

    test "scoped merge with expanded scope does not duplicate ancestor entries" do
      alias CcxtExtract.AggregateWriter

      tmp = Path.join(System.tmp_dir!(), "ws_hb_scope_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      file = Path.join(tmp, "ws_heartbeat.json")
      parent = entry("binance", %{"streaming" => streaming(keep_alive_ms: 180_000)})
      child = entry("binanceusdm", %{"extends" => "binance"})
      stale_parent = Map.put(parent, "streaming", streaming(keep_alive_ms: 999))
      all = [parent, child]

      writer_opts = [
        entry_key: "exchanges",
        id_key: "id",
        stats_fn: &WsHeartbeat.write_stats/1,
        extracted_at: "2026-06-14T12:00:00Z"
      ]

      AggregateWriter.write!(file, [stale_parent, child], Keyword.merge(writer_opts, scope: :all, tier_scope: "all"))

      {closed, scope} =
        WsHeartbeat.close_scoped_extraction([child], all, MapSet.new(["binanceusdm"]))

      AggregateWriter.write!(file, closed, Keyword.merge(writer_opts, scope: scope, tier_scope: ["exchange:binanceusdm"]))

      data = file |> File.read!() |> Jason.decode!()
      binance_rows = Enum.filter(data["exchanges"], &(&1["id"] == "binance"))

      assert length(binance_rows) == 1
      assert hd(binance_rows)["streaming"]["keep_alive_ms"] == 180_000
      assert data["count"] == length(data["exchanges"])
    end
  end

  describe "build/2 — no WebSocket class" do
    test "nil entry yields the honest none_record" do
      assert WsHeartbeat.build(nil, %{}) == WsHeartbeat.none_record()
    end

    test "none_record is internally coherent" do
      r = WsHeartbeat.none_record()
      assert r["ping_kind"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_support"
      assert is_nil(r["keep_alive_ms"])
      assert is_nil(r["ping_payload"])
      assert r["has_pong_handler"] == false
      assert Enum.sort(Map.keys(r)) == Enum.sort(WsHeartbeat.required_keys())
    end
  end

  describe "build/2 — keep_alive resolution" do
    test "resolves the exchange's own streaming.keepAlive as 'self'" do
      e = entry("derive", %{"streaming" => streaming(keep_alive_ms: 9000)})
      r = WsHeartbeat.build(e, %{"derive" => e})

      assert r["keep_alive_ms"] == 9000
      assert r["keep_alive_resolved_from"] == "self"
      assert r["source"] == "pro_describe"
    end

    test "inherits keepAlive from a parent Pro class via the extends chain" do
      parent = entry("binance", %{"streaming" => streaming(keep_alive_ms: 180_000)})
      child = entry("binanceusdm", %{"extends" => "binance"})
      lookup = %{"binance" => parent, "binanceusdm" => child}

      r = WsHeartbeat.build(child, lookup)

      assert r["keep_alive_ms"] == 180_000
      assert r["keep_alive_resolved_from"] == "binance"
      assert r["source"] == "pro_describe"
    end

    test "falls back to the base client default when streaming sets no keepAlive" do
      e = entry("deribit", %{"streaming" => streaming(keep_alive_ms: nil)})
      r = WsHeartbeat.build(e, %{"deribit" => e})

      assert r["keep_alive_ms"] == 30_000
      assert r["keep_alive_resolved_from"] == "base_default"
      assert r["source"] == "base_default"
    end

    test "falls back to the base default when there is no streaming block at all" do
      e = entry("someex")
      r = WsHeartbeat.build(e, %{"someex" => e})

      assert r["keep_alive_ms"] == 30_000
      assert r["source"] == "base_default"
    end

    test "max_ping_pong_misses defaults to 2.0, or resolves from streaming" do
      plain = entry("a")
      assert WsHeartbeat.build(plain, %{"a" => plain})["max_ping_pong_misses"] == 2.0

      tuned = entry("b", %{"streaming" => streaming(keep_alive_ms: 5000, max_ping_pong_misses: 5)})
      assert WsHeartbeat.build(tuned, %{"b" => tuned})["max_ping_pong_misses"] == 5
    end
  end

  describe "build/2 — ping classification" do
    test "no ping() anywhere yields native_frame" do
      e = entry("binance", %{"streaming" => streaming(keep_alive_ms: 180_000)})
      r = WsHeartbeat.build(e, %{"binance" => e})

      assert r["ping_kind"] == "native_frame"
      assert is_nil(r["ping_payload"])
      assert is_nil(r["ping_payload_kind"])
      assert is_nil(r["unresolved_reason"])
    end

    test "string-literal ping() yields string_message" do
      e = entry("okx", %{"ping" => string_ping("ping"), "streaming" => streaming(keep_alive_ms: 18_000)})
      r = WsHeartbeat.build(e, %{"okx" => e})

      assert r["ping_kind"] == "string_message"
      assert r["ping_payload"] == "ping"
      assert r["ping_payload_kind"] == "literal"
    end

    test "fully-literal object ping() yields json_message / literal" do
      e = entry("hyperliquid", %{"ping" => object_ping(%{"method" => "ping"}, "literal")})
      r = WsHeartbeat.build(e, %{"hyperliquid" => e})

      assert r["ping_kind"] == "json_message"
      assert r["ping_payload"] == %{"method" => "ping"}
      assert r["ping_payload_kind"] == "literal"
    end

    test "partially-dynamic object ping() keeps its literal keys as 'partial'" do
      e = entry("bybit", %{"ping" => object_ping(%{"op" => "ping"}, "partial")})
      r = WsHeartbeat.build(e, %{"bybit" => e})

      assert r["ping_kind"] == "json_message"
      assert r["ping_payload"] == %{"op" => "ping"}
      assert r["ping_payload_kind"] == "partial"
    end

    test "an unresolvable ping() return shape yields unknown, not a forced category" do
      e = entry("oddex", %{"ping" => %{"defined" => true, "shape" => "other", "return_value" => nil}})
      r = WsHeartbeat.build(e, %{"oddex" => e})

      assert r["ping_kind"] == "unknown"
      assert is_nil(r["ping_payload"])
      assert r["ping_payload_kind"] == "unresolved"
      assert r["unresolved_reason"] == "ping_return_not_literal"
    end

    test "ping() defined on a parent is inherited by a child that does not override it" do
      parent = entry("base", %{"ping" => string_ping("ping")})
      child = entry("variant", %{"extends" => "base"})
      r = WsHeartbeat.build(child, %{"base" => parent, "variant" => child})

      assert r["ping_kind"] == "string_message"
      assert r["ping_payload"] == "ping"
    end
  end

  describe "build/2 — pong handler detection" do
    test "has_pong_handler is true when any pong method is defined" do
      for method <- ~w(pong handlePong handlePing) do
        e =
          entry("ex", %{
            "pong_methods" => Map.put(%{"pong" => false, "handlePong" => false, "handlePing" => false}, method, true)
          })

        assert WsHeartbeat.build(e, %{"ex" => e})["has_pong_handler"], "expected #{method} to count"
      end
    end

    test "has_pong_handler is false when no pong method is defined" do
      e = entry("ex")
      refute WsHeartbeat.build(e, %{"ex" => e})["has_pong_handler"]
    end

    test "a pong handler on a parent counts for the child" do
      parent = entry("base", %{"pong_methods" => %{"pong" => true, "handlePong" => false, "handlePing" => false}})
      child = entry("variant", %{"extends" => "base"})
      assert WsHeartbeat.build(child, %{"base" => parent, "variant" => child})["has_pong_handler"]
    end
  end

  describe "build/2 — robustness" do
    test "a cyclic extends chain terminates instead of looping forever" do
      a = entry("a", %{"extends" => "b"})
      b = entry("b", %{"extends" => "a", "streaming" => streaming(keep_alive_ms: 7000)})
      r = WsHeartbeat.build(a, %{"a" => a, "b" => b})

      assert r["keep_alive_ms"] == 7000
    end
  end

  describe "closed-vocabulary exposers" do
    test "vocabularies are stable and non-empty" do
      assert "native_frame" in WsHeartbeat.ping_kinds()
      assert "none" in WsHeartbeat.ping_kinds()
      assert WsHeartbeat.sources() == ~w(pro_describe base_default none)
      assert WsHeartbeat.unresolved_reasons() == ~w(no_ws_support ping_return_not_literal)
    end

    test "every build/2 result carries exactly the required key set" do
      e = entry("ex", %{"streaming" => streaming(keep_alive_ms: 5000)})

      for record <- [WsHeartbeat.build(e, %{"ex" => e}), WsHeartbeat.none_record()] do
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsHeartbeat.required_keys())
      end
    end
  end

  describe "extract_from_ast/2" do
    test "extracts ping, pong, streaming, and extends from a Pro class" do
      source = """
      export default class testex extends testexRest {
          describe () {
              return this.deepExtend (super.describe (), {
                  'streaming': { 'ping': this.ping, 'keepAlive': 12345 },
              });
          }
          ping (client) { return 'ping'; }
          handlePong (client, message) { return message; }
      }
      """

      {:ok, ast} = OXC.parse(source, "testex.ts")
      e = WsHeartbeat.extract_from_ast(ast, "testex.ts")

      assert e["id"] == "testex"
      assert e["extends"] == "testexRest"
      assert e["ping"]["defined"] == true
      assert e["ping"]["shape"] == "string"
      assert e["ping"]["return_value"]["value"] == "ping"
      assert e["pong_methods"]["handlePong"] == true
      assert e["pong_methods"]["pong"] == false
      assert e["streaming"]["present"] == true
      assert e["streaming"]["keep_alive_ms"] == 12_345
      assert e["streaming"]["has_ping_property"] == true
    end

    test "finds the streaming block routed through a describeData() helper" do
      source = """
      export default class bx extends bxRest {
          describe () { return this.deepExtend (super.describe (), this.describeData ()); }
          describeData () { return { 'streaming': { 'keepAlive': 999 } }; }
      }
      """

      {:ok, ast} = OXC.parse(source, "bx.ts")
      e = WsHeartbeat.extract_from_ast(ast, "bx.ts")

      assert e["streaming"]["present"] == true
      assert e["streaming"]["keep_alive_ms"] == 999
    end

    test "a class with no ping() and no streaming reports honest absences" do
      source = """
      export default class plain extends plainRest {
          describe () { return this.deepExtend (super.describe (), { 'has': { 'ws': true } }); }
      }
      """

      {:ok, ast} = OXC.parse(source, "plain.ts")
      e = WsHeartbeat.extract_from_ast(ast, "plain.ts")

      assert e["ping"]["defined"] == false
      assert e["streaming"]["present"] == false
    end
  end
end
