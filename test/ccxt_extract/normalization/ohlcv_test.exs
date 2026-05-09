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
    assert branch["guard"] == %{"kind" => "always"}
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

  # --- 7b. non-inverse discriminator (okx-style `type === 'spot'`) → null + reason ---

  test "non-inverse ConditionalExpression test → volume slot null + branch reason" do
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

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "non_inverse_discriminator"
    # The other 5 slots still populate
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

  # --- 19. inverse_discriminator? on Identifier with broken transitive binding ---

  test "discriminator chain dead-ends at unbound Identifier → non_inverse_discriminator" do
    # volumeIndex = ghostFlag ? 7 : 5, but ghostFlag is never declared.
    # The Identifier branch of inverse_discriminator? should fall through to false.
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
    assert branch["_unresolved_reason"] =~ "non_inverse_discriminator"
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
    # without the visited-set guard in inverse_discriminator?/3. Real JS const
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

    # Must terminate (not hang). Cycle dead-ends -> non_inverse_discriminator.
    %{"branches" => [branch]} = OHLCV.derive(entry)

    assert branch["field_map"]["volume"] == nil
    assert branch["_unresolved_reason"] =~ "non_inverse_discriminator"
  end

  # --- 23. hybrid return: one array + one non-array → ambiguous, not silent always-array ---

  test "hybrid `if (Array.isArray()) return [...]; return {...}` → ambiguous_return_shape" do
    # Codex P2 finding: the deferred Task 78b/c hybrid shape must NOT emit a
    # fabricated always-array map just because exactly one return happens to
    # be an ArrayExpression. The walker counts ALL ReturnStatements, so an
    # array-plus-object body classifies as ambiguous and emits null + reason.
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
end
