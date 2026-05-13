defmodule CcxtExtract.Normalization.TradeTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.Trade` — the Task 76 derivation
  that populates `field_maps["trade"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.Trade

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

  # VariableDeclaration: `const|let <name> = <init>;`
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

  # A property in an ObjectExpression: `<key>: <value_node>`
  defp prop(key, value_node) do
    %{"key" => identifier(key), "value" => value_node}
  end

  # `return this.safeTrade({...props}, market);`
  defp safe_trade_return(props) do
    object = %{"type" => "ObjectExpression", "properties" => props}
    %{"type" => "ReturnStatement", "argument" => this_call("safeTrade", [object, identifier("market")])}
  end

  # Wrap statements into a parse_methods entry for `parseTrade`.
  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseTrade" => %{
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  # ConditionalExpression: `test ? consequent : alternate`
  defp ternary(test, consequent, alternate) do
    %{
      "type" => "ConditionalExpression",
      "test" => test,
      "consequent" => consequent,
      "alternate" => alternate
    }
  end

  defp binexp(left, op, right) do
    %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right}
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/1 — nil / missing parseTrade" do
    test "returns nil when entry is nil" do
      assert Trade.derive(nil) == nil
    end

    test "returns nil when parse_methods does not contain parseTrade" do
      entry = %{"parse_methods" => %{"parseTicker" => %{}}}
      assert Trade.derive(entry) == nil
    end

    test "returns nil for non-map input" do
      assert Trade.derive("not a map") == nil
      assert Trade.derive(42) == nil
      assert Trade.derive([]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical safeTrade return
  # ---------------------------------------------------------------------------

  describe "derive/1 — canonical safeTrade return" do
    test "all 13 unified fields appear as keys in field_map" do
      result = Trade.derive(wrap_entry([safe_trade_return([])]))

      assert result["field_map"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(Trade.unified_fields())

      assert map_size(result["field_map"]) == 13
    end

    test "_unresolved_reason is nil when canonical return found" do
      result = Trade.derive(wrap_entry([safe_trade_return([])]))
      assert result["_unresolved_reason"] == nil
    end

    test "inline safeString populates id slot" do
      props = [prop("id", this_call("safeString", [identifier("trade"), literal("tradeId")]))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["id"]
      assert slot["key"] == "tradeId"
      assert slot["coercion"] == "safeString"
      assert slot["format"] == nil
      assert result["_unresolved_reason"] == nil
    end

    test "inline safeString2 populates price slot via second key arg" do
      props = [prop("price", this_call("safeString2", [identifier("trade"), literal("fillPx"), literal("px")]))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["price"]
      assert slot["key"] == "fillPx"
      assert slot["coercion"] == "safeString2"
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved-return paths
  # ---------------------------------------------------------------------------

  describe "derive/1 — unresolved return shapes" do
    test "non-safeTrade return emits _unresolved_reason with callee name" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("parseSpotTrade", [identifier("trade"), identifier("market")])
      }

      result = Trade.derive(wrap_entry([ret]))

      assert result["_unresolved_reason"] =~ "non_safe_trade_return:parseSpotTrade"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
      assert result["extras"] == []
    end

    test "non-safeTrade safeTrade2 callee emits unresolved" do
      ret = %{
        "type" => "ReturnStatement",
        "argument" => this_call("safeTrade2", [identifier("trade")])
      }

      result = Trade.derive(wrap_entry([ret]))
      assert result["_unresolved_reason"] =~ "non_safe_trade_return:safeTrade2"
    end

    test "no return statement emits no_return_statement" do
      result = Trade.derive(wrap_entry([]))

      assert result["_unresolved_reason"] == "no_return_statement"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end

    test "non-this CallExpression return emits unrecognized_return_shape" do
      # `return Trade.from(x)` — top-level CallExpression but callee isn't `this.<method>`.
      ret = %{
        "type" => "ReturnStatement",
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => identifier("Trade"),
            "property" => identifier("from")
          },
          "arguments" => [identifier("x")]
        }
      }

      result = Trade.derive(wrap_entry([ret]))
      assert result["_unresolved_reason"] == "unrecognized_return_shape"
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-payload branching detection
  # ---------------------------------------------------------------------------

  describe "derive/1 — multi-payload branching" do
    test "top-level if (Array.isArray(trade)) emits multi_payload_branching" do
      array_check = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => identifier("Array"),
          "property" => identifier("isArray")
        },
        "arguments" => [identifier("trade")]
      }

      if_stmt = %{
        "type" => "IfStatement",
        "test" => array_check,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      result = Trade.derive(wrap_entry([if_stmt, safe_trade_return([])]))
      assert result["_unresolved_reason"] =~ ~r/^multi_payload_branching:\d+$/
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end

    test "top-level if ('<lit>' in trade) emits multi_payload_branching (binance dust-trade pattern)" do
      in_test = binexp(literal("isDustTrade"), "in", identifier("trade"))

      if_stmt = %{
        "type" => "IfStatement",
        "test" => in_test,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      result = Trade.derive(wrap_entry([if_stmt, safe_trade_return([])]))
      assert result["_unresolved_reason"] =~ ~r/^multi_payload_branching:\d+$/
    end

    test "top-level if (typeof trade === 'string') emits multi_payload_branching" do
      typeof_test =
        binexp(
          %{"type" => "UnaryExpression", "operator" => "typeof", "argument" => identifier("trade")},
          "===",
          literal("string")
        )

      if_stmt = %{
        "type" => "IfStatement",
        "test" => typeof_test,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      result = Trade.derive(wrap_entry([if_stmt, safe_trade_return([])]))
      assert result["_unresolved_reason"] =~ ~r/^multi_payload_branching:\d+$/
    end

    test "ordinary boolean ifs (not shape-discriminators) do NOT trigger multi-payload" do
      # Pattern: if (liquidity !== undefined) { ... } — a value-check, not a shape-check.
      ordinary_test = binexp(identifier("liquidity"), "!==", identifier("undefined"))

      if_stmt = %{
        "type" => "IfStatement",
        "test" => ordinary_test,
        "consequent" => %{"type" => "BlockStatement", "body" => []},
        "alternate" => nil
      }

      props = [prop("id", this_call("safeString", [identifier("trade"), literal("id")]))]
      result = Trade.derive(wrap_entry([if_stmt, safe_trade_return(props)]))

      assert result["_unresolved_reason"] == nil
      assert result["field_map"]["id"]["key"] == "id"
    end
  end

  # ---------------------------------------------------------------------------
  # Identifier binding lookup
  # ---------------------------------------------------------------------------

  describe "derive/1 — Identifier binding lookup" do
    test "const orderId = this.safeString(...); return { order: orderId } resolves" do
      binding = var_decl("orderId", this_call("safeString", [identifier("trade"), literal("ordId")]))
      props = [prop("order", identifier("orderId"))]
      result = Trade.derive(wrap_entry([binding, safe_trade_return(props)]))

      slot = result["field_map"]["order"]
      assert slot["key"] == "ordId"
      assert slot["coercion"] == "safeString"
    end

    test "unbound Identifier emits nil slot" do
      props = [prop("id", identifier("notDeclared"))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      assert result["field_map"]["id"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp format
  # ---------------------------------------------------------------------------

  describe "derive/1 — timestamp format" do
    test "safeInteger on timestamp emits format: ms" do
      binding = var_decl("timestamp", this_call("safeInteger", [identifier("trade"), literal("ts")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Trade.derive(wrap_entry([binding, safe_trade_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger"
      assert ts["format"] == "ms"
      assert ts["key"] == "ts"
    end

    test "safeInteger2 on timestamp emits format: ms" do
      binding = var_decl("timestamp", this_call("safeInteger2", [identifier("trade"), literal("t"), literal("time")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Trade.derive(wrap_entry([binding, safe_trade_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeInteger2"
      assert ts["format"] == "ms"
    end

    test "safeTimestamp on timestamp emits format: s" do
      binding = var_decl("timestamp", this_call("safeTimestamp", [identifier("trade"), literal("ts")]))
      props = [prop("timestamp", identifier("timestamp"))]
      result = Trade.derive(wrap_entry([binding, safe_trade_return(props)]))

      ts = result["field_map"]["timestamp"]
      assert ts["coercion"] == "safeTimestamp"
      assert ts["format"] == "s"
    end
  end

  # ---------------------------------------------------------------------------
  # Enum fields (type / side / takerOrMaker)
  # ---------------------------------------------------------------------------

  describe "derive/1 — enum fields" do
    test "safeStringLower populates enum slot with coercion safeStringLower" do
      props = [prop("side", this_call("safeStringLower", [identifier("trade"), literal("side")]))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["key"] == "side"
      assert slot["coercion"] == "safeStringLower"
      assert slot["enum_map"] == nil
      assert slot["format"] == nil
    end

    test "safeString(...).toLowerCase() chain canonicalizes to safeStringLower" do
      # Build: this.safeString(trade, "side").toLowerCase()
      to_lower = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => this_call("safeString", [identifier("trade"), literal("side")]),
          "property" => identifier("toLowerCase")
        },
        "arguments" => []
      }

      props = [prop("side", to_lower)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["key"] == "side"
      assert slot["coercion"] == "safeStringLower"
      assert slot["enum_map"] == nil
    end

    test "explicit-ternary enum extracts enum_map (nested ConditionalExpression)" do
      # safeString(trade, 'execType') === 'T' ? 'taker' : (safeString(trade, 'execType') === 'M' ? 'maker' : undefined)
      safe = this_call("safeString", [identifier("trade"), literal("execType")])

      inner_ternary =
        ternary(
          binexp(safe, "===", literal("M")),
          literal("maker"),
          identifier("undefined")
        )

      outer_ternary =
        ternary(
          binexp(safe, "===", literal("T")),
          literal("taker"),
          inner_ternary
        )

      props = [prop("takerOrMaker", outer_ternary)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["takerOrMaker"]
      assert slot["coercion"] == "safeString"
      assert slot["key"] == "execType"
      assert slot["enum_map"] == %{"T" => "taker", "M" => "maker"}
    end

    test "bool-flag enum (isBuyer ? 'buy' : 'sell') emits unresolved_reason: bool_flag_inferred" do
      props = [prop("side", ternary(identifier("isBuyer"), literal("buy"), literal("sell")))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["unresolved_reason"] == "bool_flag_inferred"
      assert slot["coercion"] == nil
      assert slot["key"] == nil
    end

    test "numeric-code enum (someCall === 1 ? 'buy' : 'sell') emits unresolved_reason: numeric_code_inferred" do
      test = binexp(this_call("safeInteger", [identifier("trade"), literal("dir")]), "===", literal(1))
      props = [prop("side", ternary(test, literal("buy"), literal("sell")))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["unresolved_reason"] == "numeric_code_inferred"
      assert slot["coercion"] == nil
    end

    test "char-code enum (trade[3] === 's' ? 'sell' : 'buy') emits unresolved_reason: char_code_inferred" do
      # MemberExpression with computed: true and Literal numeric index
      array_idx = %{
        "type" => "MemberExpression",
        "computed" => true,
        "object" => identifier("trade"),
        "property" => literal(3)
      }

      test = binexp(array_idx, "===", literal("s"))
      props = [prop("side", ternary(test, literal("sell"), literal("buy")))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["unresolved_reason"] == "char_code_inferred"
      assert slot["coercion"] == nil
    end

    test "ternary with non-Literal seed consequent omits seed entry from enum_map" do
      # `safeString(trade,'execType') === 'T' ? someVar : (... === 'M' ? 'maker' : undefined)`
      # Seed consequent is an Identifier (not a string Literal); previously seeded enum_map
      # with `nil`. Fix: skip the seed entry, keep only the resolvable nested branch.
      safe = this_call("safeString", [identifier("trade"), literal("execType")])

      inner_ternary =
        ternary(
          binexp(safe, "===", literal("M")),
          literal("maker"),
          identifier("undefined")
        )

      outer_ternary =
        ternary(
          binexp(safe, "===", literal("T")),
          identifier("someVar"),
          inner_ternary
        )

      props = [prop("takerOrMaker", outer_ternary)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["takerOrMaker"]
      # The "T" branch is non-Literal — dropped. The "M" → "maker" branch resolves.
      assert slot["enum_map"] == %{"M" => "maker"}
      refute Map.has_key?(slot["enum_map"], "T")
    end

    test "enum ternary where discriminator is an Identifier bound to a safe-call resolves" do
      # const side = this.safeString(trade, 'side');
      # return { side: side === 'BUY' ? 'buy' : (side === 'SELL' ? 'sell' : undefined) }
      # Exercises resolve_to_safe_call/2 Identifier-binding clause.
      binding = var_decl("side", this_call("safeString", [identifier("trade"), literal("side")]))

      inner_ternary =
        ternary(
          binexp(identifier("side"), "===", literal("SELL")),
          literal("sell"),
          identifier("undefined")
        )

      outer_ternary =
        ternary(
          binexp(identifier("side"), "===", literal("BUY")),
          literal("buy"),
          inner_ternary
        )

      props = [prop("side", outer_ternary)]
      result = Trade.derive(wrap_entry([binding, safe_trade_return(props)]))

      slot = result["field_map"]["side"]
      assert slot["coercion"] == "safeString"
      assert slot["key"] == "side"
      assert slot["enum_map"] == %{"BUY" => "buy", "SELL" => "sell"}
    end

    test "plain safeString on enum field emits enum slot with enum_map: nil" do
      props = [prop("type", this_call("safeString", [identifier("trade"), literal("ordType")]))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      slot = result["field_map"]["type"]
      assert slot["coercion"] == "safeString"
      assert slot["key"] == "ordType"
      assert slot["enum_map"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Nested fee field
  # ---------------------------------------------------------------------------

  describe "derive/1 — nested fee field" do
    test "inline fee ObjectExpression populates sub_field_map (cost + currency)" do
      fee_obj = %{
        "type" => "ObjectExpression",
        "properties" => [
          prop("cost", this_call("safeString", [identifier("trade"), literal("fee")])),
          prop("currency", this_call("safeCurrencyCode", [identifier("feeCurrencyId")]))
        ]
      }

      props = [prop("fee", fee_obj)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      fee = result["field_map"]["fee"]
      assert is_map(fee["sub_field_map"])
      assert fee["sub_field_map"]["cost"]["coercion"] == "safeString"
      assert fee["sub_field_map"]["cost"]["key"] == "fee"
      assert fee["sub_field_map"]["currency"]["coercion"] == "safeCurrencyCode"
      assert fee["sub_field_map"]["rate"] == nil
    end

    test "fee with rate sub-property populates rate slot" do
      fee_obj = %{
        "type" => "ObjectExpression",
        "properties" => [
          prop("cost", this_call("safeString", [identifier("trade"), literal("fee")])),
          prop("currency", this_call("safeCurrencyCode", [identifier("feeCcy")])),
          prop("rate", this_call("safeNumber", [identifier("trade"), literal("feeRate")]))
        ]
      }

      props = [prop("fee", fee_obj)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      fee = result["field_map"]["fee"]
      assert fee["sub_field_map"]["rate"]["coercion"] == "safeNumber"
      assert fee["sub_field_map"]["rate"]["key"] == "feeRate"
    end

    test "fee Identifier resolved via binding populates sub_field_map" do
      fee_obj = %{
        "type" => "ObjectExpression",
        "properties" => [
          prop("cost", this_call("safeString", [identifier("trade"), literal("fee")])),
          prop("currency", this_call("safeCurrencyCode", [identifier("feeCcy")]))
        ]
      }

      binding = var_decl("fee", fee_obj)
      props = [prop("fee", identifier("fee"))]
      result = Trade.derive(wrap_entry([binding, safe_trade_return(props)]))

      fee = result["field_map"]["fee"]
      assert is_map(fee["sub_field_map"])
      assert fee["sub_field_map"]["currency"]["coercion"] == "safeCurrencyCode"
    end

    test "fee non-ObjectExpression literal emits sub_field_map: nil, unresolved_reason: fee_not_object_literal" do
      # `'fee': fee` where fee is bound to a CallExpression (not an ObjectExpression)
      binding = var_decl("fee", this_call("safeFee", [identifier("trade")]))
      props = [prop("fee", identifier("fee"))]
      result = Trade.derive(wrap_entry([binding, safe_trade_return(props)]))

      fee = result["field_map"]["fee"]
      assert fee["sub_field_map"] == nil
      assert fee["unresolved_reason"] == "fee_not_object_literal"
    end

    test "fee inline Identifier (unbound) emits unresolved" do
      props = [prop("fee", identifier("undeclaredFee"))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      fee = result["field_map"]["fee"]
      assert fee["sub_field_map"] == nil
      assert fee["unresolved_reason"] == "fee_not_object_literal"
    end

    test "safeCurrencyCode with nested CallExpression arg resolves wire key" do
      # `safeCurrencyCode(this.safeString(trade, 'feeCcy'))` — binance/bitget/kraken shape
      nested_safe = this_call("safeString", [identifier("trade"), literal("feeCcy")])

      fee_obj = %{
        "type" => "ObjectExpression",
        "properties" => [
          prop("cost", this_call("safeString", [identifier("trade"), literal("fee")])),
          prop("currency", this_call("safeCurrencyCode", [nested_safe]))
        ]
      }

      props = [prop("fee", fee_obj)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      currency = result["field_map"]["fee"]["sub_field_map"]["currency"]
      assert currency["coercion"] == "safeCurrencyCode"
      assert currency["key"] == "feeCcy"
    end

    test "safeCurrencyCode with Identifier → Identifier → safe-call chain resolves wire key" do
      # Two-hop binding: const a = const b = this.safeString(trade, 'commissionAsset')
      inner_binding = var_decl("b", this_call("safeString", [identifier("trade"), literal("commissionAsset")]))
      outer_binding = var_decl("a", identifier("b"))

      fee_obj = %{
        "type" => "ObjectExpression",
        "properties" => [
          prop("cost", this_call("safeString", [identifier("trade"), literal("commission")])),
          prop("currency", this_call("safeCurrencyCode", [identifier("a")]))
        ]
      }

      props = [prop("fee", fee_obj)]
      result = Trade.derive(wrap_entry([inner_binding, outer_binding, safe_trade_return(props)]))

      currency = result["field_map"]["fee"]["sub_field_map"]["currency"]
      assert currency["key"] == "commissionAsset"
    end

    test "safeCurrencyCode with cyclic Identifier binding does not loop" do
      # `const a = b; const b = a;` — cycle. Should emit key: nil, not hang.
      a_binding = var_decl("a", identifier("b"))
      b_binding = var_decl("b", identifier("a"))

      fee_obj = %{
        "type" => "ObjectExpression",
        "properties" => [
          prop("currency", this_call("safeCurrencyCode", [identifier("a")]))
        ]
      }

      props = [prop("fee", fee_obj)]
      result = Trade.derive(wrap_entry([a_binding, b_binding, safe_trade_return(props)]))

      currency = result["field_map"]["fee"]["sub_field_map"]["currency"]
      assert currency["coercion"] == "safeCurrencyCode"
      assert currency["key"] == nil
    end

    test "fee sub-property with non-vocab coercion emits nil for that sub-slot" do
      fee_obj = %{
        "type" => "ObjectExpression",
        "properties" => [
          # Precise.stringNeg is outside the closed vocab
          prop("cost", %{
            "type" => "CallExpression",
            "callee" => %{
              "type" => "MemberExpression",
              "object" => identifier("Precise"),
              "property" => identifier("stringNeg")
            },
            "arguments" => [identifier("x")]
          }),
          prop("currency", this_call("safeCurrencyCode", [identifier("feeCcy")]))
        ]
      }

      props = [prop("fee", fee_obj)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      fee = result["field_map"]["fee"]
      assert fee["sub_field_map"]["cost"] == nil
      assert fee["sub_field_map"]["currency"]["coercion"] == "safeCurrencyCode"
    end
  end

  # ---------------------------------------------------------------------------
  # Structurally-null fields
  # ---------------------------------------------------------------------------

  describe "derive/1 — structurally-null fields" do
    test "info (Identifier 'trade' pass-through) emits nil slot" do
      props = [prop("info", identifier("trade"))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      assert result["field_map"]["info"] == nil
    end

    test "datetime (this.iso8601(timestamp) derivation) emits nil slot" do
      props = [prop("datetime", this_call("iso8601", [identifier("timestamp")]))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      assert result["field_map"]["datetime"] == nil
    end

    test "symbol (market['symbol'] member access) emits nil slot" do
      member = %{
        "type" => "MemberExpression",
        "object" => identifier("market"),
        "property" => literal("symbol"),
        "computed" => true
      }

      props = [prop("symbol", member)]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      assert result["field_map"]["symbol"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Extras list
  # ---------------------------------------------------------------------------

  describe "derive/1 — extras list" do
    test "property not in unified fields appears in extras" do
      extra_prop = prop("liquidity", this_call("safeString", [identifier("trade"), literal("liquidity")]))
      result = Trade.derive(wrap_entry([safe_trade_return([extra_prop])]))

      assert [entry] = result["extras"]
      assert entry["unified_key"] == "liquidity"
      assert entry["key"] == "liquidity"
      assert entry["coercion"] == "safeString"
    end

    test "extras is empty when all props are in unified fields" do
      props = [prop("id", this_call("safeString", [identifier("trade"), literal("tradeId")]))]
      result = Trade.derive(wrap_entry([safe_trade_return(props)]))

      assert result["extras"] == []
    end

    test "extra with non-vocab coercion is NOT included in extras" do
      extra_prop = prop("liquidity", this_call("getLiquidity", [identifier("trade")]))
      result = Trade.derive(wrap_entry([safe_trade_return([extra_prop])]))

      assert result["extras"] == []
    end

    test "computed property key is skipped from both field_map and extras" do
      computed_prop = %{
        "computed" => true,
        "key" => identifier("dynamicKey"),
        "value" => this_call("safeString", [identifier("trade"), literal("k")])
      }

      result = Trade.derive(wrap_entry([safe_trade_return([computed_prop])]))

      assert result["extras"] == []
      assert map_size(result["field_map"]) == 13
      assert result["field_map"] |> Map.values() |> Enum.all?(&is_nil/1)
    end
  end
end
