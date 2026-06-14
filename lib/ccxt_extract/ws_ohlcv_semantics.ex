defmodule CcxtExtract.WsOhlcvSemantics do
  @moduledoc """
  Extract and derive per-exchange WebSocket OHLCV (candle) update semantics.

  CCXT's `handleOHLCV(client, message)` (in `priv/ccxt/ts/src/pro/<id>.ts`)
  updates the most recent candle in place on every tick and appends a new
  candle when the bucket rolls over, keyed by timeframe, into a bounded
  `ArrayCacheByTimestamp` capped by `ohlcvLimit` (read from options as
  `OHLCVLimit` with default 1000). This module records only structural facts
  visible in the handler AST: the cache constructor, the literal key used to
  extract the timeframe dimension (e.g. kline 'i'), the closed/confirm signal
  field when present (binance 'x', bybit 'confirm'), and the cache-limit field.

  Raw discovery entries are inheritance-free. `build/2` resolves the `extends`
  chain before emitting the consumer-facing `websocket.ohlcv_semantics` section.
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_ohlcv_semantics.json"

  @ohlcv_handler "handleOHLCV"
  @cache_name "ArrayCacheByTimestamp"
  @ohlcv_limit_field "OHLCVLimit"

  @update_models ~w(replace_latest_then_append unknown none)
  @sources ~w(pro_handle_ohlcv none)
  @unresolved_reasons ~w(no_ws_support no_ws_ohlcv ohlcv_not_classifiable)
  @unresolved_entry_reasons ~w(cache_not_classifiable timeframe_key_not_classifiable closed_signal_not_classifiable)
  @required_keys ~w(update_model ohlcv_defined timeframe_key closed_signal cache_type
                    cache_limit_field cache_limit_default unresolved resolved_from source
                    unresolved_reason)

  @timeframe_keys ~w(i interval)
  @closed_signal_keys ~w(confirm x closed)

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
        "ohlcv" => extract_ohlcv_handler(members)
      }
    end
  end

  @impl true
  @spec write_stats([map()]) :: map()
  def write_stats(exchanges) do
    %{
      "with_ohlcv" => Enum.count(exchanges, &get_in(&1, ["ohlcv", "defined"]))
    }
  end

  # --- Extraction ---

  @spec extends_name(map()) :: String.t() | nil
  defp extends_name(%{superClass: %{type: :identifier, name: name}}) when is_binary(name), do: name
  defp extends_name(_class), do: nil

  @spec extract_ohlcv_handler([map()]) :: map()
  defp extract_ohlcv_handler(members) do
    case Enum.find(members, &method_named?(&1, @ohlcv_handler)) do
      nil ->
        absent_handler()

      %{value: fn_expr} ->
        cache_type = cache_type(fn_expr)
        update_model = if cache_type == @cache_name, do: "replace_latest_then_append", else: "unknown"
        {limit_field, limit_default} = ohlcv_limit(fn_expr)
        timeframe_key = timeframe_key(fn_expr)
        closed_signal = closed_signal(fn_expr)

        %{
          "defined" => true,
          "update_model" => update_model,
          "timeframe_key" => timeframe_key,
          "closed_signal" => closed_signal,
          "cache_type" => cache_type,
          "cache_limit_field" => limit_field,
          "cache_limit_default" => limit_default,
          "unresolved" => unresolved(update_model, cache_type, timeframe_key, closed_signal)
        }
    end
  end

  @spec absent_handler() :: map()
  defp absent_handler do
    %{
      "defined" => false,
      "update_model" => nil,
      "timeframe_key" => nil,
      "closed_signal" => nil,
      "cache_type" => nil,
      "cache_limit_field" => nil,
      "cache_limit_default" => nil,
      "unresolved" => []
    }
  end

  @spec cache_type(map()) :: String.t() | nil
  defp cache_type(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :new_expression, callee: %{type: :identifier, name: @cache_name}} ->
        {:keep, @cache_name}

      _ ->
        :skip
    end)
    |> List.first()
  end

  @spec ohlcv_limit(map()) :: {String.t() | nil, number() | nil}
  defp ohlcv_limit(fn_expr) do
    fn_expr
    |> OXC.collect(fn
      %{type: :call_expression, callee: callee, arguments: [_source, field | rest]} ->
        field_name = string_literal_value(field)

        if safe_callee?(callee) and field_name == @ohlcv_limit_field do
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

  @spec timeframe_key(map()) :: String.t() | nil
  defp timeframe_key(fn_expr), do: first_safe_literal(fn_expr, @timeframe_keys)

  @spec closed_signal(map()) :: String.t() | nil
  defp closed_signal(fn_expr), do: first_safe_literal(fn_expr, @closed_signal_keys)

  @spec first_safe_literal(map(), [String.t()]) :: String.t() | nil
  defp first_safe_literal(fn_expr, allowed) do
    fn_expr
    |> OXC.collect(fn
      %{type: :call_expression, callee: callee, arguments: [_first, key | _rest]} ->
        keyed_literal(callee, key, allowed)

      _ ->
        :skip
    end)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  @spec keyed_literal(map(), map(), [String.t()]) :: {:keep, String.t()} | :skip
  defp keyed_literal(callee, key, allowed) do
    value = string_literal_value(key)
    if safe_callee?(callee) and value in allowed, do: {:keep, value}, else: :skip
  end

  @spec unresolved(String.t(), String.t() | nil, String.t() | nil, String.t() | nil) :: [map()]
  defp unresolved(_update_model, cache_type, timeframe_key, closed_signal) do
    Enum.reject(
      [
        if(is_nil(cache_type), do: %{"reason" => "cache_not_classifiable"}),
        if(is_nil(timeframe_key), do: %{"reason" => "timeframe_key_not_classifiable"}),
        if(is_nil(closed_signal), do: %{"reason" => "closed_signal_not_classifiable"})
      ],
      &is_nil/1
    )
  end

  @spec method_named?(map(), String.t()) :: boolean()
  defp method_named?(%{type: :method_definition, key: %{name: name}}, name), do: true
  defp method_named?(_member, _name), do: false

  @spec safe_callee?(map()) :: boolean()
  defp safe_callee?(%{
         type: :member_expression,
         computed: false,
         object: %{type: :this_expression},
         property: %{type: :identifier, name: name}
       }), do: String.starts_with?(name, "safe")

  defp safe_callee?(_callee), do: false

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
  Project a raw discovery entry into the `websocket.ohlcv_semantics` section.
  """
  @spec build(map() | nil, %{optional(String.t()) => map()}) :: map()
  def build(nil, _lookup), do: none_record()

  def build(entry, lookup) when is_map(entry) and is_map(lookup) do
    chain = ancestry_chain(entry, lookup)
    ohlcv_entry = Enum.find(chain, &handler_defined?(&1))

    case ohlcv_entry do
      nil -> empty_record("no_ws_ohlcv", chain)
      _ -> classify(ohlcv_entry, chain)
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

  @spec handler_defined?(map()) :: boolean()
  defp handler_defined?(entry), do: get_in(entry, ["ohlcv", "defined"]) == true

  @spec classify(map(), [map()]) :: map()
  defp classify(ohlcv_entry, [head | _]) do
    ohlcv = ohlcv_entry["ohlcv"]
    update_model = ohlcv["update_model"] || "unknown"

    %{
      "update_model" => update_model,
      "ohlcv_defined" => true,
      "timeframe_key" => ohlcv["timeframe_key"],
      "closed_signal" => ohlcv["closed_signal"],
      "cache_type" => ohlcv["cache_type"],
      "cache_limit_field" => ohlcv["cache_limit_field"],
      "cache_limit_default" => ohlcv["cache_limit_default"],
      "unresolved" => ohlcv["unresolved"] || [],
      "resolved_from" => if(ohlcv_entry["id"] == head["id"], do: "self", else: ohlcv_entry["id"]),
      "source" => "pro_handle_ohlcv",
      "unresolved_reason" => if(update_model == "unknown", do: "ohlcv_not_classifiable")
    }
  end

  @spec empty_record(String.t(), [map()]) :: map()
  defp empty_record(reason, _chain) do
    Map.put(none_record(), "unresolved_reason", reason)
  end

  @doc """
  The honest-empty `websocket.ohlcv_semantics` record for an exchange with no
  WebSocket Pro class.
  """
  @spec none_record() :: %{String.t() => term()}
  def none_record do
    %{
      "update_model" => "none",
      "ohlcv_defined" => false,
      "timeframe_key" => nil,
      "closed_signal" => nil,
      "cache_type" => nil,
      "cache_limit_field" => nil,
      "cache_limit_default" => nil,
      "unresolved" => [],
      "resolved_from" => nil,
      "source" => "none",
      "unresolved_reason" => "no_ws_support"
    }
  end

  @doc "Required keys of a `websocket.ohlcv_semantics` record."
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
