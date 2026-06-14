defmodule CcxtExtract.Normalization.Position do
  @moduledoc """
  Derive `field_maps["position"]` from a per-exchange `parse_methods.json` entry.

  Scope (Task 80): handles exchanges whose `parsePosition` body contains a
  `ReturnStatement` returning `this.safePosition(%ObjectExpression{}, market)`.
  No top-level shape-discriminator detection is needed (0 of 49 parsePosition
  bodies have discriminators in the current corpus).

  ## Output

      %{
        "field_map" => %{
          "id"           => slot() | nil,
          "timestamp"    => slot() | nil,
          ...  # all 28 unified fields; nil when absent or outside closed vocab
        },
        "extras" => [%{"unified_key" => key, "key" => wire_key, "coercion" => method}],
        "_unresolved_reason" => nil | String.t()
      }

  Each scalar `slot()` is `%{"key", "coercion", "format"}` matching parseTicker.
  Enum slots (`side`/`marginMode`) add `"enum_map"`.

  ## Structurally-null fields (always nil)

  - `info` — raw position pass-through, not a safe-call
  - `datetime` — derived from `timestamp` via `iso8601`, not from raw
  - `symbol` — resolved via market reference, not a direct key lookup

  ## `_unresolved_reason` vocabulary (closed prefixes, open suffixes)

  - `nil` — canonical `safePosition` return resolved cleanly. Per-field
    slots may still be nil.
  - `"non_safe_position_return:<callee>"` — return calls a different method.
    Suffix `<callee>` is the callee identifier (open).
  - `"no_return_statement"` — body has no `ReturnStatement`.

  ## Three-Strikes Patch counter

  # Patch count: 0/3

  Authorized future patches:
  - Patch 1 candidates: bool-inference for `hedged`/`isolated` (BinaryExpression
    comparisons); let-then-reassign tracking.
  - Patch 3 escalation: migrate persistently-gappy exchanges to
    `priv/overrides/<id>.json` with documented `verified_against` evidence.
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @unified_fields ~w(id symbol timestamp datetime lastUpdateTimestamp initialMargin
                     initialMarginPercentage maintenanceMargin maintenanceMarginPercentage
                     entryPrice notional leverage unrealizedPnl realizedPnl contracts
                     contractSize marginRatio liquidationPrice markPrice lastPrice
                     collateral marginMode side percentage stopLossPrice takeProfitPrice
                     hedged info)

  # Plain-scalar coercion vocab.
  @safe_str ~w(safeString safeString2 safeStringN)
  @safe_str_lower ~w(safeStringLower safeStringLower2)
  @safe_num ~w(safeNumber safeNumber2)
  @safe_int ~w(safeInteger safeInteger2 safeIntegerN)
  @safe_ts ~w(safeTimestamp)
  @safe_bool ~w(safeBool)
  @enum_call_vocab @safe_str ++ @safe_str_lower
  @scalar_vocab @safe_str ++ @safe_str_lower ++ @safe_num ++ @safe_int ++ @safe_ts ++ @safe_bool

  # Field categories.
  @enum_fields ~w(side marginMode)
  @structurally_null ~w(info datetime symbol)
  @scalar_fields @unified_fields -- (@enum_fields ++ @structurally_null)

  @doc """
  Derive the position field map from a `parse_methods.json` entry for one exchange.

  Returns `nil` when there is no `parsePosition` override (the exchange inherits
  from a base class). Returns a map with a non-nil top-level `_unresolved_reason`
  when the return structure is not the slottable `safePosition` pattern.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parsePosition"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  @doc "Returns the list of unified position field names."
  @spec unified_fields() :: [String.t()]
  def unified_fields, do: @unified_fields

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []
    bindings = ASTHelpers.collect_bindings(body_stmts)

    case find_safe_position_object(body_stmts) do
      {:ok, properties} -> build_result(properties, bindings)
      {:error, reason} -> unresolved(reason)
    end
  end

  # --- canonical safePosition return location ---

  # Use the LAST top-level ReturnStatement (body may have early-return guards).
  @spec find_safe_position_object([map()]) :: {:ok, [map()]} | {:error, String.t()}
  defp find_safe_position_object(body_stmts) do
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
            "property" => %{"type" => "Identifier", "name" => "safePosition"}
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
        {:error, "non_safe_position_return:#{callee_name}"}

      _ ->
        {:error, "no_return_statement"}
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

  defp to_lower_chain?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "CallExpression"} = inner,
           "property" => %{"name" => "toLowerCase"}
         },
         "arguments" => []
       }), do: safe_call?(inner)

  defp to_lower_chain?(_), do: false

  defp safe_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method}
         }
       })
       when method in @scalar_vocab, do: true

  defp safe_call?(_), do: false

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

  @spec classify_ternary_test(map(), [{String.t(), map()}]) ::
          {:enum_lhs, map(), String.t()} | :bool_flag | :numeric_code | :char_code | :unknown
  defp classify_ternary_test(%{"type" => "Identifier"}, _bindings), do: :bool_flag

  defp classify_ternary_test(
         %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right},
         bindings
       )
       when op in ["===", "=="] do
    classify_eq_test(left, right, bindings)
  end

  defp classify_ternary_test(_, _), do: :unknown

  defp classify_eq_test(left, right, bindings) do
    cond do
      match?(%{"type" => "Literal", "value" => v} when is_number(v), right) ->
        :numeric_code

      match?(%{"type" => "Literal", "value" => v} when is_number(v), left) ->
        :numeric_code

      array_index?(left) ->
        :char_code

      array_index?(right) ->
        :char_code

      true ->
        classify_string_enum_test(left, right, bindings)
    end
  end

  defp array_index?(%{
         "type" => "MemberExpression",
         "computed" => true,
         "property" => %{"type" => "Literal", "value" => v}
       })
       when is_number(v), do: true

  defp array_index?(_), do: false

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

  defp finalize_enum_map(safe_call, enum_map) do
    case classify_safe_call(safe_call) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @safe_str ->
        {:enum_map, %{method: method, idx_arg: idx_arg, enum_map: enum_map}}

      _ ->
        :error
    end
  end

  defp literal_value(%{"type" => "Literal", "value" => v}), do: v
  defp literal_value(_), do: nil

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

  @spec classify_safe_call(term()) :: {:ok, %{method: String.t(), idx_arg: map()}} | :error
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
