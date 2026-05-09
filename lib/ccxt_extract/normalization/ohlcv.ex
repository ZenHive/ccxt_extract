defmodule CcxtExtract.Normalization.OHLCV do
  @moduledoc """
  Derive `field_maps["ohlcv"]` from a per-exchange `parse_methods.json` entry.

  Scope (Tasks 78 + 78b + 78e): handles exchanges whose `parseOHLCV` body is a
  single `ReturnStatement` with an `ArrayExpression` of safe-call elements.
  Both array-input (`safeInteger(ohlcv, 0)`, binance-family) and object-input
  (`safeInteger(ohlcv, 't')`, hyperliquid/lighter/htx/bitmex) bodies are in
  scope. Hybrid `Array.isArray` and scrambled-coercion shapes remain deferred
  to Tasks 78c/78d.

  ## Output

      %{
        "branches" => [
          %{
            "guard" => %{
              "kind" => "always",
              # "input_shape" is optional — omitted on mixed-locator and
              # no-pure-slots paths (see "guard.input_shape" prose below).
              "input_shape" => "array" | "object"
            },
            "shape" => "array",
            "field_map" => %{
              "timestamp" => slot(),
              "open"/"high"/"low"/"close"/"volume" => slot() | discriminated_slot()
            },
            "_unresolved_reason" => nil | String.t()
          }
        ],
        "extras" => [],
        "_unresolved_reason" => nil | String.t()
      }

  Each pure `slot()` is
  `%{"index" => integer() | nil, "key" => String.t() | nil, "coercion" => method, "format" => "ms" | "iso8601" | nil}`
  — exactly one of `"index"` or `"key"` is non-nil per slot. Method is drawn
  from the closed vocabulary `["safeInteger", "safeInteger2", "safeNumber",
  "safeNumber2"]` for OHLC/volume, plus the timestamp-only secondary family
  `["parse8601"]` (Task 78e — bitmex's `this.parse8601(this.safeString(ohlcv,
  'timestamp'))` shape, emits `format: "iso8601"`).

  `guard.input_shape` is `"array"` when every populated pure slot has
  `"index"` set, `"object"` when every populated pure slot has `"key"` set.
  A genuinely mixed branch (defensive — no real exchange does this) appends
  `mixed_input_locators` to the branch reason and omits `input_shape`.

  A `discriminated_slot()` (used when `volume`'s index resolves through
  `volumeIndex = inverse-test ? a : b`) is
  `%{"kind" => "discriminated", "discriminator" => "market.inverse",
     "true" => %{"index" => integer(), "coercion" => method},
     "false" => %{"index" => integer(), "coercion" => method}}`.

  Unresolvable slots emit `nil`; the branch's `_unresolved_reason` carries
  the explanation (e.g. bitmex's bare-Identifier `volume` bound to
  `convertFromRawQuantity` → `"volume:non_safe_coercion:convertFromRawQuantity"`).
  Honesty rule: every populated slot is provable from AST; nothing is fabricated.
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  @safe_int ~w(safeInteger safeInteger2)
  @safe_num ~w(safeNumber safeNumber2)
  # Timestamp-only secondary coercion family (Task 78e). `parse8601` accepts
  # a string and returns a UTC ms integer — same observable output as
  # `safeInteger`, but the raw exchange value is ISO-8601 not ms. The slot's
  # `format` field disambiguates.
  @parse_iso ~w(parse8601)
  @field_order ~w(timestamp open high low close volume)

  @typedoc "Pure (non-discriminated) slot record."
  @type slot :: %{required(String.t()) => term()}

  @doc """
  Derive `field_maps["ohlcv"]` from a `parse_methods.json` per-exchange
  entry (or `nil`).

  Returns `nil` when the exchange has no `parseOHLCV` override (the carrier
  signals "absent" via slot `nil` plus its `not_yet_derived` reason).
  Returns a populated record — possibly with `branches: []` and a non-nil
  `_unresolved_reason` — when `parseOHLCV` exists but the body shape isn't
  a single recognized return array.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(parse_methods_entry) when is_map(parse_methods_entry) do
    case get_in(parse_methods_entry, ["parse_methods", "parseOHLCV"]) do
      ast when is_map(ast) -> derive_from_ast(ast)
      _ -> nil
    end
  end

  def derive(_), do: nil

  # --- Internals ---

  @spec derive_from_ast(map()) :: map()
  defp derive_from_ast(ast) do
    body_stmts = get_in(ast, ["body", "body"]) || []
    bindings = ASTHelpers.collect_bindings(body_stmts)

    case walk_return_array(body_stmts) do
      {:array, elements} -> build_branch(elements, bindings)
      :ambiguous -> unresolved("ambiguous_return_shape")
      :non_array -> unresolved("non_array_return")
      :not_found -> unresolved("no_return_array")
    end
  end

  @spec walk_return_array([map()]) :: {:array, [map()]} | :ambiguous | :non_array | :not_found
  defp walk_return_array(stmts) do
    case collect_returns(stmts) do
      [%{"type" => "ArrayExpression", "elements" => els}] when is_list(els) -> {:array, els}
      [_single] -> :non_array
      [] -> :not_found
      _multiple -> :ambiguous
    end
  end

  # Collects every `ReturnStatement.argument` reachable in the method's own
  # control flow. Stops at function-body boundaries — a callback or arrow fn
  # nested inside `parseOHLCV` belongs to a different scope, and its returns
  # must not be confused with the parser's. Hybrid bodies (one `return [...]`
  # plus another `return {...}`) surface as a multi-element list, classify as
  # `:ambiguous`, and emit null + reason rather than a fabricated always-array.
  @spec collect_returns(term()) :: [term()]
  defp collect_returns(%{"type" => "ReturnStatement", "argument" => arg}), do: [arg]

  defp collect_returns(%{"type" => type})
       when type in ["FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression"],
       do: []

  defp collect_returns(node) when is_map(node) do
    node |> Map.values() |> Enum.flat_map(&collect_returns/1)
  end

  defp collect_returns(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_returns/1)
  end

  defp collect_returns(_), do: []

  @spec build_branch([map()], [{String.t(), map()}]) :: map()
  defp build_branch(elements, bindings) do
    {field_map, branch_reason} = build_field_map(elements, bindings)
    {guard, branch_reason_final} = annotate_input_shape(field_map, branch_reason)

    %{
      "branches" => [
        %{
          "guard" => guard,
          "shape" => "array",
          "field_map" => field_map,
          "_unresolved_reason" => branch_reason_final
        }
      ],
      "extras" => [],
      "_unresolved_reason" => nil
    }
  end

  # Inspect populated pure slots to decide whether the parser reads its input
  # by integer index (`array`) or string key (`object`). Discriminated and
  # honest-null slots are excluded from the determination — they don't carry
  # a locator at the top level. A genuinely mixed branch (defensive — no real
  # exchange does this) appends `mixed_input_locators` to the branch reason
  # and omits `input_shape` from the guard. When no pure slots are populated
  # (e.g. all unresolved, or the >6-element fail-closed case), the guard
  # stays at the legacy `%{"kind" => "always"}` shape.
  @spec annotate_input_shape(map(), String.t() | nil) :: {map(), String.t() | nil}
  defp annotate_input_shape(field_map, branch_reason) do
    case derive_input_shape(field_map) do
      :array -> {%{"kind" => "always", "input_shape" => "array"}, branch_reason}
      :object -> {%{"kind" => "always", "input_shape" => "object"}, branch_reason}
      :mixed -> {%{"kind" => "always"}, append_reason(branch_reason, "mixed_input_locators")}
      :no_pure_slots -> {%{"kind" => "always"}, branch_reason}
    end
  end

  @spec derive_input_shape(map()) :: :array | :object | :mixed | :no_pure_slots
  defp derive_input_shape(field_map) do
    pure_slots =
      field_map
      |> Map.values()
      |> Enum.filter(fn
        slot when is_map(slot) -> Map.has_key?(slot, "index") and Map.has_key?(slot, "key")
        _ -> false
      end)

    cond do
      pure_slots == [] -> :no_pure_slots
      Enum.all?(pure_slots, &(not is_nil(&1["key"]))) -> :object
      Enum.all?(pure_slots, &(not is_nil(&1["index"]))) -> :array
      true -> :mixed
    end
  end

  @spec append_reason(String.t() | nil, String.t()) :: String.t()
  defp append_reason(nil, new), do: new
  defp append_reason(existing, new), do: existing <> ";" <> new

  @spec build_field_map([map()], [{String.t(), map()}]) :: {map(), String.t() | nil}
  defp build_field_map(elements, _bindings) when length(elements) > 6 do
    # Honesty rule: a 7+-column return (e.g. kraken's
    # `[ts, o, h, l, c, vwap, vol]`) cannot be slot-mapped without
    # disambiguating which column is volume vs. an extra. Bail out instead
    # of silently misassigning the 6th element. Task 78d introduces an
    # `extras` list for the >6 case; until then, fail closed.
    empty = Map.new(@field_order, &{&1, nil})
    {empty, "extras_not_supported:#{length(elements)}_elements"}
  end

  defp build_field_map(elements, bindings) do
    padded = elements ++ List.duplicate(:missing, max(0, 6 - length(elements)))

    {pairs, reasons} =
      @field_order
      |> Enum.zip(Enum.take(padded, 6))
      |> Enum.map_reduce([], fn {field, element}, acc ->
        case classify_element(field, element, bindings) do
          {:ok, slot} -> {{field, slot}, acc}
          {:error, reason} -> {{field, nil}, [{field, reason} | acc]}
        end
      end)

    branch_reason =
      case Enum.reverse(reasons) do
        [] -> nil
        list -> Enum.map_join(list, ";", fn {f, r} -> "#{f}:#{r}" end)
      end

    {Map.new(pairs), branch_reason}
  end

  @spec classify_element(String.t(), :missing | map(), [{String.t(), map()}]) ::
          {:ok, map()} | {:error, String.t()}
  defp classify_element(_field, :missing, _bindings), do: {:error, "missing_from_return_array"}

  # Timestamp slot accepts both the integer-ms vocab (`safeInteger*`) and the
  # ISO-8601 wrapper (`parse8601(safeString(ohlcv, key))`, Task 78e). The two
  # paths emit the same slot record except for `format` (`"ms"` vs `"iso8601"`).
  # parse8601 is timestamp-only — see classify_element/3 OHLC and volume arms,
  # which still gate on @safe_num.
  defp classify_element("timestamp", element, _bindings) do
    case classify_parse8601_wrapper(element) do
      {:ok, %{method: m, idx_arg: idx_arg}} ->
        build_locator_slot(idx_arg, m, "iso8601")

      :error ->
        case classify_safe_call(element) do
          {:ok, %{method: m, idx_arg: idx_arg}} when m in @safe_int ->
            build_locator_slot(idx_arg, m, "ms")

          {:ok, %{method: m}} when m in @safe_num ->
            {:error, "timestamp_uses_number_coercion:#{m}"}

          {:ok, %{method: m}} ->
            {:error, "non_safe_coercion:#{m}"}

          :error ->
            {:error, "non_call_element"}
        end
    end
  end

  defp classify_element("volume", element, bindings) do
    classify_volume(element, bindings)
  end

  defp classify_element(_field, element, _bindings) do
    case classify_safe_call(element) do
      {:ok, %{method: m, idx_arg: idx_arg}} when m in @safe_num ->
        build_locator_slot(idx_arg, m, nil)

      {:ok, %{method: m}} when m in @safe_int ->
        {:error, "ohlc_uses_integer_coercion:#{m}"}

      {:ok, %{method: m}} when m in @parse_iso ->
        # parse8601 outside the timestamp slot is meaningless for OHLC values.
        {:error, "non_safe_coercion:#{m}"}

      {:ok, %{method: m}} ->
        {:error, "non_safe_coercion:#{m}"}

      :error ->
        {:error, "non_call_element"}
    end
  end

  # Volume has three legitimate shapes:
  #   1. Direct safe_num call with literal int/string idx — pure slot.
  #   2. safe_num call with Identifier idx (`volumeIndex`) — discriminated slot
  #      via `volumeIndex = inverse-test ? a : b`.
  #   3. Bare Identifier element (`volume`) bound at the top of the parseOHLCV
  #      body to something we can't slot-map (e.g. bitmex's
  #      `convertFromRawQuantity`). Honest-null the slot, surface the binding's
  #      callee in the per-branch reason.
  @spec classify_volume(map(), [{String.t(), map()}]) :: {:ok, map()} | {:error, String.t()}
  defp classify_volume(%{"type" => "Identifier", "name" => name}, bindings) do
    classify_volume_identifier(name, bindings)
  end

  defp classify_volume(element, bindings) do
    case classify_safe_call(element) do
      {:ok, %{method: m, idx_arg: %{"type" => "Identifier", "name" => name}}}
      when m in @safe_num ->
        build_discriminated_volume(name, m, bindings)

      {:ok, %{method: m, idx_arg: idx_arg}} when m in @safe_num ->
        build_locator_slot(idx_arg, m, nil)

      {:ok, %{method: m}} when m in @safe_int ->
        {:error, "volume_uses_integer_coercion:#{m}"}

      {:ok, %{method: m}} when m in @parse_iso ->
        {:error, "non_safe_coercion:#{m}"}

      {:ok, %{method: m}} ->
        {:error, "non_safe_coercion:#{m}"}

      :error ->
        {:error, "non_call_element"}
    end
  end

  # bitmex shape: top-level `const volume = this.convertFromRawQuantity(market['symbol'],
  # this.safeString(ohlcv, 'volume'))`, then volume appears bare at index 5 of
  # the return array. The binding's init isn't in our closed safe-call vocab,
  # so the slot is honest-null with the callee surfaced as the reason.
  @spec classify_volume_identifier(String.t(), [{String.t(), map()}]) ::
          {:ok, map()} | {:error, String.t()}
  defp classify_volume_identifier(name, bindings) do
    case lookup_binding(name, bindings) do
      nil ->
        {:error, "volume_index_unbound:#{name}"}

      %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => %{"type" => "ThisExpression"},
          "property" => %{"type" => "Identifier", "name" => callee}
        }
      } ->
        {:error, "non_safe_coercion:#{callee}"}

      _other ->
        {:error, "non_call_init"}
    end
  end

  # Locator-shape dispatch shared by timestamp / OHLC / safe-call volume paths.
  # A Literal integer maps to an `index` (array-input); a Literal string maps to
  # a `key` (object-input). Any other shape (Identifier, BinaryExpression,
  # Literal{value: nil/true/...}) emits the existing closed-vocab reason.
  @spec build_locator_slot(map(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  defp build_locator_slot(%{"type" => "Literal", "value" => idx}, method, format) when is_integer(idx) do
    {:ok, %{"index" => idx, "key" => nil, "coercion" => method, "format" => format}}
  end

  defp build_locator_slot(%{"type" => "Literal", "value" => key}, method, format) when is_binary(key) do
    {:ok, %{"index" => nil, "key" => key, "coercion" => method, "format" => format}}
  end

  defp build_locator_slot(_idx_arg, method, _format) do
    {:error, "non_literal_index:#{method}"}
  end

  @spec build_discriminated_volume(String.t(), String.t(), [{String.t(), map()}]) ::
          {:ok, map()} | {:error, String.t()}
  defp build_discriminated_volume(name, method, bindings) do
    case resolve_volume_index(name, bindings) do
      {:ok, %{cons: cons, alt: alt}} ->
        {:ok,
         %{
           "kind" => "discriminated",
           "discriminator" => "market.inverse",
           "true" => %{"index" => cons, "coercion" => method},
           "false" => %{"index" => alt, "coercion" => method}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resolve_volume_index(String.t(), [{String.t(), map()}]) ::
          {:ok, %{cons: integer(), alt: integer()}} | {:error, String.t()}
  defp resolve_volume_index(name, bindings) do
    case lookup_binding(name, bindings) do
      %{
        "type" => "ConditionalExpression",
        "test" => test,
        "consequent" => %{"type" => "Literal", "value" => cons},
        "alternate" => %{"type" => "Literal", "value" => alt}
      }
      when is_integer(cons) and is_integer(alt) ->
        if inverse_discriminator?(test, bindings),
          do: {:ok, %{cons: cons, alt: alt}},
          else: {:error, "non_inverse_discriminator"}

      nil ->
        {:error, "volume_index_unbound:#{name}"}

      _ ->
        {:error, "volume_index_non_conditional"}
    end
  end

  # Recognizes `market.inverse`-shaped tests:
  #   market['inverse']                    (MemberExpression w/ Literal property "inverse")
  #   (market['inverse'])                  (ParenthesizedExpression around the above)
  #   this.safeBool(market, 'inverse', …)  (CallExpression)
  #   inverse                              (Identifier — bound transitively via `bindings`)
  #
  # The Identifier clause threads a visited-set through arity-3 to defend
  # against cyclic AST chains (`a -> b -> a`) that would otherwise infinite-loop.
  # Real JS const semantics forbid the cycle, but the AST representation can
  # carry one (codegen, future fixtures); the guard keeps the function total.
  @spec inverse_discriminator?(map(), [{String.t(), map()}]) :: boolean()
  defp inverse_discriminator?(node, bindings), do: inverse_discriminator?(node, bindings, MapSet.new())

  @spec inverse_discriminator?(map(), [{String.t(), map()}], MapSet.t()) :: boolean()
  defp inverse_discriminator?(%{"type" => "ParenthesizedExpression", "expression" => inner}, bindings, seen) do
    inverse_discriminator?(inner, bindings, seen)
  end

  defp inverse_discriminator?(
         %{
           "type" => "MemberExpression",
           "object" => %{"type" => "Identifier", "name" => "market"},
           "property" => %{"type" => "Literal", "value" => "inverse"}
         },
         _bindings,
         _seen
       ),
       do: true

  defp inverse_discriminator?(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "safeBool"}
           },
           "arguments" => [
             %{"type" => "Identifier", "name" => "market"},
             %{"type" => "Literal", "value" => "inverse"} | _
           ]
         },
         _bindings,
         _seen
       ),
       do: true

  defp inverse_discriminator?(%{"type" => "Identifier", "name" => name}, bindings, seen) do
    if MapSet.member?(seen, name) do
      false
    else
      case lookup_binding(name, bindings) do
        nil -> false
        init -> inverse_discriminator?(init, bindings, MapSet.put(seen, name))
      end
    end
  end

  defp inverse_discriminator?(_, _, _), do: false

  @spec lookup_binding(String.t(), [{String.t(), map()}]) :: map() | nil
  defp lookup_binding(name, bindings) do
    Enum.find_value(bindings, fn
      {^name, init} when is_map(init) -> init
      _ -> nil
    end)
  end

  @spec classify_safe_call(term()) ::
          {:ok, %{method: String.t(), idx_arg: map(), key_arg: map() | nil}} | :error
  defp classify_safe_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method}
         },
         "arguments" => [_obj, idx_arg | rest]
       }) do
    {:ok, %{method: method, idx_arg: idx_arg, key_arg: List.first(rest)}}
  end

  defp classify_safe_call(_), do: :error

  # Recognizes the bitmex timestamp shape `this.parse8601(this.safeString(ohlcv,
  # 'timestamp'))`. The outer call's callee is `parse8601`; its sole argument
  # is itself a `this.safeString(obj, key)` call whose `idx_arg` carries the
  # object key. Returns the same `%{method, idx_arg}` shape `classify_safe_call`
  # produces, with method pinned to "parse8601" — `build_locator_slot/3` then
  # emits the slot with `format: "iso8601"`.
  @spec classify_parse8601_wrapper(term()) :: {:ok, %{method: String.t(), idx_arg: map()}} | :error
  defp classify_parse8601_wrapper(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "parse8601"}
         },
         "arguments" => [
           %{
             "type" => "CallExpression",
             "callee" => %{
               "type" => "MemberExpression",
               "object" => %{"type" => "ThisExpression"},
               "property" => %{"type" => "Identifier", "name" => "safeString"}
             },
             "arguments" => [_obj, idx_arg | _rest]
           }
         ]
       }) do
    {:ok, %{method: "parse8601", idx_arg: idx_arg}}
  end

  defp classify_parse8601_wrapper(_), do: :error

  @spec unresolved(String.t()) :: map()
  defp unresolved(reason) do
    %{
      "branches" => [],
      "extras" => [],
      "_unresolved_reason" => reason
    }
  end
end
