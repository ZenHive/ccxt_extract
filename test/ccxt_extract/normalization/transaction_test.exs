defmodule CcxtExtract.Normalization.TransactionTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.Transaction` — the Task 81 derivation
  that populates `field_maps["transaction"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Transaction

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
      "typeAnnotation" => %{"type" => "TSTypeReference", "typeName" => identifier("Transaction")}
    }

    %{"type" => "ReturnStatement", "argument" => ts_as}
  end

  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseTransaction" => %{
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/1 — nil / missing parseTransaction" do
    test "returns nil when entry is nil" do
      assert Transaction.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parseTransaction" do
      entry = %{"parse_methods" => %{"parseTrade" => %{}}}
      assert Transaction.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert Transaction.derive("not a map") == nil
      assert Transaction.derive(42) == nil
      assert Transaction.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # unified_fields/0
  # ---------------------------------------------------------------------------

  describe "unified_fields/0" do
    test "returns the list of 18 unified transaction field names" do
      fields = Transaction.unified_fields()
      assert length(fields) == 18
      assert "id" in fields
      assert "timestamp" in fields
      assert "type" in fields
      assert "status" in fields
      assert "address" in fields
      assert "amount" in fields
      assert "fee" in fields
      assert "info" in fields
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-reason paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved paths" do
    test "no return statement emits _unresolved_reason: no_return_statement" do
      result = Transaction.derive(wrap_entry([]))

      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "non-object return emits _unresolved_reason with the return type" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("safeCurrencyCode", [identifier("id")])
      }

      result = Transaction.derive(wrap_entry([ret]))

      assert is_binary(result["_unresolved_reason"])
      assert result["_unresolved_reason"] =~ "non_object_return:CallExpression"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end

    test "last return statement is used (not first) when multiple returns present" do
      early_return = %{
        "type" => "ReturnStatement",
        "argument" => identifier("undefined")
      }

      props = [prop("id", this_call("safeString", [identifier("tx"), literal("id")]))]
      result = Transaction.derive(wrap_entry([early_return, object_return(props)]))

      assert result["_unresolved_reason"] == nil
      assert result["field_map"]["id"]["key"] == "id"
    end
  end

  # ---------------------------------------------------------------------------
  # TSAsExpression unwrapping
  # ---------------------------------------------------------------------------

  describe "derive/1 — TSAsExpression unwrapping" do
    test "TSAsExpression wrapper is unwrapped to the inner ObjectExpression" do
      props = [prop("id", this_call("safeString", [identifier("tx"), literal("txId")]))]
      result = Transaction.derive(wrap_entry([ts_as_return(props)]))

      assert result["_unresolved_reason"] == nil
      assert result["field_map"]["id"]["key"] == "txId"
    end
  end

  # ---------------------------------------------------------------------------
  # Inline CallExpression property (no binding lookup)
  # ---------------------------------------------------------------------------

  describe "derive/1 — inline CallExpression property" do
    test "inline safeString call populates scalar slot" do
      props = [prop("txid", this_call("safeString", [identifier("tx"), literal("txHash")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      assert result["_unresolved_reason"] == nil
      slot = result["field_map"]["txid"]
      assert slot["key"] == "txHash"
      assert slot["coercion"] == "safeString"
      assert slot["format"] == nil
    end

    test "inline safeNumber call populates amount slot" do
      props = [prop("amount", this_call("safeNumber", [identifier("tx"), literal("qty")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      slot = result["field_map"]["amount"]
      assert slot["key"] == "qty"
      assert slot["coercion"] == "safeNumber"
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier binding lookup
  # ---------------------------------------------------------------------------

  describe "derive/1 — Identifier binding lookup" do
    test "Identifier property resolved via binding populates slot" do
      binding = var_decl("txid", this_call("safeString2", [identifier("tx"), literal("hash")]))
      props = [prop("txid", identifier("txid"))]
      result = Transaction.derive(wrap_entry([binding, object_return(props)]))

      slot = result["field_map"]["txid"]
      assert slot["key"] == "hash"
      assert slot["coercion"] == "safeString2"
    end

    test "unbound Identifier emits nil for that field" do
      props = [prop("txid", identifier("notDeclared"))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      assert result["field_map"]["txid"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp format
  # ---------------------------------------------------------------------------

  describe "derive/1 — timestamp and updated format" do
    test "safeInteger on timestamp emits format: ms" do
      binding = var_decl("timestamp", this_call("safeInteger", [identifier("tx"), literal("time")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Transaction.derive(wrap_entry([binding, object_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger"
      assert ts["format"] == "ms"
      assert ts["key"] == "time"
    end

    test "safeTimestamp on timestamp emits format: s" do
      binding = var_decl("timestamp", this_call("safeTimestamp", [identifier("tx"), literal("ts")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Transaction.derive(wrap_entry([binding, object_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeTimestamp"
      assert ts["format"] == "s"
    end

    test "updated field also uses timestamp classification (format-aware)" do
      binding = var_decl("updated", this_call("safeInteger2", [identifier("tx"), literal("updatedAt")]))
      props = [prop("updated", identifier("updated"))]
      result = Transaction.derive(wrap_entry([binding, object_return(props)]))

      upd = result["field_map"]["updated"]
      assert upd["coercion"] == "safeInteger2"
      assert upd["format"] == "ms"
      assert upd["key"] == "updatedAt"
    end
  end

  # ---------------------------------------------------------------------------
  # Enum fields: type and status
  # ---------------------------------------------------------------------------

  describe "derive/1 — enum fields" do
    test "type field carries enum_values with deposit/withdrawal" do
      props = [prop("type", this_call("safeString", [identifier("tx"), literal("txType")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      type_slot = result["field_map"]["type"]
      assert type_slot["key"] == "txType"
      assert type_slot["coercion"] == "safeString"
      assert "deposit" in type_slot["enum_values"]
      assert "withdrawal" in type_slot["enum_values"]
    end

    test "status field carries enum_values with ok/pending/canceled/failed" do
      props = [prop("status", this_call("safeString", [identifier("tx"), literal("state")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      status_slot = result["field_map"]["status"]
      assert status_slot["key"] == "state"
      assert "ok" in status_slot["enum_values"]
      assert "pending" in status_slot["enum_values"]
      assert "canceled" in status_slot["enum_values"]
      assert "failed" in status_slot["enum_values"]
    end

    test "enum field with unresolvable binding emits nil" do
      props = [prop("type", identifier("notDeclared"))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      assert result["field_map"]["type"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Structurally-null fields
  # ---------------------------------------------------------------------------

  describe "derive/1 — structurally-null fields" do
    test "info is nil — raw pass-through" do
      props = [prop("info", identifier("transaction"))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      assert result["field_map"]["info"] == nil
    end

    test "datetime is nil — derived from timestamp, not a direct lookup" do
      props = [prop("datetime", this_call("iso8601", [identifier("timestamp")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      assert result["field_map"]["datetime"] == nil
    end

    test "network is nil — resolved via resolver call pattern" do
      props = [prop("network", this_call("networkIdToCode", [identifier("tx"), literal("network")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      # networkIdToCode is outside the closed safe* vocab
      assert result["field_map"]["network"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Output shape contract
  # ---------------------------------------------------------------------------

  describe "derive/1 — output shape contract" do
    test "all 18 unified fields appear as keys in field_map" do
      result = Transaction.derive(wrap_entry([object_return([])]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Transaction.unified_fields())
    end

    test "_unresolved_reason is nil when ObjectExpression return found" do
      result = Transaction.derive(wrap_entry([object_return([])]))

      assert result["_unresolved_reason"] == nil
    end

    test "field_map has 18 entries regardless of how many props in the object" do
      props = [prop("id", this_call("safeString", [identifier("tx"), literal("i")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      assert map_size(result["field_map"]) == 18
    end
  end

  # ---------------------------------------------------------------------------
  # Extras list
  # ---------------------------------------------------------------------------

  describe "derive/1 — extras list" do
    test "property not in unified fields appears in extras" do
      extra_prop = prop("internalId", this_call("safeString", [identifier("tx"), literal("iid")]))
      result = Transaction.derive(wrap_entry([object_return([extra_prop])]))

      assert [entry] = result["extras"]
      assert entry["unified_key"] == "internalId"
      assert entry["key"] == "iid"
      assert entry["coercion"] == "safeString"
    end

    test "extras is empty when all props are unified fields" do
      props = [prop("id", this_call("safeString", [identifier("tx"), literal("id")]))]
      result = Transaction.derive(wrap_entry([object_return(props)]))

      assert result["extras"] == []
    end

    test "computed property key is skipped from both field_map and extras" do
      computed_prop = %{
        "computed" => true,
        "key" => %{"type" => "Identifier", "name" => "dynKey"},
        "value" => this_call("safeString", [identifier("tx"), literal("k")])
      }

      result = Transaction.derive(wrap_entry([object_return([computed_prop])]))

      assert result["extras"] == []
      assert map_size(result["field_map"]) == 18
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end
end
