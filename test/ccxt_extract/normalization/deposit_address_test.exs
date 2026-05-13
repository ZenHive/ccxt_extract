defmodule CcxtExtract.Normalization.DepositAddressTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.DepositAddress` — the Task 82 derivation
  that populates `field_maps["deposit_address"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.DepositAddress

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

  defp object_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}
    %{"type" => "ReturnStatement", "argument" => object}
  end

  defp ts_as_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}

    ts_as = %{
      "type" => "TSAsExpression",
      "expression" => object,
      "typeAnnotation" => %{"type" => "TSTypeReference", "typeName" => identifier("DepositAddress")}
    }

    %{"type" => "ReturnStatement", "argument" => ts_as}
  end

  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseDepositAddress" => %{
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/1 — nil / missing parseDepositAddress" do
    test "returns nil when entry is nil" do
      assert DepositAddress.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parseDepositAddress" do
      entry = %{"parse_methods" => %{"parseTrade" => %{}}}
      assert DepositAddress.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert DepositAddress.derive("not a map") == nil
      assert DepositAddress.derive(42) == nil
      assert DepositAddress.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # unified_fields/0
  # ---------------------------------------------------------------------------

  describe "unified_fields/0" do
    test "returns the list of 5 unified depositAddress field names" do
      fields = DepositAddress.unified_fields()
      assert length(fields) == 5
      assert "currency" in fields
      assert "address" in fields
      assert "tag" in fields
      assert "network" in fields
      assert "info" in fields
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-reason paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved paths" do
    test "no return statement emits _unresolved_reason: no_return_statement" do
      result = DepositAddress.derive(wrap_entry([]))

      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "non-object return emits _unresolved_reason with the return type" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("safeCurrencyCode", [identifier("id")])
      }

      result = DepositAddress.derive(wrap_entry([ret]))

      assert is_binary(result["_unresolved_reason"])
      assert result["_unresolved_reason"] =~ "non_object_return:CallExpression"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end

    test "last return statement is used (not first) when multiple returns present" do
      early_return = %{
        "type" => "ReturnStatement",
        "argument" => identifier("undefined")
      }

      props = [prop("address", this_call("safeString", [identifier("d"), literal("address")]))]
      result = DepositAddress.derive(wrap_entry([early_return, object_return(props)]))

      assert result["_unresolved_reason"] == nil
      assert result["field_map"]["address"]["key"] == "address"
    end
  end

  # ---------------------------------------------------------------------------
  # TSAsExpression unwrapping
  # ---------------------------------------------------------------------------

  describe "derive/1 — TSAsExpression unwrapping" do
    test "TSAsExpression wrapper is unwrapped to the inner ObjectExpression" do
      props = [prop("address", this_call("safeString", [identifier("d"), literal("depositAddress")]))]
      result = DepositAddress.derive(wrap_entry([ts_as_return(props)]))

      assert result["_unresolved_reason"] == nil
      assert result["field_map"]["address"]["key"] == "depositAddress"
    end
  end

  # ---------------------------------------------------------------------------
  # Inline CallExpression property (no binding lookup)
  # ---------------------------------------------------------------------------

  describe "derive/1 — inline CallExpression property" do
    test "inline safeString call populates address slot" do
      props = [prop("address", this_call("safeString", [identifier("d"), literal("addr")]))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      assert result["_unresolved_reason"] == nil
      slot = result["field_map"]["address"]
      assert slot["key"] == "addr"
      assert slot["coercion"] == "safeString"
      assert slot["format"] == nil
    end

    test "inline safeString call populates tag slot" do
      props = [prop("tag", this_call("safeString", [identifier("d"), literal("memo")]))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      slot = result["field_map"]["tag"]
      assert slot["key"] == "memo"
      assert slot["coercion"] == "safeString"
    end

    test "inline safeString2 call populates currency slot" do
      props = [prop("currency", this_call("safeString2", [identifier("d"), literal("coin")]))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      slot = result["field_map"]["currency"]
      assert slot["key"] == "coin"
      assert slot["coercion"] == "safeString2"
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier binding lookup
  # ---------------------------------------------------------------------------

  describe "derive/1 — Identifier binding lookup" do
    test "Identifier property resolved via binding populates slot" do
      binding = var_decl("addr", this_call("safeString", [identifier("d"), literal("depositAddress")]))
      props = [prop("address", identifier("addr"))]
      result = DepositAddress.derive(wrap_entry([binding, object_return(props)]))

      slot = result["field_map"]["address"]
      assert slot["key"] == "depositAddress"
      assert slot["coercion"] == "safeString"
    end

    test "unbound Identifier emits nil for that field" do
      props = [prop("address", identifier("notDeclared"))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      assert result["field_map"]["address"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Structurally-null fields
  # ---------------------------------------------------------------------------

  describe "derive/1 — structurally-null fields" do
    test "info is nil — raw pass-through" do
      props = [prop("info", identifier("depositAddress"))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      assert result["field_map"]["info"] == nil
    end

    test "network with resolver call emits nil (outside closed safe* vocab)" do
      props = [
        prop("network", this_call("getNetworkCodeByNetworkUrl", [identifier("d"), literal("url")]))
      ]

      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      # getNetworkCodeByNetworkUrl is outside the closed safe* vocab → honest nil
      assert result["field_map"]["network"] == nil
    end

    test "network with safeString populates the slot" do
      props = [prop("network", this_call("safeString", [identifier("d"), literal("networkId")]))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      slot = result["field_map"]["network"]
      assert slot["key"] == "networkId"
      assert slot["coercion"] == "safeString"
    end
  end

  # ---------------------------------------------------------------------------
  # Output shape contract
  # ---------------------------------------------------------------------------

  describe "derive/1 — output shape contract" do
    test "all 5 unified fields appear as keys in field_map" do
      result = DepositAddress.derive(wrap_entry([object_return([])]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(DepositAddress.unified_fields())
    end

    test "_unresolved_reason is nil when ObjectExpression return found" do
      result = DepositAddress.derive(wrap_entry([object_return([])]))

      assert result["_unresolved_reason"] == nil
    end

    test "field_map has 5 entries regardless of how many props in the object" do
      props = [prop("address", this_call("safeString", [identifier("d"), literal("a")]))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      assert map_size(result["field_map"]) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # Extras list
  # ---------------------------------------------------------------------------

  describe "derive/1 — extras list" do
    test "property not in unified fields appears in extras" do
      extra_prop = prop("memo2", this_call("safeString", [identifier("d"), literal("memo2")]))
      result = DepositAddress.derive(wrap_entry([object_return([extra_prop])]))

      assert [entry] = result["extras"]
      assert entry["unified_key"] == "memo2"
      assert entry["key"] == "memo2"
      assert entry["coercion"] == "safeString"
    end

    test "extras is empty when all props are unified fields" do
      props = [prop("address", this_call("safeString", [identifier("d"), literal("addr")]))]
      result = DepositAddress.derive(wrap_entry([object_return(props)]))

      assert result["extras"] == []
    end

    test "computed property key is skipped from both field_map and extras" do
      computed_prop = %{
        "computed" => true,
        "key" => %{"type" => "Identifier", "name" => "dynKey"},
        "value" => this_call("safeString", [identifier("d"), literal("k")])
      }

      result = DepositAddress.derive(wrap_entry([object_return([computed_prop])]))

      assert result["extras"] == []
      assert map_size(result["field_map"]) == 5
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end
end
