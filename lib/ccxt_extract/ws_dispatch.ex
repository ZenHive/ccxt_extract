defmodule CcxtExtract.WsDispatch do
  @moduledoc """
  Extract and derive, per WS exchange, the channel → parse-handler dispatch
  table CCXT's Pro class uses to route an inbound frame.

  CCXT routes every WebSocket message through `handleMessage(client, message)`
  in `priv/ccxt/ts/src/pro/<id>.ts`. The method reads one or more
  *discriminator* fields off the frame (e.g.
  `this.safeString(message, 'channel' | 'topic' | 'e' | 'type' | 'op')`) and
  dispatches to a `handle<Channel>` method through one of two shapes:

    * an object-literal **handler map** — `const methods = { 'channel':
      this.handleX, ... }` looked up with `this.safeValue(methods, topic)`;
    * an **if/switch chain** — `if (topic === 'kline') this.handleOHLCV(...)`
      that calls the handler directly.

  This is the receive/parse side of the WS contract — which parse handler owns
  a given inbound channel frame. The watch*/subscribe side (channel-name
  templates) is Task 91.

  ## Two roles

  This module is both an **extractor** and a **derivation**, mirroring
  `CcxtExtract.WsAuth` / `CcxtExtract.WsHeartbeat`:

    * Extractor (`extract/0`, `write!/2` via `CcxtExtract.OXCExtractor`) —
      parses every `pro/*.ts` into raw, inheritance-free facts written to
      `priv/discoveries/ws_dispatch.json`. Each entry records only what its
      own file's `handleMessage` states.
    * Derivation (`build/2`) — projects one raw entry plus the full discovery
      lookup into the consumer-facing `websocket.dispatch` section, resolving
      `extends`-chain inheritance (a Pro class without its own `handleMessage`
      inherits the parent's table, as `WsHeartbeat.build/2` walks `extends`).

  ## Structural classification, not interpretation

  An `entry` is emitted only when both halves are literal: the handler is the
  literal `this.<identifier>` invoked (identifier must start with `handle`),
  and the channel is the literal string key of the map property (or the string
  literal compared in the if-chain `===`). A discriminator is the literal key
  argument to the `safeString`/`safeValue` lookup that feeds the dispatch. An
  unrecognized dispatch shape (computed channel key, spread, non-handler value)
  lands in `unresolved` with a reason — never a guessed mapping. A
  `handleMessage` whose dispatch yields no resolvable entry is classified
  `opaque`, never forced into a table.
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_dispatch.json"

  @kinds ~w(routed opaque none)
  @sources ~w(pro_handle_message none)
  @unresolved_reasons ~w(no_ws_support no_ws_dispatch dispatch_not_classifiable)
  @unresolved_entry_reasons ~w(computed_channel_key spread_property non_handler_value)
  @required_keys ~w(kind handle_message_defined discriminators entries unresolved
                    resolved_from source unresolved_reason)

  # --- Extractor callbacks ---

  @impl true
  @spec source_dir() :: String.t()
  def source_dir, do: Path.join(CcxtExtract.Paths.ts_src(), "pro")

  @impl true
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name, else: Path.rootname(filename)
      members = Enum.filter(class.body.body, &(&1.type == :method_definition))

      %{
        "id" => class_name,
        "class_name" => class_name,
        "file" => filename,
        "extends" => extends_name(class),
        "handle_message" => extract_handle_message(members)
      }
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_handle_message" => Enum.count(exchanges, &handle_message_defined?/1),
      "with_entries" => Enum.count(exchanges, &(handle_entries(&1) != []))
    }
  end

  # --- Extraction: class shape ---

  @spec extends_name(map()) :: String.t() | nil
  defp extends_name(%{superClass: %{type: :identifier, name: name}}) when is_binary(name), do: name
  defp extends_name(_class), do: nil

  # --- Extraction: handleMessage ---

  @spec extract_handle_message([map()]) :: map()
  defp extract_handle_message(members) do
    case Enum.find(members, &method_named?(&1, "handleMessage")) do
      nil ->
        absent_handle_message()

      %{value: fn_expr} ->
        maps = handler_map_objects(fn_expr)
        map_names = MapSet.new(maps, fn {name, _obj} -> name end)
        {map_entries, map_unresolved} = collect_map_results(maps)
        if_entries = if_chain_entries(fn_expr)
        switch_entries = switch_entries(fn_expr)

        bindings = safe_key_bindings(fn_expr)
        discriminators = discriminator_keys(fn_expr, map_names, bindings)

        %{
          "defined" => true,
          "discriminators" => discriminators,
          "entries" => dedup_entries(map_entries ++ if_entries ++ switch_entries),
          "unresolved" => map_unresolved
        }
    end
  end

  @spec absent_handle_message() :: map()
  defp absent_handle_message do
    %{"defined" => false, "discriminators" => [], "entries" => [], "unresolved" => []}
  end

  # --- Extraction: object-literal handler maps ---

  # `const <name> = { ... }` declarators whose object is a handler map (at
  # least one property value is `this.handle*`). Returns `[{name, object}]`.
  @spec handler_map_objects(map()) :: [{String.t(), map()}]
  defp handler_map_objects(fn_expr) do
    OXC.collect(fn_expr, fn
      %{type: :variable_declarator, id: %{type: :identifier, name: name}, init: %{type: :object_expression} = obj} ->
        if handler_map?(obj), do: {:keep, {name, obj}}, else: :skip

      _ ->
        :skip
    end)
  end

  @spec handler_map?(map()) :: boolean()
  defp handler_map?(%{properties: props}) do
    Enum.any?(props, fn prop -> handler_value(Map.get(prop, :value)) != nil end)
  end

  defp handler_map?(_), do: false

  # Resolve a property/comparison value node to its handler name, or nil. A
  # handler is `this.<ident>` (or a `"handle..."` string literal) whose name
  # starts with `handle`.
  @spec handler_value(map() | nil) :: String.t() | nil
  defp handler_value(%{
         type: :member_expression,
         computed: false,
         object: %{type: :this_expression},
         property: %{type: :identifier, name: name}
       }) do
    if handler_name?(name), do: name
  end

  defp handler_value(%{type: type, value: v}) when type in [:literal, :string_literal] and is_binary(v) do
    if handler_name?(v), do: v
  end

  defp handler_value(_node), do: nil

  @spec handler_name?(String.t() | nil) :: boolean()
  defp handler_name?(name) when is_binary(name), do: String.starts_with?(name, "handle")
  defp handler_name?(_), do: false

  # Split every handler-map property into resolved entries and unresolved
  # shape findings.
  @spec collect_map_results([{String.t(), map()}]) :: {[map()], [map()]}
  defp collect_map_results(maps) do
    results =
      Enum.flat_map(maps, fn {_name, %{properties: props}} ->
        Enum.map(props, &map_property_result/1)
      end)

    entries = for {:entry, e} <- results, do: e
    unresolved = for {:unresolved, reason} <- results, do: %{"reason" => reason}

    {entries, Enum.uniq(unresolved)}
  end

  @spec map_property_result(map()) :: {:entry, map()} | {:unresolved, String.t()} | nil
  defp map_property_result(%{type: :spread_element}), do: {:unresolved, "spread_property"}

  defp map_property_result(%{type: type} = prop) when type in [:object_property, :property] do
    if Map.get(prop, :computed, false) do
      {:unresolved, "computed_channel_key"}
    else
      classify_map_property(property_key(prop), handler_value(Map.get(prop, :value)))
    end
  end

  defp map_property_result(_prop), do: nil

  defp classify_map_property(nil, _handler), do: nil
  defp classify_map_property(_key, nil), do: {:unresolved, "non_handler_value"}
  defp classify_map_property(key, handler), do: {:entry, %{"channel" => key, "handler" => handler}}

  # --- Extraction: if/switch chain ---

  # `if (<disc> === '<channel>') this.handle*(...)` statements (and
  # `else if` chains, and `||`-joined channel literals) → channel→handler
  # entries. Each `if_statement` is processed for its own test + consequent;
  # OXC.collect visits nested `else if` nodes independently.
  @spec if_chain_entries(map()) :: [map()]
  defp if_chain_entries(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :if_statement} = node -> {:keep, node}
      _ -> :skip
    end)
    |> Enum.flat_map(&if_statement_entries/1)
  end

  @spec if_statement_entries(map()) :: [map()]
  defp if_statement_entries(%{test: test, consequent: consequent}) do
    case consequent_handler(consequent) do
      nil -> []
      handler -> Enum.map(comparison_channels(test), &%{"channel" => &1, "handler" => handler})
    end
  end

  defp if_statement_entries(_node), do: []

  @spec switch_entries(map()) :: [map()]
  defp switch_entries(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :switch_statement} = node -> {:keep, node}
      _ -> :skip
    end)
    |> Enum.flat_map(&switch_statement_entries/1)
  end

  @spec switch_statement_entries(map()) :: [map()]
  defp switch_statement_entries(%{cases: cases}) do
    {entries, _pending} =
      Enum.reduce(cases, {[], []}, fn case_node, {entries, pending} ->
        channel = string_literal_value(Map.get(case_node, :test))
        channels = if is_binary(channel), do: pending ++ [channel], else: pending

        case consequent_handler(Map.get(case_node, :consequent)) do
          nil -> {entries, channels}
          handler -> {entries ++ Enum.map(channels, &%{"channel" => &1, "handler" => handler}), []}
        end
      end)

    entries
  end

  defp switch_statement_entries(_node), do: []

  # First `this.handle*(...)` call inside a consequent, or nil. The `alternate`
  # branch is not part of the consequent, so else-if handlers are not captured
  # here (their own `if_statement` is processed separately).
  @spec consequent_handler(term()) :: String.t() | nil
  defp consequent_handler(nil), do: nil
  defp consequent_handler(nodes) when is_list(nodes), do: Enum.find_value(nodes, &consequent_handler/1)

  defp consequent_handler(consequent) do
    consequent
    |> OXC.collect(fn
      %{
        type: :call_expression,
        callee: %{
          type: :member_expression,
          computed: false,
          object: %{type: :this_expression},
          property: %{type: :identifier, name: name}
        }
      } ->
        if handler_name?(name), do: {:keep, name}, else: :skip

      _ ->
        :skip
    end)
    |> List.first()
  end

  # String-literal channels in an `<ident> === '<channel>'` test, including
  # `||`-joined comparisons. Returns [] for any other test shape.
  @spec comparison_channels(map()) :: [String.t()]
  defp comparison_channels(%{type: :parenthesized_expression, expression: inner}), do: comparison_channels(inner)

  defp comparison_channels(%{type: :logical_expression, operator: "||", left: l, right: r}) do
    comparison_channels(l) ++ comparison_channels(r)
  end

  defp comparison_channels(%{type: :binary_expression, operator: op, left: l, right: r}) when op in ["===", "=="] do
    case {string_literal_value(l), string_literal_value(r)} do
      {nil, v} when is_binary(v) -> [v]
      {v, nil} when is_binary(v) -> [v]
      _ -> []
    end
  end

  defp comparison_channels(_test), do: []

  # Identifier names compared against a string literal in a test (mirror of
  # comparison_channels, but the discriminator side).
  @spec comparison_identifiers(map()) :: [String.t()]
  defp comparison_identifiers(%{type: :parenthesized_expression, expression: inner}), do: comparison_identifiers(inner)

  defp comparison_identifiers(%{type: :logical_expression, operator: "||", left: l, right: r}) do
    comparison_identifiers(l) ++ comparison_identifiers(r)
  end

  defp comparison_identifiers(%{type: :binary_expression, operator: op, left: l, right: r}) when op in ["===", "=="] do
    Enum.flat_map([l, r], fn
      %{type: :identifier, name: name} -> [name]
      _ -> []
    end)
  end

  defp comparison_identifiers(_test), do: []

  # --- Extraction: discriminator keys ---

  # Literal message keys that feed a dispatch. Two sources: the safe-accessor
  # key that produces the lookup-key variable for a handler-map
  # `this.safeValue(map, keyVar)`, and the safe-accessor key behind an
  # if-chain comparison identifier. Both resolve through `bindings`
  # (name → literal keys).
  @spec discriminator_keys(map(), MapSet.t(), %{String.t() => [String.t()]}) :: [String.t()]
  defp discriminator_keys(fn_expr, map_names, bindings) do
    from_map = fn_expr |> lookup_key_exprs(map_names) |> Enum.flat_map(&key_expr_keys(&1, bindings))
    from_if = fn_expr |> if_chain_identifiers() |> Enum.flat_map(&Map.get(bindings, &1, []))
    from_switch = fn_expr |> switch_discriminants() |> Enum.flat_map(&key_expr_keys(&1, bindings))

    (from_map ++ from_if ++ from_switch) |> Enum.uniq() |> Enum.sort()
  end

  # `const <name> = this.safe*(<obj>, '<k1>', '<k2>', ...)` declarators →
  # %{name => [literal keys]}.
  @spec safe_key_bindings(map()) :: %{String.t() => [String.t()]}
  defp safe_key_bindings(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :variable_declarator, id: %{type: :identifier, name: name}, init: init} ->
        case safe_accessor_keys(init) do
          [] -> :skip
          keys -> {:keep, {name, keys}}
        end

      _ ->
        :skip
    end)
    |> Map.new()
  end

  # The key-expression argument of every `this.safe*(<map>, keyExpr, ...)`
  # whose first argument names a known handler map.
  @spec lookup_key_exprs(map(), MapSet.t()) :: [map()]
  defp lookup_key_exprs(fn_expr, map_names) do
    OXC.collect(fn_expr, fn
      %{type: :call_expression, callee: callee, arguments: [first, key_expr | _rest]} ->
        if safe_callee?(callee) and identifier_member?(first, map_names),
          do: {:keep, key_expr},
          else: :skip

      _ ->
        :skip
    end)
  end

  defp identifier_member?(%{type: :identifier, name: name}, map_names), do: MapSet.member?(map_names, name)
  defp identifier_member?(_node, _map_names), do: false

  # Resolve a lookup key expression to literal keys: an identifier through the
  # const bindings, or an inline safe-accessor call directly.
  @spec key_expr_keys(map(), %{String.t() => [String.t()]}) :: [String.t()]
  defp key_expr_keys(%{type: :identifier, name: name}, bindings), do: Map.get(bindings, name, [])
  defp key_expr_keys(%{type: :call_expression} = call, _bindings), do: safe_accessor_keys(call)
  defp key_expr_keys(_node, _bindings), do: []

  # Identifier names compared against a string literal anywhere a handler is
  # the if's consequent.
  @spec if_chain_identifiers(map()) :: [String.t()]
  defp if_chain_identifiers(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :if_statement, test: test, consequent: consequent} ->
        if consequent_handler(consequent), do: {:keep, comparison_identifiers(test)}, else: :skip

      _ ->
        :skip
    end)
    |> List.flatten()
  end

  @spec switch_discriminants(map()) :: [map()]
  defp switch_discriminants(fn_expr) do
    OXC.collect(fn_expr, fn
      %{type: :switch_statement, discriminant: discriminant} -> {:keep, discriminant}
      _ -> :skip
    end)
  end

  # Non-empty string-literal key arguments of a `this.safe*(<obj>, keys...)`
  # call (the first argument is the object, not a key). The trailing `''`
  # default is dropped.
  @spec safe_accessor_keys(map() | nil) :: [String.t()]
  defp safe_accessor_keys(%{type: :call_expression, callee: callee, arguments: [_obj | keys]}) do
    if safe_callee?(callee) do
      keys |> Enum.map(&string_literal_value/1) |> Enum.reject(&(&1 in [nil, ""]))
    else
      []
    end
  end

  defp safe_accessor_keys(_node), do: []

  @spec safe_callee?(map()) :: boolean()
  defp safe_callee?(%{
         type: :member_expression,
         computed: false,
         object: %{type: :this_expression},
         property: %{type: :identifier, name: name}
       }), do: String.starts_with?(name, "safe")

  defp safe_callee?(_node), do: false

  # --- Shared AST helpers ---

  @spec method_named?(map(), String.t()) :: boolean()
  defp method_named?(%{type: :method_definition, key: %{name: name}}, name), do: true
  defp method_named?(_member, _name), do: false

  @spec string_literal_value(map() | nil) :: String.t() | nil
  defp string_literal_value(%{type: type, value: value}) when type in [:literal, :string_literal] and is_binary(value),
    do: value

  defp string_literal_value(_node), do: nil

  @spec property_key(map()) :: String.t() | nil
  defp property_key(%{key: %{type: :identifier, name: n}}) when is_binary(n), do: n
  defp property_key(%{key: %{type: type, value: v}}) when type in [:literal, :string_literal] and is_binary(v), do: v
  defp property_key(_prop), do: nil

  @spec dedup_entries([map()]) :: [map()]
  defp dedup_entries(entries), do: Enum.uniq(entries)

  @spec handle_message_defined?(map()) :: boolean()
  defp handle_message_defined?(entry), do: get_in(entry, ["handle_message", "defined"]) == true

  @spec handle_entries(map()) :: [map()]
  defp handle_entries(entry), do: get_in(entry, ["handle_message", "entries"]) || []

  # --- Derivation ---

  @doc """
  Project a raw discovery entry into the `websocket.dispatch` section.

  `lookup` is the full `%{id => raw_entry}` discovery map — used to resolve
  `extends`-chain inheritance (a Pro class without its own `handleMessage`
  inherits the parent's table). A `nil` entry (REST-only exchange with no Pro
  class) yields `none_record/0`. A Pro class that defines no `handleMessage`
  anywhere in its chain yields a `kind: "none"` record tagged
  `unresolved_reason: "no_ws_dispatch"`.
  """
  @spec build(map() | nil, %{optional(String.t()) => map()}) :: map()
  def build(nil, _lookup), do: none_record()

  def build(entry, lookup) when is_map(entry) and is_map(lookup) do
    chain = ancestry_chain(entry, lookup)

    case Enum.find(chain, &handle_message_defined?/1) do
      nil -> empty_record("no_ws_dispatch")
      hm_entry -> classify(hm_entry, chain)
    end
  end

  # `[self, parent, grandparent, ...]` by walking `extends` through the
  # discovery lookup. Stops when `extends` names a non-WS class (absent from
  # the lookup). The seen-set guards against cycles.
  @spec ancestry_chain(map(), map()) :: [map()]
  defp ancestry_chain(entry, lookup), do: ancestry_chain(entry, lookup, [], MapSet.new())

  @spec ancestry_chain(map() | nil, map(), [map()], MapSet.t()) :: [map()]
  defp ancestry_chain(nil, _lookup, acc, _seen), do: Enum.reverse(acc)

  defp ancestry_chain(entry, lookup, acc, seen) do
    id = entry["id"]

    if MapSet.member?(seen, id) do
      Enum.reverse(acc)
    else
      parent = entry["extends"] && Map.get(lookup, entry["extends"])
      ancestry_chain(parent, lookup, [entry | acc], MapSet.put(seen, id))
    end
  end

  # Project the most-derived `handleMessage` in the chain. Overriding
  # `handleMessage` in JS replaces it wholesale, so the resolved entry's
  # table is used as-is (nothing to merge from ancestors).
  @spec classify(map(), [map()]) :: map()
  defp classify(hm_entry, [head | _]) do
    hm = hm_entry["handle_message"]
    entries = hm["entries"] || []
    {kind, reason} = if entries == [], do: {"opaque", "dispatch_not_classifiable"}, else: {"routed", nil}

    %{
      "kind" => kind,
      "handle_message_defined" => true,
      "discriminators" => hm["discriminators"] || [],
      "entries" => entries,
      "unresolved" => hm["unresolved"] || [],
      "resolved_from" => if(hm_entry["id"] == head["id"], do: "self", else: hm_entry["id"]),
      "source" => "pro_handle_message",
      "unresolved_reason" => reason
    }
  end

  # --- Always-emit honest-empty record + closed-vocabulary exposers ---

  @doc """
  The `websocket.dispatch` record for an exchange with no WebSocket (Pro)
  class. `kind: "none"`, `unresolved_reason: "no_ws_support"` — mirrors
  `CcxtExtract.WsAuth.none_record/0`.
  """
  @spec none_record() :: %{String.t() => term()}
  def none_record, do: empty_record("no_ws_support")

  @spec empty_record(String.t()) :: %{String.t() => term()}
  defp empty_record(reason) do
    %{
      "kind" => "none",
      "handle_message_defined" => false,
      "discriminators" => [],
      "entries" => [],
      "unresolved" => [],
      "resolved_from" => nil,
      "source" => "none",
      "unresolved_reason" => reason
    }
  end

  @doc "Required keys of a `websocket.dispatch` record. For contract-test invariants."
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc "Closed vocabulary for `kind`. For contract-test invariants."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Closed vocabulary for `source`. For contract-test invariants."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Closed vocabulary for non-null `unresolved_reason`. For contract-test invariants."
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons

  @doc "Closed vocabulary for per-shape `unresolved` entry reasons. For contract-test invariants."
  @spec unresolved_entry_reasons() :: [String.t()]
  def unresolved_entry_reasons, do: @unresolved_entry_reasons
end
