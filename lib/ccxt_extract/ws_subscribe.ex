defmodule CcxtExtract.WsSubscribe do
  @moduledoc """
  Extract and derive per-exchange WebSocket subscribe / unsubscribe message
  shape and per-method channel-name templates.

  To open a WS stream a consumer sends a *subscribe* frame and, to close it,
  an *unsubscribe* frame. CCXT models both in each Pro class
  (`priv/ccxt/ts/src/pro/<id>.ts`). Across the 110+ exchanges the frame is an
  object literal carrying a discriminant key (`op`/`method`/`event`/`type`)
  whose value is a subscribe/unsubscribe verb, plus a channel-list carrier
  (`args`/`params`/`channels`/`topics`). The classic shapes:

    * **bybit** — `{ 'op': 'subscribe', 'req_id': ..., 'args': topics }`
      / `{ 'op': 'unsubscribe', 'req_id': ..., 'args': topics }`.
    * **okx** — `{ 'op': 'subscribe', 'args': args }` / `{ 'op':
      'unsubscribe', 'args': topics }`.
    * **binance** — `{ 'method': 'SUBSCRIBE', 'params': subParams, 'id': ...
      }` / `{ 'method': 'UNSUBSCRIBE', 'params': subParams }`.

  The channels each `watch*` method subscribes to are string templates —
  `"tickers.{symbol}"`, `"book.{symbol}.raw"`, `"trades"` — built from
  literal segments plus the market/symbol identifier.

  ## Two roles

  This module is both an **extractor** and a **derivation**, mirroring
  `CcxtExtract.WsAuth` / `CcxtExtract.WsHeartbeat`:

    * Extractor (`extract/0`, `write!/2` via `CcxtExtract.OXCExtractor`) —
      parses every `pro/*.ts` into raw, inheritance-free facts written to
      `priv/discoveries/ws_subscribe.json`. Each entry records only what its
      own file states.
    * Derivation (`build/2`) — projects one raw entry plus the full
      discovery lookup into the consumer-facing `websocket.subscribe`
      section, resolving `extends`-chain inheritance and classifying the
      envelope mechanism.

  ## Raw probes, not heuristics

  Both facts are read structurally off the AST. The **envelope** is the first
  object literal whose discriminant key holds a subscribe/unsubscribe verb
  string literal (resolved through local `const` bindings, exactly as
  `WsAuth` recovers okx's `op: operation`). The **channel templates** are
  produced by three total, structural collectors over each `watch*` method:

    1. `+`-concatenation chains that resolve fully to string literals plus
       recognized subscription placeholders (`{symbol}` for a market/symbol
       identifier, `{timeframe}` for a timeframe identifier) — e.g.
       `'book.' + market['id'] + '.raw'` → `"book.{symbol}.raw"`.
    2. channel-name string literals carried as a `channel`/`topic`/`name`/
       `type`/`instType` object property value (okx's `{ channel: 'tickers'
       }`).
    3. `safeString`/`handleOptionAndParams` channel defaults — a string
       literal default that follows a `'channel'`/`'name'`/`'topic'` lookup
       key (bybit's `safeString(options, 'name', 'tickers')`).

  A concat chain seeded by a local variable (bybit's reassigned `topic`) does
  not resolve and is **not** guessed — it is simply absent from the template
  set. A Pro class whose subscribe frame matches no known shape lands in
  `unknown` with `unresolved_reason: "subscribe_not_classifiable"` rather
  than being forced into a category.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.WsSubscribe.extract()
      CcxtExtract.WsSubscribe.write!(exchanges)

      subscribe = CcxtExtract.WsSubscribe.build(entry, ws_subscribe_lookup)
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_subscribe.json"

  @mechanisms ~w(json_message unknown none)
  @sources ~w(pro_watch none)
  @unresolved_reasons ~w(no_ws_support subscribe_not_classifiable)
  @required_keys ~w(mechanism discriminant subscribe_op unsubscribe_op args_key
                    envelope_keys channels resolved_from source unresolved_reason)

  # Object-literal keys that can carry the subscribe/unsubscribe verb.
  @discriminant_keys ~w(op method event type action cmd command)
  # Object-property keys / lookup keys whose value is a channel name.
  @channel_keys ~w(channel topic name type instType)
  # Identifiers / member reads that stand in for the subscribed symbol.
  @symbol_names ~w(symbol symbols symbolString)
  @symbol_market_props ~w(id lowercaseId uppercaseId baseId quoteId symbol marketId)
  # Identifiers that stand in for the timeframe.
  @timeframe_names ~w(timeframe timeframeId interval rawTimeframe unfiedTimeframe)

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
      const_map = local_const_strings(class)
      channels = extract_channels(members)

      %{
        "id" => class_name,
        "class_name" => class_name,
        "file" => filename,
        "extends" => extends_name(class),
        "envelope" => extract_envelope(class, const_map),
        "channels" => channels,
        "watch_method_count" => count_watch_methods(members),
        "channel_template_count" => channels |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      }
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_envelope" => Enum.count(exchanges, &has_envelope?/1),
      "with_channels" => Enum.count(exchanges, &(map_size(&1["channels"]) > 0))
    }
  end

  # --- Extraction: class shape ---

  @spec extends_name(map()) :: String.t() | nil
  defp extends_name(%{superClass: %{type: :identifier, name: name}}) when is_binary(name), do: name
  defp extends_name(_class), do: nil

  # Map of `const/let <name> = "<string literal>"` declarators anywhere in the
  # class — used to resolve identifier-valued op discriminants (okx's
  # `const operation = 'subscribe'`).
  @spec local_const_strings(map()) :: %{String.t() => String.t()}
  defp local_const_strings(node) do
    node
    |> OXC.collect(fn
      %{type: :variable_declarator, id: %{type: :identifier, name: name}, init: init} -> {:keep, {name, init}}
      _ -> :skip
    end)
    |> Enum.reduce(%{}, fn {name, init}, acc ->
      case string_literal_value(init) do
        nil -> acc
        value -> Map.put_new(acc, name, value)
      end
    end)
  end

  # --- Extraction: subscribe / unsubscribe envelope ---

  @spec extract_envelope(map(), %{String.t() => String.t()}) :: map()
  defp extract_envelope(class, const_map) do
    objects = OXC.collect(class, fn %{type: :object_expression} = n -> {:keep, n}; _ -> :skip end)

    sub_classifier = fn value -> subscribe_op?(value) end
    unsub_classifier = fn value -> unsubscribe_op?(value) end
    sub = Enum.find_value(objects, &op_object(&1, const_map, sub_classifier))
    unsub = Enum.find_value(objects, &op_object(&1, const_map, unsub_classifier))

    primary = sub || unsub

    %{
      "discriminant" => primary && primary.disc_key,
      "subscribe" => sub && sub.op,
      "unsubscribe" => unsub && unsub.op,
      "args_key" => primary && args_key(primary.object),
      "subscribe_keys" => (sub && message_keys(sub.object)) || [],
      "unsubscribe_keys" => (unsub && message_keys(unsub.object)) || []
    }
  end

  # `%{disc_key, op, object}` when one of the discriminant keys of `object`
  # holds a verb that passes `classifier`, else nil.
  @spec op_object(map(), %{String.t() => String.t()}, (String.t() -> boolean())) ::
          %{disc_key: String.t(), op: String.t(), object: map()} | nil
  defp op_object(%{type: :object_expression} = object, const_map, classifier) do
    Enum.find_value(@discriminant_keys, fn key ->
      case discriminant_value(object, key, const_map) do
        value when is_binary(value) ->
          if classifier.(value), do: %{disc_key: key, op: value, object: object}

        _ ->
          nil
      end
    end)
  end

  defp op_object(_node, _const_map, _classifier), do: nil

  # Verb-value classifiers. `contains` (not exact) catches the JSON-RPC
  # namespaced forms `public/subscribe` (deribit) and `public/unsubscribe`
  # (derive) alongside the bare `subscribe` / `SUBSCRIBE`. unsubscribe is
  # checked first because "unsubscribe" contains "subscribe".
  @spec subscribe_op?(String.t()) :: boolean()
  defp subscribe_op?(value) do
    down = String.downcase(value)
    String.contains?(down, "subscribe") and not String.contains?(down, "unsubscribe")
  end

  @spec unsubscribe_op?(String.t()) :: boolean()
  defp unsubscribe_op?(value), do: value |> String.downcase() |> String.contains?("unsubscribe")

  # First top-level key (other than a discriminant) whose value is an array
  # or identifier — the channel-list carrier (`args`/`params`/`topics`).
  @spec args_key(map()) :: String.t() | nil
  defp args_key(%{type: :object_expression, properties: properties}) do
    Enum.find_value(properties, fn prop ->
      key = property_key(prop)
      value = Map.get(prop, :value)

      if is_binary(key) and key not in @discriminant_keys and carrier_value?(value) do
        key
      end
    end)
  end

  defp carrier_value?(%{type: type}) when type in [:array_expression, :identifier], do: true
  defp carrier_value?(_node), do: false

  # --- Extraction: per-method channel templates ---

  @spec extract_channels([map()]) :: %{String.t() => [String.t()]}
  defp extract_channels(members) do
    members
    |> Enum.filter(&watch_method?/1)
    |> Enum.reduce(%{}, fn method, acc ->
      templates = method_channel_templates(method)

      if templates == [] do
        acc
      else
        Map.put(acc, method.key.name, templates)
      end
    end)
  end

  @spec watch_method?(map()) :: boolean()
  defp watch_method?(%{type: :method_definition, key: %{name: name}}) when is_binary(name) do
    String.starts_with?(name, "watch") and not String.starts_with?(name, "watchMultiple")
  end

  defp watch_method?(_member), do: false

  @spec count_watch_methods([map()]) :: non_neg_integer()
  defp count_watch_methods(members), do: Enum.count(members, &watch_method?/1)

  # The three structural collectors, deduped and sorted.
  @spec method_channel_templates(map()) :: [String.t()]
  defp method_channel_templates(method) do
    (concat_templates(method) ++ property_channel_literals(method) ++ option_channel_defaults(method))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # (1) Maximal `+`-concatenation chains that resolve fully to literals plus
  # recognized placeholders.
  @spec concat_templates(map()) :: [String.t()]
  defp concat_templates(method) do
    plus_nodes =
      OXC.collect(method, fn
        %{type: :binary_expression, operator: "+"} = n -> {:keep, n}
        _ -> :skip
      end)

    child_ids = nested_plus_ids(plus_nodes)

    plus_nodes
    |> Enum.reject(&MapSet.member?(child_ids, node_id(&1)))
    |> Enum.map(&concat_template/1)
    |> Enum.reject(&is_nil/1)
  end

  # Offsets of `+` nodes that are an operand of another `+` node — i.e. not a
  # maximal chain root.
  @spec nested_plus_ids([map()]) :: MapSet.t()
  defp nested_plus_ids(plus_nodes) do
    Enum.reduce(plus_nodes, MapSet.new(), fn %{left: l, right: r}, acc ->
      acc
      |> maybe_put_plus(l)
      |> maybe_put_plus(r)
    end)
  end

  defp maybe_put_plus(acc, %{type: :binary_expression, operator: "+"} = n), do: MapSet.put(acc, node_id(n))
  defp maybe_put_plus(acc, _node), do: acc

  @spec node_id(map()) :: {term(), term()}
  defp node_id(node), do: {Map.get(node, :start), Map.get(node, :end)}

  @spec concat_template(map()) :: String.t() | nil
  defp concat_template(bin) do
    parts = flatten_plus(bin)
    tokens = Enum.map(parts, &operand_token/1)

    cond do
      Enum.any?(tokens, &(&1 == :unresolved)) -> nil
      not Enum.any?(parts, &string_literal?/1) -> nil
      true -> Enum.join(tokens)
    end
  end

  @spec flatten_plus(map()) :: [map()]
  defp flatten_plus(%{type: :binary_expression, operator: "+", left: l, right: r}) do
    flatten_plus(l) ++ flatten_plus(r)
  end

  defp flatten_plus(node), do: [node]

  # A concat operand becomes a literal string, a placeholder, or :unresolved.
  @spec operand_token(map()) :: String.t() | :unresolved
  defp operand_token(%{type: type, value: value}) when type in [:literal, :string_literal] and is_binary(value),
    do: value

  defp operand_token(%{type: :identifier, name: name}) do
    cond do
      name in @symbol_names -> "{symbol}"
      name in @timeframe_names -> "{timeframe}"
      true -> :unresolved
    end
  end

  defp operand_token(%{type: :member_expression, computed: true, object: %{type: :identifier, name: "market"}, property: prop}) do
    case string_literal_value(prop) do
      v when v in @symbol_market_props -> "{symbol}"
      _ -> :unresolved
    end
  end

  defp operand_token(_node), do: :unresolved

  # (2) Channel-name string literals carried as a channel-ish object property.
  @spec property_channel_literals(map()) :: [String.t()]
  defp property_channel_literals(method) do
    method
    |> OXC.collect(fn %{type: :object_expression} = n -> {:keep, n}; _ -> :skip end)
    |> Enum.flat_map(fn %{properties: props} ->
      Enum.flat_map(props, fn prop ->
        with key when key in @channel_keys <- property_key(prop),
             value when is_binary(value) <- string_literal_value(Map.get(prop, :value)) do
          [value]
        else
          _ -> []
        end
      end)
    end)
  end

  # (3) String-literal channel defaults that follow a `'channel'`/`'name'`/
  # `'topic'` lookup key in a call (safeString / handleOptionAndParams).
  @spec option_channel_defaults(map()) :: [String.t()]
  defp option_channel_defaults(method) do
    method
    |> OXC.collect(fn %{type: :call_expression} = n -> {:keep, n}; _ -> :skip end)
    |> Enum.flat_map(fn %{arguments: args} -> channel_defaults_in_args(args) end)
  end

  @spec channel_defaults_in_args([map()]) :: [String.t()]
  defp channel_defaults_in_args(args) do
    args
    |> Enum.map(&string_literal_value/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [key, default] when key in @channel_keys and is_binary(default) -> [default]
      _ -> []
    end)
  end

  # --- Shared AST helpers ---

  @spec string_literal_value(map() | nil) :: String.t() | nil
  defp string_literal_value(%{type: type, value: value}) when type in [:literal, :string_literal] and is_binary(value),
    do: value

  defp string_literal_value(_node), do: nil

  @spec string_literal?(map()) :: boolean()
  defp string_literal?(node), do: is_binary(string_literal_value(node))

  # Top-level non-computed property keys, in source order.
  @spec message_keys(map()) :: [String.t()]
  defp message_keys(%{type: :object_expression, properties: properties}) do
    properties |> Enum.map(&property_key/1) |> Enum.reject(&is_nil/1)
  end

  # Literal value of a discriminant property — direct string literal or an
  # identifier resolved through the local-const map. nil otherwise.
  @spec discriminant_value(map(), String.t(), %{String.t() => String.t()}) :: String.t() | nil
  defp discriminant_value(object, key, const_map) do
    case property_value_node(object, key) do
      %{type: type, value: value} when type in [:literal, :string_literal] and is_binary(value) ->
        value

      %{type: :identifier, name: name} ->
        Map.get(const_map, name)

      _ ->
        nil
    end
  end

  @spec property_value_node(map(), String.t()) :: map() | nil
  defp property_value_node(%{type: :object_expression, properties: properties}, key_name) do
    Enum.find_value(properties, fn prop ->
      if Map.get(prop, :computed, false) == false and property_key(prop) == key_name do
        Map.get(prop, :value)
      end
    end)
  end

  @spec property_key(map()) :: String.t() | nil
  defp property_key(%{key: %{type: :identifier, name: n}}) when is_binary(n), do: n
  defp property_key(%{key: %{type: type, value: v}}) when type in [:literal, :string_literal] and is_binary(v), do: v
  defp property_key(_prop), do: nil

  @spec has_envelope?(map()) :: boolean()
  defp has_envelope?(entry), do: not is_nil(get_in(entry, ["envelope", "discriminant"]))

  # --- Derivation ---

  @doc """
  Project a raw discovery entry into the `websocket.subscribe` section.

  `lookup` is the full `%{id => raw_entry}` discovery map — used to resolve
  `extends`-chain inheritance (e.g. `binanceusdm` inherits `binance`'s
  subscribe envelope and most `watch*` channel templates). A `nil` entry
  (REST-only exchange with no Pro class) yields `none_record/0`. A Pro class
  whose chain carries no classifiable subscribe envelope yields a
  `mechanism: "unknown"` record tagged
  `unresolved_reason: "subscribe_not_classifiable"` — its channel templates,
  if any, are still emitted.
  """
  @spec build(map() | nil, %{optional(String.t()) => map()}) :: map()
  def build(nil, _lookup), do: none_record()

  def build(entry, lookup) when is_map(entry) and is_map(lookup) do
    chain = ancestry_chain(entry, lookup)
    channels = resolve_channels(chain)

    case Enum.find(chain, &has_envelope?/1) do
      nil -> unknown_record(channels)
      env_entry -> classify(env_entry, chain, channels)
    end
  end

  # Merge channel maps across the chain, most-derived wins on key collision.
  @spec resolve_channels([map()]) :: %{String.t() => [String.t()]}
  defp resolve_channels(chain) do
    chain
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn entry, acc -> Map.merge(acc, entry["channels"] || %{}) end)
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

  @spec classify(map(), [map()], %{String.t() => [String.t()]}) :: map()
  defp classify(env_entry, [head | _], channels) do
    env = env_entry["envelope"]

    %{
      "mechanism" => "json_message",
      "discriminant" => env["discriminant"],
      "subscribe_op" => env["subscribe"],
      "unsubscribe_op" => env["unsubscribe"],
      "args_key" => env["args_key"],
      "envelope_keys" => env["subscribe_keys"] || [],
      "channels" => channels,
      "resolved_from" => if(env_entry["id"] == head["id"], do: "self", else: env_entry["id"]),
      "source" => "pro_watch",
      "unresolved_reason" => nil
    }
  end

  # Pro class present but no classifiable subscribe envelope anywhere in the
  # chain. Channels (if statically resolvable) are still emitted.
  @spec unknown_record(%{String.t() => [String.t()]}) :: map()
  defp unknown_record(channels) do
    %{
      "mechanism" => "unknown",
      "discriminant" => nil,
      "subscribe_op" => nil,
      "unsubscribe_op" => nil,
      "args_key" => nil,
      "envelope_keys" => [],
      "channels" => channels,
      "resolved_from" => nil,
      "source" => "pro_watch",
      "unresolved_reason" => "subscribe_not_classifiable"
    }
  end

  # --- Always-emit honest-empty record + closed-vocabulary exposers ---

  @doc """
  The `websocket.subscribe` record for an exchange with no WebSocket (Pro)
  class. `mechanism: "none"`, `unresolved_reason: "no_ws_support"` — mirrors
  `CcxtExtract.WsAuth.none_record/0`.
  """
  @spec none_record() :: %{String.t() => term()}
  def none_record do
    %{
      "mechanism" => "none",
      "discriminant" => nil,
      "subscribe_op" => nil,
      "unsubscribe_op" => nil,
      "args_key" => nil,
      "envelope_keys" => [],
      "channels" => %{},
      "resolved_from" => nil,
      "source" => "none",
      "unresolved_reason" => "no_ws_support"
    }
  end

  @doc "Required keys of a `websocket.subscribe` record. For contract-test invariants."
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc "Closed vocabulary for `mechanism`. For contract-test invariants."
  @spec mechanisms() :: [String.t()]
  def mechanisms, do: @mechanisms

  @doc "Closed vocabulary for `source`. For contract-test invariants."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Closed vocabulary for non-null `unresolved_reason`. For contract-test invariants."
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons
end
