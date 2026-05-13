defmodule CcxtExtract.Normalization.Transaction do
  @moduledoc """
  Derive `field_maps["transaction"]` from a per-exchange `parse_methods.json` entry.

  Scope (Task 81): handles exchanges whose `parseTransaction` body returns an
  ObjectExpression (directly or wrapped in a TSAsExpression) built from
  variable bindings to safe* calls.

  ## Output

      %{
        "field_map" => %{
          "id"          => slot() | nil,
          "timestamp"   => slot() | nil,
          ...  # all 18 unified fields; nil when absent or outside closed vocab
        },
        "extras" => [%{"unified_key" => key, "key" => wire_key, "coercion" => method}],
        "_unresolved_reason" => nil | String.t()
      }

  Each scalar `slot()` is `%{"key", "coercion", "format"}` (always key-based,
  no index field). Method is drawn from the closed vocabulary.

  ## Structurally-null fields

  Several fields are always `nil` by design:

  - `info` — raw-pass-through `Identifier`, not a safe* call
  - `datetime` — derived via `iso8601(timestamp)`, not from raw
  - `currency` — resolved via `safeCurrencyCode`, which uses a 1-arg form
    distinct from the 2-arg form the classifier recognizes
  - `network` — typically derived from `networkIdToCode(...)` or similar
    resolver call rather than a direct safe* lookup on the raw dict
  - `fee` — built as an inline `%{cost, currency, rate}` sub-object rather
    than a flat safe* call on the top-level transaction dict

  ## `_unresolved_reason` vocabulary

  - `nil` — ObjectExpression return resolved cleanly; per-field slots may
    still be nil within the closed-vocab honesty rule
  - `"no_return_statement"` — body has no `ReturnStatement`
  - `"non_object_return:<type>"` — last return yields something other than
    an ObjectExpression (after unwrapping any TSAsExpression wrapper)

  ## Enum tables

  `type` — CCXT unified values: `"deposit"` / `"withdrawal"`. Carried as
  `"enum_values"` on the type slot when we can detect its wire key.

  `status` — CCXT unified values: `"ok"` / `"pending"` / `"canceled"` /
  `"failed"`. Emitted as `"enum_values"` when we can detect its wire key.

  ## Three-Strikes Patch counter

  # Patch count: 0/3

  Authorized future patches:
  - Patch 1 candidates: fee sub-object extraction (sub_field_map shape);
    per-branch extraction for shape-discriminated bodies.
  - Patch 3 escalation: migrate persistently-gappy exchanges to
    `priv/overrides/<id>.json`.
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @unified_fields ~w(id timestamp datetime txid type status amount currency
                     address addressFrom addressTo tag tagFrom tagTo network
                     updated fee info)

  @safe_str ~w(safeString safeString2 safeStringN)
  @safe_str_lower ~w(safeStringLower safeStringUpper)
  @safe_num ~w(safeNumber safeNumber2)
  @safe_int ~w(safeInteger safeInteger2)
  @safe_ts ~w(safeTimestamp)
  @scalar_vocab @safe_str ++ @safe_str_lower ++ @safe_num ++ @safe_int ++ @safe_ts

  # Fields that are structurally null — not derived by direct safe* lookup.
  @structurally_null ~w(info datetime currency network fee)

  # Enum-typed fields with closed value sets.
  @enum_fields ~w(type status)

  # Enum value sets by field name (CCXT unified).
  @type_enum_values ~w(deposit withdrawal)
  @status_enum_values ~w(ok pending canceled failed)

  @doc """
  Derive the transaction field map from a `parse_methods.json` entry for one
  exchange.

  Returns `nil` when there is no `parseTransaction` override. Returns a map
  with a non-nil `_unresolved_reason` when the return structure is not a
  slottable ObjectExpression.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parseTransaction"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  @doc "Returns the list of 18 unified transaction field names."
  @spec unified_fields() :: [String.t()]
  def unified_fields, do: @unified_fields

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []
    bindings = ASTHelpers.collect_bindings(body_stmts)

    case find_transaction_object(body_stmts) do
      {:ok, properties} -> build_result(properties, bindings)
      {:error, reason} -> unresolved(reason)
    end
  end

  # Finds the last ReturnStatement and unwraps TSAsExpression if present.
  # Returns {:ok, properties} when the return yields an ObjectExpression,
  # or {:error, reason} otherwise.
  @spec find_transaction_object([map()]) :: {:ok, [map()]} | {:error, String.t()}
  defp find_transaction_object(body_stmts) do
    last_return = body_stmts |> Enum.filter(&match?(%{"type" => "ReturnStatement"}, &1)) |> List.last()

    case last_return do
      nil ->
        {:error, "no_return_statement"}

      %{"argument" => arg} ->
        # Unwrap TypeScript `as` cast before inspecting the inner expression.
        inner = unwrap_ts_as(arg)

        case inner do
          %{"type" => "ObjectExpression", "properties" => properties} ->
            {:ok, properties}

          %{"type" => other_type} ->
            {:error, "non_object_return:#{other_type}"}

          _ ->
            {:error, "non_object_return:unknown"}
        end
    end
  end

  # TSAsExpression wraps `expr as Type` TypeScript casts; unwrap to the inner expr.
  @spec unwrap_ts_as(map()) :: map()
  defp unwrap_ts_as(%{"type" => "TSAsExpression", "expression" => inner}), do: inner
  defp unwrap_ts_as(node), do: node

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

  defp classify_unified_field("updated", value_node, bindings), do: classify_timestamp_field(value_node, bindings)

  defp classify_unified_field(field, value_node, bindings) when field in @enum_fields,
    do: classify_enum_field(field, value_node, bindings)

  defp classify_unified_field(_field, value_node, bindings), do: classify_scalar_field(value_node, bindings)

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

  @spec classify_enum_field(String.t(), map(), [{String.t(), map()}]) :: map() | nil
  defp classify_enum_field(field, value_node, bindings) do
    case resolve_then_classify(value_node, bindings) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @scalar_vocab ->
        enum_values = enum_values_for_field(field)

        case build_slot(idx_arg, method, nil) do
          nil -> nil
          slot -> Map.put(slot, "enum_values", enum_values)
        end

      _ ->
        nil
    end
  end

  @spec enum_values_for_field(String.t()) :: [String.t()]
  defp enum_values_for_field("type"), do: @type_enum_values
  defp enum_values_for_field("status"), do: @status_enum_values
  defp enum_values_for_field(_), do: []

  # --- resolve & classify helpers ---

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
