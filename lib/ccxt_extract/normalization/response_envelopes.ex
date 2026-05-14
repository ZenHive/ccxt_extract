defmodule CcxtExtract.Normalization.ResponseEnvelopes do
  @moduledoc """
  Derive `response_envelopes` from `parse_methods.json` + `fetch_methods.json`
  per-exchange entries.

  Scope (Task 83b): for every fetcher→parser dispatch pair known from
  `parse_dispatch`, walk the fetcher body in `fetch_methods.json` to locate
  the first `this.safeList(response, …)` or `this.safeValue(response, …)` call
  that supplies the data passed on to the parser. The extracted key (or `null`
  when the fetcher passes `response` directly) plus fallback keys (`safeList2` /
  `safeValue2` / `safeListN` / `safeValueN`) and the literal default are the
  per-fetcher envelope record.

  ## Output

      %{
        "_unresolved_reason" => nil | String.t(),
        "ticker"           => nil | per_fetcher_map(),
        "trade"            => nil | per_fetcher_map(),
        "ohlcv"            => nil | per_fetcher_map(),
        "order"            => nil | per_fetcher_map(),
        "position"         => nil | per_fetcher_map(),
        "balance"          => nil | per_fetcher_map(),
        "market"           => nil | per_fetcher_map(),
        "transaction"      => nil | per_fetcher_map(),
        "deposit_address"  => nil | per_fetcher_map()
      }

  Each `per_fetcher_map()` is `%{fetcher_name => fetcher_entry()}` where
  `fetcher_entry()` is either:

  - `%{"key" => nil | String.t(), "fallback_keys" => [String.t()], "default" => term()}`
    — `"key": null` means the fetcher passes `response` directly to the parser;
    `"key": "rows"` means it first calls `safeList(response, "rows", …)`.
  - `%{"_unresolved_reason" => String.t()}`
    — one of four closed-vocab strings (see module attribute below).

  `_unresolved_reason` at the top-level block is `nil` when at least one
  parser type was attempted (even if individual fetchers are unresolved), and
  the scaffold sentinel `"not_yet_derived"` only when `derive/2` was never
  reached (i.e., this module is not yet wired in — retained for
  forward-compat with the carrier stub, but this module always returns `nil`
  or a per-type map, never `"not_yet_derived"`).

  ## Closed-vocab `_unresolved_reason` strings

  - `"no_fetcher_method_body"` — `fetch_methods.json` has no entry for this fetcher.
  - `"no_safe_value_call"` — fetcher body has no `safeValue`/`safeList`/etc.
    call against `response`.
  - `"non_literal_key"` — first arg to `safeValue`/`safeList` is a variable
    (not a string literal); key is not statically derivable.
  - `"nested_response_unwrap"` — first arg to a binding's `safeValue`/`safeList`
    is a sub-property of `response` (e.g. `safeList(response.payload, "rows", …)`);
    multi-level unwrap is not statically resolved at this tier. Direct
    member-access returns (`return this.parseTrades(response.payload, …)`)
    DO resolve the property as the envelope key — see Task 83b audit F3.

  Top-level `_unresolved_reason` carries the same closed vocab plus:

  - `"no_fetcher_dispatch"` — `parse_dispatch` has entries but none are
    fetcher names (only mutators like `createOrder` / `transfer` / `describe`),
    so every parser-type slot is `nil`. The derivation ran and found nothing.
  """

  # The CCXT methods we recognise as response-unwrap calls.
  @safe_list_methods ~w(safeList safeList2 safeListN)
  @safe_value_methods ~w(safeValue safeValue2 safeValueN)
  @safe_response_methods @safe_list_methods ++ @safe_value_methods

  # Parser-type → canonical parse* function names (N:1 fetcher→parser).
  # Audit F1 (Task 83b follow-up): plural forms (parseTickers, parseOHLCVs,
  # parseDepositAddresses) DO exist in the corpus — binance/okx alone have
  # 55+ parseTickers callsites — and must be grouped with their singular
  # counterparts so the fetcher dispatch routes through.
  @parser_type_to_parse_fns %{
    "ticker" => ~w(parseTicker parseTickers),
    "trade" => ~w(parseTrade parseTrades),
    "ohlcv" => ~w(parseOHLCV parseOHLCVs),
    "order" => ~w(parseOrder parseOrders),
    "position" => ~w(parsePosition parsePositions),
    "balance" => ~w(parseBalance),
    "market" => ~w(parseMarket parseMarkets),
    "transaction" => ~w(parseTransaction parseTransactions),
    "deposit_address" => ~w(parseDepositAddress parseDepositAddresses)
  }

  @doc """
  Derive `response_envelopes` for one exchange.

  `parse_methods_entry` is the per-exchange entry from `parse_methods.json`
  (carries `parse_dispatch`, which maps fetcher → [parser_fn]).
  `fetch_methods_entry` is the per-exchange entry from `fetch_methods.json`
  (carries `fetch_methods`, which maps method_name → body AST record).

  Returns `nil` when `parse_methods_entry` is `nil` (the exchange has no
  `parse_dispatch`). Returns a populated map otherwise — individual parser
  types are `nil` when no fetcher dispatches to them.
  """
  @spec derive(map() | nil, map() | nil) :: map() | nil
  def derive(nil, _fetch_methods_entry), do: nil

  def derive(parse_methods_entry, fetch_methods_entry) when is_map(parse_methods_entry) do
    parse_dispatch = Map.get(parse_methods_entry, "parse_dispatch") || %{}
    fetch_methods = fetch_methods_from_entry(fetch_methods_entry)

    if map_size(parse_dispatch) == 0 do
      nil
    else
      build_result(parse_dispatch, fetch_methods)
    end
  end

  def derive(_parse_methods_entry, _fetch_methods_entry), do: nil

  # ---------------------------------------------------------------------------
  # Internal derivation
  # ---------------------------------------------------------------------------

  @spec fetch_methods_from_entry(map() | nil) :: map()
  defp fetch_methods_from_entry(nil), do: %{}
  defp fetch_methods_from_entry(%{"fetch_methods" => methods}) when is_map(methods), do: methods
  defp fetch_methods_from_entry(_), do: %{}

  @spec build_result(map(), map()) :: map()
  defp build_result(parse_dispatch, fetch_methods) do
    parser_slots =
      Map.new(@parser_type_to_parse_fns, fn {parser_type, parse_fns} ->
        fetchers = fetchers_for_type(parse_dispatch, parse_fns)
        {parser_type, derive_for_type(fetchers, fetch_methods)}
      end)

    # Audit F5 (Task 83b follow-up): when `parse_dispatch` has entries but
    # none are fetcher names (only mutators / non-fetcher dispatchers like
    # `describe`, `transfer`, `createOrder`), every parser-type slot is `nil`.
    # Reporting `_unresolved_reason: nil` here would falsely signal "derived
    # cleanly." Surface a distinct top-level reason instead.
    top_reason =
      if Enum.all?(parser_slots, fn {_k, v} -> is_nil(v) end) do
        "no_fetcher_dispatch"
      end

    Map.put(parser_slots, "_unresolved_reason", top_reason)
  end

  # Collect all `fetch*` method names whose parse_dispatch list includes any
  # of the canonical parse functions for this parser type. Non-fetcher
  # dispatchers (createOrder, cancelOrder, editSpotOrder, …) also call
  # parsers on their response, but response-envelope semantics — the static
  # safeList/safeValue unwrap of an outer-key wrapper — are a fetcher-shaped
  # contract; mutator round-trips are out of scope for Task 83b.
  @spec fetchers_for_type(map(), [String.t()]) :: [String.t()]
  defp fetchers_for_type(parse_dispatch, parse_fns) do
    parse_fn_set = MapSet.new(parse_fns)

    Enum.flat_map(parse_dispatch, fn {fetcher, dispatched_fns} ->
      dispatched_set = MapSet.new(dispatched_fns)

      cond do
        not String.starts_with?(fetcher, "fetch") -> []
        MapSet.disjoint?(parse_fn_set, dispatched_set) -> []
        true -> [fetcher]
      end
    end)
  end

  # Derive the per-fetcher map for one parser type.
  # Returns nil when no fetchers dispatch to this parser type.
  @spec derive_for_type([String.t()], map()) :: map() | nil
  defp derive_for_type([], _fetch_methods), do: nil

  defp derive_for_type(fetchers, fetch_methods) do
    Map.new(fetchers, fn fetcher ->
      {fetcher, derive_for_fetcher(fetcher, fetch_methods)}
    end)
  end

  @spec derive_for_fetcher(String.t(), map()) :: map()
  defp derive_for_fetcher(fetcher_name, fetch_methods) do
    case Map.get(fetch_methods, fetcher_name) do
      nil ->
        unresolved("no_fetcher_method_body")

      %{"body" => %{"body" => body_stmts}} when is_list(body_stmts) ->
        derive_from_body(body_stmts)

      _ ->
        unresolved("no_fetcher_method_body")
    end
  end

  # Walk the body for variable declarations that bind this.safeList/safeValue(response, ...)
  # then check the return statement to see which bound variable (if any) is passed to the parser.
  @spec derive_from_body([map()]) :: map()
  defp derive_from_body(body_stmts) do
    # Collect bindings: var_name → {method, key, fallback_keys, default}
    response_bindings = collect_response_bindings(body_stmts)

    # Find what the return statement passes as first arg to the parse call.
    case find_return_first_arg(body_stmts) do
      nil ->
        # No parseFoo call as a return (some fetchers return via assignment or conditional)
        # Fall back to the first safeList/safeValue binding against response.
        derive_from_first_binding(response_bindings)

      {:inline_binding, binding} ->
        # Audit F2/F3 (Task 83b follow-up): the parser arg is an inline
        # `this.safeList(response, "k", default)` call, or a direct
        # `response["k"]` / `response.k` member access. Whitebit/kraken/bitget
        # use the first shape; bitso/coinex/coinmate/bittrade/zaif use the
        # second.
        binding

      "response" ->
        # Passes response directly — no envelope unwrap.
        %{"key" => nil, "fallback_keys" => [], "default" => nil}

      var_name ->
        case Map.get(response_bindings, var_name) do
          nil ->
            # The return variable is not bound to a safeList/safeValue(response, ...).
            # Check if the body has ANY direct safeList/safeValue(response) call at all.
            derive_from_first_binding(response_bindings)

          binding ->
            binding
        end
    end
  end

  # Find the first `return this.parseX(arg0, ...)` statement and report what
  # arg0 supplies to the parser. Three shapes:
  #   - `Identifier("response")` / other Identifier → return its name (string)
  #   - inline `this.safe{List,Value}(response, "k", default)` → `{:inline_binding, binding}`
  #   - `response["k"]` / `response.k` (one-level) → `{:inline_binding, key_binding}`
  # Returns nil when the return doesn't match the `return this.parse*(...)` shape.
  @spec find_return_first_arg([map()]) :: nil | String.t() | {:inline_binding, map()}
  defp find_return_first_arg(stmts) do
    Enum.find_value(stmts, fn stmt ->
      case stmt do
        %{
          "type" => "ReturnStatement",
          "argument" => %{
            "type" => "CallExpression",
            "callee" => %{
              "type" => "MemberExpression",
              "object" => %{"type" => "ThisExpression"},
              "property" => %{"type" => "Identifier", "name" => callee_name}
            },
            "arguments" => [first_arg | _]
          }
        }
        when is_binary(callee_name) ->
          classify_return_first_arg(first_arg)

        _ ->
          nil
      end
    end)
  end

  # Classify the first-arg AST passed to a `return this.parse*(arg0, ...)` call.
  @spec classify_return_first_arg(map()) :: nil | String.t() | {:inline_binding, map()}
  defp classify_return_first_arg(arg) do
    case extract_identifier_name(arg) do
      nil -> classify_non_identifier_return_arg(arg)
      name -> name
    end
  end

  @spec classify_non_identifier_return_arg(map()) :: {:inline_binding, map()} | nil
  defp classify_non_identifier_return_arg(arg) do
    cond do
      binding = extract_response_safe_call(arg) ->
        {:inline_binding, binding}

      key = extract_response_member_key(arg) ->
        {:inline_binding, %{"key" => key, "fallback_keys" => [], "default" => nil}}

      true ->
        nil
    end
  end

  # Match `response.foo` or `response['foo']` — one-level member access on `response`.
  # Used for the F3 case where a fetcher returns `this.parseTrades(response['payload'], …)`.
  @spec extract_response_member_key(map()) :: String.t() | nil
  defp extract_response_member_key(%{
         "type" => "MemberExpression",
         "object" => %{"type" => "Identifier", "name" => "response"},
         "property" => prop
       }) do
    extract_property_name(prop)
  end

  defp extract_response_member_key(_), do: nil

  @spec extract_property_name(map() | nil) :: String.t() | nil
  defp extract_property_name(%{"type" => "Identifier", "name" => name}) when is_binary(name), do: name
  defp extract_property_name(%{"type" => "Literal", "value" => v}) when is_binary(v), do: v
  defp extract_property_name(_), do: nil

  # Collect all `const x = this.safeList(response, "key", default)` bindings.
  # Only records bindings whose first argument is the identifier `response`.
  @spec collect_response_bindings([map()]) :: %{String.t() => map()}
  defp collect_response_bindings(stmts) do
    Enum.reduce(stmts, %{}, &reduce_response_binding/2)
  end

  @spec reduce_response_binding(map(), %{String.t() => map()}) :: %{String.t() => map()}
  defp reduce_response_binding(
         %{
           "type" => "VariableDeclaration",
           "declarations" => [
             %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => var_name}, "init" => init}
           ]
         },
         acc
       ) do
    case extract_response_safe_call(init) do
      nil -> acc
      binding -> Map.put(acc, var_name, binding)
    end
  end

  defp reduce_response_binding(_stmt, acc), do: acc

  # Match `this.safeList(response, KEY, DEFAULT)` or `this.safeValue(response, KEY, DEFAULT)`.
  # Handles safeList2, safeListN, safeValue2, safeValueN for fallback keys.
  @spec extract_response_safe_call(map() | nil) :: map() | nil
  defp extract_response_safe_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method}
         },
         "arguments" => [first_arg | rest_args]
       })
       when method in @safe_response_methods do
    build_binding(method, first_arg, rest_args)
  end

  defp extract_response_safe_call(_), do: nil

  @spec build_binding(String.t(), map(), [map()]) :: map() | nil
  defp build_binding(method, first_arg, rest_args) do
    case first_arg do
      %{"type" => "Identifier", "name" => "response"} ->
        # Direct response binding — extract key per the method's CCXT signature.
        extract_key_binding(method, rest_args)

      %{
        "type" => "MemberExpression",
        "object" => %{"type" => "Identifier", "name" => "response"}
      } ->
        # Nested sub-property access: response["userAssetDribblets"] etc.
        unresolved("nested_response_unwrap")

      %{"type" => "Identifier"} ->
        # Object is an identifier (not response directly) — not a response binding.
        nil

      _ ->
        nil
    end
  end

  @spec extract_key_binding(String.t(), [map()]) :: map()
  defp extract_key_binding(_method, []) do
    %{"key" => nil, "fallback_keys" => [], "default" => nil}
  end

  defp extract_key_binding(method, [key_arg | rest]) do
    case key_arg do
      %{"type" => "Literal", "value" => key} when is_binary(key) ->
        # Audit F4 (Task 83b follow-up): safeValue2 / safeList2 carry exactly
        # one fallback key. With no default supplied (3 args total), the
        # old code mistreated the fallback key as the default. Parse args
        # using the method's actual CCXT signature.
        {fallback_keys, default_val} = parse_remaining_args(method, rest)
        %{"key" => key, "fallback_keys" => fallback_keys, "default" => default_val}

      %{"type" => "ArrayExpression", "elements" => elements} ->
        # safeListN / safeValueN — keys are an array literal; rest_args is
        # [default?].
        keys = elements |> Enum.map(&extract_literal_value/1) |> Enum.reject(&is_nil/1)

        case keys do
          [] ->
            unresolved("non_literal_key")

          [primary | fallbacks] ->
            default_val = extract_default_literal(List.last(rest))
            %{"key" => primary, "fallback_keys" => fallbacks, "default" => default_val}
        end

      %{"type" => "Literal"} ->
        # Non-string literal key (number etc.) — treat as non-derivable.
        unresolved("non_literal_key")

      _ ->
        # Variable or computed key — cannot statically derive.
        unresolved("non_literal_key")
    end
  end

  # Split rest_args (everything after key1) into {fallback_keys, default}
  # using the CCXT signature for each safe* method family.
  #
  #   safeValue(obj, key, default?)     → rest = [] | [default]
  #   safeList(obj, key, default?)      → rest = [] | [default]
  #   safeValue2(obj, k1, k2, default?) → rest = [k2] | [k2, default]
  #   safeList2(obj, k1, k2, default?)  → rest = [k2] | [k2, default]
  #
  # `safe{Value,List}N` callers hit the ArrayExpression clause above and
  # don't reach this function.
  @spec parse_remaining_args(String.t(), [map()]) :: {[String.t()], term()}
  defp parse_remaining_args(method, rest) when method in ~w(safeValue2 safeList2) do
    case rest do
      [] ->
        {[], nil}

      [k2] ->
        {literal_string_list([k2]), nil}

      [k2, default | _] ->
        {literal_string_list([k2]), extract_default_literal(default)}
    end
  end

  defp parse_remaining_args(_method, rest) do
    case rest do
      [] -> {[], nil}
      [default | _] -> {[], extract_default_literal(default)}
    end
  end

  @spec literal_string_list([map()]) :: [String.t()]
  defp literal_string_list(nodes) do
    nodes
    |> Enum.map(&extract_literal_string/1)
    |> Enum.reject(&is_nil/1)
  end

  # When no return variable is traced, use the first response binding we found.
  # If there are no response bindings, emit no_safe_value_call.
  @spec derive_from_first_binding(%{String.t() => map()}) :: map()
  defp derive_from_first_binding(response_bindings) do
    case Map.values(response_bindings) do
      [] -> unresolved("no_safe_value_call")
      [first | _] -> first
    end
  end

  @spec extract_identifier_name(map() | nil) :: String.t() | nil
  defp extract_identifier_name(%{"type" => "Identifier", "name" => name}), do: name
  defp extract_identifier_name(_), do: nil

  @spec extract_literal_value(map() | nil) :: term() | nil
  defp extract_literal_value(%{"type" => "Literal", "value" => value}), do: value
  defp extract_literal_value(_), do: nil

  @spec extract_literal_string(map() | nil) :: String.t() | nil
  defp extract_literal_string(%{"type" => "Literal", "value" => v}) when is_binary(v), do: v
  defp extract_literal_string(_), do: nil

  # Extract the default literal value from the last argument of a safe* call.
  # Returns nil when absent or not a statically known literal.
  @spec extract_default_literal(map() | nil) :: term()
  defp extract_default_literal(nil), do: nil
  defp extract_default_literal(%{"type" => "Literal", "value" => value}), do: value

  defp extract_default_literal(%{"type" => "ArrayExpression", "elements" => elements}) do
    Enum.map(elements, &extract_literal_value/1)
  end

  defp extract_default_literal(%{"type" => "ObjectExpression", "properties" => props}) do
    Map.new(props, fn p ->
      key = extract_identifier_name(p["key"]) || extract_literal_value(p["key"])
      {to_string(key), extract_literal_value(p["value"])}
    end)
  end

  defp extract_default_literal(_), do: nil

  @spec unresolved(String.t()) :: map()
  defp unresolved(reason), do: %{"_unresolved_reason" => reason}
end
