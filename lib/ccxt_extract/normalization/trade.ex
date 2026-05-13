defmodule CcxtExtract.Normalization.Trade do
  @moduledoc """
  Derive `field_maps["trade"]` from a per-exchange `parse_methods.json` entry.

  Scope (Task 76): handles exchanges whose `parseTrade` body contains a
  `ReturnStatement` returning `this.safeTrade(%ObjectExpression{}, market)`,
  where the body has no top-level shape-discriminator (`Array.isArray`,
  `'<lit>' in <var>`, `typeof <var> === '<str>'`).

  ## Output

      %{
        "field_map" => %{
          "id"           => slot() | nil,
          "timestamp"    => slot() | nil,
          ...  # all 13 unified fields; nil when absent or outside closed vocab
        },
        "extras" => [%{"unified_key" => key, "key" => wire_key, "coercion" => method}],
        "_unresolved_reason" => nil | String.t()
      }

  Each scalar `slot()` is `%{"key", "coercion", "format"}` matching parseTicker.
  Enum slots (`type`/`side`/`takerOrMaker`) add `"enum_map"`. Nested `fee`
  slot uses `"sub_field_map" => %{"cost", "currency", "rate"}`.

  Three fields are structurally null for all exchanges: `info` (raw
  pass-through), `datetime` (derived from `timestamp` via `iso8601`),
  `symbol` (resolved via `safeSymbol` / `market['symbol']`, not a direct
  key lookup).

  ## `_unresolved_reason` vocabulary (closed prefixes, open suffixes)

  Two prefixes carry an open suffix — consumers MUST match on the prefix
  (`String.starts_with?/2`), not on the full string. See SCHEMA.md for the
  schema-level statement of the same contract.

  - `nil` — canonical `safeTrade` return resolved cleanly. Per-field
    slots may still be nil or carry their own `unresolved_reason`.
  - `"multi_payload_branching:<N>"` — body has N top-level shape-discriminator
    IfStatements (Array.isArray / `'<lit>' in <var>` / typeof). First-cut
    skips per-branch extraction. Suffix `<N>` is an integer count (open).
  - `"non_safe_trade_return:<callee>"` — return calls a different method
    (e.g. `parseSpotTrade`, `safeTrade2`). Suffix `<callee>` is the callee
    identifier from the source (open — any future CCXT method name).
  - `"no_return_statement"` — body has no `ReturnStatement` at all.
  - `"unrecognized_return_shape"` — body has a top-level `ReturnStatement`,
    but its argument is neither a `this.safeTrade*` CallExpression (which
    would be the canonical pattern) nor a `this.<otherMethod>` CallExpression
    (which would be `non_safe_trade_return:<callee>`). Covers raw literals,
    non-`this` callees, and other unhandled shapes.

  ## Per-field `unresolved_reason` vocabulary (enum/fee slots only)

  - `"bool_flag_inferred"` — `isBuyer ? 'buy' : 'sell'` (bool-test ternary)
  - `"numeric_code_inferred"` — `safeCall === <int> ? 'a' : 'b'`
  - `"char_code_inferred"` — `trade[<int>] === '<char>' ? 'a' : 'b'`
  - `"fee_not_object_literal"` — `'fee': fee` where `fee` is not an inline
    ObjectExpression literal (delegated derivation we can't slot).

  ## Three-Strikes Patch counter

  # Patch count: 0/3

  Authorized future patches:
  - Patch 1 candidates: per-branch extraction inside Array.isArray-discriminated
    bodies; bool/numeric/char enum derivation; let-then-reassign tracking.
  - Patch 3 escalation: migrate persistently-gappy exchanges to
    `priv/overrides/<id>.json` with documented `verified_against` evidence.
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @unified_fields ~w(id timestamp datetime order price amount cost type side takerOrMaker fee info symbol)

  # Plain-scalar coercion vocab (inherits parseTicker's set; parseTrade-specific
  # additions: safeStringLower for enum passthrough, safeCurrencyCode for fee.currency).
  @safe_str ~w(safeString safeString2 safeStringN)
  @safe_str_lower ~w(safeStringLower)
  @safe_num ~w(safeNumber safeNumber2)
  @safe_int ~w(safeInteger safeInteger2)
  @safe_ts ~w(safeTimestamp)
  @enum_call_vocab @safe_str ++ @safe_str_lower
  @scalar_vocab @safe_str ++ @safe_str_lower ++ @safe_num ++ @safe_int ++ @safe_ts

  # Field categories.
  @enum_fields ~w(type side takerOrMaker)
  @nested_fields ~w(fee)
  @structurally_null ~w(info datetime symbol)
  @scalar_fields @unified_fields -- (@enum_fields ++ @nested_fields ++ @structurally_null)

  @doc """
  Derive the trade field map from a `parse_methods.json` entry for one exchange.

  Returns `nil` when there is no `parseTrade` override (the exchange inherits
  from a base class). Returns a map with a non-nil top-level `_unresolved_reason`
  when the return structure is not the slottable `safeTrade` pattern OR when
  the body uses shape-discriminator branching.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parseTrade"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  @doc "Returns the list of 13 unified trade field names."
  @spec unified_fields() :: [String.t()]
  def unified_fields, do: @unified_fields

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []

    case shape_discriminator_count(body_stmts) do
      n when n > 0 ->
        unresolved("multi_payload_branching:#{n}")

      0 ->
        bindings = ASTHelpers.collect_bindings(body_stmts)

        case find_safe_trade_object(body_stmts) do
          {:ok, properties} -> build_result(properties, bindings)
          {:error, reason} -> unresolved(reason)
        end
    end
  end

  # --- multi-payload branching detection ---

  @spec shape_discriminator_count([map()]) :: non_neg_integer()
  defp shape_discriminator_count(body_stmts) do
    body_stmts
    |> Enum.filter(&shape_discriminator?/1)
    |> length()
  end

  @spec shape_discriminator?(term()) :: boolean()
  defp shape_discriminator?(%{"type" => "IfStatement", "test" => test}), do: discriminator_test?(test)
  defp shape_discriminator?(_), do: false

  # Array.isArray(<arg>)
  @spec discriminator_test?(term()) :: boolean()
  defp discriminator_test?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"name" => "Array"},
           "property" => %{"name" => "isArray"}
         }
       }),
       do: true

  # '<lit>' in <var>
  defp discriminator_test?(%{
         "type" => "BinaryExpression",
         "operator" => "in",
         "left" => %{"type" => "Literal", "value" => v},
         "right" => %{"type" => "Identifier"}
       })
       when is_binary(v),
       do: true

  # typeof <var> ===/!== '<str>' (either side)
  defp discriminator_test?(%{
         "type" => "BinaryExpression",
         "operator" => op,
         "left" => %{"type" => "UnaryExpression", "operator" => "typeof"}
       })
       when op in ["===", "!==", "==", "!="],
       do: true

  defp discriminator_test?(%{
         "type" => "BinaryExpression",
         "operator" => op,
         "right" => %{"type" => "UnaryExpression", "operator" => "typeof"}
       })
       when op in ["===", "!==", "==", "!="],
       do: true

  defp discriminator_test?(_), do: false

  # --- canonical safeTrade return location ---

  # parseTrade can have early-return guards before the canonical return;
  # the canonical pattern is the LAST top-level ReturnStatement.
  @spec find_safe_trade_object([map()]) :: {:ok, [map()]} | {:error, String.t()}
  defp find_safe_trade_object(body_stmts) do
    last_return = body_stmts |> Enum.filter(&match?(%{"type" => "ReturnStatement"}, &1)) |> List.last()

    case last_return do
      nil ->
        {:error, "no_return_statement"}

      %{
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => "safeTrade"}
          },
          "arguments" => [%{"type" => "ObjectExpression", "properties" => properties} | _]
        }
      } ->
        {:ok, properties}

      %{
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => callee_name}
          }
        }
      } ->
        {:error, "non_safe_trade_return:#{callee_name}"}

      _ ->
        {:error, "unrecognized_return_shape"}
    end
  end

  # --- result assembly ---

  @spec build_result([map()], [{String.t(), map()}]) :: map()
  defp build_result(properties, bindings) do
    unified_set = MapSet.new(@unified_fields)

    prop_map =
      properties
      |> Enum.flat_map(fn p ->
        case key_from_property(p) do
          nil -> []
          k -> [{k, p["value"]}]
        end
      end)
      |> Map.new()

    field_map =
      Map.new(@unified_fields, fn field ->
        {field, classify_unified_field(field, Map.get(prop_map, field), bindings)}
      end)

    extras =
      properties
      |> Enum.reject(fn p ->
        key = key_from_property(p)
        is_nil(key) or MapSet.member?(unified_set, key)
      end)
      |> Enum.flat_map(fn p ->
        key = key_from_property(p)
        value_node = p["value"]

        case resolve_then_classify(value_node, bindings) do
          {:ok, %{method: method, idx_arg: %{"type" => "Literal", "value" => wire_key}}}
          when is_binary(wire_key) and method in @scalar_vocab ->
            [%{"unified_key" => key, "key" => wire_key, "coercion" => method}]

          _ ->
            []
        end
      end)

    %{"field_map" => field_map, "extras" => extras, "_unresolved_reason" => nil}
  end

  @spec key_from_property(map()) :: String.t() | nil
  defp key_from_property(%{"computed" => true}), do: nil
  defp key_from_property(%{"key" => %{"name" => name}}), do: name
  defp key_from_property(%{"key" => %{"value" => value}}) when is_binary(value), do: value
  defp key_from_property(_), do: nil

  # --- per-field classification ---

  @spec classify_unified_field(String.t(), map() | nil, [{String.t(), map()}]) :: map() | nil
  defp classify_unified_field(_field, nil, _bindings), do: nil

  defp classify_unified_field(field, _value_node, _bindings) when field in @structurally_null, do: nil

  defp classify_unified_field("timestamp", value_node, bindings), do: classify_timestamp_field(value_node, bindings)

  defp classify_unified_field("fee", value_node, bindings), do: classify_fee_field(value_node, bindings)

  defp classify_unified_field(field, value_node, bindings) when field in @enum_fields,
    do: classify_enum_field(value_node, bindings)

  defp classify_unified_field(field, value_node, bindings) when field in @scalar_fields,
    do: classify_scalar_field(value_node, bindings)

  # --- scalar slot ---

  @spec classify_scalar_field(map(), [{String.t(), map()}]) :: map() | nil
  defp classify_scalar_field(value_node, bindings) do
    case resolve_then_classify(value_node, bindings) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @scalar_vocab ->
        build_slot(idx_arg, method, nil)

      _ ->
        nil
    end
  end

  # --- timestamp slot (format-aware) ---

  @spec classify_timestamp_field(map(), [{String.t(), map()}]) :: map() | nil
  defp classify_timestamp_field(value_node, bindings) do
    case resolve_then_classify(value_node, bindings) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @safe_int ->
        build_slot(idx_arg, method, "ms")

      {:ok, %{method: method, idx_arg: idx_arg}} when method in @safe_ts ->
        build_slot(idx_arg, method, "s")

      _ ->
        nil
    end
  end

  # --- enum slot ---

  @spec classify_enum_field(map(), [{String.t(), map()}]) :: map() | nil
  defp classify_enum_field(value_node, bindings) do
    resolved = resolve_identifier(value_node, bindings)

    cond do
      # `safeString(...).toLowerCase()` chain canonicalizes to safeStringLower.
      to_lower_chain?(resolved) ->
        build_enum_from_lowercase_chain(resolved)

      # Plain `this.safe*(arg, 'key')` call.
      match?(%{"type" => "CallExpression"}, resolved) ->
        build_enum_from_call(resolved)

      # ConditionalExpression patterns (ternary).
      match?(%{"type" => "ConditionalExpression"}, resolved) ->
        build_enum_from_ternary(resolved, bindings)

      true ->
        nil
    end
  end

  # `this.safeString(x, 'k').toLowerCase()` — canonicalize to safeStringLower.
  @spec to_lower_chain?(term()) :: boolean()
  defp to_lower_chain?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "CallExpression"} = inner,
           "property" => %{"name" => "toLowerCase"}
         },
         "arguments" => []
       }),
       do: safe_call?(inner)

  defp to_lower_chain?(_), do: false

  @spec safe_call?(term()) :: boolean()
  defp safe_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method}
         }
       })
       when method in @scalar_vocab,
       do: true

  defp safe_call?(_), do: false

  @spec build_enum_from_lowercase_chain(map()) :: map() | nil
  defp build_enum_from_lowercase_chain(%{"callee" => %{"object" => inner}}) do
    case classify_safe_call(inner) do
      {:ok, %{idx_arg: idx_arg}} ->
        case build_slot(idx_arg, "safeStringLower", nil) do
          nil -> nil
          slot -> Map.put(slot, "enum_map", nil)
        end

      _ ->
        nil
    end
  end

  @spec build_enum_from_call(map()) :: map() | nil
  defp build_enum_from_call(call) do
    case classify_safe_call(call) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @enum_call_vocab ->
        case build_slot(idx_arg, method, nil) do
          nil -> nil
          slot -> Map.put(slot, "enum_map", nil)
        end

      _ ->
        nil
    end
  end

  @spec build_enum_from_ternary(map(), [{String.t(), map()}]) :: map() | nil
  defp build_enum_from_ternary(ternary, bindings) do
    case classify_ternary(ternary, bindings) do
      {:enum_map, %{method: method, idx_arg: idx_arg, enum_map: map}} when method in @safe_str ->
        case build_slot(idx_arg, method, nil) do
          nil -> nil
          slot -> Map.put(slot, "enum_map", map)
        end

      {:unresolved, reason} ->
        %{"key" => nil, "coercion" => nil, "format" => nil, "enum_map" => nil, "unresolved_reason" => reason}

      _ ->
        nil
    end
  end

  # Classify a ConditionalExpression as either an extractable enum_map ternary
  # or a per-field unresolved-reason pattern.
  @spec classify_ternary(map(), [{String.t(), map()}]) ::
          {:enum_map, %{method: String.t(), idx_arg: map(), enum_map: %{String.t() => String.t()}}}
          | {:unresolved, String.t()}
          | :error
  defp classify_ternary(%{"type" => "ConditionalExpression", "test" => test} = node, bindings) do
    case classify_ternary_test(test, bindings) do
      {:enum_lhs, safe_call, rhs_value} when is_binary(rhs_value) ->
        consequent_value = literal_value(node["consequent"])

        seed =
          if is_binary(consequent_value),
            do: %{rhs_value => consequent_value},
            else: %{}

        accumulate_enum_map(node, safe_call, bindings, seed, node["alternate"])

      :bool_flag ->
        {:unresolved, "bool_flag_inferred"}

      :numeric_code ->
        {:unresolved, "numeric_code_inferred"}

      :char_code ->
        {:unresolved, "char_code_inferred"}

      _ ->
        :error
    end
  end

  defp classify_ternary(_, _), do: :error

  # Inspect the ternary test to classify the comparison pattern.
  @spec classify_ternary_test(map(), [{String.t(), map()}]) ::
          {:enum_lhs, map(), String.t()} | :bool_flag | :numeric_code | :char_code | :unknown
  defp classify_ternary_test(%{"type" => "Identifier"}, _bindings), do: :bool_flag

  defp classify_ternary_test(
         %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right},
         bindings
       )
       when op in ["===", "!==", "==", "!="] do
    classify_eq_test(left, right, bindings)
  end

  defp classify_ternary_test(_, _), do: :unknown

  @spec classify_eq_test(map(), map(), [{String.t(), map()}]) ::
          {:enum_lhs, map(), String.t()} | :bool_flag | :numeric_code | :char_code | :unknown
  defp classify_eq_test(left, right, bindings) do
    cond do
      # Numeric-code comparison: RHS is a numeric Literal.
      match?(%{"type" => "Literal", "value" => v} when is_number(v), right) ->
        :numeric_code

      match?(%{"type" => "Literal", "value" => v} when is_number(v), left) ->
        :numeric_code

      # Char-code comparison: LHS is `<arr>[<int>]` MemberExpression.
      array_index?(left) ->
        :char_code

      array_index?(right) ->
        :char_code

      # String-key enum: LHS is a safe* call (direct or via binding), RHS is string Literal.
      true ->
        classify_string_enum_test(left, right, bindings)
    end
  end

  @spec array_index?(term()) :: boolean()
  defp array_index?(%{
         "type" => "MemberExpression",
         "computed" => true,
         "property" => %{"type" => "Literal", "value" => v}
       })
       when is_number(v),
       do: true

  defp array_index?(_), do: false

  @spec classify_string_enum_test(map(), map(), [{String.t(), map()}]) ::
          {:enum_lhs, map(), String.t()} | :unknown
  defp classify_string_enum_test(left, right, bindings) do
    with %{"type" => "Literal", "value" => rhs} when is_binary(rhs) <- right,
         safe_call when not is_nil(safe_call) <- resolve_to_safe_call(left, bindings) do
      {:enum_lhs, safe_call, rhs}
    else
      _ ->
        with %{"type" => "Literal", "value" => lhs} when is_binary(lhs) <- left,
             safe_call when not is_nil(safe_call) <- resolve_to_safe_call(right, bindings) do
          {:enum_lhs, safe_call, lhs}
        else
          _ -> :unknown
        end
    end
  end

  @spec resolve_to_safe_call(term(), [{String.t(), map()}]) :: map() | nil
  defp resolve_to_safe_call(%{"type" => "CallExpression"} = node, _bindings) do
    if safe_call?(node), do: node
  end

  defp resolve_to_safe_call(%{"type" => "Identifier", "name" => name}, bindings) do
    case lookup_binding(name, bindings) do
      %{"type" => "CallExpression"} = bound -> if safe_call?(bound), do: bound
      _ -> nil
    end
  end

  defp resolve_to_safe_call(_, _), do: nil

  # Walk a nested-ternary chain `safe === 'X' ? 'a' : (safe === 'Y' ? 'b' : default)`,
  # accumulating the literal-to-arm-literal map.
  @spec accumulate_enum_map(map(), map(), [{String.t(), map()}], %{String.t() => String.t()}, term()) ::
          {:enum_map, %{method: String.t(), idx_arg: map(), enum_map: %{String.t() => String.t()}}} | :error
  defp accumulate_enum_map(_node, safe_call, _bindings, enum_map, %{"type" => "Literal"}) do
    finalize_enum_map(safe_call, enum_map)
  end

  defp accumulate_enum_map(_node, safe_call, _bindings, enum_map, %{"type" => "Identifier", "name" => "undefined"}) do
    finalize_enum_map(safe_call, enum_map)
  end

  defp accumulate_enum_map(_node, safe_call, bindings, enum_map, %{"type" => "ConditionalExpression"} = nested) do
    case classify_ternary_test(nested["test"], bindings) do
      {:enum_lhs, nested_call, rhs_value} when is_binary(rhs_value) ->
        descend_or_finalize(nested, safe_call, nested_call, bindings, enum_map, rhs_value)

      _ ->
        finalize_enum_map(safe_call, enum_map)
    end
  end

  defp accumulate_enum_map(_node, safe_call, _bindings, enum_map, _alternate), do: finalize_enum_map(safe_call, enum_map)

  @spec descend_or_finalize(map(), map(), map(), [{String.t(), map()}], %{String.t() => String.t()}, String.t()) ::
          {:enum_map, %{method: String.t(), idx_arg: map(), enum_map: %{String.t() => String.t()}}} | :error
  defp descend_or_finalize(nested, safe_call, nested_call, bindings, enum_map, rhs_value) do
    if same_safe_call?(safe_call, nested_call) do
      consequent_value = literal_value(nested["consequent"])

      updated =
        if is_binary(consequent_value),
          do: Map.put(enum_map, rhs_value, consequent_value),
          else: enum_map

      accumulate_enum_map(nested, safe_call, bindings, updated, nested["alternate"])
    else
      finalize_enum_map(safe_call, enum_map)
    end
  end

  @spec finalize_enum_map(map(), %{String.t() => String.t()}) ::
          {:enum_map, %{method: String.t(), idx_arg: map(), enum_map: %{String.t() => String.t()}}} | :error
  defp finalize_enum_map(safe_call, enum_map) do
    case classify_safe_call(safe_call) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @safe_str ->
        {:enum_map, %{method: method, idx_arg: idx_arg, enum_map: enum_map}}

      _ ->
        :error
    end
  end

  @spec literal_value(term()) :: term() | nil
  defp literal_value(%{"type" => "Literal", "value" => v}), do: v
  defp literal_value(_), do: nil

  @spec same_safe_call?(term(), term()) :: boolean()
  defp same_safe_call?(a, b) do
    with {:ok, %{method: ma, idx_arg: ka}} <- classify_safe_call(a),
         {:ok, %{method: mb, idx_arg: kb}} <- classify_safe_call(b),
         %{"value" => va} <- ka,
         %{"value" => vb} <- kb do
      ma == mb and va == vb
    else
      _ -> false
    end
  end

  # --- nested fee slot ---

  @spec classify_fee_field(map(), [{String.t(), map()}]) :: map()
  defp classify_fee_field(value_node, bindings) do
    resolved = resolve_identifier(value_node, bindings)

    case resolved do
      %{"type" => "ObjectExpression", "properties" => props} ->
        sub_field_map = build_fee_sub_map(props, bindings)
        %{"sub_field_map" => sub_field_map}

      _ ->
        %{"sub_field_map" => nil, "unresolved_reason" => "fee_not_object_literal"}
    end
  end

  @spec build_fee_sub_map([map()], [{String.t(), map()}]) :: %{String.t() => map() | nil}
  defp build_fee_sub_map(properties, bindings) do
    by_key =
      properties
      |> Enum.flat_map(fn p ->
        case key_from_property(p) do
          nil -> []
          k -> [{k, p["value"]}]
        end
      end)
      |> Map.new()

    cost = classify_fee_subfield(Map.get(by_key, "cost"), bindings)
    currency = classify_fee_subfield(Map.get(by_key, "currency"), bindings)
    rate = classify_fee_subfield(Map.get(by_key, "rate"), bindings)

    %{"cost" => cost, "currency" => currency, "rate" => rate}
  end

  @spec classify_fee_subfield(map() | nil, [{String.t(), map()}]) :: map() | nil
  defp classify_fee_subfield(nil, _bindings), do: nil

  defp classify_fee_subfield(value_node, bindings) do
    case resolve_then_classify(value_node, bindings) do
      {:ok, %{method: "safeCurrencyCode", idx_arg: idx_arg}} ->
        currency_slot(idx_arg, bindings)

      {:ok, %{method: method, idx_arg: idx_arg}} when method in @scalar_vocab ->
        build_slot(idx_arg, method, nil)

      _ ->
        nil
    end
  end

  # safeCurrencyCode takes a currency-id arg which can be: a Literal wire key,
  # an Identifier bound to a safe-call (or chained Identifier→Identifier→safe-call),
  # or a nested CallExpression (`safeCurrencyCode(this.safeString(trade, 'feeCcy'))`).
  # Trace back through the binding chain / call nesting to extract the wire key
  # when provable; emit key: nil otherwise.
  @spec currency_slot(map(), [{String.t(), map()}]) :: map()
  defp currency_slot(arg, bindings) do
    wire_key = trace_currency_wire_key(arg, bindings, MapSet.new())
    %{"key" => wire_key, "coercion" => "safeCurrencyCode", "format" => nil}
  end

  @spec trace_currency_wire_key(term(), [{String.t(), map()}], MapSet.t()) :: String.t() | nil
  defp trace_currency_wire_key(%{"type" => "Literal", "value" => v}, _bindings, _seen) when is_binary(v), do: v

  defp trace_currency_wire_key(%{"type" => "Identifier", "name" => name}, bindings, seen) do
    if MapSet.member?(seen, name) do
      nil
    else
      case lookup_binding(name, bindings) do
        nil -> nil
        bound -> trace_currency_wire_key(bound, bindings, MapSet.put(seen, name))
      end
    end
  end

  defp trace_currency_wire_key(%{"type" => "CallExpression"} = node, _bindings, _seen) do
    case classify_safe_call(node) do
      {:ok, %{idx_arg: %{"type" => "Literal", "value" => k}}} when is_binary(k) -> k
      _ -> nil
    end
  end

  defp trace_currency_wire_key(_, _bindings, _seen), do: nil

  # --- Identifier resolution & safe-call classification ---

  @spec resolve_identifier(map() | nil, [{String.t(), map()}]) :: map() | nil
  defp resolve_identifier(%{"type" => "Identifier", "name" => name}, bindings), do: lookup_binding(name, bindings)

  defp resolve_identifier(node, _bindings), do: node

  @spec resolve_then_classify(map() | nil, [{String.t(), map()}]) ::
          {:ok, %{method: String.t(), idx_arg: map()}} | :error
  defp resolve_then_classify(nil, _bindings), do: :error

  defp resolve_then_classify(%{"type" => "Identifier", "name" => name}, bindings) do
    case lookup_binding(name, bindings) do
      nil -> :error
      init -> classify_safe_call(init)
    end
  end

  defp resolve_then_classify(%{"type" => "CallExpression"} = node, _bindings), do: classify_safe_call(node)

  defp resolve_then_classify(_, _bindings), do: :error

  # safeCurrencyCode takes one arg, not (obj, key). Special-case it.
  @spec classify_safe_call(term()) :: {:ok, %{method: String.t(), idx_arg: map()}} | :error
  defp classify_safe_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "safeCurrencyCode"}
         },
         "arguments" => [arg | _]
       }) do
    {:ok, %{method: "safeCurrencyCode", idx_arg: arg}}
  end

  defp classify_safe_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method}
         },
         "arguments" => [_obj, idx_arg | _rest]
       }) do
    {:ok, %{method: method, idx_arg: idx_arg}}
  end

  defp classify_safe_call(_), do: :error

  @spec build_slot(map(), String.t(), String.t() | nil) :: map() | nil
  defp build_slot(%{"type" => "Literal", "value" => key}, method, format) when is_binary(key) do
    %{"key" => key, "coercion" => method, "format" => format}
  end

  defp build_slot(_, _, _), do: nil

  @spec lookup_binding(String.t(), [{String.t(), map()}]) :: map() | nil
  defp lookup_binding(name, bindings) do
    Enum.find_value(bindings, fn
      {^name, init} when is_map(init) -> init
      _ -> nil
    end)
  end

  @spec unresolved(String.t()) :: map()
  defp unresolved(reason) do
    null_field_map = Map.new(@unified_fields, fn field -> {field, nil} end)
    %{"field_map" => null_field_map, "extras" => [], "_unresolved_reason" => reason}
  end
end
