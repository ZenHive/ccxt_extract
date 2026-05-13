defmodule CcxtExtract.Normalization.OrderTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.Order` — the Task 75 derivation
  that populates `field_maps["order"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Order

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

  defp var_decl(name, init, kind \\ "const") do
    %{
      "type" => "VariableDeclaration",
      "kind" => kind,
      "declarations" => [
        %{
          "type" => "VariableDeclarator",
          "id" => identifier(name),
          "init" => init
        }
      ]
    }
  end

  defp prop(key, value_node) do
    %{"key" => identifier(key), "value" => value_node}
  end

  defp safe_order_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}
    %{"type" => "ReturnStatement", "argument" => this_call("safeOrder", [object, identifier("market")])}
  end

  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseOrder" => %{
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  defp ternary(test, consequent, alternate) do
    %{"type" => "ConditionalExpression", "test" => test, "consequent" => consequent, "alternate" => alternate}
  end

  defp binexp(left, op, right) do
    %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right}
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/1 — nil / missing parseOrder" do
    test "returns nil when entry is nil" do
      assert Order.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parseOrder" do
      entry = %{"parse_methods" => %{"parseTrade" => %{}}}
      assert Order.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert Order.derive("not a map") == nil
      assert Order.derive(42) == nil
      assert Order.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical safeOrder return
  # ---------------------------------------------------------------------------

  describe "derive/1 — canonical safeOrder return" do
    test "all unified fields appear as keys in field_map (even when nil)" do
      result = Order.derive(wrap_entry([safe_order_return([])]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Order.unified_fields())
    end

    test "_unresolved_reason is nil when canonical return found" do
      result = Order.derive(wrap_entry([safe_order_return([])]))
      assert result["_unresolved_reason"] == nil
    end

    test "inline safeString populates id slot" do
      props = [prop("id", this_call("safeString", [identifier("order"), literal("orderId")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["id"]
      assert slot["key"] == "orderId"
      assert slot["coercion"] == "safeString"
      assert slot["format"] == nil
    end

    test "inline safeNumber populates price slot" do
      props = [prop("price", this_call("safeNumber", [identifier("order"), literal("px")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["price"]
      assert slot["key"] == "px"
      assert slot["coercion"] == "safeNumber"
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-return paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved return shapes" do
    test "non-safeOrder return emits _unresolved_reason with callee name" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("parseSpotOrder", [identifier("order"), identifier("market")])
      }

      result = Order.derive(wrap_entry([ret]))

      assert result["_unresolved_reason"] =~ "non_safe_order_return:parseSpotOrder"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "no return statement emits no_return_statement" do
      result = Order.derive(wrap_entry([]))

      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-payload branching detection
  # ---------------------------------------------------------------------------

  describe "derive/1 — multi-payload branching" do
    test "top-level if (Array.isArray(order)) emits multi_payload_branching" do
      array_check = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => identifier("Array"),
          "property" => identifier("isArray")
        },
        "arguments" => [identifier("order")]
      }

      if_stmt = %{
        "type" => "IfStatement",
        "test" => array_check,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      result = Order.derive(wrap_entry([if_stmt, safe_order_return([])]))
      assert result["_unresolved_reason"] =~ ~r/^multi_payload_branching:\d+$/
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end

    test "top-level if ('ordType' in order) emits multi_payload_branching" do
      in_test = binexp(literal("ordType"), "in", identifier("order"))

      if_stmt = %{
        "type" => "IfStatement",
        "test" => in_test,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      result = Order.derive(wrap_entry([if_stmt, safe_order_return([])]))
      assert result["_unresolved_reason"] =~ ~r/^multi_payload_branching:\d+$/
    end

    test "ordinary boolean ifs do NOT trigger multi-payload" do
      ordinary_test = binexp(identifier("status"), "!==", identifier("undefined"))

      if_stmt = %{
        "type" => "IfStatement",
        "test" => ordinary_test,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      props = [prop("id", this_call("safeString", [identifier("order"), literal("id")]))]
      result = Order.derive(wrap_entry([if_stmt, safe_order_return(props)]))

      assert result["_unresolved_reason"] == nil
      assert result["field_map"]["id"]["key"] == "id"
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier binding lookup
  # ---------------------------------------------------------------------------

  describe "derive/1 — Identifier binding lookup" do
    test "binding-resolved scalar populates slot" do
      binding = var_decl("orderId", this_call("safeString", [identifier("order"), literal("id")]))
      props = [prop("id", identifier("orderId"))]
      result = Order.derive(wrap_entry([binding, safe_order_return(props)]))

      slot = result["field_map"]["id"]
      assert slot["key"] == "id"
      assert slot["coercion"] == "safeString"
    end

    test "unbound Identifier emits nil slot" do
      props = [prop("id", identifier("notDeclared"))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["id"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp format
  # ---------------------------------------------------------------------------

  describe "derive/1 — timestamp format" do
    test "safeInteger on timestamp emits format: ms" do
      binding = var_decl("timestamp", this_call("safeInteger", [identifier("order"), literal("ts")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Order.derive(wrap_entry([binding, safe_order_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger"
      assert ts["format"] == "ms"
      assert ts["key"] == "ts"
    end

    test "safeTimestamp on timestamp emits format: s" do
      binding = var_decl("timestamp", this_call("safeTimestamp", [identifier("order"), literal("createdAt")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Order.derive(wrap_entry([binding, safe_order_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeTimestamp"
      assert ts["format"] == "s"
    end
  end

  # ---------------------------------------------------------------------------
  # Enum fields (status / side / type)
  # ---------------------------------------------------------------------------

  describe "derive/1 — enum fields" do
    test "safeStringLower on side populates enum slot" do
      props = [prop("side", this_call("safeStringLower", [identifier("order"), literal("side")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["key"] == "side"
      assert slot["coercion"] == "safeStringLower"
      assert slot["enum_map"] == nil
    end

    test "safeString on status populates enum slot with enum_map: nil" do
      props = [prop("status", this_call("safeString", [identifier("order"), literal("status")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["status"]
      assert slot["key"] == "status"
      assert slot["coercion"] == "safeString"
      assert slot["enum_map"] == nil
    end

    test "explicit-ternary enum on status extracts enum_map" do
      safe = this_call("safeString", [identifier("order"), literal("ordStatus")])

      inner_ternary =
        ternary(
          binexp(safe, "===", literal("Filled")),
          literal("closed"),
          identifier("undefined")
        )

      outer_ternary =
        ternary(
          binexp(safe, "===", literal("New")),
          literal("open"),
          inner_ternary
        )

      props = [prop("status", outer_ternary)]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["status"]
      assert slot["coercion"] == "safeString"
      assert slot["key"] == "ordStatus"
      assert slot["enum_map"] == %{"New" => "open", "Filled" => "closed"}
    end

    test "bool-flag enum emits unresolved_reason: bool_flag_inferred" do
      props = [prop("side", ternary(identifier("isBuy"), literal("buy"), literal("sell")))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["unresolved_reason"] == "bool_flag_inferred"
      assert slot["coercion"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Structurally-null fields
  # ---------------------------------------------------------------------------

  describe "derive/1 — structurally-null fields" do
    test "info (Identifier pass-through) emits nil slot" do
      props = [prop("info", identifier("order"))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["info"] == nil
    end

    test "datetime (iso8601 derivation) emits nil slot" do
      props = [prop("datetime", this_call("iso8601", [identifier("timestamp")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["datetime"] == nil
    end

    test "symbol emits nil slot" do
      props = [prop("symbol", this_call("safeSymbol", [identifier("order"), identifier("market")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["symbol"] == nil
    end

    test "fee emits nil slot (nested object, not a scalar safe-call)" do
      fee_obj = %{"type" => "ObjectExpression", "properties" => []}
      props = [prop("fee", fee_obj)]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["fee"] == nil
    end

    test "trades emits nil slot (list, not a scalar safe-call)" do
      props = [prop("trades", this_call("safeList", [identifier("order"), literal("fills")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["trades"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Extras list
  # ---------------------------------------------------------------------------

  describe "derive/1 — extras list" do
    test "property not in unified fields appears in extras" do
      extra_prop = prop("orderCategory", this_call("safeString", [identifier("order"), literal("category")]))
      result = Order.derive(wrap_entry([safe_order_return([extra_prop])]))

      assert [entry] = result["extras"]
      assert entry["unified_key"] == "orderCategory"
      assert entry["key"] == "category"
      assert entry["coercion"] == "safeString"
    end

    test "extras is empty when all props are unified fields" do
      props = [prop("id", this_call("safeString", [identifier("order"), literal("orderId")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["extras"] == []
    end

    test "computed property key is skipped from both field_map and extras" do
      computed_prop = %{
        "computed" => true,
        "key" => identifier("dynamicKey"),
        "value" => this_call("safeString", [identifier("order"), literal("k")])
      }

      result = Order.derive(wrap_entry([safe_order_return([computed_prop])]))

      assert result["extras"] == []
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # safeBool + safeIntegerN coercion vocab
  # ---------------------------------------------------------------------------

  describe "derive/1 — extended coercion vocab" do
    test "safeBool on postOnly populates slot" do
      props = [prop("postOnly", this_call("safeBool", [identifier("order"), literal("postOnly")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["postOnly"]
      assert slot["key"] == "postOnly"
      assert slot["coercion"] == "safeBool"
      assert slot["format"] == nil
    end

    test "safeIntegerN on timestamp populates slot with format: ms" do
      props = [prop("timestamp", this_call("safeIntegerN", [identifier("order"), literal("ts"), literal("time")]))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeIntegerN"
      assert ts["format"] == "ms"
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-payload branching — typeof discriminator
  # ---------------------------------------------------------------------------

  describe "derive/1 — typeof discriminator detection" do
    test "top-level if (typeof order === 'string') emits multi_payload_branching" do
      typeof_test =
        binexp(
          %{"type" => "UnaryExpression", "operator" => "typeof", "argument" => identifier("order")},
          "===",
          literal("string")
        )

      if_stmt = %{
        "type" => "IfStatement",
        "test" => typeof_test,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      result = Order.derive(wrap_entry([if_stmt, safe_order_return([])]))
      assert result["_unresolved_reason"] =~ ~r/^multi_payload_branching:\d+$/
    end

    test "top-level if ('string' === typeof order) emits multi_payload_branching (typeof on right)" do
      typeof_test =
        binexp(
          literal("string"),
          "===",
          %{"type" => "UnaryExpression", "operator" => "typeof", "argument" => identifier("order")}
        )

      if_stmt = %{
        "type" => "IfStatement",
        "test" => typeof_test,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      result = Order.derive(wrap_entry([if_stmt, safe_order_return([])]))
      assert result["_unresolved_reason"] =~ ~r/^multi_payload_branching:\d+$/
    end
  end

  # ---------------------------------------------------------------------------
  # Enum: numeric-code / char-code / toLowerCase chain / nested ternary
  # ---------------------------------------------------------------------------

  describe "derive/1 — enum edge cases" do
    test "numeric-code enum (safeInteger === 1 ? 'buy' : 'sell') emits numeric_code_inferred" do
      test = binexp(this_call("safeInteger", [identifier("order"), literal("dir")]), "===", literal(1))
      props = [prop("side", ternary(test, literal("buy"), literal("sell")))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["unresolved_reason"] == "numeric_code_inferred"
      assert slot["coercion"] == nil
    end

    test "char-code enum (order[0] === 'B' ? 'buy' : 'sell') emits char_code_inferred" do
      array_idx = %{
        "type" => "MemberExpression",
        "computed" => true,
        "object" => identifier("order"),
        "property" => literal(0)
      }

      test = binexp(array_idx, "===", literal("B"))
      props = [prop("side", ternary(test, literal("buy"), literal("sell")))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["unresolved_reason"] == "char_code_inferred"
      assert slot["coercion"] == nil
    end

    test "safeString(...).toLowerCase() chain on type field canonicalizes to safeStringLower" do
      to_lower = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => this_call("safeString", [identifier("order"), literal("type")]),
          "property" => identifier("toLowerCase")
        },
        "arguments" => []
      }

      props = [prop("type", to_lower)]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["type"]
      assert slot["coercion"] == "safeStringLower"
      assert slot["key"] == "type"
      assert slot["enum_map"] == nil
    end

    test "nested ternary chain on status extracts full enum_map" do
      safe = this_call("safeString", [identifier("order"), literal("state")])

      inner =
        ternary(
          binexp(safe, "===", literal("canceled")),
          literal("canceled"),
          identifier("undefined")
        )

      outer =
        ternary(
          binexp(safe, "===", literal("filled")),
          literal("closed"),
          inner
        )

      props = [prop("status", outer)]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["status"]
      assert slot["coercion"] == "safeString"
      assert slot["key"] == "state"
      assert slot["enum_map"] == %{"filled" => "closed", "canceled" => "canceled"}
    end

    test "ternary with binding-resolved safe call on side extracts enum_map" do
      safe = this_call("safeString", [identifier("order"), literal("side")])
      binding = var_decl("sideVal", safe)

      test = binexp(identifier("sideVal"), "===", literal("BUY"))
      props = [prop("side", ternary(test, literal("buy"), literal("sell")))]
      result = Order.derive(wrap_entry([binding, safe_order_return(props)]))

      slot = result["field_map"]["side"]
      assert is_map(slot)
      assert slot["coercion"] == "safeString"
      assert slot["enum_map"]["BUY"] == "buy"
    end

    test "ternary alternate terminates on Literal (not undefined)" do
      # Covers the accumulate_enum_map({:type => Literal}) clause
      safe = this_call("safeString", [identifier("order"), literal("status")])

      outer =
        ternary(
          binexp(safe, "===", literal("NEW")),
          literal("open"),
          literal("closed")
        )

      props = [prop("status", outer)]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["status"]
      assert is_map(slot)
      assert slot["coercion"] == "safeString"
      assert is_map(slot["enum_map"])
    end

    test "ternary alternate is a non-ternary/non-literal expression finalizes enum_map" do
      safe = this_call("safeString", [identifier("order"), literal("status")])

      outer =
        ternary(
          binexp(safe, "===", literal("NEW")),
          literal("open"),
          identifier("someVar")
        )

      props = [prop("status", outer)]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["status"]
      assert is_map(slot)
      assert slot["coercion"] == "safeString"
    end

    test "ternary where nested call differs from outer (different key) finalizes current map" do
      safe1 = this_call("safeString", [identifier("order"), literal("status")])
      safe2 = this_call("safeString", [identifier("order"), literal("otherField")])

      inner =
        ternary(
          binexp(safe2, "===", literal("X")),
          literal("x"),
          identifier("undefined")
        )

      outer =
        ternary(
          binexp(safe1, "===", literal("NEW")),
          literal("open"),
          inner
        )

      props = [prop("status", outer)]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      slot = result["field_map"]["status"]
      assert is_map(slot)
      assert slot["coercion"] == "safeString"
      # Only the outer branch resolves (inner uses a different safe call)
      assert slot["enum_map"] == %{"NEW" => "open"}
    end

    test "ternary with unknown test shape emits nil for enum field" do
      # test is a complex expression that isn't Identifier, BinaryExpression equality, etc.
      complex_test = %{
        "type" => "LogicalExpression",
        "operator" => "&&",
        "left" => identifier("a"),
        "right" => identifier("b")
      }

      props = [prop("side", ternary(complex_test, literal("buy"), literal("sell")))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["side"] == nil
    end

    test "enum field with non-safe-call value node emits nil" do
      # value is a plain Identifier that isn't a safe-call binding
      props = [prop("side", identifier("unrelated"))]
      result = Order.derive(wrap_entry([safe_order_return(props)]))

      assert result["field_map"]["side"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # String-keyed property literal keys
  # ---------------------------------------------------------------------------

  describe "derive/1 — string-keyed property" do
    test "property with string-literal key name resolves correctly" do
      # Some ASTs use { "key": value_node } with a Literal key instead of Identifier
      str_key_prop = %{
        "key" => literal("clientOrderId"),
        "value" => this_call("safeString", [identifier("order"), literal("clOrdId")])
      }

      result = Order.derive(wrap_entry([safe_order_return([str_key_prop])]))

      slot = result["field_map"]["clientOrderId"]
      assert slot["key"] == "clOrdId"
      assert slot["coercion"] == "safeString"
    end
  end

  # ---------------------------------------------------------------------------
  # Return fallthrough: neither safeOrder nor a known callee
  # ---------------------------------------------------------------------------

  describe "derive/1 — return fallthrough" do
    test "return with non-ThisExpression callee emits no_return_statement" do
      # Covers the catch-all `_` clause in find_safe_order_object
      ret = %{
        "type" => "ReturnStatement",
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => identifier("helper"),
            "property" => identifier("parseOrder")
          },
          "arguments" => [identifier("order")]
        }
      }

      result = Order.derive(wrap_entry([ret]))
      assert result["_unresolved_reason"] == "no_return_statement"
    end
  end
end
