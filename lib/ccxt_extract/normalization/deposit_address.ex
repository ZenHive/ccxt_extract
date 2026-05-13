defmodule CcxtExtract.Normalization.DepositAddress do
  @moduledoc """
  Derive `field_maps["depositAddress"]` from a per-exchange `parse_methods.json`
  entry.

  Scope (Task 82): handles exchanges whose `parseDepositAddress` body returns an
  ObjectExpression (directly or wrapped in a TSAsExpression) built from
  variable bindings to safe* calls.

  ## Output

      %{
        "field_map" => %{
          "currency" => slot() | nil,
          "address"  => slot() | nil,
          "tag"      => slot() | nil,
          "network"  => slot() | nil,
          "info"     => nil
        },
        "extras" => [%{"unified_key" => key, "key" => wire_key, "coercion" => method}],
        "_unresolved_reason" => nil | String.t()
      }

  Each scalar `slot()` is `%{"key", "coercion", "format"}` (always key-based,
  no index field).

  ## Structurally-null fields

  - `info` — raw-pass-through `Identifier`, not a safe* call
  - `network` — frequently resolved via `getNetworkCodeByNetworkUrl(...)` or
    similar resolver call rather than a direct safe* dict lookup; emits nil
    in the closed-vocab honesty rule when the pattern is not recognized

  ## `_unresolved_reason` vocabulary

  - `nil` — ObjectExpression return resolved cleanly; per-field slots may
    still be nil within the closed-vocab honesty rule
  - `"no_return_statement"` — body has no `ReturnStatement`
  - `"non_object_return:<type>"` — last return yields something other than
    an ObjectExpression (after unwrapping any TSAsExpression wrapper)

  ## Three-Strikes Patch counter

  # Patch count: 0/3

  Authorized future patches:
  - Patch 1 candidates: resolver-call tracing (getNetworkCodeByNetworkUrl) to
    populate the network slot.
  - Patch 3 escalation: migrate persistently-gappy exchanges to
    `priv/overrides/<id>.json`.
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @unified_fields ~w(currency address tag network info)

  @safe_str ~w(safeString safeString2 safeStringN)
  @safe_str_lower ~w(safeStringLower safeStringUpper)
  @safe_num ~w(safeNumber safeNumber2)
  @safe_int ~w(safeInteger safeInteger2)
  @safe_ts ~w(safeTimestamp)
  @scalar_vocab @safe_str ++ @safe_str_lower ++ @safe_num ++ @safe_int ++ @safe_ts

  # Fields that are structurally null — not derived by direct safe* lookup.
  @structurally_null ~w(info)

  @doc """
  Derive the deposit-address field map from a `parse_methods.json` entry for
  one exchange.

  Returns `nil` when there is no `parseDepositAddress` override. Returns a map
  with a non-nil `_unresolved_reason` when the return structure is not a
  slottable ObjectExpression.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parseDepositAddress"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  @doc "Returns the list of 5 unified depositAddress field names."
  @spec unified_fields() :: [String.t()]
  def unified_fields, do: @unified_fields

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []
    bindings = ASTHelpers.collect_bindings(body_stmts)

    case find_deposit_address_object(body_stmts) do
      {:ok, properties} -> build_result(properties, bindings)
      {:error, reason} -> unresolved(reason)
    end
  end

  # Finds the last ReturnStatement and unwraps TSAsExpression if present.
  # Returns {:ok, properties} when the return yields an ObjectExpression,
  # or {:error, reason} otherwise.
  @spec find_deposit_address_object([map()]) :: {:ok, [map()]} | {:error, String.t()}
  defp find_deposit_address_object(body_stmts) do
    last_return = body_stmts |> Enum.filter(&match?(%{"type" => "ReturnStatement"}, &1)) |> List.last()

    case last_return do
      nil ->
        {:error, "no_return_statement"}

      %{"argument" => arg} ->
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
