defmodule CcxtExtract.WsOrderbookSemanticsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsOrderbookSemantics, as: OB

  # --- Raw-entry fixture builders ---

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class_name" => id,
        "file" => "#{id}.ts",
        "extends" => "#{id}Rest",
        "orderbook" => ob_absent()
      },
      overrides
    )
  end

  defp ob_absent do
    %{
      "defined" => false,
      "methods" => [],
      "comparisons" => [],
      "sequence_keys" => [],
      "checksum" => %{"present" => false, "field" => nil, "algorithm" => nil},
      "applies_deltas" => false,
      "resets_book" => false
    }
  end

  defp ob(opts) do
    %{
      "defined" => Keyword.get(opts, :defined, true),
      "methods" => Keyword.get(opts, :methods, ["handleOrderBook"]),
      "comparisons" => Keyword.get(opts, :comparisons, []),
      "sequence_keys" => Keyword.get(opts, :sequence_keys, []),
      "checksum" => Keyword.get(opts, :checksum, %{"present" => false, "field" => nil, "algorithm" => nil}),
      "applies_deltas" => Keyword.get(opts, :applies_deltas, false),
      "resets_book" => Keyword.get(opts, :resets_book, false)
    }
  end

  defp cmp(field, value), do: %{"field" => field, "value" => value}

  describe "build/2 — no WebSocket class" do
    test "nil entry yields the honest none_record" do
      assert OB.build(nil, %{}) == OB.none_record()
    end

    test "none_record is internally coherent" do
      r = OB.none_record()
      assert r["apply_mode"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_support"
      assert r["handle_orderbook_defined"] == false
      assert r["sequence_fields"] == []
      assert r["discriminator"] == %{"field" => nil, "snapshot_values" => [], "delta_values" => []}
      assert r["checksum"] == %{"present" => false, "field" => nil, "algorithm" => nil}
      assert is_nil(r["resolved_from"])
      assert Enum.sort(Map.keys(r)) == Enum.sort(OB.required_keys())
    end
  end

  describe "build/2 — Pro class without an orderbook handler" do
    test "a WS class lacking handleOrderBook is apply_mode none tagged no_ws_orderbook" do
      e = entry("foo")
      r = OB.build(e, %{"foo" => e})

      assert r["apply_mode"] == "none"
      assert r["source"] == "none"
      assert r["unresolved_reason"] == "no_ws_orderbook"
      assert r["handle_orderbook_defined"] == false
      assert is_nil(r["resolved_from"])
    end
  end

  describe "build/2 — apply_mode classification" do
    test "handleDeltas-only handler is incremental" do
      e = entry("ic", %{"orderbook" => ob(applies_deltas: true)})
      r = OB.build(e, %{"ic" => e})

      assert r["apply_mode"] == "incremental"
      assert r["handle_orderbook_defined"] == true
      assert r["source"] == "pro_handle_orderbook"
      assert r["resolved_from"] == "self"
      assert is_nil(r["unresolved_reason"])
    end

    test "reset-only handler is replace" do
      e = entry("rp", %{"orderbook" => ob(resets_book: true)})
      r = OB.build(e, %{"rp" => e})

      assert r["apply_mode"] == "replace"
      assert is_nil(r["unresolved_reason"])
    end

    test "both deltas and reset is both" do
      e = entry("bo", %{"orderbook" => ob(applies_deltas: true, resets_book: true)})
      r = OB.build(e, %{"bo" => e})

      assert r["apply_mode"] == "both"
      assert is_nil(r["unresolved_reason"])
    end

    test "neither marker is unknown tagged orderbook_not_classifiable" do
      e = entry("un", %{"orderbook" => ob(applies_deltas: false, resets_book: false)})
      r = OB.build(e, %{"un" => e})

      assert r["apply_mode"] == "unknown"
      assert r["unresolved_reason"] == "orderbook_not_classifiable"
      assert r["handle_orderbook_defined"] == true
    end
  end

  describe "build/2 — discriminator derivation" do
    test "splits snapshot and delta literals on the dominant field" do
      comparisons = [cmp("type", "snapshot"), cmp("type", "delta")]
      e = entry("by", %{"orderbook" => ob(applies_deltas: true, comparisons: comparisons)})
      r = OB.build(e, %{"by" => e})

      assert r["discriminator"] == %{
               "field" => "type",
               "snapshot_values" => ["snapshot"],
               "delta_values" => ["delta"]
             }
    end

    test "ignores comparison literals outside the closed vocabulary" do
      comparisons = [cmp("action", "snapshot"), cmp("event", "subscribe"), cmp("action", "update")]
      e = entry("okx", %{"orderbook" => ob(applies_deltas: true, comparisons: comparisons)})
      r = OB.build(e, %{"okx" => e})

      assert r["discriminator"]["field"] == "action"
      assert r["discriminator"]["snapshot_values"] == ["snapshot"]
      assert r["discriminator"]["delta_values"] == ["update"]
    end

    test "bitmex partial action is classified as a snapshot literal" do
      comparisons = [cmp("action", "partial"), cmp("action", "update")]
      e = entry("bitmex", %{"orderbook" => ob(comparisons: comparisons)})
      r = OB.build(e, %{"bitmex" => e})

      assert r["discriminator"]["snapshot_values"] == ["partial"]
      assert r["discriminator"]["delta_values"] == ["update"]
    end

    test "no in-vocabulary comparison yields a null discriminator field" do
      e = entry("kr", %{"orderbook" => ob(resets_book: true, comparisons: [cmp("event", "ping")])})
      r = OB.build(e, %{"kr" => e})

      assert r["discriminator"] == %{"field" => nil, "snapshot_values" => [], "delta_values" => []}
    end

    test "the dominant field wins when two fields both carry vocabulary hits" do
      comparisons = [
        cmp("type", "snapshot"),
        cmp("type", "update"),
        cmp("other", "delta")
      ]

      e = entry("dm", %{"orderbook" => ob(applies_deltas: true, comparisons: comparisons)})
      r = OB.build(e, %{"dm" => e})

      assert r["discriminator"]["field"] == "type"
      assert r["discriminator"]["snapshot_values"] == ["snapshot"]
      assert r["discriminator"]["delta_values"] == ["update"]
    end
  end

  describe "build/2 — sequence fields + checksum" do
    test "keeps only sequence keys in the closed vocabulary, sorted and unique" do
      keys = ["U", "u", "pu", "timestamp", "E", "u"]
      e = entry("bn", %{"orderbook" => ob(applies_deltas: true, sequence_keys: keys)})
      r = OB.build(e, %{"bn" => e})

      assert r["sequence_fields"] == ["U", "pu", "u"]
    end

    test "carries the checksum field and algorithm through verbatim" do
      checksum = %{"present" => true, "field" => "checksum", "algorithm" => "crc32"}
      e = entry("kr", %{"orderbook" => ob(applies_deltas: true, checksum: checksum)})
      r = OB.build(e, %{"kr" => e})

      assert r["checksum"] == checksum
    end
  end

  describe "build/2 — extends-chain inheritance" do
    test "a child without its own orderbook handler inherits the parent's semantics" do
      parent =
        entry("binance", %{
          "orderbook" => ob(applies_deltas: true, comparisons: [cmp("e", "snapshot")], sequence_keys: ["U", "u"])
        })

      child = entry("binanceusdm", %{"extends" => "binance"})
      lookup = %{"binance" => parent, "binanceusdm" => child}

      r = OB.build(child, lookup)

      assert r["apply_mode"] == "incremental"
      assert r["resolved_from"] == "binance"
      assert r["sequence_fields"] == ["U", "u"]
    end

    test "a child that defines its own handler resolves as self, not the parent" do
      parent = entry("base", %{"orderbook" => ob(resets_book: true)})
      child = entry("variant", %{"extends" => "base", "orderbook" => ob(applies_deltas: true)})
      r = OB.build(child, %{"base" => parent, "variant" => child})

      assert r["resolved_from"] == "self"
      assert r["apply_mode"] == "incremental"
    end

    test "a cyclic extends chain terminates instead of looping forever" do
      a = entry("a", %{"extends" => "b"})
      b = entry("b", %{"extends" => "a", "orderbook" => ob(applies_deltas: true)})
      r = OB.build(a, %{"a" => a, "b" => b})

      assert r["apply_mode"] == "incremental"
      assert r["resolved_from"] == "b"
    end
  end

  describe "closed-vocabulary exposers" do
    test "vocabularies are stable" do
      assert OB.apply_modes() == ~w(incremental replace both unknown none)
      assert OB.sources() == ~w(pro_handle_orderbook none)
      assert OB.unresolved_reasons() == ~w(no_ws_support no_ws_orderbook orderbook_not_classifiable)
      assert OB.algorithms() == ~w(crc32)
      assert "snapshot" in OB.snapshot_value_vocab()
      assert "partial" in OB.snapshot_value_vocab()
      assert "update" in OB.delta_value_vocab()
      assert "U" in OB.sequence_field_vocab()
    end

    test "every build/2 result carries exactly the required key set" do
      e = entry("ex", %{"orderbook" => ob(applies_deltas: true)})

      for record <- [OB.build(e, %{"ex" => e}), OB.none_record(), OB.build(entry("p"), %{"p" => entry("p")})] do
        assert Enum.sort(Map.keys(record)) == Enum.sort(OB.required_keys())
      end
    end
  end

  describe "extract_from_ast/2 — discriminator + deltas" do
    test "extracts the bound discriminator field, snapshot/delta literals, and incremental marker" do
      source = """
      export default class by extends byRest {
          handleOrderBook (client, message) {
              const type = this.safeString (message, 'type');
              if (type === 'snapshot') {
                  this.handleSnapshot (client, message);
              } else if (type === 'delta') {
                  this.handleDeltas (orderbook['asks'], message['data']);
              }
          }
          handleSnapshot (client, message) {
              const orderbook = this.orderBook ();
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "by.ts")
      e = OB.extract_from_ast(ast, "by.ts")
      o = e["orderbook"]

      assert e["id"] == "by"
      assert e["extends"] == "byRest"
      assert o["defined"] == true
      assert cmp("type", "snapshot") in o["comparisons"]
      assert cmp("type", "delta") in o["comparisons"]
      assert o["applies_deltas"] == true
      assert o["resets_book"] == true
    end

    test "end-to-end: extract_from_ast feeds build/2 into both apply_mode" do
      source = """
      export default class by extends byRest {
          handleOrderBook (client, message) {
              const type = this.safeString (message, 'type');
              if (type === 'snapshot') {
                  this.orderbooks[symbol].reset ();
              } else {
                  this.handleDeltas (orderbook, message);
              }
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "by.ts")
      e = OB.extract_from_ast(ast, "by.ts")
      r = OB.build(e, %{"by" => e})

      assert r["apply_mode"] == "both"
      assert r["discriminator"]["snapshot_values"] == ["snapshot"]
    end
  end

  describe "extract_from_ast/2 — sequence + checksum" do
    test "collects integer-accessor sequence keys and the checksum field + crc32 algorithm" do
      source = """
      export default class kr extends krRest {
          handleOrderBook (client, message) {
              const U = this.safeInteger (message, 'U');
              const u = this.safeInteger (message, 'u');
              const checksum = this.safeString (message, 'checksum');
              const local = this.crc32 (payload, true);
              this.handleDeltas (orderbook, message);
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "kr.ts")
      o = OB.extract_from_ast(ast, "kr.ts")["orderbook"]

      assert "U" in o["sequence_keys"]
      assert "u" in o["sequence_keys"]
      assert o["checksum"]["present"] == true
      assert o["checksum"]["field"] == "checksum"
      assert o["checksum"]["algorithm"] == "crc32"
    end

    test "checksum is absent when no checksum key is read and crc32 is never computed" do
      source = """
      export default class nc extends ncRest {
          handleOrderBook (client, message) {
              const seq = this.safeInteger (message, 'seqNum');
              this.handleDeltas (orderbook, message);
          }
      }
      """

      {:ok, ast} = OXC.parse(source, "nc.ts")
      o = OB.extract_from_ast(ast, "nc.ts")["orderbook"]

      assert o["checksum"]["present"] == false
      assert "seqNum" in o["sequence_keys"]
    end
  end

  describe "extract_from_ast/2 — honest absence" do
    test "a class with no orderbook handler reports defined false and empty facts" do
      source = """
      export default class plain extends plainRest {
          watchTicker (symbol, params = {}) { return this.watch (symbol, params); }
      }
      """

      {:ok, ast} = OXC.parse(source, "plain.ts")
      o = OB.extract_from_ast(ast, "plain.ts")["orderbook"]

      assert o["defined"] == false
      assert o["comparisons"] == []
      assert o["sequence_keys"] == []
      assert o["checksum"]["present"] == false
      assert o["applies_deltas"] == false
      assert o["resets_book"] == false
    end
  end
end
