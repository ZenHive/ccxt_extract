defmodule CcxtExtract.WsHeartbeat do
  @moduledoc """
  Extract and derive per-exchange WebSocket heartbeat (ping/pong keep-alive)
  configuration.

  CCXT's WS layer keeps a connection alive via the base client in
  `priv/ccxt/ts/src/base/ws/Client.ts` — `keepAlive` (interval, default
  30000ms), `maxPingPongMisses` (missed-pong tolerance, default 2.0), an
  `onPingInterval()` loop and an `onPong()` handler. A per-exchange Pro class
  (`priv/ccxt/ts/src/pro/<id>.ts`) tunes this in three places:

    * `describe().streaming` — a `{ keepAlive, ping, ... }` map merged onto
      the parent via `deepExtend`. `keepAlive` is the resolved interval;
      a `ping` property wires the method below.
    * `ping(client)` — an optional method returning the application-level
      ping payload. Its absence means the base client falls back to
      protocol-level WebSocket ping frames.
    * `pong` / `handlePong` / `handlePing` — optional methods that process
      inbound heartbeat frames instead of relying on the base `onPong()`.

  ## Two roles

  This module is both an **extractor** and a **derivation**, mirroring
  `CcxtExtract.RateLimitBuckets`:

    * Extractor (`extract/0`, `write!/2` via `CcxtExtract.OXCExtractor`) —
      parses every `pro/*.ts` into raw, inheritance-free facts written to
      `priv/discoveries/ws_heartbeat.json`. Each entry records only what its
      own file states; `streaming.keepAlive` is `null` when the class does
      not set it (inheritance is resolved later, not here).
    * Derivation (`build/2`) — projects one raw entry plus the full
      discovery lookup into the consumer-facing `websocket.heartbeat`
      section, resolving `extends`-chain inheritance and classifying the
      ping strategy.

  ## Structural classification, not interpretation

  `ping_kind` is a total function of the `ping()` return-node AST type — a
  string `Literal` is `string_message`, an `ObjectExpression` is
  `json_message`, an absent `ping()` is `native_frame`. It never inspects
  what the payload *says* or guesses server behavior. An unrecognized return
  shape lands in `unknown` with `unresolved_reason: "ping_return_not_literal"`
  rather than being forced into a category.

  ## Base defaults

  `base/ws/Client.ts` is gitignored (absent on a fresh clone before
  `mix ccxt_extract.setup`), so its defaults cannot be read at compile time.
  They are pinned as module attributes here and guarded against upstream
  drift by the "base client default drift guard" test in
  `ws_heartbeat_integration_test.exs` (`:extraction`-tagged — runs only
  when the CCXT source is present).

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.WsHeartbeat.extract()
      CcxtExtract.WsHeartbeat.write!(exchanges)

      heartbeat = CcxtExtract.WsHeartbeat.build(entry, ws_heartbeat_lookup)
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_heartbeat.json"

  alias CcxtExtract.RequestDefaults

  # base/ws/Client.ts constructor defaults (lines ~97-98). See @moduledoc
  # "Base defaults" for why these are pinned rather than read from source.
  @base_keep_alive_ms 30_000
  @base_max_ping_pong_misses 2.0

  @ping_kinds ~w(native_frame string_message json_message unknown none)
  @sources ~w(pro_describe base_default none)
  @unresolved_reasons ~w(no_ws_support ping_return_not_literal)
  @required_keys ~w(ping_kind ping_payload ping_payload_kind keep_alive_ms
                    max_ping_pong_misses has_pong_handler keep_alive_resolved_from
                    source unresolved_reason)

  @pong_method_names ~w(pong handlePong handlePing)

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
        "ping" => extract_ping(members),
        "pong_methods" => extract_pong_methods(members),
        "streaming" => extract_streaming(members)
      }
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_ping_method" => Enum.count(exchanges, &get_in(&1, ["ping", "defined"])),
      "with_pong_handler" => Enum.count(exchanges, &any_pong_method?/1),
      "with_streaming" => Enum.count(exchanges, &get_in(&1, ["streaming", "present"]))
    }
  end

  # --- Extraction: class shape ---

  @spec extends_name(map()) :: String.t() | nil
  defp extends_name(%{superClass: %{type: :identifier, name: name}}) when is_binary(name), do: name
  defp extends_name(_class), do: nil

  # --- Extraction: ping method ---

  @spec extract_ping([map()]) :: map()
  defp extract_ping(members) do
    case Enum.find(members, &method_named?(&1, "ping")) do
      nil ->
        %{"defined" => false, "shape" => nil, "return_value" => nil}

      method ->
        node = ping_return_node(method)
        %{"defined" => true, "shape" => return_shape(node), "return_value" => decode_return(node)}
    end
  end

  # First `return` statement's argument inside the method body, or nil.
  @spec ping_return_node(map()) :: map() | nil
  defp ping_return_node(%{value: %{body: %{body: stmts}}}) when is_list(stmts) do
    case Enum.find(stmts, &(&1.type == :return_statement)) do
      %{argument: arg} -> arg
      _ -> nil
    end
  end

  defp ping_return_node(_method), do: nil

  @spec return_shape(map() | nil) :: String.t() | nil
  defp return_shape(nil), do: nil
  defp return_shape(%{type: :object_expression}), do: "object"
  defp return_shape(%{type: type, value: v}) when type in [:literal, :string_literal] and is_binary(v), do: "string"
  defp return_shape(_node), do: "other"

  # Decoded ping payload. Object returns are decoded per-property so a
  # partially-dynamic payload (bybit's static `op` + dynamic `req_id`)
  # keeps its literal keys instead of collapsing to fully-unresolved.
  @spec decode_return(map() | nil) :: map() | nil
  defp decode_return(nil), do: nil

  defp decode_return(%{type: type, value: v}) when type in [:literal, :string_literal] and is_binary(v) do
    %{"value" => v, "kind" => "literal", "reason" => nil}
  end

  defp decode_return(%{type: :object_expression} = node) do
    entries = RequestDefaults.extract_object_expression(node)
    literal = for {k, %{"kind" => "literal", "value" => val}} <- entries, into: %{}, do: {k, val}

    kind =
      cond do
        entries == %{} -> "unresolved"
        map_size(literal) == map_size(entries) -> "literal"
        map_size(literal) > 0 -> "partial"
        true -> "unresolved"
      end

    %{"value" => literal, "kind" => kind, "reason" => nil}
  end

  defp decode_return(_node), do: %{"value" => nil, "kind" => "unresolved", "reason" => "non_literal_return"}

  # --- Extraction: pong methods ---

  @spec extract_pong_methods([map()]) :: map()
  defp extract_pong_methods(members) do
    Map.new(@pong_method_names, fn name -> {name, Enum.any?(members, &method_named?(&1, name))} end)
  end

  @spec any_pong_method?(map()) :: boolean()
  defp any_pong_method?(entry) do
    entry |> Map.get("pong_methods", %{}) |> Map.values() |> Enum.any?(& &1)
  end

  # --- Extraction: describe().streaming ---

  @spec extract_streaming([map()]) :: map()
  defp extract_streaming(members) do
    case streaming_node(members) do
      nil ->
        %{"present" => false, "keep_alive_ms" => nil, "max_ping_pong_misses" => nil, "has_ping_property" => false}

      streaming ->
        decoded = RequestDefaults.extract_object_expression(streaming)

        %{
          "present" => true,
          "keep_alive_ms" => numeric_value(decoded, "keepAlive"),
          "max_ping_pong_misses" => numeric_value(decoded, "maxPingPongMisses"),
          "has_ping_property" => Map.has_key?(decoded, "ping")
        }
    end
  end

  # The `streaming` object literal, sought in describe() then describeData()
  # (the binance family routes its describe map through a describeData()
  # helper, so the streaming block is not reachable from describe() itself).
  @spec streaming_node([map()]) :: map() | nil
  defp streaming_node(members) do
    ["describe", "describeData"]
    |> Enum.flat_map(fn name ->
      case Enum.find(members, &method_named?(&1, name)) do
        nil -> []
        method -> [method]
      end
    end)
    |> Enum.map(&describe_object/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&find_property(&1, "streaming"))
  end

  # The describe() literal — argument of `return this.deepExtend(super.describe(), {OBJ})`
  # (or a bare returned ObjectExpression). Picks the last ObjectExpression
  # among the call arguments (super.describe() is a CallExpression, not it).
  @spec describe_object(map()) :: map() | nil
  defp describe_object(%{value: %{body: %{body: stmts}}}) when is_list(stmts) do
    case Enum.find(stmts, &(&1.type == :return_statement)) do
      %{argument: %{type: :object_expression} = obj} -> obj
      %{argument: %{type: :call_expression, arguments: args}} -> last_object_expression(args)
      _ -> nil
    end
  end

  defp describe_object(_method), do: nil

  @spec last_object_expression([map()]) :: map() | nil
  defp last_object_expression(args) when is_list(args) do
    args |> Enum.filter(&(&1.type == :object_expression)) |> List.last()
  end

  # --- Shared AST helpers ---

  @spec method_named?(map(), String.t()) :: boolean()
  defp method_named?(%{type: :method_definition, key: %{name: name}}, name), do: true
  defp method_named?(_member, _name), do: false

  # Value node of a non-computed property whose key resolves to `key_name`.
  @spec find_property(map(), String.t()) :: map() | nil
  defp find_property(%{type: :object_expression, properties: props}, key_name) do
    Enum.find_value(props, fn prop ->
      if Map.get(prop, :computed, false) == false and property_key(prop) == key_name do
        Map.get(prop, :value)
      end
    end)
  end

  defp find_property(_node, _key_name), do: nil

  @spec property_key(map()) :: String.t() | nil
  defp property_key(%{key: %{type: :identifier, name: n}}) when is_binary(n), do: n
  defp property_key(%{key: %{type: type, value: v}}) when type in [:literal, :string_literal] and is_binary(v), do: v
  defp property_key(_prop), do: nil

  # A decoded-object key whose entry is a literal number.
  @spec numeric_value(map(), String.t()) :: number() | nil
  defp numeric_value(decoded, key) do
    case Map.get(decoded, key) do
      %{"kind" => "literal", "value" => v} when is_number(v) -> v
      _ -> nil
    end
  end

  # --- Scoped extraction: extends-chain ancestor closure ---

  @doc """
  Augment scoped entries with missing WS `extends`-chain ancestors.

  A scoped run naming a variant without its WS root (e.g. `--exchange
  binanceusdm`) must still persist every ancestor `build/2` walks — otherwise
  inheritance resolution falls back to `base_default` with dishonest provenance.
  Pulls missing ancestors from the full `extract/0` result; already-scoped
  entries are left untouched.
  """
  @spec close_ancestor_entries([map()], [map()]) :: [map()]
  def close_ancestor_entries(scoped_entries, all_entries) when is_list(scoped_entries) and is_list(all_entries) do
    lookup = Map.new(all_entries, &{&1["id"], &1})
    scoped_ids = MapSet.new(scoped_entries, & &1["id"])

    missing =
      scoped_entries
      |> Enum.flat_map(&ws_ancestor_ids(&1, lookup))
      |> Enum.reject(&MapSet.member?(scoped_ids, &1))
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(lookup, &1))

    Enum.uniq_by(scoped_entries ++ missing, & &1["id"])
  end

  @doc """
  Union a scoped `MapSet` with the WS `extends`-chain ancestor ids of
  `scoped_entries`.

  Required alongside `close_ancestor_entries/2` so `AggregateWriter` replaces
  stale on-disk ancestor copies instead of appending duplicates.
  """
  @spec expand_scope_with_ancestors(MapSet.t(), [map()], [map()]) :: MapSet.t()
  def expand_scope_with_ancestors(%MapSet{} = scope, scoped_entries, all_entries)
      when is_list(scoped_entries) and is_list(all_entries) do
    lookup = Map.new(all_entries, &{&1["id"], &1})

    ancestor_ids =
      scoped_entries
      |> Enum.flat_map(&ws_ancestor_ids(&1, lookup))
      |> MapSet.new()

    MapSet.union(scope, ancestor_ids)
  end

  @doc """
  Close scoped entries and expand the write scope over WS ancestors.

  No-op when `scope` is `:all`.
  """
  @spec close_scoped_extraction([map()], [map()], :all | MapSet.t()) ::
          {[map()], :all | MapSet.t()}
  def close_scoped_extraction(scoped_entries, _all_entries, :all), do: {scoped_entries, :all}

  def close_scoped_extraction(scoped_entries, all_entries, %MapSet{} = scope) do
    closed = close_ancestor_entries(scoped_entries, all_entries)
    expanded = expand_scope_with_ancestors(scope, scoped_entries, all_entries)
    {closed, expanded}
  end

  # Parent Pro-class ids along the WS `extends` chain (excludes `entry` itself).
  @spec ws_ancestor_ids(map(), %{String.t() => map()}) :: [String.t()]
  defp ws_ancestor_ids(entry, lookup) do
    entry
    |> ancestry_chain(lookup)
    |> Enum.drop(1)
    |> Enum.map(& &1["id"])
  end

  # --- Derivation ---

  @doc """
  Project a raw discovery entry into the `websocket.heartbeat` section.

  `lookup` is the full `%{id => raw_entry}` discovery map — used to resolve
  `extends`-chain inheritance (e.g. `binanceusdm` inherits `binance`'s
  `keepAlive: 180000`). A `nil` entry (REST-only exchange with no Pro class)
  yields `none_record/0`.
  """
  @spec build(map() | nil, %{optional(String.t()) => map()}) :: map()
  def build(nil, _lookup), do: none_record()

  def build(entry, lookup) when is_map(entry) and is_map(lookup) do
    chain = ancestry_chain(entry, lookup)
    {keep_alive, ka_from} = resolve_keep_alive(chain)
    {ping_kind, payload, payload_kind, unresolved} = resolve_ping(chain)

    %{
      "ping_kind" => ping_kind,
      "ping_payload" => payload,
      "ping_payload_kind" => payload_kind,
      "keep_alive_ms" => keep_alive,
      "max_ping_pong_misses" => resolve_max_misses(chain),
      "has_pong_handler" => Enum.any?(chain, &any_pong_method?/1),
      "keep_alive_resolved_from" => ka_from,
      "source" => if(ka_from == "base_default", do: "base_default", else: "pro_describe"),
      "unresolved_reason" => unresolved
    }
  end

  # `[self, parent, grandparent, ...]` by walking `extends` through the
  # discovery lookup. Stops when `extends` names a non-WS class (a REST
  # class, absent from the lookup). The seen-set guards against cycles.
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

  # First ancestor whose own streaming block sets `keepAlive`; the head of
  # the chain resolves as "self". Falls back to the base client default.
  @spec resolve_keep_alive([map()]) :: {number(), String.t()}
  defp resolve_keep_alive([head | _] = chain) do
    case Enum.find(chain, &get_in(&1, ["streaming", "keep_alive_ms"])) do
      nil -> {@base_keep_alive_ms, "base_default"}
      ^head -> {get_in(head, ["streaming", "keep_alive_ms"]), "self"}
      ancestor -> {get_in(ancestor, ["streaming", "keep_alive_ms"]), ancestor["id"]}
    end
  end

  @spec resolve_max_misses([map()]) :: number()
  defp resolve_max_misses(chain) do
    case Enum.find_value(chain, &get_in(&1, ["streaming", "max_ping_pong_misses"])) do
      nil -> @base_max_ping_pong_misses
      value -> value
    end
  end

  # First ancestor defining `ping()`, classified structurally. No `ping()`
  # anywhere → native protocol-level frames.
  @spec resolve_ping([map()]) :: {String.t(), map() | nil, String.t() | nil, String.t() | nil}
  defp resolve_ping(chain) do
    case Enum.find(chain, &get_in(&1, ["ping", "defined"])) do
      nil -> {"native_frame", nil, nil, nil}
      entry -> classify_ping(entry["ping"])
    end
  end

  @spec classify_ping(map()) :: {String.t(), map() | nil, String.t() | nil, String.t() | nil}
  defp classify_ping(%{"shape" => "string", "return_value" => %{"value" => v}}) do
    {"string_message", v, "literal", nil}
  end

  defp classify_ping(%{"shape" => "object", "return_value" => %{"value" => v, "kind" => kind}}) do
    {"json_message", v, kind, nil}
  end

  defp classify_ping(_ping) do
    {"unknown", nil, "unresolved", "ping_return_not_literal"}
  end

  # --- Always-emit honest-empty record + closed-vocabulary exposers ---

  @doc """
  The `websocket.heartbeat` record for an exchange with no WebSocket (Pro)
  class. Every derivation field is null/false with
  `unresolved_reason: "no_ws_support"` — mirrors `TestnetUrls.none_record/0`.
  """
  @spec none_record() :: %{String.t() => term()}
  def none_record do
    %{
      "ping_kind" => "none",
      "ping_payload" => nil,
      "ping_payload_kind" => nil,
      "keep_alive_ms" => nil,
      "max_ping_pong_misses" => nil,
      "has_pong_handler" => false,
      "keep_alive_resolved_from" => nil,
      "source" => "none",
      "unresolved_reason" => "no_ws_support"
    }
  end

  @doc "Required keys of a `websocket.heartbeat` record. For contract-test invariants."
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc "Closed vocabulary for `ping_kind`. For contract-test invariants."
  @spec ping_kinds() :: [String.t()]
  def ping_kinds, do: @ping_kinds

  @doc "Closed vocabulary for `source`. For contract-test invariants."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Closed vocabulary for non-null `unresolved_reason`. For contract-test invariants."
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons
end
