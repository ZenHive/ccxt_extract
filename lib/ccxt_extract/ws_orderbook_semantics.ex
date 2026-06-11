defmodule CcxtExtract.WsOrderbookSemantics do
  @moduledoc """
  Extract and derive, per WS exchange, how the orderbook channel signals a
  full snapshot vs an incremental delta — and the fields a consumer needs to
  apply deltas correctly.

  CCXT routes an inbound orderbook frame through `handleOrderBook(client,
  message)` (and the helpers `handleOrderBookMessage` / `handleSnapshot` /
  `handleChecksum` / `checkOrderBookChecksum`) in
  `priv/ccxt/ts/src/pro/<id>.ts`. Across exchanges the snapshot-vs-delta
  distinction is encoded one of three ways:

    * a **discriminator field** read off the frame and compared to string
      literals — bybit `type: 'snapshot' | 'delta'`, okx `action: 'snapshot'
      | 'update'`, kraken `type: 'snapshot' | 'update'`;
    * a **REST-seeded snapshot** followed by deltas keyed by first/final/
      previous update ids — binance `U` / `u` (+ `pu` on futures), okx
      `seqId` / `prevSeqId`;
    * an **integrity checksum** the consumer re-computes — kraken
      `checksum` verified with `crc32`.

  ## Two roles

  This module is both an **extractor** and a **derivation**, mirroring
  `CcxtExtract.WsDispatch` / `CcxtExtract.WsAuth` / `CcxtExtract.WsHeartbeat`:

    * Extractor (`extract/0`, `write!/2` via `CcxtExtract.OXCExtractor`) —
      parses every `pro/*.ts` into raw, inheritance-free facts written to
      `priv/discoveries/ws_orderbook_semantics.json`. Each entry records only
      what its own file's orderbook handlers state.
    * Derivation (`build/2`) — projects one raw entry plus the full discovery
      lookup into the consumer-facing `websocket.orderbook_semantics` section,
      resolving `extends`-chain inheritance (a variant/alias Pro class without
      its own orderbook handler inherits the parent's semantics, as
      `WsHeartbeat.build/2` walks `extends`).

  ## Structural classification, not interpretation

  Every fact is read straight off literal AST arguments — the `safeInteger`/
  `safeString`/`safeValue` key strings, the `===` comparison literals, the
  presence of a `handleDeltas` call vs an `orderbook.reset(...)` /
  `this.orderBook(...)` reset. Nothing is inferred from server behaviour. The
  snapshot/delta discriminator is the frame key whose compared literals fall
  in the closed snapshot/delta vocabulary; `sequence_fields` is the subset of
  integer-accessor keys in the closed `sequence_field_vocab`; `checksum` is
  present only when a checksum key is read or `crc32` is computed in the
  handler. An orderbook handler whose apply strategy is neither incremental
  nor replace lands in `apply_mode: "unknown"` tagged
  `unresolved_reason: "orderbook_not_classifiable"`, never a guessed mode.

  ## Known limitation

  Checksum detection is scoped to the orderbook handler methods. An exchange
  that reads its wire checksum field outside this set carries
  `checksum.present: false` — honest about what the scanned handlers state.
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_orderbook_semantics.json"

  @apply_modes ~w(incremental replace both unknown none)
  @sources ~w(pro_handle_orderbook none)
  @unresolved_reasons ~w(no_ws_support no_ws_orderbook orderbook_not_classifiable)
  @algorithms ~w(crc32)
  @required_keys ~w(apply_mode handle_orderbook_defined discriminator sequence_fields
                    checksum resolved_from source unresolved_reason)

  # Orderbook handler methods scanned for raw facts. handleOrderBook /
  # handleOrderBookMessage are the entry points; handleSnapshot / handleChecksum
  # / checkOrderBookChecksum carry snapshot-reset and checksum facts on the
  # exchanges that split them out.
  @handler_methods ~w(handleOrderBook handleOrderBookMessage handleSnapshot
                      handleChecksum checkOrderBookChecksum)
  # The two entry points whose presence means "this class handles orderbooks".
  @entry_methods ~w(handleOrderBook handleOrderBookMessage)

  # Closed vocabularies for the snapshot/delta discriminator literals.
  # 'partial' is bitmex's full-table snapshot action, not a delta.
  @snapshot_values ~w(snapshot partial)
  @delta_values ~w(update delta change increment incremental)

  # Closed vocabulary of sequence / ordering id keys. The integer-accessor
  # keys read by the handlers are intersected with this set to drop timestamps
  # (ts / E / T / time) that are not sequence fields.
  @sequence_field_vocab ~w(U u pu fu lu seqId prevSeqId seq prevSeq nonce
                           lastUpdateId sequence seqNum version changeId
                           prevChangeId change_id prev_change_id
                           first_update_id last_update_id)

  # Wire checksum key strings read via a safe-accessor.
  @checksum_keys ~w(checksum crc32 crc)
  # Integer safe-accessors whose key arguments are candidate sequence fields.
  @integer_accessors ~w(safeInteger safeInteger2 safeIntegerProduct safeIntegerN safeInteger64)

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
        "orderbook" => extract_orderbook(members)
      }
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_handle_orderbook" => Enum.count(exchanges, &orderbook_defined?/1),
      "with_discriminator" => Enum.count(exchanges, &(orderbook_comparisons(&1) != [])),
      "with_checksum" => Enum.count(exchanges, &orderbook_checksum_present?/1)
    }
  end

  # --- Extraction: class shape ---

  @spec extends_name(map()) :: String.t() | nil
  defp extends_name(%{superClass: %{type: :identifier, name: name}}) when is_binary(name), do: name
  defp extends_name(_class), do: nil

  # --- Extraction: orderbook handlers ---

  @spec extract_orderbook([map()]) :: map()
  defp extract_orderbook(members) do
    bodies = Enum.filter(members, &(method_name(&1) in @handler_methods))

    case bodies do
      [] ->
        absent_orderbook()

      _ ->
        bindings = Enum.reduce(bodies, %{}, &Map.merge(&2, safe_string_bindings(&1)))

        %{
          "defined" => Enum.any?(members, &(method_name(&1) in @entry_methods)),
          "methods" => bodies |> Enum.map(&method_name/1) |> Enum.uniq() |> Enum.sort(),
          "comparisons" => collect_comparisons(bodies, bindings),
          "sequence_keys" => collect_sequence_keys(bodies),
          "checksum" => collect_checksum(bodies),
          "applies_deltas" => Enum.any?(bodies, &applies_deltas?/1),
          "resets_book" => Enum.any?(bodies, &resets_book?/1)
        }
    end
  end

  @spec absent_orderbook() :: map()
  defp absent_orderbook do
    %{
      "defined" => false,
      "methods" => [],
      "comparisons" => [],
      "sequence_keys" => [],
      "checksum" => %{"present" => false, "field" => nil, "algorithm" => nil},
      "applies_deltas" => false,
      "resets_book" => false
    }
  end

  # `const <name> = this.safe*(<obj>, '<key>', ...)` declarators → name → first
  # literal key. Used to resolve the identifier side of a discriminator
  # comparison back to the frame field it was read from.
  @spec safe_string_bindings(map()) :: %{String.t() => String.t()}
  defp safe_string_bindings(method) do
    method
    |> OXC.collect(fn
      %{type: :variable_declarator, id: %{type: :identifier, name: name}, init: init} ->
        case safe_accessor_first_key(init) do
          nil -> :skip
          key -> {:keep, {name, key}}
        end

      _ ->
        :skip
    end)
    |> Map.new()
  end

  # Discriminator candidates: every `<ident> === '<lit>'` (or inline
  # `this.safe*(msg,'key') === '<lit>'`) reduced to `{field, value}`. The
  # field is the safe-accessor key the identifier was bound to, or the inline
  # accessor's key. Deduped and sorted for determinism.
  @spec collect_comparisons([map()], %{String.t() => String.t()}) :: [map()]
  defp collect_comparisons(bodies, bindings) do
    bodies
    |> Enum.flat_map(fn body ->
      OXC.collect(body, fn
        %{type: :binary_expression, operator: op, left: l, right: r} when op in ["===", "=="] ->
          {:keep, comparison_pair(l, r, bindings)}

        _ ->
          :skip
      end)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["field"], &1["value"]})
  end

  # One side a string literal, the other a discriminator field expression.
  @spec comparison_pair(map(), map(), %{String.t() => String.t()}) :: map() | nil
  defp comparison_pair(left, right, bindings) do
    case {string_literal_value(left), string_literal_value(right)} do
      {nil, value} when is_binary(value) -> pair_for(left, value, bindings)
      {value, nil} when is_binary(value) -> pair_for(right, value, bindings)
      _ -> nil
    end
  end

  @spec pair_for(map(), String.t(), %{String.t() => String.t()}) :: map() | nil
  defp pair_for(field_node, value, bindings) do
    case comparison_field(field_node, bindings) do
      nil -> nil
      field -> %{"field" => field, "value" => value}
    end
  end

  # Resolve the non-literal side of a comparison to the frame field it reads:
  # an identifier through the safe-accessor bindings, or an inline accessor.
  @spec comparison_field(map(), %{String.t() => String.t()}) :: String.t() | nil
  defp comparison_field(%{type: :identifier, name: name}, bindings), do: Map.get(bindings, name)
  defp comparison_field(%{type: :call_expression} = call, _bindings), do: safe_accessor_first_key(call)
  defp comparison_field(_node, _bindings), do: nil

  # Every string-literal key read via an integer safe-accessor in the handlers.
  @spec collect_sequence_keys([map()]) :: [String.t()]
  defp collect_sequence_keys(bodies) do
    bodies
    |> Enum.flat_map(fn body -> OXC.collect(body, &integer_accessor_keys/1) end)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Keep the string-literal key args of an integer safe-accessor call.
  @spec integer_accessor_keys(map()) :: {:keep, [String.t()]} | :skip
  defp integer_accessor_keys(%{type: :call_expression, callee: callee, arguments: [_obj | keys]}) do
    if integer_accessor?(callee),
      do: {:keep, keys |> Enum.map(&string_literal_value/1) |> Enum.reject(&is_nil/1)},
      else: :skip
  end

  defp integer_accessor_keys(_node), do: :skip

  # Checksum facts: present when a checksum key is read via a safe-accessor or
  # `crc32` is computed. field is the safe-accessor key; algorithm is "crc32"
  # when a crc32 call/identifier appears in the handler subtree.
  @spec collect_checksum([map()]) :: map()
  defp collect_checksum(bodies) do
    field = Enum.find_value(bodies, &checksum_accessor_key/1)
    crc32? = Enum.any?(bodies, &crc32?/1)

    %{
      "present" => not is_nil(field) or crc32?,
      "field" => field,
      "algorithm" => if(crc32?, do: "crc32")
    }
  end

  @spec checksum_accessor_key(map()) :: String.t() | nil
  defp checksum_accessor_key(body) do
    body
    |> OXC.collect(fn
      %{type: :call_expression, callee: callee, arguments: [_obj | keys]} ->
        if safe_callee?(callee) do
          first_checksum_key(keys)
        else
          :skip
        end

      _ ->
        :skip
    end)
    |> List.first()
  end

  @spec first_checksum_key([map()]) :: {:keep, String.t()} | :skip
  defp first_checksum_key(keys) do
    case keys |> Enum.map(&string_literal_value/1) |> Enum.find(&(&1 in @checksum_keys)) do
      nil -> :skip
      key -> {:keep, key}
    end
  end

  # `this.crc32(...)` call or a bare `crc32` identifier reference.
  @spec crc32?(map()) :: boolean()
  defp crc32?(body) do
    body
    |> OXC.collect(fn
      %{type: :member_expression, computed: false, property: %{type: :identifier, name: "crc32"}} -> {:keep, true}
      %{type: :identifier, name: "crc32"} -> {:keep, true}
      _ -> :skip
    end)
    |> Kernel.!=([])
  end

  # A call to `this.handleDeltas` / `this.handleDelta` / `this.customHandleDeltas`
  # — the structural marker that the handler applies incremental row updates.
  @spec applies_deltas?(map()) :: boolean()
  defp applies_deltas?(body) do
    body
    |> OXC.collect(fn
      %{
        type: :call_expression,
        callee: %{type: :member_expression, computed: false, property: %{type: :identifier, name: name}}
      } ->
        if String.contains?(name, "andleDelta"), do: {:keep, true}, else: :skip

      _ ->
        :skip
    end)
    |> Kernel.!=([])
  end

  # A `<x>.reset(...)` call or a fresh `this.orderBook(...)` construction — the
  # structural marker that the handler can fully replace the local book.
  @spec resets_book?(map()) :: boolean()
  defp resets_book?(body) do
    body
    |> OXC.collect(fn
      %{type: :call_expression, callee: %{type: :member_expression, computed: false, property: %{name: "reset"}}} ->
        {:keep, true}

      %{
        type: :call_expression,
        callee: %{
          type: :member_expression,
          computed: false,
          object: %{type: :this_expression},
          property: %{type: :identifier, name: "orderBook"}
        }
      } ->
        {:keep, true}

      _ ->
        :skip
    end)
    |> Kernel.!=([])
  end

  # --- Shared AST helpers ---

  @spec method_name(map()) :: String.t() | nil
  defp method_name(%{type: :method_definition, key: %{name: name}}) when is_binary(name), do: name
  defp method_name(_member), do: nil

  @spec safe_accessor_first_key(map() | nil) :: String.t() | nil
  defp safe_accessor_first_key(%{type: :call_expression, callee: callee, arguments: [_obj | keys]}) do
    if safe_callee?(callee) do
      keys |> Enum.map(&string_literal_value/1) |> Enum.find(&(&1 not in [nil, ""]))
    end
  end

  defp safe_accessor_first_key(_node), do: nil

  @spec integer_accessor?(map()) :: boolean()
  defp integer_accessor?(%{
         type: :member_expression,
         computed: false,
         object: %{type: :this_expression},
         property: %{type: :identifier, name: name}
       }),
       do: name in @integer_accessors

  defp integer_accessor?(_node), do: false

  @spec safe_callee?(map()) :: boolean()
  defp safe_callee?(%{
         type: :member_expression,
         computed: false,
         object: %{type: :this_expression},
         property: %{type: :identifier, name: name}
       }),
       do: String.starts_with?(name, "safe")

  defp safe_callee?(_node), do: false

  @spec string_literal_value(map() | nil) :: String.t() | nil
  defp string_literal_value(%{type: type, value: value}) when type in [:literal, :string_literal] and is_binary(value),
    do: value

  defp string_literal_value(_node), do: nil

  @spec orderbook_defined?(map()) :: boolean()
  defp orderbook_defined?(entry), do: get_in(entry, ["orderbook", "defined"]) == true

  @spec orderbook_comparisons(map()) :: [map()]
  defp orderbook_comparisons(entry), do: get_in(entry, ["orderbook", "comparisons"]) || []

  @spec orderbook_checksum_present?(map()) :: boolean()
  defp orderbook_checksum_present?(entry), do: get_in(entry, ["orderbook", "checksum", "present"]) == true

  # --- Derivation ---

  @doc """
  Project a raw discovery entry into the `websocket.orderbook_semantics`
  section.

  `lookup` is the full `%{id => raw_entry}` discovery map — used to resolve
  `extends`-chain inheritance (a variant/alias Pro class without its own
  orderbook handler inherits the parent's semantics). A `nil` entry
  (REST-only exchange with no Pro class) yields `none_record/0`. A Pro class
  with no orderbook handler anywhere in its chain yields an `apply_mode:
  "none"` record tagged `unresolved_reason: "no_ws_orderbook"`.
  """
  @spec build(map() | nil, %{optional(String.t()) => map()}) :: map()
  def build(nil, _lookup), do: none_record()

  def build(entry, lookup) when is_map(entry) and is_map(lookup) do
    chain = ancestry_chain(entry, lookup)

    case Enum.find(chain, &orderbook_defined?/1) do
      nil -> empty_record("no_ws_orderbook")
      ob_entry -> classify(ob_entry, chain)
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

  # Project the most-derived orderbook handler in the chain. Overriding the
  # handler in JS replaces it wholesale, so its facts are used as-is.
  @spec classify(map(), [map()]) :: map()
  defp classify(ob_entry, [head | _]) do
    ob = ob_entry["orderbook"]
    {apply_mode, unresolved} = classify_apply_mode(ob)

    %{
      "apply_mode" => apply_mode,
      "handle_orderbook_defined" => true,
      "discriminator" => derive_discriminator(ob["comparisons"] || []),
      "sequence_fields" => derive_sequence_fields(ob["sequence_keys"] || []),
      "checksum" => ob["checksum"] || %{"present" => false, "field" => nil, "algorithm" => nil},
      "resolved_from" => if(ob_entry["id"] == head["id"], do: "self", else: ob_entry["id"]),
      "source" => "pro_handle_orderbook",
      "unresolved_reason" => unresolved
    }
  end

  # Total structural classifier over the delta/reset markers.
  @spec classify_apply_mode(map()) :: {String.t(), String.t() | nil}
  defp classify_apply_mode(ob) do
    case {ob["applies_deltas"] == true, ob["resets_book"] == true} do
      {true, true} -> {"both", nil}
      {true, false} -> {"incremental", nil}
      {false, true} -> {"replace", nil}
      {false, false} -> {"unknown", "orderbook_not_classifiable"}
    end
  end

  # The discriminator field is the frame key whose compared literals fall in
  # the snapshot/delta vocabulary (the field with the most such hits, ties
  # broken by name). snapshot/delta values are split by vocabulary.
  @spec derive_discriminator([map()]) :: map()
  defp derive_discriminator(comparisons) do
    vocab = @snapshot_values ++ @delta_values

    relevant = Enum.filter(comparisons, &(&1["value"] in vocab))

    case relevant do
      [] ->
        %{"field" => nil, "snapshot_values" => [], "delta_values" => []}

      _ ->
        field =
          relevant
          |> Enum.group_by(& &1["field"])
          |> Enum.max_by(fn {name, hits} -> {length(hits), -byte_weight(name)} end)
          |> elem(0)

        values = for c <- relevant, c["field"] == field, do: c["value"]

        %{
          "field" => field,
          "snapshot_values" => values |> Enum.filter(&(&1 in @snapshot_values)) |> Enum.uniq() |> Enum.sort(),
          "delta_values" => values |> Enum.filter(&(&1 in @delta_values)) |> Enum.uniq() |> Enum.sort()
        }
    end
  end

  # Deterministic tie-break weight so `max_by` prefers the lexicographically
  # smaller field name on an equal hit count.
  @spec byte_weight(String.t()) :: integer()
  defp byte_weight(name), do: :erlang.phash2(name, 1_000_000)

  @spec derive_sequence_fields([String.t()]) :: [String.t()]
  defp derive_sequence_fields(keys) do
    keys |> Enum.filter(&(&1 in @sequence_field_vocab)) |> Enum.uniq() |> Enum.sort()
  end

  # --- Always-emit honest-empty record + closed-vocabulary exposers ---

  @doc """
  The `websocket.orderbook_semantics` record for an exchange with no WebSocket
  (Pro) class. `apply_mode: "none"`, `unresolved_reason: "no_ws_support"` —
  mirrors `CcxtExtract.WsDispatch.none_record/0`.
  """
  @spec none_record() :: %{String.t() => term()}
  def none_record, do: empty_record("no_ws_support")

  @spec empty_record(String.t()) :: %{String.t() => term()}
  defp empty_record(reason) do
    %{
      "apply_mode" => "none",
      "handle_orderbook_defined" => false,
      "discriminator" => %{"field" => nil, "snapshot_values" => [], "delta_values" => []},
      "sequence_fields" => [],
      "checksum" => %{"present" => false, "field" => nil, "algorithm" => nil},
      "resolved_from" => nil,
      "source" => "none",
      "unresolved_reason" => reason
    }
  end

  @doc "Required keys of a `websocket.orderbook_semantics` record. For contract-test invariants."
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc "Closed vocabulary for `apply_mode`. For contract-test invariants."
  @spec apply_modes() :: [String.t()]
  def apply_modes, do: @apply_modes

  @doc "Closed vocabulary for `source`. For contract-test invariants."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Closed vocabulary for non-null `unresolved_reason`. For contract-test invariants."
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons

  @doc "Closed vocabulary for non-null `checksum.algorithm`. For contract-test invariants."
  @spec algorithms() :: [String.t()]
  def algorithms, do: @algorithms

  @doc "Closed vocabulary of recognized sequence/ordering id keys. For contract-test invariants."
  @spec sequence_field_vocab() :: [String.t()]
  def sequence_field_vocab, do: @sequence_field_vocab

  @doc "Closed vocabulary of recognized snapshot discriminator literals. For contract-test invariants."
  @spec snapshot_value_vocab() :: [String.t()]
  def snapshot_value_vocab, do: @snapshot_values

  @doc "Closed vocabulary of recognized delta discriminator literals. For contract-test invariants."
  @spec delta_value_vocab() :: [String.t()]
  def delta_value_vocab, do: @delta_values
end
