defmodule CcxtExtract.Pipeline do
  @moduledoc """
  Assemble per-exchange JSON files from all extraction outputs.

  Reads discovery data produced by individual extractors (QuickBEAM runtime
  values + OXC AST data) and combines them into validated per-exchange JSON
  files conforming to `exchange_v1.json` schema.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.Pipeline.extract()
      CcxtExtract.Pipeline.write!(exchanges)

  ## Options

    * `:discoveries_dir` — override input directory (for testing)
    * `:ccxt_version` — override version (auto-read from ccxt_version.json)
    * `:extracted_at` — override timestamp (defaults to now, use for determinism)
  """

  alias CcxtExtract.Paths
  alias CcxtExtract.Schema

  require Logger

  @output_dir "output"

  # --- Public API ---

  @doc """
  Read all discovery data, assemble per-exchange output, validate each.

  Returns `{:ok, exchanges, stats}` where `exchanges` is a sorted list of
  validated exchange maps and `stats` tracks counts.
  """
  @spec extract(keyword()) :: {:ok, [map()], map()} | {:error, {:missing_input, String.t()}}
  def extract(opts \\ []) do
    dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))
    exchanges_path = Path.join(dir, "exchanges.json")

    with {:ok, exchanges_json} <- read_json(exchanges_path) do
      data = load_all_data(dir, exchanges_json)

      if data.missing_files != [] do
        raise "Pipeline cannot run — missing required discovery files: #{Enum.join(data.missing_files, ", ")}"
      end

      ccxt_version = Keyword.get_lazy(opts, :ccxt_version, fn -> read_ccxt_version() end)

      extracted_at =
        Keyword.get_lazy(opts, :extracted_at, fn ->
          DateTime.to_iso8601(DateTime.utc_now())
        end)

      schema_opts = [ccxt_version: ccxt_version, extracted_at: extracted_at]

      {exchanges, errors} =
        data.exchanges
        |> Enum.sort_by(& &1["id"])
        |> Enum.reduce({[], []}, &assemble_and_validate(&1, data, schema_opts, &2))

      stats = %{
        exchange_count: length(exchanges),
        validation_errors: Enum.reverse(errors),
        missing_files: data.missing_files
      }

      {:ok, Enum.reverse(exchanges), stats}
    end
  end

  @doc """
  Write per-exchange JSON files and a manifest.

  Cleans stale files from the output directory before writing.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(exchanges, output_dir \\ Paths.priv(@output_dir)) do
    File.mkdir_p!(output_dir)
    clean_stale_files(output_dir, exchanges)

    for exchange <- exchanges do
      id = exchange["exchange"]["id"]
      path = Path.join(output_dir, "#{id}.json")
      File.write!(path, Jason.encode!(exchange, pretty: true))
    end

    manifest = build_manifest(exchanges)
    manifest_path = Path.join(output_dir, "_manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    :ok
  end

  # Reduce callback: build one exchange and validate it
  defp assemble_and_validate(meta, data, schema_opts, {acc, errs}) do
    exchange = build_exchange_data(meta, data, schema_opts)

    case Schema.validate(exchange) do
      :ok ->
        {[exchange | acc], errs}

      {:error, reasons} ->
        Logger.warning("Validation failed for #{meta["id"]}: #{inspect(reasons)}")
        {[exchange | acc], [{meta["id"], reasons} | errs]}
    end
  end

  # --- Assembly ---

  @doc false
  @spec build_exchange_data(map(), map(), keyword()) :: map()
  def build_exchange_data(meta, data, opts) do
    id = meta["id"]

    runtime_data = %{
      "describe" => get_describe(id, data),
      "markets" => get_markets(id, data)
    }

    structure_data = %{
      "class_info" => get_class_info(id, data),
      "methods" => get_methods(id, data),
      "sign_method" => get_sign_method(id, data),
      "handle_errors" => get_handle_errors(id, data),
      "parse_methods" => get_parse_methods(id, data),
      "ws_methods" => get_ws_methods(id, data),
      "overrides" => get_overrides(id, data)
    }

    Schema.build_exchange(meta, runtime_data, structure_data, opts)
  end

  # --- Data Mapping (pure functions) ---

  # Describe: read the "describe" key from the per-exchange file
  defp get_describe(id, data), do: Map.get(data.describe, id)

  # Markets: read market_count + markets from per-exchange file
  defp get_markets(id, data), do: Map.get(data.load_markets, id)

  # Class info: group by type into %{"rest" => entry, "ws" => entry|nil}
  defp get_class_info(id, data) do
    case Map.get(data.classes, id) do
      nil -> nil
      entries -> build_class_info(entries)
    end
  end

  defp build_class_info(entries) do
    rest = Enum.find(entries, &(&1["type"] == "rest"))
    ws = Enum.find(entries, &(&1["type"] == "ws"))

    if rest || ws do
      %{"rest" => rest, "ws" => ws}
    end
  end

  # Methods: combine rest + ws into %{"rest" => [...], "ws" => [...]|nil}
  defp get_methods(id, data) do
    rest = Map.get(data.methods_rest, id)
    ws = Map.get(data.methods_ws, id)

    if rest do
      %{"rest" => rest, "ws" => ws}
    end
  end

  # Sign method: direct passthrough (already MethodAST or nil)
  defp get_sign_method(id, data), do: Map.get(data.sign_methods, id)

  # Handle errors: rename handle_errors → method
  defp get_handle_errors(id, data) do
    case Map.get(data.handle_errors, id) do
      nil ->
        nil

      %{"handle_errors" => nil} ->
        nil

      %{"handle_errors" => method} = entry when is_map(method) ->
        %{
          "method" => method,
          "exceptions" => entry["exceptions"],
          "http_exceptions" => entry["http_exceptions"]
        }

      _ ->
        nil
    end
  end

  # Parse methods: extract the parse_methods map
  defp get_parse_methods(id, data) do
    case Map.get(data.parse_methods, id) do
      nil -> nil
      %{"parse_methods" => methods} when map_size(methods) > 0 -> methods
      _ -> nil
    end
  end

  # WS methods: extract the ws_methods map
  defp get_ws_methods(id, data) do
    case Map.get(data.ws_methods, id) do
      nil -> nil
      %{"ws_methods" => methods} when map_size(methods) > 0 -> methods
      _ -> nil
    end
  end

  # Overrides: group REST/WS entries, rename fields
  # Data is grouped by id (list of entries per exchange) because exchanges
  # with both REST and WS derived classes have two override records.
  defp get_overrides(id, data) do
    case Map.get(data.overrides, id) do
      nil -> nil
      [] -> nil
      entries when is_list(entries) -> build_overrides(entries)
    end
  end

  defp build_overrides(entries) do
    rest = Enum.find(entries, &String.starts_with?(&1["parent_key"] || "", "rest:"))
    ws = Enum.find(entries, &String.starts_with?(&1["parent_key"] || "", "ws:"))

    # Use REST entry as primary (or WS if no REST)
    primary = rest || ws

    %{
      "extends" => primary["extends"],
      "rest" => format_override_entry(rest),
      "ws" => format_override_entry(ws)
    }
  end

  defp format_override_entry(nil), do: nil

  defp format_override_entry(entry) do
    %{
      "parent_key" => entry["parent_key"],
      "overridden" => entry["overrides"],
      "new_methods" => entry["new_methods"],
      "inherited" => entry["inherited_methods"]
    }
  end

  # --- Data Loading ---

  # Loads all discovery files into indexed lookup maps
  defp load_all_data(dir, exchanges_json) do
    missing = []

    {describe, missing} = load_describe_files(dir, missing)
    {load_markets, missing} = load_markets_files(dir, missing)
    {classes, missing} = load_classes(dir, missing)
    {methods_rest, missing} = load_exchange_field(dir, "methods_rest.json", "methods", missing)
    {methods_ws, missing} = load_exchange_field(dir, "methods_ws.json", "methods", missing)
    {sign_methods, missing} = load_sign_methods(dir, missing)
    {handle_errors, missing} = load_exchange_lookup(dir, "handle_errors.json", missing)
    {parse_methods, missing} = load_exchange_lookup(dir, "parse_methods.json", missing)
    {ws_methods, missing} = load_exchange_lookup(dir, "ws_methods.json", missing)
    {overrides, missing} = load_overrides(dir, missing)

    %{
      exchanges: exchanges_json["exchanges"],
      describe: describe,
      load_markets: load_markets,
      classes: classes,
      methods_rest: methods_rest,
      methods_ws: methods_ws,
      sign_methods: sign_methods,
      handle_errors: handle_errors,
      parse_methods: parse_methods,
      ws_methods: ws_methods,
      overrides: overrides,
      missing_files: Enum.reverse(missing)
    }
  end

  # Load per-exchange describe files using manifest
  defp load_describe_files(dir, missing) do
    manifest_path = Path.join(dir, "describe/_manifest.json")

    case read_json(manifest_path) do
      {:ok, manifest} ->
        lookup = Map.new(manifest["exchanges"], &read_describe_entry(dir, &1))
        {lookup, missing}

      {:error, _} ->
        {%{}, ["describe/_manifest.json" | missing]}
    end
  end

  defp read_describe_entry(dir, id) do
    path = Path.join(dir, "describe/#{id}.json")

    case read_json(path) do
      {:ok, data} -> {id, data["describe"]}
      {:error, _} -> {id, nil}
    end
  end

  # Load per-exchange load_markets files using manifest
  defp load_markets_files(dir, missing) do
    manifest_path = Path.join(dir, "load_markets/_manifest.json")

    case read_json(manifest_path) do
      {:ok, manifest} ->
        succeeded = manifest["succeeded"] || []
        lookup = Map.new(succeeded, &read_markets_entry(dir, &1))
        {lookup, missing}

      {:error, _} ->
        {%{}, ["load_markets/_manifest.json" | missing]}
    end
  end

  defp read_markets_entry(dir, entry) do
    id = if is_map(entry), do: entry["id"], else: entry
    path = Path.join(dir, "load_markets/#{id}.json")

    case read_json(path) do
      {:ok, data} ->
        {id, %{"market_count" => data["market_count"], "markets" => data["markets"]}}

      {:error, _} ->
        {id, nil}
    end
  end

  # Load class hierarchy, group by class_name for rest/ws splitting
  defp load_classes(dir, missing) do
    path = Path.join(dir, "class_hierarchy.json")

    case read_json(path) do
      {:ok, data} ->
        lookup = Enum.group_by(data["classes"], & &1["class_name"])

        {lookup, missing}

      {:error, _} ->
        {%{}, ["class_hierarchy.json" | missing]}
    end
  end

  # Load a global file and index by id, extracting a specific field as value
  defp load_exchange_field(dir, filename, field, missing) do
    path = Path.join(dir, filename)

    case read_json(path) do
      {:ok, data} ->
        lookup =
          Map.new(data["exchanges"], fn entry ->
            {entry["id"], entry[field]}
          end)

        {lookup, missing}

      {:error, _} ->
        {%{}, [filename | missing]}
    end
  end

  # Load sign_methods — the value is the "sign" key (MethodAST or nil)
  defp load_sign_methods(dir, missing) do
    path = Path.join(dir, "sign_methods.json")

    case read_json(path) do
      {:ok, data} ->
        lookup =
          Map.new(data["exchanges"], fn entry ->
            {entry["id"], entry["sign"]}
          end)

        {lookup, missing}

      {:error, _} ->
        {%{}, ["sign_methods.json" | missing]}
    end
  end

  # Load a global file and index by id, keeping the full entry
  defp load_exchange_lookup(dir, filename, missing) do
    path = Path.join(dir, filename)

    case read_json(path) do
      {:ok, data} ->
        lookup = Map.new(data["exchanges"], fn entry -> {entry["id"], entry} end)
        {lookup, missing}

      {:error, _} ->
        {%{}, [filename | missing]}
    end
  end

  # Load overrides, grouped by id (exchanges can have both REST and WS entries)
  defp load_overrides(dir, missing) do
    path = Path.join(dir, "overrides.json")

    case read_json(path) do
      {:ok, data} ->
        lookup = Enum.group_by(data["exchanges"], & &1["id"])
        {lookup, missing}

      {:error, _} ->
        {%{}, ["overrides.json" | missing]}
    end
  end

  # --- Helpers ---

  defp read_json(path) do
    case File.read(path) do
      {:ok, content} ->
        try do
          {:ok, Jason.decode!(content)}
        rescue
          e in Jason.DecodeError ->
            {:error, {:invalid_json, "#{path}: #{Exception.message(e)}"}}
        end

      {:error, reason} ->
        {:error, {:missing_input, "#{path}: #{reason}"}}
    end
  end

  defp read_ccxt_version do
    case read_json(Paths.version_file()) do
      {:ok, data} -> data["npm_version"] || "unknown"
      {:error, _} -> "unknown"
    end
  end

  # Remove JSON files from output dir that aren't in the current exchange set
  defp clean_stale_files(output_dir, exchanges) do
    current_ids = MapSet.new(exchanges, & &1["exchange"]["id"])

    output_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reject(&(&1 == "_manifest.json"))
    |> Enum.each(fn filename ->
      id = String.trim_trailing(filename, ".json")

      if !MapSet.member?(current_ids, id) do
        File.rm!(Path.join(output_dir, filename))
      end
    end)
  end

  defp build_manifest(exchanges) do
    first = List.first(exchanges) || %{}

    %{
      "schema_version" => Schema.schema_version(),
      "ccxt_version" => first["ccxt_version"] || "unknown",
      "extracted_at" => first["extracted_at"] || DateTime.to_iso8601(DateTime.utc_now()),
      "exchange_count" => length(exchanges),
      "exchanges" => Enum.map(exchanges, & &1["exchange"]["id"])
    }
  end
end
