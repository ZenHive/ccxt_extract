defmodule CcxtExtract.Normalization.PositionTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.Position` — the Task 80 derivation
  that populates `field_maps["position"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Position

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

  defp prop(key, value_node) do
    %{"key" => identifier(key), "value" => value_node}
  end

  defp safe_position_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}
    %{"type" => "ReturnStatement", "argument" => this_call("safePosition", [object, identifier("market")])}
  end

  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parsePosition" => %{
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

  describe "derive/1 — nil / missing parsePosition" do
    test "returns nil when entry is nil" do
      assert Position.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parsePosition" do
      entry = %{"parse_methods" => %{"parseTrade" => %{}}}
      assert Position.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert Position.derive("not a map") == nil
      assert Position.derive(42) == nil
      assert Position.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical safePosition return
  # ---------------------------------------------------------------------------

  describe "derive/1 — canonical safePosition return" do
    test "all unified fields appear as keys in field_map (even when nil)" do
      result = Position.derive(wrap_entry([safe_position_return([])]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Position.unified_fields())
    end

    test "_unresolved_reason is nil when canonical return found" do
      result = Position.derive(wrap_entry([safe_position_return([])]))
      assert result["_unresolved_reason"] == nil
    end

    test "inline safeNumber populates entryPrice slot" do
      props = [prop("entryPrice", this_call("safeNumber", [identifier("pos"), literal("entryPrice")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["entryPrice"]
      assert slot["key"] == "entryPrice"
      assert slot["coercion"] == "safeNumber"
      assert slot["format"] == nil
    end

    test "inline safeString populates id slot" do
      props = [prop("id", this_call("safeString", [identifier("pos"), literal("posId")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["id"]
      assert slot["key"] == "posId"
      assert slot["coercion"] == "safeString"
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-return paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved return shapes" do
    test "non-safePosition return emits _unresolved_reason with callee name" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("parseLinearPosition", [identifier("pos"), identifier("market")])
      }

      result = Position.derive(wrap_entry([ret]))

      assert result["_unresolved_reason"] =~ "non_safe_position_return:parseLinearPosition"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "no return statement emits no_return_statement" do
      result = Position.derive(wrap_entry([]))

      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier binding lookup
  # ---------------------------------------------------------------------------

  describe "derive/1 — Identifier binding lookup" do
    test "binding-resolved scalar populates slot" do
      binding = var_decl("liqPx", this_call("safeNumber", [identifier("pos"), literal("liquidationPrice")]))
      props = [prop("liquidationPrice", identifier("liqPx"))]
      result = Position.derive(wrap_entry([binding, safe_position_return(props)]))

      slot = result["field_map"]["liquidationPrice"]
      assert slot["key"] == "liquidationPrice"
      assert slot["coercion"] == "safeNumber"
    end

    test "unbound Identifier emits nil slot" do
      props = [prop("entryPrice", identifier("notDeclared"))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      assert result["field_map"]["entryPrice"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp format
  # ---------------------------------------------------------------------------

  describe "derive/1 — timestamp format" do
    test "safeInteger on timestamp emits format: ms" do
      binding = var_decl("timestamp", this_call("safeInteger", [identifier("pos"), literal("cTime")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Position.derive(wrap_entry([binding, safe_position_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger"
      assert ts["format"] == "ms"
      assert ts["key"] == "cTime"
    end

    test "safeInteger inline on timestamp emits format: ms" do
      props = [prop("timestamp", this_call("safeInteger", [identifier("pos"), literal("updateTime")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger"
      assert ts["format"] == "ms"
    end
  end

  # ---------------------------------------------------------------------------
  # Enum fields (side / marginMode)
  # ---------------------------------------------------------------------------

  describe "derive/1 — enum fields" do
    test "safeString on side populates enum slot with enum_map: nil" do
      props = [prop("side", this_call("safeString", [identifier("pos"), literal("side")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["key"] == "side"
      assert slot["coercion"] == "safeString"
      assert slot["enum_map"] == nil
    end

    test "safeString on marginMode populates enum slot" do
      props = [prop("marginMode", this_call("safeString", [identifier("pos"), literal("mgnMode")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["marginMode"]
      assert slot["key"] == "mgnMode"
      assert slot["coercion"] == "safeString"
      assert slot["enum_map"] == nil
    end

    test "safeStringLower chain on side canonicalizes to safeStringLower" do
      to_lower = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => this_call("safeString", [identifier("pos"), literal("positionSide")]),
          "property" => identifier("toLowerCase")
        },
        "arguments" => []
      }

      props = [prop("side", to_lower)]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["coercion"] == "safeStringLower"
      assert slot["enum_map"] == nil
    end

    test "ternary enum on side extracts enum_map" do
      safe = this_call("safeString", [identifier("pos"), literal("posSide")])

      outer_ternary =
        ternary(
          binexp(safe, "===", literal("long")),
          literal("long"),
          ternary(
            binexp(safe, "===", literal("short")),
            literal("short"),
            identifier("undefined")
          )
        )

      props = [prop("side", outer_ternary)]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["coercion"] == "safeString"
      assert slot["key"] == "posSide"
      assert slot["enum_map"] == %{"long" => "long", "short" => "short"}
    end

    test "bool-flag ternary emits unresolved_reason: bool_flag_inferred" do
      props = [prop("side", ternary(identifier("isLong"), literal("long"), literal("short")))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

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
      props = [prop("info", identifier("position"))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      assert result["field_map"]["info"] == nil
    end

    test "datetime (iso8601 derivation) emits nil slot" do
      props = [prop("datetime", this_call("iso8601", [identifier("timestamp")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      assert result["field_map"]["datetime"] == nil
    end

    test "symbol (market reference) emits nil slot" do
      member = %{
        "type" => "MemberExpression",
        "object" => identifier("market"),
        "property" => literal("symbol"),
        "computed" => true
      }

      props = [prop("symbol", member)]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      assert result["field_map"]["symbol"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Extras list
  # ---------------------------------------------------------------------------

  describe "derive/1 — extras list" do
    test "property not in unified fields appears in extras" do
      extra_prop = prop("fundingRate", this_call("safeNumber", [identifier("pos"), literal("fundingRate")]))
      result = Position.derive(wrap_entry([safe_position_return([extra_prop])]))

      assert [entry] = result["extras"]
      assert entry["unified_key"] == "fundingRate"
      assert entry["key"] == "fundingRate"
      assert entry["coercion"] == "safeNumber"
    end

    test "extras is empty when all props are unified fields" do
      props = [prop("id", this_call("safeString", [identifier("pos"), literal("posId")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      assert result["extras"] == []
    end

    test "computed property key is skipped from both field_map and extras" do
      computed_prop = %{
        "computed" => true,
        "key" => identifier("dynamicKey"),
        "value" => this_call("safeNumber", [identifier("pos"), literal("k")])
      }

      result = Position.derive(wrap_entry([safe_position_return([computed_prop])]))

      assert result["extras"] == []
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # safeNumber2 + safeBool in scalar vocab
  # ---------------------------------------------------------------------------

  describe "derive/1 — extended coercion vocab" do
    test "safeNumber2 on realizedPnl populates slot" do
      props = [
        prop(
          "realizedPnl",
          this_call("safeNumber2", [identifier("pos"), literal("curRealisedPnl"), literal("realisedPnl")])
        )
      ]

      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["realizedPnl"]
      assert slot["key"] == "curRealisedPnl"
      assert slot["coercion"] == "safeNumber2"
    end

    test "safeBool on hedged populates slot" do
      props = [prop("hedged", this_call("safeBool", [identifier("pos"), literal("hedged")]))]
      result = Position.derive(wrap_entry([safe_position_return(props)]))

      slot = result["field_map"]["hedged"]
      assert slot["key"] == "hedged"
      assert slot["coercion"] == "safeBool"
    end
  end
end
