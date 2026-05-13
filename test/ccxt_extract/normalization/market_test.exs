defmodule CcxtExtract.Normalization.MarketTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.Market` — the Task 79 derivation
  that populates `field_maps["market"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Market

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

  # `return this.safeMarketStructure({...props});`
  defp safe_market_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}
    %{"type" => "ReturnStatement", "argument" => this_call("safeMarketStructure", [object])}
  end

  # `return {...props};` — direct ObjectExpression return
  defp direct_obj_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}
    %{"type" => "ReturnStatement", "argument" => object}
  end

  # Wrap statements into a parse_methods entry for `parseMarket`.
  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseMarket" => %{
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/1 — nil / missing parseMarket" do
    test "returns nil when entry is nil" do
      assert Market.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parseMarket" do
      entry = %{"parse_methods" => %{"parseTrade" => %{}}}
      assert Market.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert Market.derive("not a map") == nil
      assert Market.derive(42) == nil
      assert Market.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-reason paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved paths" do
    test "no return statement emits _unresolved_reason: no_return_statement" do
      result = Market.derive(wrap_entry([]))
      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "non-slottable call return emits _unresolved_reason with callee name" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("extend", [identifier("market"), identifier("result")])
      }

      result = Market.derive(wrap_entry([ret]))
      assert result["_unresolved_reason"] =~ "non_safe_market_return:extend"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Output shape contract
  # ---------------------------------------------------------------------------

  describe "derive/1 — output shape contract" do
    test "all unified fields appear as keys in field_map (even when nil)" do
      result = Market.derive(wrap_entry([safe_market_return([])]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Market.unified_fields())
    end

    test "_unresolved_reason is nil when safeMarketStructure return found" do
      result = Market.derive(wrap_entry([safe_market_return([])]))
      assert result["_unresolved_reason"] == nil
    end

    test "_unresolved_reason is nil for direct ObjectExpression return" do
      result = Market.derive(wrap_entry([direct_obj_return([])]))
      assert result["_unresolved_reason"] == nil
    end

    test "extras is an empty list when all properties are in unified fields" do
      props = [prop("id", this_call("safeString", [identifier("market"), literal("id")]))]
      result = Market.derive(wrap_entry([safe_market_return(props)]))
      assert result["extras"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # Structurally-null fields
  # ---------------------------------------------------------------------------

  describe "derive/1 — structurally-null fields" do
    test "symbol is always nil (computed, not a direct safe-call)" do
      # Even if symbol appears in the object with a safeString call, the
      # structurally-null rule applies because symbol is in @structurally_null.
      props = [
        prop("symbol", this_call("safeString", [identifier("market"), literal("symbol")]))
      ]

      result = Market.derive(wrap_entry([safe_market_return(props)]))
      assert result["field_map"]["symbol"] == nil
    end

    test "info is always nil (raw pass-through)" do
      result = Market.derive(wrap_entry([safe_market_return([])]))
      assert result["field_map"]["info"] == nil
    end

    test "precision is always nil (nested ObjectExpression, deferred)" do
      result = Market.derive(wrap_entry([safe_market_return([])]))
      assert result["field_map"]["precision"] == nil
    end

    test "limits is always nil (deeply nested ObjectExpression, deferred)" do
      result = Market.derive(wrap_entry([safe_market_return([])]))
      assert result["field_map"]["limits"] == nil
    end

    test "expiryDatetime is always nil (iso8601 derivation, not a safe-call)" do
      result = Market.derive(wrap_entry([safe_market_return([])]))
      assert result["field_map"]["expiryDatetime"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Direct inline CallExpression properties
  # ---------------------------------------------------------------------------

  describe "derive/1 — inline safe-call properties" do
    test "id: safeString(market, 'id') populates slot" do
      props = [prop("id", this_call("safeString", [identifier("market"), literal("id")]))]
      result = Market.derive(wrap_entry([safe_market_return(props)]))
      slot = result["field_map"]["id"]
      assert slot["key"] == "id"
      assert slot["coercion"] == "safeString"
      assert slot["format"] == nil
    end

    test "taker: safeNumber(market, 'taker_fee') populates slot" do
      props = [
        prop("taker", this_call("safeNumber", [identifier("market"), literal("taker_fee")]))
      ]

      result = Market.derive(wrap_entry([safe_market_return(props)]))
      slot = result["field_map"]["taker"]
      assert slot["key"] == "taker_fee"
      assert slot["coercion"] == "safeNumber"
    end

    test "active: safeBool(market, 'isActive') populates slot (bool extension)" do
      props = [
        prop("active", this_call("safeBool", [identifier("market"), literal("isActive")]))
      ]

      result = Market.derive(wrap_entry([safe_market_return(props)]))
      slot = result["field_map"]["active"]
      assert slot["key"] == "isActive"
      assert slot["coercion"] == "safeBool"
    end

    test "out-of-vocab coercion emits nil for that field" do
      # safeSymbol is outside the closed vocab
      props = [
        prop(
          "base",
          this_call("safeSymbol", [identifier("market"), literal("baseAsset")])
        )
      ]

      result = Market.derive(wrap_entry([safe_market_return(props)]))
      assert result["field_map"]["base"] == nil
    end

    test "field absent from properties emits nil" do
      result = Market.derive(wrap_entry([safe_market_return([])]))
      assert result["field_map"]["base"] == nil
      assert result["field_map"]["quote"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Direct ObjectExpression return (no safeMarketStructure wrapper)
  # ---------------------------------------------------------------------------

  describe "derive/1 — direct ObjectExpression return" do
    test "safeNumber in direct return populates slot" do
      props = [
        prop("maker", this_call("safeNumber", [identifier("market"), literal("maker_fee_rate")]))
      ]

      result = Market.derive(wrap_entry([direct_obj_return(props)]))
      slot = result["field_map"]["maker"]
      assert slot["key"] == "maker_fee_rate"
      assert slot["coercion"] == "safeNumber"
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier binding lookup
  # ---------------------------------------------------------------------------

  describe "derive/1 — Identifier binding lookup" do
    test "Identifier property resolved via top-level binding populates slot" do
      binding =
        var_decl("baseId", this_call("safeString", [identifier("market"), literal("baseCurrency")]))

      props = [prop("baseId", identifier("baseId"))]
      result = Market.derive(wrap_entry([binding, safe_market_return(props)]))
      slot = result["field_map"]["baseId"]
      assert slot["key"] == "baseCurrency"
      assert slot["coercion"] == "safeString"
    end

    test "unbound Identifier emits nil for that field" do
      props = [prop("quoteId", identifier("notDeclared"))]
      result = Market.derive(wrap_entry([safe_market_return(props)]))
      assert result["field_map"]["quoteId"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Extras list
  # ---------------------------------------------------------------------------

  describe "derive/1 — extras list" do
    test "property not in unified fields with in-vocab coercion appears in extras" do
      extra_prop =
        prop(
          "openInterestUsd",
          this_call("safeString", [identifier("market"), literal("openInterest")])
        )

      result = Market.derive(wrap_entry([safe_market_return([extra_prop])]))
      assert [entry] = result["extras"]
      assert entry["unified_key"] == "openInterestUsd"
      assert entry["key"] == "openInterest"
      assert entry["coercion"] == "safeString"
    end

    test "extra with out-of-vocab coercion is NOT included in extras" do
      extra_prop =
        prop(
          "customField",
          this_call("safeSymbol", [identifier("market"), literal("x")])
        )

      result = Market.derive(wrap_entry([safe_market_return([extra_prop])]))
      assert result["extras"] == []
    end

    test "computed property key is excluded from both field_map and extras" do
      computed_prop = %{
        "computed" => true,
        "key" => identifier("dynamicKey"),
        "value" => this_call("safeString", [identifier("market"), literal("k")])
      }

      result = Market.derive(wrap_entry([safe_market_return([computed_prop])]))
      assert result["extras"] == []
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end
end
