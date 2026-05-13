defmodule CcxtExtract.Normalization.Market do
  @moduledoc """
  Derive `field_maps["market"]` from a per-exchange `parse_methods.json` entry.

  Scope (Task 79): handles exchanges whose `parseMarket` body contains a
  `ReturnStatement` returning either:
  - `this.safeMarketStructure(%ObjectExpression{})` — 22 corpus exchanges
  - `%ObjectExpression{}` directly — 21 corpus exchanges

  Both forms have the same per-field classification logic. Exchanges using
  `extend`, `Identifier`, or `TSAsExpression` return shapes are marked
  unresolved.

  ## Output

      %{
        "field_map" => %{
          "id"          => slot() | nil,
          "symbol"      => nil,      # structurally null (computed, not a direct key)
          "base"        => slot() | nil,
          ...  # all unified fields; nil when absent or outside closed vocab
          "precision"   => nil,      # structurally null: nested ObjectExpression
          "limits"      => nil,      # structurally null: nested ObjectExpression
          "info"        => nil       # structurally null: raw pass-through
        },
        "extras" => [%{"unified_key" => key, "key" => wire_key, "coercion" => method}],
        "_unresolved_reason" => nil | String.t()
      }

  Each `slot()` is `%{"key" => String.t(), "coercion" => method, "format" => nil}`.
  Method is drawn from the closed vocabulary `[safeString, safeString2, safeStringN,
  safeNumber, safeNumber2, safeInteger, safeInteger2, safeTimestamp, safeBool]`.

  `safeBool` is a parseMarket-specific extension (boolean market-type flags
  like `spot`, `swap`, `future`, `linear`, `inverse`, `option`, `contract`,
  `active`, `margin`, `tierBased`, `percentage`).

  ## Structurally-null fields

  - `symbol` — computed from base/quote/settle, not a direct safe-call
  - `info` — raw market object pass-through
  - `precision` — nested `ObjectExpression` with sub-fields (amount, price,
    cost, base, quote); emitted as nil with `_unresolved_reason: "nested_shape"`
    deferred to a future patch
  - `limits` — deeply-nested `ObjectExpression` (amount.min/max, price.min/max,
    cost.min/max, leverage.min/max); emitted as nil with `nested_shape` reason
  - `expiryDatetime` — derived from `expiry` via `iso8601`, not a safe-call
  - `created` fields using `parse8601` are outside the slot vocab (deferred)

  ## `_unresolved_reason` vocabulary

  - `nil` — ObjectExpression return pattern found
  - `"non_safe_market_return:<callee>"` — return is a non-slottable call
  - `"no_return_statement"` — body has no `ReturnStatement`

  ## Three-Strikes Patch counter

  # Patch count: 0/3

  Authorized future patches:
  - Patch 1 candidates: precision/limits nested extraction; Identifier-binding
    resolution for `base`, `quote`, `settle`, etc. (most are pre-computed vars).
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @unified_fields ~w(
    id symbol base quote settle baseId quoteId settleId
    type subType spot margin swap future option active contract
    linear inverse tierBased percentage contractSize expiry expiryDatetime
    strike optionType taker maker
    precision limits info created
  )

  @safe_str ~w(safeString safeString2 safeStringN)
  @safe_num ~w(safeNumber safeNumber2)
  @safe_int ~w(safeInteger safeInteger2)
  @safe_ts ~w(safeTimestamp)
  @safe_bool ~w(safeBool)
  @slot_vocab @safe_str ++ @safe_num ++ @safe_int ++ @safe_ts ++ @safe_bool

  # Fields that are structurally null across all exchanges — cannot be
  # expressed as a direct `this.safe*(market, 'key')` call.
  # - symbol: computed from base/quote/settle (often a BinaryExpression)
  # - info: raw object pass-through (Identifier)
  # - precision: nested ObjectExpression (deferred — nested_shape)
  # - limits: deeply-nested ObjectExpression (deferred — nested_shape)
  # - expiryDatetime: iso8601(expiry) derivation
  @structurally_null ~w(symbol info precision limits expiryDatetime)

  @doc """
  Derive the market field map from a `parse_methods.json` entry for one exchange.

  Returns `nil` when there is no `parseMarket` override. Returns a map with
  a non-nil `_unresolved_reason` when the return structure is not the
  slottable ObjectExpression pattern.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parseMarket"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  @doc "Returns the list of unified market field names."
  @spec unified_fields() :: [String.t()]
  def unified_fields, do: @unified_fields

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []
    bindings = ASTHelpers.collect_bindings(body_stmts)

    case find_market_object(body_stmts) do
      {:ok, properties} -> build_result(properties, bindings)
      {:error, reason} -> unresolved(reason)
    end
  end

  # Find the last ReturnStatement returning either:
  # - `this.safeMarketStructure({...})`
  # - `{...}` directly (ObjectExpression)
  @spec find_market_object([map()]) :: {:ok, [map()]} | {:error, String.t()}
  defp find_market_object(body_stmts) do
    last_return =
      body_stmts
      |> Enum.filter(&match?(%{"type" => "ReturnStatement"}, &1))
      |> List.last()

    case last_return do
      nil ->
        {:error, "no_return_statement"}

      # `return this.safeMarketStructure({...})`
      %{
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => "safeMarketStructure"}
          },
          "arguments" => [%{"type" => "ObjectExpression", "properties" => properties} | _]
        }
      } ->
        {:ok, properties}

      # `return {...}` (direct ObjectExpression)
      %{"argument" => %{"type" => "ObjectExpression", "properties" => properties}} ->
        {:ok, properties}

      # Some other call — extract callee name for the unresolved reason.
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
        {:error, "non_safe_market_return:#{callee_name}"}

      _ ->
        {:error, "no_return_statement"}
    end
  end

  # ---------------------------------------------------------------------------
  # Result assembly
  # ---------------------------------------------------------------------------

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
          when is_binary(wire_key) and method in @slot_vocab ->
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

  # ---------------------------------------------------------------------------
  # Per-field classification
  # ---------------------------------------------------------------------------

  @spec classify_unified_field(String.t(), map() | nil, [{String.t(), map()}]) :: map() | nil
  defp classify_unified_field(_field, nil, _bindings), do: nil

  defp classify_unified_field(field, _value_node, _bindings) when field in @structurally_null, do: nil

  defp classify_unified_field(_field, value_node, bindings) do
    classify_scalar_field(value_node, bindings)
  end

  @spec classify_scalar_field(map(), [{String.t(), map()}]) :: map() | nil
  defp classify_scalar_field(value_node, bindings) do
    case resolve_then_classify(value_node, bindings) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @slot_vocab ->
        build_slot(idx_arg, method, nil)

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  @spec resolve_then_classify(map() | nil, [{String.t(), map()}]) ::
          {:ok, %{method: String.t(), idx_arg: map()}} | :error
  defp resolve_then_classify(nil, _bindings), do: :error

  defp resolve_then_classify(%{"type" => "Identifier", "name" => name}, bindings) do
    case lookup_binding(name, bindings) do
      nil -> :error
      init -> classify_safe_call(init)
    end
  end

  defp resolve_then_classify(%{"type" => "CallExpression"} = node, _bindings) do
    classify_safe_call(node)
  end

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
