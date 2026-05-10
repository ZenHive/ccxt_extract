defmodule CcxtExtract.Normalization.Ticker do
  @moduledoc """
  Derive `field_maps["ticker"]` from a per-exchange `parse_methods.json` entry.

  Scope (Task 74): handles exchanges whose `parseTicker` body contains a
  `ReturnStatement` returning `this.safeTicker(%ObjectExpression{}, market)`.
  Fields in the object expression are classified by resolving binding
  references to const variable declarations in the function body.

  ## Output

      %{
        "field_map" => %{
          "timestamp" => slot() | nil,
          "high"      => slot() | nil,
          ...  # all 22 unified fields; nil when absent or outside closed vocab
        },
        "extras" => [%{"unified_key" => key, "key" => wire_key, "coercion" => method}],
        "_unresolved_reason" => nil | String.t()
      }

  Each `slot()` is
  `%{"key" => String.t(), "coercion" => method, "format" => "ms" | "s" | nil}`
  — always key-based (no `"index"` field). Method is drawn from the closed
  vocabulary `[safeString, safeString2, safeStringN, safeNumber, safeNumber2,
  safeInteger, safeInteger2, safeTimestamp]`.

  Three fields are structurally null for all exchanges: `symbol` (uses
  `safeSymbol` — not a direct key lookup), `datetime` (derived from
  `timestamp` via `iso8601`, not from raw), and `info` (the raw ticker
  object pass-through — not a safe-call).

  `_unresolved_reason` is nil when the `safeTicker` return pattern was found
  (even if many individual fields are null); non-nil when the return structure
  is not the slottable pattern (e.g. kucoin returns `parseContractTicker`).
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @unified_fields ~w(symbol timestamp datetime high low bid bidVolume ask askVolume
                     vwap open close last previousClose change percentage average
                     baseVolume quoteVolume markPrice indexPrice info)

  @safe_str ~w(safeString safeString2 safeStringN)
  @safe_num ~w(safeNumber safeNumber2)
  @safe_int ~w(safeInteger safeInteger2)
  @safe_ts ~w(safeTimestamp)
  @slot_vocab @safe_str ++ @safe_num ++ @safe_int ++ @safe_ts

  @doc """
  Derive the ticker field map from a `parse_methods.json` entry for one exchange.

  Returns `nil` when there is no `parseTicker` override (the exchange inherits
  from a base class). Returns a map with a non-nil `_unresolved_reason` when
  the return structure is not the slottable `safeTicker` pattern.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parseTicker"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  @doc "Returns the list of 22 unified ticker field names."
  @spec unified_fields() :: [String.t()]
  def unified_fields, do: @unified_fields

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []
    bindings = ASTHelpers.collect_bindings(body_stmts)

    case find_safe_ticker_object(body_stmts) do
      {:ok, properties} -> build_result(properties, bindings)
      {:error, reason} -> unresolved(reason)
    end
  end

  # Finds the top-level ReturnStatement returning `this.safeTicker({...}, market)`.
  # Returns {:ok, properties} where properties is the ObjectExpression's property list,
  # or {:error, reason} when the pattern doesn't match.
  @spec find_safe_ticker_object([map()]) :: {:ok, [map()]} | {:error, String.t()}
  defp find_safe_ticker_object(body_stmts) do
    return_stmt = Enum.find(body_stmts, &(is_map(&1) and &1["type"] == "ReturnStatement"))

    case return_stmt do
      nil ->
        {:error, "no_return_statement"}

      %{
        "argument" => %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => "safeTicker"}
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
        {:error, "non_safe_ticker_return:#{callee_name}"}

      _ ->
        {:error, "no_return_statement"}
    end
  end

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
  # Computed properties ({[expr]: value}) have a runtime-determined key — not statically slottable.
  defp key_from_property(%{"computed" => true}), do: nil
  defp key_from_property(%{"key" => %{"name" => name}}), do: name
  defp key_from_property(%{"key" => %{"value" => value}}) when is_binary(value), do: value
  defp key_from_property(_), do: nil

  @spec classify_unified_field(String.t(), map() | nil, [{String.t(), map()}]) :: map() | nil
  defp classify_unified_field(_field, nil, _bindings), do: nil

  defp classify_unified_field("timestamp", value_node, bindings) do
    classify_timestamp_field(value_node, bindings)
  end

  defp classify_unified_field(_field, value_node, bindings) do
    classify_generic_field(value_node, bindings)
  end

  # Format-aware classification for the timestamp field only.
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

  # All non-timestamp fields always emit format: nil.
  @spec classify_generic_field(map(), [{String.t(), map()}]) :: map() | nil
  defp classify_generic_field(value_node, bindings) do
    case resolve_then_classify(value_node, bindings) do
      {:ok, %{method: method, idx_arg: idx_arg}} when method in @slot_vocab ->
        build_slot(idx_arg, method, nil)

      _ ->
        nil
    end
  end

  # Resolves an Identifier through bindings before classifying; classifies
  # CallExpression nodes directly.
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

  # Emits a slot only when the key argument is a string literal — any other
  # shape (computed key, another call, etc.) is an honest null.
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

  @spec classify_safe_call(term()) ::
          {:ok, %{method: String.t(), idx_arg: map()}} | :error
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

  @spec unresolved(String.t()) :: map()
  defp unresolved(reason) do
    null_field_map = Map.new(@unified_fields, fn field -> {field, nil} end)
    %{"field_map" => null_field_map, "extras" => [], "_unresolved_reason" => reason}
  end
end
