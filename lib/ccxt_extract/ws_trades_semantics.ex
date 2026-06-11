defmodule CcxtExtract.WsTradesSemantics do
  @moduledoc """
  Extract and derive per-exchange WebSocket trades update semantics.

  CCXT Pro trade handlers (`handleTrade` / `handleTrades`) normally append
  parsed trades into a bounded cache. This module records only structural
  facts visible in the handler AST: cache constructor type, the `safeString`
  key used as the trade id, the `tradesLimit` / `myTradesLimit` option read,
  and whether the handler appends, replaces, snapshots, or cannot be
  classified.

  Like the other WebSocket extractors, raw discovery entries are
  inheritance-free. `build/2` resolves the `extends` chain before emitting the
  consumer-facing `websocket.trades_semantics` section.
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_trades_semantics.json"

  @public_trade_handlers ~w(handleTrade handleTrades)
  @private_trade_handlers ~w(handleMyTrade handleMyTrades)
  @limit_fields ~w(tradesLimit myTradesLimit)
  @cache_prefix "ArrayCache"

  @update_models ~w(append replace snapshot unknown none)
  @sources ~w(pro_handle_trades none)
  @unresolved_reasons ~w(no_ws_support no_ws_trades trades_not_classifiable)
  @unresolved_entry_reasons ~w(cache_not_classifiable dedup_key_not_classifiable update_model_not_classifiable)
  @required_keys ~w(update_model trades_defined cache_type dedup_key cache_limit_field
                    cache_limit_default my_trades unresolved resolved_from source
                    unresolved_reason)

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
        "trades" => extract_trade_handler(members, @public_trade_handlers),
        "my_trades" => extract_trade_handler(members, @private_trade_handlers)
      }
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_trades" => Enum.count(exchanges, &get_in(&1, ["trades", "defined"])),
      "with_my_trades" => Enum.count(exchanges, &get_in(&1, ["my_trades", "defined"]))
    }
  end

  # --- Extraction ---

  @spec extends_name(map()) :: String.t() | nil
  defp extends_name(%{superClass: %{type: :identifier, name: name}}) when is_binary(name), do: name
  defp extends_name(_class), do: nil

  @spec extract_trade_handler([map()], [String.t()]) :: map()
  defp extract_trade_handler(members, names) do
    case Enum.find(members, &method_named?(&1, names)) do
      nil ->
        absent_handler()

      %{value: fn_expr} ->
        update_model = update_model(fn_expr)
        cache_type = cache_type(fn_expr)
        dedup_key = dedup_key(fn_expr)
        {limit_field, limit_default} = cache_limit(fn_expr)

        %{
          "defined" => true,
          "update_model" => update_model,
          "cache_type" => cache_type,
          "dedup_key" => dedup_key,
          "cache_limit_field" => limit_field,
          "cache_limit_default" => limit_default,
          "unresolved" => unresolved(update_model, cache_type, dedup_key)
        }
    end
  end

  @spec absent_handler() :: map()
  defp absent_handler do
    %{
      "defined" => false,
      "update_model" => nil,
      "cache_type" => nil,
      "dedup_key" => nil,
      "cache_limit_field" => nil,
      "cache_limit_default" => nil,
      "unresolved" => []
    }
  end

  @spec update_model(map()) :: String.t()
  defp update_model(fn_expr) do
    cond do
      has_member_call?(fn_expr, "append") -> "append"
      has_member_call?(fn_expr, "reset") or has_member_call?(fn_expr, "clear") -> "replace"
      cache_type(fn_expr) != nil -> "snapshot"
      true -> "unknown"
    end
  end

  @spec cache_type(map()) :: String.t() | nil
  defp cache_type(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :new_expression, callee: %{type: :identifier, name: name}} ->
        if String.starts_with?(name, @cache_prefix), do: {:keep, name}, else: :skip

      _ ->
        :skip
    end)
    |> List.first()
  end

  @spec dedup_key(map()) :: String.t() | nil
  defp dedup_key(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :call_expression, callee: callee, arguments: [first, key | _rest]} ->
        if safe_string_callee?(callee) and tradeish?(first), do: {:keep, string_literal_value(key)}, else: :skip

      _ ->
        :skip
    end)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  @spec cache_limit(map()) :: {String.t() | nil, number() | nil}
  defp cache_limit(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :call_expression, callee: callee, arguments: [_source, field | rest]} ->
        field_name = string_literal_value(field)

        if safe_callee?(callee) and field_name in @limit_fields do
          {:keep, {field_name, numeric_literal_value(List.first(rest))}}
        else
          :skip
        end

      _ ->
        :skip
    end)
    |> List.first()
    |> case do
      nil -> {nil, nil}
      pair -> pair
    end
  end

  @spec unresolved(String.t(), String.t() | nil, String.t() | nil) :: [map()]
  defp unresolved(update_model, cache_type, dedup_key) do
    Enum.reject(
      [
        if(update_model == "unknown", do: %{"reason" => "update_model_not_classifiable"}),
        if(is_nil(cache_type), do: %{"reason" => "cache_not_classifiable"}),
        if(is_nil(dedup_key), do: %{"reason" => "dedup_key_not_classifiable"})
      ],
      &is_nil/1
    )
  end

  @spec method_named?(map(), [String.t()]) :: boolean()
  defp method_named?(%{type: :method_definition, key: %{name: name}}, names), do: name in names
  defp method_named?(_member, _names), do: false

  @spec has_member_call?(map(), String.t()) :: boolean()
  defp has_member_call?(fn_expr, name) do
    fn_expr
    |> OXC.collect(fn
      %{type: :call_expression, callee: %{type: :member_expression, property: %{type: :identifier, name: ^name}}} ->
        {:keep, true}

      _ ->
        :skip
    end)
    |> Kernel.!=([])
  end

  @spec safe_string_callee?(map()) :: boolean()
  defp safe_string_callee?(%{
         type: :member_expression,
         computed: false,
         object: %{type: :this_expression},
         property: %{type: :identifier, name: name}
       }),
       do: String.starts_with?(name, "safeString")

  defp safe_string_callee?(_callee), do: false

  @spec safe_callee?(map()) :: boolean()
  defp safe_callee?(%{
         type: :member_expression,
         computed: false,
         object: %{type: :this_expression},
         property: %{type: :identifier, name: name}
       }),
       do: String.starts_with?(name, "safe")

  defp safe_callee?(_callee), do: false

  @spec tradeish?(map()) :: boolean()
  defp tradeish?(%{type: :identifier, name: name}) when is_binary(name), do: String.contains?(name, "trade")
  defp tradeish?(_node), do: false

  @spec string_literal_value(map() | nil) :: String.t() | nil
  defp string_literal_value(%{type: type, value: value}) when type in [:literal, :string_literal] and is_binary(value),
    do: value

  defp string_literal_value(_node), do: nil

  @spec numeric_literal_value(map() | nil) :: number() | nil
  defp numeric_literal_value(%{type: type, value: value}) when type in [:literal, :number_literal] and is_number(value),
    do: value

  defp numeric_literal_value(_node), do: nil

  # --- Derivation ---

  @doc """
  Project a raw discovery entry into the `websocket.trades_semantics` section.
  """
  @spec build(map() | nil, %{optional(String.t()) => map()}) :: map()
  def build(nil, _lookup), do: none_record()

  def build(entry, lookup) when is_map(entry) and is_map(lookup) do
    chain = ancestry_chain(entry, lookup)
    trades_entry = Enum.find(chain, &handler_defined?(&1, "trades"))
    my_trades_entry = Enum.find(chain, &handler_defined?(&1, "my_trades"))

    case trades_entry do
      nil -> empty_record("no_ws_trades", my_trades_entry, chain)
      _ -> classify(trades_entry, my_trades_entry, chain)
    end
  end

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

  @spec handler_defined?(map(), String.t()) :: boolean()
  defp handler_defined?(entry, key), do: get_in(entry, [key, "defined"]) == true

  @spec classify(map(), map() | nil, [map()]) :: map()
  defp classify(trades_entry, my_trades_entry, [head | _]) do
    trades = trades_entry["trades"]
    update_model = trades["update_model"] || "unknown"

    %{
      "update_model" => update_model,
      "trades_defined" => true,
      "cache_type" => trades["cache_type"],
      "dedup_key" => trades["dedup_key"],
      "cache_limit_field" => trades["cache_limit_field"],
      "cache_limit_default" => trades["cache_limit_default"],
      "my_trades" => my_trades_record(my_trades_entry),
      "unresolved" => trades["unresolved"] || [],
      "resolved_from" => if(trades_entry["id"] == head["id"], do: "self", else: trades_entry["id"]),
      "source" => "pro_handle_trades",
      "unresolved_reason" => if(update_model == "unknown", do: "trades_not_classifiable")
    }
  end

  @spec empty_record(String.t(), map() | nil, [map()]) :: map()
  defp empty_record(reason, my_trades_entry, chain) do
    none_record()
    |> Map.put("unresolved_reason", reason)
    |> Map.put("my_trades", my_trades_record(my_trades_entry))
    |> maybe_mark_source(my_trades_entry, chain)
  end

  @spec maybe_mark_source(map(), map() | nil, [map()]) :: map()
  defp maybe_mark_source(record, nil, _chain), do: record
  defp maybe_mark_source(record, _my_trades_entry, []), do: record
  defp maybe_mark_source(record, _my_trades_entry, _chain), do: Map.put(record, "source", "pro_handle_trades")

  @spec my_trades_record(map() | nil) :: map()
  defp my_trades_record(nil) do
    %{
      "defined" => false,
      "cache_type" => nil,
      "dedup_key" => nil,
      "cache_limit_field" => nil,
      "cache_limit_default" => nil
    }
  end

  defp my_trades_record(entry) do
    my_trades = entry["my_trades"] || %{}

    %{
      "defined" => my_trades["defined"] == true,
      "cache_type" => my_trades["cache_type"],
      "dedup_key" => my_trades["dedup_key"],
      "cache_limit_field" => my_trades["cache_limit_field"],
      "cache_limit_default" => my_trades["cache_limit_default"]
    }
  end

  @doc """
  The honest-empty `websocket.trades_semantics` record for an exchange with no
  WebSocket Pro class.
  """
  @spec none_record() :: %{String.t() => term()}
  def none_record do
    %{
      "update_model" => "none",
      "trades_defined" => false,
      "cache_type" => nil,
      "dedup_key" => nil,
      "cache_limit_field" => nil,
      "cache_limit_default" => nil,
      "my_trades" => my_trades_record(nil),
      "unresolved" => [],
      "resolved_from" => nil,
      "source" => "none",
      "unresolved_reason" => "no_ws_support"
    }
  end

  @doc "Required keys of a `websocket.trades_semantics` record."
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required_keys

  @doc "Closed vocabulary for `update_model`."
  @spec update_models() :: [String.t()]
  def update_models, do: @update_models

  @doc "Closed vocabulary for `source`."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Closed vocabulary for non-null `unresolved_reason`."
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: @unresolved_reasons

  @doc "Closed vocabulary for per-shape unresolved reasons."
  @spec unresolved_entry_reasons() :: [String.t()]
  def unresolved_entry_reasons, do: @unresolved_entry_reasons
end
