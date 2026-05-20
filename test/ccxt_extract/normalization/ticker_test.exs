defmodule CcxtExtract.Normalization.TickerTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.Ticker` — the Task 74 derivation
  that populates `field_maps["ticker"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Ticker

  # --- AST builder helpers ---

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}

  defp this_call(method, args) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => %{"type" => "ThisExpression"},
        "property" => identifier(method)
      },
      "arguments" => args
    }
  end

  # VariableDeclaration: `const <name> = <init>;`
  defp var_decl(name, init) do
    %{
      "type" => "VariableDeclaration",
      "kind" => "const",
      "declarations" => [
        %{
          "type" => "VariableDeclarator",
          "id" => identifier(name),
          "init" => init
        }
      ]
    }
  end

  # A property in an ObjectExpression: `<key>: <value_node>`
  defp prop(key, value_node) do
    %{"key" => identifier(key), "value" => value_node}
  end

  # `return this.safeTicker({...props}, market);`
  defp safe_ticker_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}
    %{"type" => "ReturnStatement", "argument" => this_call("safeTicker", [object, identifier("market")])}
  end

  # Wrap statements into a parse_methods entry for `parseTicker`.
  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseTicker" => %{
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/1 — nil / missing parseTicker" do
    test "returns nil when entry is nil" do
      assert Ticker.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parseTicker" do
      entry = %{"parse_methods" => %{"parseTrade" => %{}}}
      assert Ticker.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert Ticker.derive("not a map") == nil
      assert Ticker.derive(42) == nil
      assert Ticker.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-reason paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved paths" do
    test "non-safeTicker return emits _unresolved_reason with callee name" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("parseContractTicker", [identifier("ticker"), identifier("market")])
      }

      result = Ticker.derive(wrap_entry([ret]))

      assert is_map(result)
      assert result["_unresolved_reason"] =~ "non_safe_ticker_return:parseContractTicker"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "no return statement emits _unresolved_reason: no_return_statement" do
      result = Ticker.derive(wrap_entry([]))

      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "bare Identifier return emits _unresolved_reason: identifier_return" do
      ret = %{"type" => "ReturnStatement", "argument" => identifier("ticker")}

      result = Ticker.derive(wrap_entry([ret]))
      assert result["_unresolved_reason"] == "identifier_return"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "unrecognized return shape emits _unresolved_reason: unrecognized_return_shape" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => %{
          "type" => "BinaryExpression",
          "operator" => "+",
          "left" => identifier("a"),
          "right" => identifier("b")
        }
      }

      result = Ticker.derive(wrap_entry([ret]))
      assert result["_unresolved_reason"] == "unrecognized_return_shape"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # Inline CallExpression property (no binding lookup)
  # ---------------------------------------------------------------------------

  describe "derive/1 — inline CallExpression property" do
    test "inline safeString call populates slot with key and nil format" do
      props = [prop("high", this_call("safeString", [identifier("ticker"), literal("highPrice")]))]
      result = Ticker.derive(wrap_entry([safe_ticker_return(props)]))

      assert result["_unresolved_reason"] == nil
      slot = result["field_map"]["high"]
      assert slot["key"] == "highPrice"
      assert slot["coercion"] == "safeString"
      assert slot["format"] == nil
    end

    test "inline safeNumber call populates slot" do
      props = [prop("bid", this_call("safeNumber", [identifier("ticker"), literal("bidPrice")]))]
      result = Ticker.derive(wrap_entry([safe_ticker_return(props)]))

      slot = result["field_map"]["bid"]
      assert slot["key"] == "bidPrice"
      assert slot["coercion"] == "safeNumber"
    end

    test "TSAsExpression-wrapped safeTicker return resolves cleanly" do
      # `return this.safeTicker({ high: ... }, market) as Ticker;`
      props = [prop("high", this_call("safeString", [identifier("ticker"), literal("highPrice")]))]
      object = %{"type" => "ObjectExpression", "properties" => props}

      ts_as = %{
        "type" => "TSAsExpression",
        "expression" => this_call("safeTicker", [object, identifier("market")])
      }

      ret = %{"type" => "ReturnStatement", "argument" => ts_as}
      result = Ticker.derive(wrap_entry([ret]))

      assert result["_unresolved_reason"] == nil
      slot = result["field_map"]["high"]
      assert slot["key"] == "highPrice"
      assert slot["coercion"] == "safeString"
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier binding lookup
  # ---------------------------------------------------------------------------

  describe "derive/1 — Identifier binding lookup" do
    test "Identifier property resolved via binding populates slot" do
      binding = var_decl("high", this_call("safeString2", [identifier("ticker"), literal("highPrice")]))
      props = [prop("high", identifier("high"))]
      result = Ticker.derive(wrap_entry([binding, safe_ticker_return(props)]))

      slot = result["field_map"]["high"]
      assert slot["key"] == "highPrice"
      assert slot["coercion"] == "safeString2"
      assert slot["format"] == nil
    end

    test "Identifier with non-vocab binding coercion emits nil for that field" do
      # safeSymbol is outside the closed vocab
      binding = var_decl("symbol", this_call("safeSymbol", [identifier("ticker"), literal("s"), identifier("market")]))
      props = [prop("symbol", identifier("symbol"))]
      result = Ticker.derive(wrap_entry([binding, safe_ticker_return(props)]))

      assert result["field_map"]["symbol"] == nil
    end

    test "unbound Identifier emits nil for that field" do
      props = [prop("high", identifier("notDeclared"))]
      result = Ticker.derive(wrap_entry([safe_ticker_return(props)]))

      assert result["field_map"]["high"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp format
  # ---------------------------------------------------------------------------

  describe "derive/1 — timestamp format" do
    test "safeInteger binding on timestamp field emits format: ms" do
      binding = var_decl("timestamp", this_call("safeInteger", [identifier("ticker"), literal("time")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Ticker.derive(wrap_entry([binding, safe_ticker_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger"
      assert ts["format"] == "ms"
      assert ts["key"] == "time"
    end

    test "safeInteger2 binding on timestamp field emits format: ms" do
      binding = var_decl("timestamp", this_call("safeInteger2", [identifier("ticker"), literal("closeTime")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Ticker.derive(wrap_entry([binding, safe_ticker_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger2"
      assert ts["format"] == "ms"
    end

    test "safeTimestamp binding on timestamp field emits format: s" do
      binding = var_decl("timestamp", this_call("safeTimestamp", [identifier("ticker"), literal("ts")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Ticker.derive(wrap_entry([binding, safe_ticker_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeTimestamp"
      assert ts["format"] == "s"
    end

    test "safeNumber on timestamp field emits nil (not a time coercion)" do
      # safeNumber is in slot_vocab but not a timestamp coercion
      binding = var_decl("timestamp", this_call("safeNumber", [identifier("ticker"), literal("ts")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Ticker.derive(wrap_entry([binding, safe_ticker_return(props)]))

      assert result["field_map"]["timestamp"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # All 22 unified fields present; _unresolved_reason contract
  # ---------------------------------------------------------------------------

  describe "derive/1 — output shape contract" do
    test "all 22 unified fields appear as keys in field_map (even when nil)" do
      result = Ticker.derive(wrap_entry([safe_ticker_return([])]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Ticker.unified_fields())
    end

    test "_unresolved_reason is nil when safeTicker return found (even if all fields null)" do
      result = Ticker.derive(wrap_entry([safe_ticker_return([])]))

      assert result["_unresolved_reason"] == nil
    end

    test "field_map has 22 entries regardless of how many props are in the object" do
      props = [prop("high", this_call("safeString", [identifier("ticker"), literal("h")]))]
      result = Ticker.derive(wrap_entry([safe_ticker_return(props)]))

      assert map_size(result["field_map"]) == 22
    end
  end

  # ---------------------------------------------------------------------------
  # Extras list
  # ---------------------------------------------------------------------------

  describe "derive/1 — extras list" do
    test "property not in unified fields appears in extras" do
      extra_prop = prop("openInterest", this_call("safeString", [identifier("ticker"), literal("oi")]))
      result = Ticker.derive(wrap_entry([safe_ticker_return([extra_prop])]))

      assert [entry] = result["extras"]
      assert entry["unified_key"] == "openInterest"
      assert entry["key"] == "oi"
      assert entry["coercion"] == "safeString"
    end

    test "extras is empty when all props are in unified fields" do
      props = [prop("high", this_call("safeNumber", [identifier("ticker"), literal("h")]))]
      result = Ticker.derive(wrap_entry([safe_ticker_return(props)]))

      assert result["extras"] == []
    end

    test "extra with non-vocab coercion is NOT included in extras" do
      # safeSymbol is outside the closed vocab
      extra_prop = prop("sym", this_call("safeSymbol", [identifier("ticker"), literal("s"), identifier("market")]))
      result = Ticker.derive(wrap_entry([safe_ticker_return([extra_prop])]))

      assert result["extras"] == []
    end

    test "computed property key is skipped from both field_map and extras" do
      # {[dynamicKey]: this.safeString(ticker, "k")} — computed: true means the key
      # is a runtime expression; key_from_property/1 must return nil, not the identifier name.
      computed_prop = %{
        "computed" => true,
        "key" => %{"type" => "Identifier", "name" => "dynamicKey"},
        "value" => this_call("safeString", [identifier("ticker"), literal("someKey")])
      }

      result = Ticker.derive(wrap_entry([safe_ticker_return([computed_prop])]))

      assert result["extras"] == [], "computed prop must not appear in extras"
      assert map_size(result["field_map"]) == 22

      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1),
             "dynamicKey must not bleed into any unified field slot"
    end
  end

  # ---------------------------------------------------------------------------
  # Structurally-null fields
  # ---------------------------------------------------------------------------

  describe "derive/1 — structurally-null fields by design" do
    test "symbol is nil — safeSymbol is outside the closed coercion vocab" do
      binding = var_decl("symbol", this_call("safeSymbol", [identifier("ticker"), literal("sym"), identifier("market")]))
      props = [prop("symbol", identifier("symbol"))]
      result = Ticker.derive(wrap_entry([binding, safe_ticker_return(props)]))

      assert result["field_map"]["symbol"] == nil
    end

    test "datetime is nil — iso8601 call does not match this.method(obj, key) pattern" do
      props = [prop("datetime", this_call("iso8601", [identifier("timestamp")]))]
      result = Ticker.derive(wrap_entry([safe_ticker_return(props)]))

      assert result["field_map"]["datetime"] == nil
    end
  end
end
