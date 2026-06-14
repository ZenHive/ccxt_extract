defmodule CcxtExtract.Normalization.OHLCVTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.OHLCV` — the Task 78 derivation
  that populates `field_maps["ohlcv"]` from a per-exchange `parse_methods.json`
  entry.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.OHLCV

  # --- AST builder helpers ---

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

  defp this_call(method, args) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => this_expression(),
        "property" => identifier(method)
      },
      "arguments" => args
    }
  end

  defp safe_call(method, args), do: this_call(method, args)

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

  defp conditional(test, cons, alt) do
    %{
      "type" => "ConditionalExpression",
      "test" => test,
      "consequent" => cons,
      "alternate" => alt
    }
  end

  defp paren(expr), do: %{"type" => "ParenthesizedExpression", "expression" => expr}

  defp member(object, property) do
    %{
      "type" => "MemberExpression",
      "object" => object,
      "property" => property,
      "computed" => true
    }
  end

  defp return_stmt(arg), do: %{"type" => "ReturnStatement", "argument" => arg}

  defp array_expr(elements), do: %{"type" => "ArrayExpression", "elements" => elements}

  defp wrap_entry(stmts) do
    %{
      "parse_methods" => %{
        "parseOHLCV" => %{
          "async" => false,
          "params" => [],
          "return_type" => nil,
          "statements" => length(stmts),
          "body" => %{"type" => "BlockStatement", "body" => stmts}
        }
      }
    }
  end

  # --- 1. nil entry ---

  test "derive(nil) returns nil" do
    assert OHLCV.derive(nil) == nil
  end

  # --- 2. no parseOHLCV ---

  test "entry without parseOHLCV returns nil" do
    entry = %{"parse_methods" => %{"parseTicker" => %{}}}
    assert OHLCV.derive(entry) == nil
  end

  # --- 3. pure array, safeInteger / safeNumber, idx 0..5 ---

  test "pure array with safeInteger timestamp + safeNumber OHLCV populates fully" do
    elements =
      Enum.map(0..5, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    entry = wrap_entry([return_stmt(array_expr(elements))])
    result = OHLCV.derive(entry)

    assert %{"branches" => [branch], "extras" => [], "_unresolved_reason" => nil} = result
    # Task 78b: guard now carries `input_shape` reflecting the locator family
    # of the populated pure slots. Integer-keyed slots → `"array"`.
    assert branch["guard"] == %{"kind" => "always", "input_shape" => "array"}
    assert branch["shape"] == "array"
    assert branch["_unresolved_reason"] == nil

    fm = branch["field_map"]

    assert fm["timestamp"] == %{
             "index" => 0,
             "key" => nil,
             "coercion" => "safeInteger",
             "format" => "ms"
           }

    for {field, idx} <- Enum.with_index(~w(open high low close volume), 1) do
      assert fm[field] == %{
               "index" => idx,
               "key" => nil,
               "coercion" => "safeNumber",
               "format" => nil
             }
    end
  end

  # --- 4. safeInteger2 / safeNumber2 (binance family) ---

  test "safeInteger2 timestamp + safeNumber2 OHLC are recognized" do
    elements =
      Enum.map(0..5, fn idx ->
        method = if idx == 0, do: "safeInteger2", else: "safeNumber2"
        safe_call(method, [identifier("ohlcv"), literal(idx), literal("name#{idx}")])
      end)

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger2"
    assert branch["field_map"]["timestamp"]["format"] == "ms"
    assert branch["field_map"]["volume"]["coercion"] == "safeNumber2"
  end

  # --- 5. scrambled column order (bitfinex shape) ---

  test "scrambled return-array indices map by output position, not input index" do
    # Output order is timestamp, open, high, low, close, volume.
    # Input indices are 0, 1, 3, 4, 2, 5 — bitfinex's order.
    indices = [0, 1, 3, 4, 2, 5]

    elements =
      Enum.map(indices, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)
    fm = branch["field_map"]

    assert fm["open"]["index"] == 1
    assert fm["high"]["index"] == 3
    assert fm["low"]["index"] == 4
    assert fm["close"]["index"] == 2
    assert fm["volume"]["index"] == 5
  end

  # --- 6. discriminated volume via inverse Identifier (binance/bitget pattern) ---

  test "discriminated volume resolves through chained `inverse = safeBool(market, 'inverse')`" do
    inverse_decl =
      var_decl(
        "inverse",
        this_call("safeBool", [identifier("market"), literal("inverse")])
      )

    volume_index_decl =
      var_decl(
        "volumeIndex",
        conditional(identifier("inverse"), literal(7), literal(5))
      )

    elements = [
      safe_call("safeInteger2", [identifier("ohlcv"), literal(0), literal("openTime")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal(1), literal("open")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal(2), literal("high")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal(3), literal("low")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal(4), literal("close")]),
      safe_call("safeNumber2", [identifier("ohlcv"), identifier("volumeIndex"), literal("volume")])
    ]

    entry = wrap_entry([inverse_decl, volume_index_decl, return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["_unresolved_reason"] == nil

    assert branch["field_map"]["volume"] == %{
             "kind" => "discriminated",
             "discriminator" => "market.inverse",
             "true" => %{"index" => 7, "coercion" => "safeNumber2"},
             "false" => %{"index" => 5, "coercion" => "safeNumber2"}
           }
  end

  # --- 7. discriminated volume via direct (market['inverse']) with paren wrapper (bybit) ---

  test "discriminated volume resolves through `(market['inverse']) ? 6 : 5`" do
    test_expr = paren(member(identifier("market"), literal("inverse")))

    volume_index_decl =
      var_decl("volumeIndex", conditional(test_expr, literal(6), literal(5)))

    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++
        [safe_call("safeNumber", [identifier("ohlcv"), identifier("volumeIndex")])]

    entry = wrap_entry([volume_index_decl, return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"]["kind"] == "discriminated"
    assert branch["field_map"]["volume"]["true"]["index"] == 6
    assert branch["field_map"]["volume"]["false"]["index"] == 5
  end

  # --- 7b. market.spot discriminator (okx-style `type === 'spot'`) — volume now populated ---

  test "discriminated volume via market.spot (okx `(type === 'spot') ? 5 : 6`)" do
    test_expr =
      paren(%{
        "type" => "BinaryExpression",
        "operator" => "===",
        "left" => identifier("type"),
        "right" => literal("spot")
      })

    volume_index_decl =
      var_decl("volumeIndex", conditional(test_expr, literal(5), literal(6)))

    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++
        [safe_call("safeNumber", [identifier("ohlcv"), identifier("volumeIndex")])]

    entry = wrap_entry([volume_index_decl, return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    volume_slot = branch["field_map"]["volume"]
    assert volume_slot["kind"] == "discriminated"
    assert volume_slot["discriminator"] == "market.spot"
    assert volume_slot["true"]["index"] == 5
    assert volume_slot["false"]["index"] == 6
    assert branch["_unresolved_reason"] == nil
    # All slots populate
    assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger"
    assert branch["field_map"]["close"]["index"] == 4
  end

  # --- 8. fewer than 6 elements → missing positions emit null + reason ---

  test "return array of length 5 leaves volume slot null with reason" do
    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["close"]["index"] == 4
    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "missing_from_return_array"
  end

  # --- 9. unknown call on volume slot → null slot + reason on that slot ---

  test "non-safe call on volume slot leaves it null with closed-vocab reason" do
    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++
        [this_call("weirdHelper", [identifier("ohlcv"), literal(5)])]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "non_safe_coercion:weirdHelper"
    # Other slots populate normally
    assert branch["field_map"]["open"]["index"] == 1
    assert branch["field_map"]["close"]["index"] == 4
  end

  # --- 10. multiple distinct return arrays → ambiguous ---

  # --- 11. parseOHLCV body with no ReturnStatement → no_return_array ---

  test "parseOHLCV with no ReturnStatement → no_return_array" do
    # Empty body — degenerate, but lock the contract
    entry = wrap_entry([])
    result = OHLCV.derive(entry)
    assert result["branches"] == []
    assert result["_unresolved_reason"] == "no_return_array"
  end

  # --- 12. timestamp slot uses safeNumber (wrong coercion family) ---

  test "timestamp slot using safeNumber → null + reason" do
    elements =
      Enum.map(0..5, fn idx ->
        # First slot uses safeNumber where safeInteger is required
        safe_call("safeNumber", [identifier("ohlcv"), literal(idx)])
      end)

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["timestamp"] == nil
    assert branch["_unresolved_reason"] =~ "timestamp_uses_number_coercion"
  end

  # --- 13. timestamp slot is a non-CallExpression literal ---

  test "timestamp slot is non-CallExpression → null + non_call_element" do
    elements = [literal(123_456_789) | for(idx <- 1..5, do: safe_call("safeNumber", [identifier("ohlcv"), literal(idx)]))]
    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["timestamp"] == nil
    assert branch["_unresolved_reason"] =~ "timestamp:non_call_element"
  end

  # --- 14. OHLC slot uses safeInteger (wrong family) ---

  test "OHLC slot using safeInteger → null + reason" do
    # idx 1 ('open') uses safeInteger where safeNumber is required
    elements = [
      safe_call("safeInteger", [identifier("ohlcv"), literal(0)]),
      safe_call("safeInteger", [identifier("ohlcv"), literal(1)])
      | for(idx <- 2..5, do: safe_call("safeNumber", [identifier("ohlcv"), literal(idx)]))
    ]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["open"] == nil
    assert branch["_unresolved_reason"] =~ "ohlc_uses_integer_coercion"
  end

  # --- 15. OHLC slot non-CallExpression + non-safe call ---

  test "OHLC slot non-CallExpression and non-safe call surface distinct reasons" do
    elements = [
      safe_call("safeInteger", [identifier("ohlcv"), literal(0)]),
      literal(0),
      this_call("weirdHelper", [identifier("ohlcv"), literal(2)]),
      safe_call("safeNumber", [identifier("ohlcv"), literal(3)]),
      safe_call("safeNumber", [identifier("ohlcv"), literal(4)]),
      safe_call("safeNumber", [identifier("ohlcv"), literal(5)])
    ]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["open"] == nil
    assert branch["field_map"]["high"] == nil
    assert branch["_unresolved_reason"] =~ "open:non_call_element"
    assert branch["_unresolved_reason"] =~ "high:non_safe_coercion:weirdHelper"
  end

  # --- 16. volume slot uses safeInteger (wrong family) ---

  test "volume slot using safeInteger → null + reason" do
    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++ [safe_call("safeInteger", [identifier("ohlcv"), literal(5)])]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "volume_uses_integer_coercion"
  end

  # --- 17. volumeIndex Identifier is unbound ---

  test "volumeIndex Identifier with no binding → volume_index_unbound" do
    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++ [safe_call("safeNumber", [identifier("ohlcv"), identifier("nowhereDefined")])]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "volume_index_unbound:nowhereDefined"
  end

  # --- 18. volumeIndex bound to non-Conditional → volume_index_non_conditional ---

  test "volumeIndex bound to a literal → volume_index_non_conditional" do
    volume_index_decl = var_decl("volumeIndex", literal(5))

    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++ [safe_call("safeNumber", [identifier("ohlcv"), identifier("volumeIndex")])]

    entry = wrap_entry([volume_index_decl, return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "volume_index_non_conditional"
  end

  # --- 19. unsupported discriminator test (Identifier chain that does not resolve to inverse/spot shape) ---

  test "discriminator chain dead-ends at unbound Identifier → unsupported_discriminator" do
    # volumeIndex = ghostFlag ? 7 : 5, but ghostFlag is never declared.
    # The test ident does not resolve to a recognized inverse/spot shape.
    volume_index_decl =
      var_decl(
        "volumeIndex",
        conditional(identifier("ghostFlag"), literal(7), literal(5))
      )

    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++ [safe_call("safeNumber", [identifier("ohlcv"), identifier("volumeIndex")])]

    entry = wrap_entry([volume_index_decl, return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "unsupported_discriminator"
  end

  # --- 20. derive/1 with a non-map, non-nil fallthrough ---

  test "derive/1 on a non-map, non-nil value returns nil" do
    assert OHLCV.derive(42) == nil
    assert OHLCV.derive("string") == nil
  end

  # --- multiple-return ambiguity ---

  test "multiple ReturnStatements with array literals → ambiguous_return_shape" do
    elements_a =
      Enum.map(0..5, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    elements_b =
      Enum.map(10..15, fn idx ->
        method = if idx == 10, do: "safeInteger2", else: "safeNumber2"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    if_stmt = %{
      "type" => "IfStatement",
      "test" => identifier("x"),
      "consequent" => %{"type" => "BlockStatement", "body" => [return_stmt(array_expr(elements_a))]},
      "alternate" => %{"type" => "BlockStatement", "body" => [return_stmt(array_expr(elements_b))]}
    }

    entry = wrap_entry([if_stmt])
    result = OHLCV.derive(entry)

    assert result["branches"] == []
    assert result["_unresolved_reason"] == "ambiguous_return_shape"
  end

  # --- 22. cyclic Identifier binding chain → terminates without infinite loop ---

  test "cyclic identifier binding chain terminates without hanging" do
    # Synthetic AST cycle: `a` binds to identifier `b`, `b` binds to identifier
    # `a`. `volumeIndex = a ? 7 : 5` would chain `a -> b -> a -> infinity`
    # without the visited-set guard in discriminator_for_test/3. Real JS const
    # semantics forbid this, but the AST representation could carry it
    # (codegen, future fixtures, macro-synthesized parse_methods entries).
    decl_a = var_decl("a", identifier("b"))
    decl_b = var_decl("b", identifier("a"))

    volume_index_decl =
      var_decl("volumeIndex", conditional(identifier("a"), literal(7), literal(5)))

    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++
        [safe_call("safeNumber", [identifier("ohlcv"), identifier("volumeIndex")])]

    entry = wrap_entry([decl_a, decl_b, volume_index_decl, return_stmt(array_expr(elements))])

    # Must terminate (not hang). Cycle dead-ends -> unsupported_discriminator.
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "unsupported_discriminator"
  end

  # --- 23. non-Array.isArray hybrid → still ambiguous ---

  test "non-Array.isArray hybrid `if (safeBool) return [...]; return {...}` → ambiguous_return_shape" do
    # Only the Array.isArray discriminator is handled (Task 78c). Other
    # shape tests (safeBool, typeof, etc.) still classify as ambiguous.
    array_elements =
      Enum.map(0..5, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    object_return =
      return_stmt(%{
        "type" => "ObjectExpression",
        "properties" => [
          %{
            "type" => "Property",
            "key" => %{"type" => "Identifier", "name" => "timestamp"},
            "value" => safe_call("safeInteger", [identifier("ohlcv"), literal("t")])
          }
        ]
      })

    if_stmt = %{
      "type" => "IfStatement",
      "test" => this_call("safeBool", [identifier("ohlcv"), literal("isArray")]),
      "consequent" => %{"type" => "BlockStatement", "body" => [return_stmt(array_expr(array_elements))]},
      "alternate" => nil
    }

    entry = wrap_entry([if_stmt, object_return])
    result = OHLCV.derive(entry)

    assert result["branches"] == []
    assert result["_unresolved_reason"] == "ambiguous_return_shape"
  end

  # --- 23b. Task 78c: Array.isArray if/else hybrid → two guarded branches + discriminator ---

  test "Array.isArray if/else with array returns on both arms → array_input + object_input branches" do
    array_elements =
      Enum.map(0..5, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    object_elements = [
      safe_call("safeInteger", [identifier("ohlcv"), literal("t")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("o")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("h")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("l")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("c")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("v")])
    ]

    is_array_test =
      %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => %{"type" => "Identifier", "name" => "Array"},
          "property" => %{"type" => "Identifier", "name" => "isArray"}
        },
        "arguments" => [identifier("ohlcv")]
      }

    if_stmt = %{
      "type" => "IfStatement",
      "test" => is_array_test,
      "consequent" => %{"type" => "BlockStatement", "body" => [return_stmt(array_expr(array_elements))]},
      "alternate" => %{"type" => "BlockStatement", "body" => [return_stmt(array_expr(object_elements))]}
    }

    entry = wrap_entry([if_stmt])
    result = OHLCV.derive(entry)

    assert result["_unresolved_reason"] == nil

    assert result["discriminator"] == %{
             "call" => "Array.isArray",
             "variable" => "ohlcv"
           }

    assert [array_branch, object_branch] = result["branches"]
    assert array_branch["guard"] == %{"kind" => "array_input"}
    assert object_branch["guard"] == %{"kind" => "object_input"}
    assert array_branch["field_map"]["timestamp"]["index"] == 0
    assert array_branch["field_map"]["timestamp"]["key"] == nil
    assert object_branch["field_map"]["timestamp"]["key"] == "t"
    assert object_branch["field_map"]["timestamp"]["index"] == nil
    assert object_branch["field_map"]["volume"]["key"] == "v"
  end

  # --- 23c. Task 78c: bingx-style if + fallthrough return ---

  test "Array.isArray if with fallthrough return → array_input + object_input branches" do
    array_elements =
      Enum.map(0..5, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    object_elements = [
      safe_call("safeInteger", [identifier("ohlcv"), literal("time")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("open")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("high")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("low")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("close")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("volume")])
    ]

    is_array_test =
      %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => %{"type" => "Identifier", "name" => "Array"},
          "property" => %{"type" => "Identifier", "name" => "isArray"}
        },
        "arguments" => [identifier("ohlcv")]
      }

    if_stmt = %{
      "type" => "IfStatement",
      "test" => is_array_test,
      "consequent" => %{"type" => "BlockStatement", "body" => [return_stmt(array_expr(array_elements))]},
      "alternate" => nil
    }

    entry = wrap_entry([if_stmt, return_stmt(array_expr(object_elements))])
    result = OHLCV.derive(entry)

    assert result["discriminator"]["variable"] == "ohlcv"
    assert [array_branch, object_branch] = result["branches"]
    assert array_branch["guard"]["kind"] == "array_input"
    assert object_branch["guard"]["kind"] == "object_input"
    assert object_branch["field_map"]["open"]["key"] == "open"
  end

  # --- 23d. Task 78c verified no-op: binance corpus has no hybrid branch ---

  test "binance parseOHLCV in linked corpus stays single always branch (verified no-op)" do
    data = Jason.decode!(File.read!("priv/discoveries/parse_methods.json"))
    entry = Enum.find(data["exchanges"], &(&1["id"] == "binance"))

    result = OHLCV.derive(entry)

    assert is_map(result)
    refute Map.has_key?(result, "discriminator")
    assert [branch] = result["branches"]
    assert branch["guard"]["kind"] == "always"
    assert branch["guard"]["input_shape"] == "array"
    assert branch["field_map"]["volume"]["discriminator"] == "market.inverse"
  end

  # --- 24. nested function/arrow with its own array return must not pollute ---

  test "nested ArrowFunctionExpression with array return is not counted as parseOHLCV's return" do
    # CodeRabbit major finding: if collect_returns descended into nested
    # function bodies, an inline callback like `arr.map((x) => [x, x])` would
    # add bogus array returns and flip a clean single-return body to
    # ambiguous. The collector stops at function-body boundaries.
    pure_elements =
      Enum.map(0..5, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end)

    nested_arrow = %{
      "type" => "ArrowFunctionExpression",
      "params" => [identifier("x")],
      "body" => %{
        "type" => "BlockStatement",
        "body" => [return_stmt(array_expr([identifier("x"), identifier("x")]))]
      },
      "async" => false
    }

    # `const _noise = [].map((x) => [x, x]);` lives in the body, but its
    # array-returning arrow body must be invisible to walk_return_array.
    noise_decl =
      var_decl(
        "_noise",
        this_call("map", [%{"type" => "ArrayExpression", "elements" => []}, nested_arrow])
      )

    entry = wrap_entry([noise_decl, return_stmt(array_expr(pure_elements))])

    %{"branches" => [branch]} = OHLCV.derive(entry)

    # Single legitimate return survives the nested-fn noise → fully populated.
    assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger"
    assert branch["field_map"]["volume"]["index"] == 5
    assert branch["_unresolved_reason"] == nil
  end

  # --- 25. > 6-element return → fail-closed instead of misassigning ---

  test "seven-element return array fails closed with extras_not_supported reason" do
    # CodeRabbit major finding: kraken's `[ts, o, h, l, c, vwap, volume]`
    # would silently land VWAP in the volume slot under the old Enum.take(6)
    # code. Honesty rule: bail out, leave every slot null, surface the cause.
    elements =
      [safe_call("safeInteger", [identifier("ohlcv"), literal(0)])] ++
        Enum.map(1..6, fn idx ->
          safe_call("safeNumber", [identifier("ohlcv"), literal(idx)])
        end)

    entry = wrap_entry([return_stmt(array_expr(elements))])

    %{"branches" => [branch]} = OHLCV.derive(entry)

    for field <- ~w(timestamp open high low close volume) do
      assert branch["field_map"][field] == nil, "#{field} must be nil under fail-closed"
    end

    assert branch["_unresolved_reason"] == "extras_not_supported:7_elements"
  end

  # --- 26. single non-array return → distinct reason from "no return at all" ---

  test "single ReturnStatement that's not an ArrayExpression → non_array_return" do
    # Surfaces the new :non_array branch in walk_return_array. Distinct from
    # `no_return_array` (no returns) because the parser DID return something —
    # we just can't slot-map an object/literal/identifier shape under this scope.
    object_return =
      return_stmt(%{
        "type" => "ObjectExpression",
        "properties" => []
      })

    entry = wrap_entry([object_return])
    result = OHLCV.derive(entry)

    assert result["branches"] == []
    assert result["_unresolved_reason"] == "non_array_return"
  end

  # --- 27. in-vocab method with non-literal index → non_literal_index, not non_safe_coercion ---

  test "OHLC slot using safeNumber with a non-literal index emits non_literal_index reason" do
    # Copilot finding: `non_safe_coercion:<m>` was misleading when `<m>` IS
    # in vocab but the index is e.g. a binary expression. Distinct reason
    # `non_literal_index:<m>` lets consumers dispatch correctly.
    timestamp_call = safe_call("safeInteger", [identifier("ohlcv"), literal(0)])

    # close (idx 4) uses safeNumber but index is `i + 1` — a BinaryExpression.
    weird_index = %{
      "type" => "BinaryExpression",
      "operator" => "+",
      "left" => identifier("i"),
      "right" => literal(1)
    }

    close_call = safe_call("safeNumber", [identifier("ohlcv"), weird_index])

    other_calls =
      Enum.map([1, 2, 3], fn idx ->
        safe_call("safeNumber", [identifier("ohlcv"), literal(idx)])
      end)

    volume_call = safe_call("safeNumber", [identifier("ohlcv"), literal(5)])

    elements = [timestamp_call] ++ other_calls ++ [close_call, volume_call]

    entry = wrap_entry([return_stmt(array_expr(elements))])

    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["close"] == nil
    assert branch["_unresolved_reason"] =~ "close:non_literal_index:safeNumber"
    refute branch["_unresolved_reason"] =~ "non_safe_coercion"
  end

  # --- 28. Task 78b: object-input vanilla (hyperliquid/lighter shape) ---

  test "object-input safeInteger/safeNumber with string-literal keys → input_shape: object, every slot has key" do
    elements = [
      safe_call("safeInteger", [identifier("ohlcv"), literal("t")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("o")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("h")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("l")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("c")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("v")])
    ]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["guard"] == %{"kind" => "always", "input_shape" => "object"}
    assert branch["_unresolved_reason"] == nil

    assert branch["field_map"]["timestamp"] == %{
             "index" => nil,
             "key" => "t",
             "coercion" => "safeInteger",
             "format" => "ms"
           }

    for {field, key} <- Enum.zip(~w(open high low close volume), ~w(o h l c v)) do
      assert branch["field_map"][field] == %{
               "index" => nil,
               "key" => key,
               "coercion" => "safeNumber",
               "format" => nil
             }
    end
  end

  # --- 29. Task 78b: object-input safeInteger2/safeNumber2 ---

  test "object-input safeInteger2/safeNumber2 with string-literal keys are recognized" do
    # Mirrors test 4 (binance-family integer-key safeInteger2/safeNumber2) but
    # with string keys — exercises the `is_binary(value)` arm of
    # build_locator_slot/3 for the *2 vocab.
    elements = [
      safe_call("safeInteger2", [identifier("ohlcv"), literal("ts"), literal("timestamp")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal("o"), literal("open")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal("h"), literal("high")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal("l"), literal("low")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal("c"), literal("close")]),
      safe_call("safeNumber2", [identifier("ohlcv"), literal("v"), literal("volume")])
    ]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["guard"] == %{"kind" => "always", "input_shape" => "object"}
    assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger2"
    assert branch["field_map"]["timestamp"]["key"] == "ts"
    assert branch["field_map"]["timestamp"]["index"] == nil
    assert branch["field_map"]["volume"]["coercion"] == "safeNumber2"
    assert branch["field_map"]["volume"]["key"] == "v"
  end

  # --- 30. Task 78b: bitmex bare-Identifier volume bound to convertFromRawQuantity ---

  test "bare-Identifier volume bound to this.convertFromRawQuantity → null + non_safe_coercion reason" do
    # bitmex shape: top-level `const volume = this.convertFromRawQuantity(...)`
    # then `volume` appears bare at index 5 of the return array. The init's
    # callee is outside the closed safe-call vocab → honest-null with the
    # callee surfaced. The other 5 slots populate (string-keyed).
    volume_decl =
      var_decl(
        "volume",
        this_call("convertFromRawQuantity", [
          member(identifier("market"), literal("symbol")),
          safe_call("safeString", [identifier("ohlcv"), literal("volume")])
        ])
      )

    elements = [
      this_call("parse8601", [safe_call("safeString", [identifier("ohlcv"), literal("timestamp")])]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("open")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("high")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("low")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("close")]),
      identifier("volume")
    ]

    entry = wrap_entry([volume_decl, return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "volume:non_safe_coercion:convertFromRawQuantity"

    # Other 5 slots populate, all string-keyed → input_shape inferred from
    # the populated pure slots. timestamp is parse8601 (Task 78e); OHLC are
    # safeNumber.
    assert branch["field_map"]["timestamp"]["key"] == "timestamp"
    assert branch["field_map"]["timestamp"]["coercion"] == "parse8601"
    assert branch["field_map"]["timestamp"]["format"] == "iso8601"
    assert branch["field_map"]["open"]["key"] == "open"
    assert branch["field_map"]["close"]["key"] == "close"
    assert branch["guard"]["input_shape"] == "object"
  end

  # --- 31. Task 78b: bare-Identifier volume bound to a non-CallExpression init ---

  test "bare-Identifier volume bound to a non-call init → non_call_init reason" do
    # `const x = ohlcv['v']` — init is a MemberExpression, not a CallExpression.
    # classify_volume_identifier/2 falls through to the catch-all `_other` arm
    # and emits non_call_init.
    x_decl = var_decl("x", member(identifier("ohlcv"), literal("v")))

    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++ [identifier("x")]

    entry = wrap_entry([x_decl, return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "volume:non_call_init"
  end

  # --- 32. Task 78b: bare-Identifier volume with no binding ---

  test "bare-Identifier volume with no binding → volume_index_unbound" do
    # No top-level `const phantomVolume = ...` declaration in the body.
    # classify_volume_identifier/2's `nil` arm reuses the existing
    # volume_index_unbound:NAME reason (same string as the Identifier-as-idx_arg
    # path in test 17 — caller can't disambiguate the two unbound shapes
    # without re-walking the AST, which is fine: both are honestly null).
    elements =
      Enum.map(0..4, fn idx ->
        method = if idx == 0, do: "safeInteger", else: "safeNumber"
        safe_call(method, [identifier("ohlcv"), literal(idx)])
      end) ++ [identifier("phantomVolume")]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "volume:volume_index_unbound:phantomVolume"
  end

  # --- 33. Task 78e: parse8601(safeString(...)) wrapper on timestamp slot ---

  test "parse8601(safeString(ohlcv, key)) on timestamp → coercion: parse8601, format: iso8601" do
    # bitmex shape — the only known target for parse8601 wrapper recognition.
    # Outer call is `this.parse8601(...)`, inner call is `this.safeString(ohlcv, 'timestamp')`.
    # classify_parse8601_wrapper/1 lifts the inner key arg out so
    # build_locator_slot/3 emits an object-locator slot with format iso8601.
    ts_call =
      this_call("parse8601", [
        safe_call("safeString", [identifier("ohlcv"), literal("timestamp")])
      ])

    elements = [
      ts_call,
      safe_call("safeNumber", [identifier("ohlcv"), literal("o")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("h")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("l")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("c")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("v")])
    ]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["_unresolved_reason"] == nil

    assert branch["field_map"]["timestamp"] == %{
             "index" => nil,
             "key" => "timestamp",
             "coercion" => "parse8601",
             "format" => "iso8601"
           }

    assert branch["guard"] == %{"kind" => "always", "input_shape" => "object"}
  end

  # --- 34. Task 78e: parse8601 outside the timestamp slot is rejected ---

  test "parse8601 wrapper on non-timestamp slot → null + non_call_element reason" do
    # parse8601 is timestamp-only. The wrapper `this.parse8601(this.safeString(...))`
    # has exactly ONE argument (the inner safeString call), so it does NOT match
    # `classify_safe_call`'s `[_obj, idx_arg | rest]` shape (≥2 args). The OHLC
    # arm therefore falls through to `non_call_element` — honest closed-vocab
    # rejection, just with a more generic reason than `non_safe_coercion:parse8601`.
    # The dead @parse_iso clause in the OHLC arm catches the hypothetical
    # direct 2+-arg form `this.parse8601(x, y)` if CCXT ever introduces it.
    elements = [
      safe_call("safeInteger", [identifier("ohlcv"), literal("t")]),
      this_call("parse8601", [safe_call("safeString", [identifier("ohlcv"), literal("o")])]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("h")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("l")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("c")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("v")])
    ]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["open"] == nil
    assert branch["_unresolved_reason"] =~ "open:non_call_element"
  end

  # --- 35. Task 78b: defensive — mixed integer+string locators in the same branch ---

  test "mixed integer-locator and string-locator slots → guard omits input_shape, branch reason mixed_input_locators" do
    # Defensive case: no real exchange does this, but if extraction ever
    # encountered an array-input timestamp paired with object-input OHLC,
    # we want derive_input_shape/1 to surface the mismatch instead of
    # silently committing to one shape.
    elements = [
      safe_call("safeInteger", [identifier("ohlcv"), literal(0)]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("o")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("h")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("l")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("c")]),
      safe_call("safeNumber", [identifier("ohlcv"), literal("v")])
    ]

    entry = wrap_entry([return_stmt(array_expr(elements))])
    %{"branches" => [branch]} = OHLCV.derive(entry)

    # Each slot is individually well-formed → all 6 populate
    assert branch["field_map"]["timestamp"]
    assert branch["field_map"]["volume"]

    # But the guard omits input_shape because the locators don't agree
    assert branch["guard"] == %{"kind" => "always"}
    assert branch["_unresolved_reason"] == "mixed_input_locators"
  end
end
