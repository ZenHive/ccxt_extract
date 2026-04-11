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

      version_info = Keyword.get_lazy(opts, :version_info, fn -> read_ccxt_version_info() end)
      ccxt_version = Keyword.get(opts, :ccxt_version) || version_info["npm_version"] || "unknown"

      extracted_at =
        Keyword.get_lazy(opts, :extracted_at, fn ->
          DateTime.to_iso8601(DateTime.utc_now())
        end)

      schema_opts = [ccxt_version: ccxt_version, extracted_at: extracted_at, version_info: version_info]

      {exchanges, errors} =
        data.exchanges
        |> Enum.sort_by(& &1["id"])
        |> Enum.reduce({[], []}, &assemble_and_validate(&1, data, schema_opts, &2))

      stats = %{
        exchange_count: length(exchanges),
        validation_errors: Enum.reverse(errors),
        missing_files: data.missing_files,
        missing_entries: data.missing_entries,
        corrupt_entries: data.corrupt_entries,
        orphan_entries: data.orphan_entries,
        id_mismatch_entries: data.id_mismatch_entries
      }

      {:ok, Enum.reverse(exchanges), stats}
    end
  end

  @doc """
  Write per-exchange JSON files, the schema, and a manifest.

  Cleans stale files from the output directory before writing.
  """
  @spec write!([map()], String.t(), keyword()) :: :ok
  def write!(exchanges, output_dir \\ Paths.priv(@output_dir), opts \\ []) do
    discoveries_dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))

    File.mkdir_p!(output_dir)
    clean_stale_files(output_dir, exchanges)

    for exchange <- exchanges do
      id = exchange["exchange"]["id"]
      path = Path.join(output_dir, "#{id}.json")
      File.write!(path, Jason.encode!(exchange, pretty: true))
    end

    manifest = build_manifest(exchanges, opts)
    manifest_path = Path.join(output_dir, "_manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    copy_schema!(output_dir)
    copy_base_methods!(output_dir, discoveries_dir)

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

    markets = get_markets(id, data)
    describe = get_describe(id, data)

    runtime_data = %{
      "describe" => describe,
      "markets" => markets,
      "symbol_patterns" => CcxtExtract.SymbolPatterns.derive(markets, describe),
      "url_templates" => get_url_templates(id, data)
    }

    structure_data = %{
      "class_info" => get_class_info(id, data),
      "methods" => get_methods(id, data),
      "sign_method" => get_sign_method(id, data),
      "handle_errors" => get_handle_errors(id, data),
      "parse_methods" => get_parse_methods(id, data),
      "ws_methods" => get_ws_methods(id, data),
      "interface_signatures" => get_interface_signatures(id, data),
      "pagination" => get_pagination(id, data),
      "unified_endpoints" => get_unified_endpoints(id, data),
      "overrides" => get_overrides(id, data)
    }

    Schema.build_exchange(meta, runtime_data, structure_data, opts)
  end

  # --- Data Mapping (pure functions) ---

  # Describe: read the "describe" key from the per-exchange file.
  # Alias exchanges (e.g. coinbaseadvanced, gateio, huobi) have no own describe data —
  # fall back to parent exchange's describe via class hierarchy.
  defp get_describe(id, data) do
    case Map.get(data.describe, id) do
      nil -> get_parent_data(id, data, :describe)
      describe -> describe
    end
  end

  # Markets: read market_count + markets from per-exchange file.
  # Same parent fallback as describe for alias exchanges.
  defp get_markets(id, data) do
    case Map.get(data.load_markets, id) do
      nil -> get_parent_data(id, data, :load_markets)
      markets -> markets
    end
  end

  # Resolve parent data for alias exchanges that have no own discovery data.
  defp get_parent_data(id, data, field) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> Map.get(Map.get(data, field, %{}), parent_id)
    end
  end

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

    %{"rest" => rest, "ws" => ws}
  end

  # Methods: combine rest + ws into %{"rest" => [...], "ws" => [...]|nil}
  defp get_methods(id, data) do
    rest_present? = Map.has_key?(data.methods_rest, id)
    ws_present? = Map.has_key?(data.methods_ws, id)
    rest = Map.get(data.methods_rest, id)
    ws = Map.get(data.methods_ws, id)

    if rest_present? || ws_present? do
      %{
        "rest" => rest,
        "ws" => if(ws_present?, do: ws)
      }
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
          "http_exceptions" => entry["http_exceptions"],
          "error_code_fields" => CcxtExtract.ErrorCodeFields.derive(method)
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

  # Interface signatures: extract the interface_signatures map
  defp get_interface_signatures(id, data) do
    case Map.get(data.interface_signatures, id) do
      nil -> nil
      %{"interface_signatures" => sigs} when map_size(sigs) > 0 -> sigs
      _ -> nil
    end
  end

  # URL templates: extract the url_templates inner map.
  # Alias exchanges (e.g. coinbaseadvanced, gateio, huobi) have no own url_templates data —
  # fall back to parent exchange's url_templates via class hierarchy.
  defp get_url_templates(id, data) do
    case Map.get(data.url_templates, id) do
      nil -> get_parent_url_templates(id, data)
      %{"url_templates" => templates} when map_size(templates) > 0 -> templates
      _ -> nil
    end
  end

  # Recursion is safe: CCXT class hierarchy is a DAG (max depth ~3),
  # and find_parent_exchange_id returns nil for base Exchange class, terminating the chain.
  defp get_parent_url_templates(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_url_templates(parent_id, data)
    end
  end

  # Pagination: extract the pagination map (arrays of entries per method) + unresolved
  defp get_pagination(id, data) do
    data.pagination
    |> Map.get(id)
    |> build_pagination_output()
  end

  defp build_pagination_output(nil), do: nil

  defp build_pagination_output(exchange_data) do
    pagination = Map.get(exchange_data, "pagination", %{})
    unresolved = Map.get(exchange_data, "pagination_unresolved", [])

    case {map_size(pagination), unresolved} do
      {0, []} -> nil
      {_, []} -> pagination
      _ -> Map.put(pagination, "_unresolved", unresolved)
    end
  end

  # Unified endpoints: extract the unified_endpoints map, merge parent mappings for derived exchanges,
  # then filter against interface_signatures to remove leaked helper method names.
  defp get_unified_endpoints(id, data) do
    own = extract_unified_endpoints_map(id, data)
    parent_id = find_parent_exchange_id(id, data)
    merged = merge_parent_endpoints(own, parent_id, data)
    valid_endpoints = collect_interface_signature_keys(id, parent_id, data)
    filter_unified_endpoints(merged, valid_endpoints)
  end

  # Extract the raw unified_endpoints map from the discovery lookup
  defp extract_unified_endpoints_map(id, data) do
    case Map.get(data.unified_endpoints, id) do
      nil -> nil
      %{"unified_endpoints" => endpoints} when map_size(endpoints) > 0 -> endpoints
      _ -> nil
    end
  end

  # Find the parent exchange id from class hierarchy (REST class takes precedence).
  # Single-level lookup only: reads parent from discovery data, not merged pipeline output.
  # If B extends C, A extends B, and B has no own endpoints, A won't inherit C's endpoints.
  # Acceptable: CCXT's hierarchy is shallow and derived exchanges typically define own endpoints.
  defp find_parent_exchange_id(id, data) do
    case Map.get(data.classes, id) do
      nil ->
        nil

      entries ->
        rest = Enum.find(entries, &(&1["type"] == "rest"))
        parent_key = rest && rest["parent_key"]

        case parent_key do
          nil -> nil
          "Exchange" -> nil
          "rest:" <> parent_id -> parent_id
          _ -> nil
        end
    end
  end

  # Merge parent endpoints with child — child overrides take precedence
  defp merge_parent_endpoints(own, nil, _data), do: own
  defp merge_parent_endpoints(nil, parent_id, data), do: extract_unified_endpoints_map(parent_id, data)

  defp merge_parent_endpoints(own, parent_id, data) do
    case extract_unified_endpoints_map(parent_id, data) do
      nil -> own
      parent_endpoints -> Map.merge(parent_endpoints, own)
    end
  end

  # Collect valid interface signature keys for an exchange (own + parent).
  # Returns a MapSet for O(1) membership checks, or nil if no signatures available.
  defp collect_interface_signature_keys(id, parent_id, data) do
    own_sigs = get_interface_signature_keys(id, data)
    parent_sigs = if parent_id, do: get_interface_signature_keys(parent_id, data), else: MapSet.new()

    combined = MapSet.union(own_sigs, parent_sigs)
    if MapSet.size(combined) > 0, do: combined
  end

  defp get_interface_signature_keys(id, data) do
    case Map.get(data.interface_signatures, id) do
      %{"interface_signatures" => sigs} when map_size(sigs) > 0 -> sigs |> Map.keys() |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  # Filter unified_endpoints map: keep only endpoint names that exist in interface_signatures.
  # Removes unified methods that end up with empty endpoint lists after filtering.
  defp filter_unified_endpoints(nil, _valid), do: nil
  # TODO: All 110 exchanges should have interface_signatures (Task 30). If this fires,
  # investigate why signatures are missing rather than silently discarding endpoints.
  defp filter_unified_endpoints(endpoints, nil), do: endpoints

  defp filter_unified_endpoints(endpoints, valid_endpoints) do
    filtered =
      endpoints
      |> Map.new(fn {method, calls} ->
        {method, Enum.filter(calls, &MapSet.member?(valid_endpoints, &1))}
      end)
      |> Enum.reject(fn {_method, calls} -> calls == [] end)
      |> Map.new()

    if map_size(filtered) > 0, do: filtered
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
    expected_ids = expected_exchange_ids(exchanges_json)
    stats = empty_integrity_stats()

    {describe, stats} = load_describe_files(dir, stats)
    {load_markets, stats} = load_markets_files(dir, stats)
    {classes, stats} = load_classes(dir, expected_ids, stats)
    {methods_rest, stats} = load_exchange_field(dir, "methods_rest.json", "methods", expected_ids, stats)
    {methods_ws, stats} = load_exchange_field(dir, "methods_ws.json", "methods", expected_ids, stats)
    {sign_methods, stats} = load_sign_methods(dir, expected_ids, stats)
    {handle_errors, stats} = load_exchange_lookup(dir, "handle_errors.json", expected_ids, stats)
    {parse_methods, stats} = load_exchange_lookup(dir, "parse_methods.json", expected_ids, stats)
    {ws_methods, stats} = load_exchange_lookup(dir, "ws_methods.json", expected_ids, stats)
    {interface_signatures, stats} = load_exchange_lookup(dir, "interface_signatures.json", expected_ids, stats)
    {pagination, stats} = load_exchange_lookup(dir, "pagination.json", expected_ids, stats)
    {unified_endpoints, stats} = load_exchange_lookup(dir, "unified_endpoints.json", expected_ids, stats)
    {url_templates, stats} = load_exchange_lookup(dir, "url_templates.json", expected_ids, stats)
    {overrides, stats} = load_overrides(dir, expected_ids, stats)

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
      interface_signatures: interface_signatures,
      pagination: pagination,
      unified_endpoints: unified_endpoints,
      url_templates: url_templates,
      overrides: overrides,
      missing_files: Enum.reverse(stats.missing_files),
      missing_entries: Enum.reverse(stats.missing_entries),
      corrupt_entries: Enum.reverse(stats.corrupt_entries),
      orphan_entries: Enum.reverse(stats.orphan_entries),
      id_mismatch_entries: Enum.reverse(stats.id_mismatch_entries)
    }
  end

  # Load per-exchange describe files using manifest
  defp load_describe_files(dir, stats) do
    manifest_path = Path.join(dir, "describe/_manifest.json")

    case read_json(manifest_path) do
      {:ok, %{"exchanges" => exchanges}} when is_list(exchanges) ->
        validate_manifest_ids!(exchanges, manifest_path)
        stats = record_directory_orphans(dir, "describe", exchanges, stats)

        {lookup, stats} =
          Enum.reduce(exchanges, {%{}, stats}, &reduce_describe_entry(dir, &1, &2))

        {lookup, stats}

      {:ok, _malformed} ->
        raise "Corrupt discovery artifact: #{manifest_path} missing or invalid \"exchanges\" key"

      {:error, {:missing_input, _}} ->
        {%{}, add_stat_entry(stats, :missing_files, "describe/_manifest.json")}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  defp reduce_describe_entry(dir, id, {acc, stats}) do
    case read_describe_entry(dir, id) do
      {:ok, id, data} ->
        {Map.put(acc, id, data), stats}

      {:missing, id, path} ->
        {Map.put(acc, id, nil), add_stat_entry(stats, :missing_entries, path)}

      {:corrupt, _id, detail} ->
        {acc, add_stat_entry(stats, :corrupt_entries, detail)}

      {:id_mismatch, _id, detail} ->
        {acc, add_stat_entry(stats, :id_mismatch_entries, detail)}
    end
  end

  defp read_describe_entry(dir, id) do
    path = Path.join(dir, "describe/#{id}.json")

    case read_json(path) do
      {:ok, data} ->
        with :ok <- validate_expected_id(path, "id", id, data["id"]),
             :ok <- validate_expected_id(path, "describe.id", id, get_in(data, ["describe", "id"])) do
          {:ok, id, data["describe"]}
        else
          {:id_mismatch, detail} -> {:id_mismatch, id, detail}
        end

      {:error, {:missing_input, _}} ->
        {:missing, id, "describe/#{id}.json"}

      {:error, {:invalid_json, detail}} ->
        {:corrupt, id, detail}
    end
  end

  # Load per-exchange load_markets files using manifest
  defp load_markets_files(dir, stats) do
    manifest_path = Path.join(dir, "load_markets/_manifest.json")

    case read_json(manifest_path) do
      {:ok, %{"succeeded" => succeeded}} when is_list(succeeded) ->
        validate_manifest_ids!(Enum.map(succeeded, &markets_entry_id/1), manifest_path)

        stats =
          record_directory_orphans(
            dir,
            "load_markets",
            Enum.map(succeeded, &markets_entry_id/1),
            stats
          )

        {lookup, stats} =
          Enum.reduce(succeeded, {%{}, stats}, &reduce_markets_entry(dir, &1, &2))

        {lookup, stats}

      {:ok, _malformed} ->
        raise "Corrupt discovery artifact: #{manifest_path} missing or invalid \"succeeded\" key"

      {:error, {:missing_input, _}} ->
        {%{}, add_stat_entry(stats, :missing_files, "load_markets/_manifest.json")}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  defp reduce_markets_entry(dir, entry, {acc, stats}) do
    case read_markets_entry(dir, entry) do
      {:ok, id, data} ->
        {Map.put(acc, id, data), stats}

      {:missing, id, path} ->
        {Map.put(acc, id, nil), add_stat_entry(stats, :missing_entries, path)}

      {:corrupt, _id, detail} ->
        {acc, add_stat_entry(stats, :corrupt_entries, detail)}

      {:id_mismatch, _id, detail} ->
        {acc, add_stat_entry(stats, :id_mismatch_entries, detail)}
    end
  end

  defp read_markets_entry(dir, entry) do
    id = if is_map(entry), do: entry["id"], else: entry
    path = Path.join(dir, "load_markets/#{id}.json")

    case read_json(path) do
      {:ok, data} ->
        case validate_expected_id(path, "id", id, data["id"]) do
          :ok -> {:ok, id, %{"market_count" => data["market_count"], "markets" => data["markets"]}}
          {:id_mismatch, detail} -> {:id_mismatch, id, detail}
        end

      {:error, {:missing_input, _}} ->
        {:missing, id, "load_markets/#{id}.json"}

      {:error, {:invalid_json, detail}} ->
        {:corrupt, id, detail}
    end
  end

  # Extract ID from load_markets manifest entries (can be string or map with "id" key)
  defp markets_entry_id(entry) when is_map(entry), do: entry["id"]
  defp markets_entry_id(entry), do: entry

  # Validate that all manifest IDs are strings — non-string IDs indicate a corrupt manifest
  defp validate_manifest_ids!(ids, manifest_path) do
    non_strings = Enum.reject(ids, &is_binary/1)

    if non_strings != [] do
      raise "Corrupt discovery artifact: #{manifest_path} contains non-string IDs: #{inspect(non_strings)}"
    end
  end

  # Load class hierarchy, group by class_name for rest/ws splitting
  defp load_classes(dir, expected_ids, stats) do
    path = Path.join(dir, "class_hierarchy.json")

    case read_json(path) do
      {:ok, data} ->
        stats = record_global_orphans(stats, "class_hierarchy.json", data["classes"], expected_ids)
        lookup = Enum.group_by(data["classes"], & &1["class_name"])
        {lookup, stats}

      {:error, {:missing_input, _}} ->
        {%{}, add_stat_entry(stats, :missing_files, "class_hierarchy.json")}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  # Load a global file and index by id, extracting a specific field as value
  defp load_exchange_field(dir, filename, field, expected_ids, stats) do
    path = Path.join(dir, filename)

    case read_json(path) do
      {:ok, %{"exchanges" => entries}} when is_list(entries) ->
        stats = record_global_orphans(stats, filename, entries, expected_ids)

        reduce_validated(entries, stats, &validate_exchange_field_entry(filename, field, &1))

      {:ok, _malformed} ->
        raise "Corrupt discovery artifact: #{path} missing or invalid \"exchanges\" key"

      {:error, {:missing_input, _}} ->
        {%{}, add_stat_entry(stats, :missing_files, filename)}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  # Load sign_methods — the value is the "sign" key (MethodAST or nil)
  defp load_sign_methods(dir, expected_ids, stats) do
    path = Path.join(dir, "sign_methods.json")

    case read_json(path) do
      {:ok, data} ->
        stats = record_global_orphans(stats, "sign_methods.json", data["exchanges"], expected_ids)

        lookup =
          Map.new(data["exchanges"], fn entry ->
            {entry["id"], entry["sign"]}
          end)

        {lookup, stats}

      {:error, {:missing_input, _}} ->
        {%{}, add_stat_entry(stats, :missing_files, "sign_methods.json")}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  # Load a global file and index by id, keeping the full entry
  defp load_exchange_lookup(dir, filename, expected_ids, stats) do
    path = Path.join(dir, filename)

    case read_json(path) do
      {:ok, %{"exchanges" => entries}} when is_list(entries) ->
        stats = record_global_orphans(stats, filename, entries, expected_ids)

        reduce_validated(entries, stats, &validate_exchange_lookup_entry(filename, &1))

      {:ok, _malformed} ->
        raise "Corrupt discovery artifact: #{path} missing or invalid \"exchanges\" key"

      {:error, {:missing_input, _}} ->
        {%{}, add_stat_entry(stats, :missing_files, filename)}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  # Load overrides, grouped by id (exchanges can have both REST and WS entries)
  defp load_overrides(dir, expected_ids, stats) do
    path = Path.join(dir, "overrides.json")

    case read_json(path) do
      {:ok, data} ->
        stats = record_global_orphans(stats, "overrides.json", data["exchanges"], expected_ids)
        lookup = Enum.group_by(data["exchanges"], & &1["id"])
        {lookup, stats}

      {:error, {:missing_input, _}} ->
        {%{}, add_stat_entry(stats, :missing_files, "overrides.json")}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  # Shared reduce for validated entries — flattens nesting in load_exchange_field/load_exchange_lookup
  defp reduce_validated(entries, stats, validate_fn) do
    Enum.reduce(entries, {%{}, stats}, fn entry, {acc, acc_stats} ->
      case validate_fn.(entry) do
        {:ok, id, value} -> {Map.put(acc, id, value), acc_stats}
        {:corrupt, detail} -> {acc, add_stat_entry(acc_stats, :corrupt_entries, detail)}
      end
    end)
  end

  # --- Helpers ---

  defp expected_exchange_ids(%{"exchanges" => exchanges}) do
    MapSet.new(exchanges, & &1["id"])
  end

  defp empty_integrity_stats do
    %{
      missing_files: [],
      missing_entries: [],
      corrupt_entries: [],
      orphan_entries: [],
      id_mismatch_entries: []
    }
  end

  defp add_stat_entry(stats, key, entry), do: Map.update!(stats, key, &[entry | &1])

  defp record_directory_orphans(dir, subdir, manifest_ids, stats) do
    directory = Path.join(dir, subdir)
    manifest_ids = MapSet.new(manifest_ids)

    case File.ls(directory) do
      {:ok, filenames} ->
        filenames
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reject(&(&1 == "_manifest.json"))
        |> Enum.map(&String.trim_trailing(&1, ".json"))
        |> Enum.reject(&MapSet.member?(manifest_ids, &1))
        |> Enum.sort()
        |> Enum.reduce(stats, fn id, acc ->
          add_stat_entry(acc, :orphan_entries, "#{subdir}/#{id}.json")
        end)

      {:error, _reason} ->
        stats
    end
  end

  defp record_global_orphans(stats, filename, entries, expected_ids) when is_list(entries) do
    entries
    |> Enum.map(& &1["id"])
    |> Enum.reject(&(is_binary(&1) and MapSet.member?(expected_ids, &1)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(stats, fn id, acc ->
      add_stat_entry(acc, :orphan_entries, "#{filename}#id=#{inspect(id)}")
    end)
  end

  defp record_global_orphans(stats, _filename, _entries, _expected_ids), do: stats

  defp validate_expected_id(path, field, expected_id, actual_id) do
    if actual_id == expected_id do
      :ok
    else
      {:id_mismatch, "#{path}: expected #{field} #{inspect(expected_id)}, got #{inspect(actual_id)}"}
    end
  end

  defp validate_exchange_field_entry(filename, field, %{"id" => id} = entry) when is_binary(id) do
    case Map.fetch(entry, field) do
      {:ok, value} when is_list(value) ->
        {:ok, id, value}

      {:ok, value} ->
        {:corrupt, "#{filename}#id=#{inspect(id)} invalid #{field}: expected list, got #{type_name(value)}"}

      :error ->
        {:corrupt, "#{filename}#id=#{inspect(id)} missing required #{field} key"}
    end
  end

  defp validate_exchange_field_entry(filename, _field, entry) do
    {:corrupt, "#{filename} invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry("handle_errors.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, method} <- fetch_required_key(entry, "handle_errors", id, "handle_errors.json"),
         :ok <- validate_optional_map_field("handle_errors.json", id, "handle_errors", method),
         :ok <- validate_optional_map_field("handle_errors.json", id, "exceptions", entry["exceptions"]),
         :ok <-
           validate_optional_map_field(
             "handle_errors.json",
             id,
             "http_exceptions",
             entry["http_exceptions"]
           ) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("handle_errors.json", entry) do
    {:corrupt, "handle_errors.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry(filename, %{"id" => id} = entry)
       when filename in ["parse_methods.json", "ws_methods.json"] and is_binary(id) do
    methods_key = if filename == "parse_methods.json", do: "parse_methods", else: "ws_methods"

    with {:ok, methods} <- fetch_required_key(entry, methods_key, id, filename),
         :ok <- validate_required_map_field(filename, id, methods_key, methods) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry(filename, entry) when filename in ["parse_methods.json", "ws_methods.json"] do
    {:corrupt, "#{filename} invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry("interface_signatures.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, sigs} <- fetch_required_key(entry, "interface_signatures", id, "interface_signatures.json"),
         :ok <- validate_required_map_field("interface_signatures.json", id, "interface_signatures", sigs) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("interface_signatures.json", entry) do
    {:corrupt, "interface_signatures.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry("pagination.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, pagination} <- fetch_required_key(entry, "pagination", id, "pagination.json"),
         :ok <- validate_required_map_field("pagination.json", id, "pagination", pagination) do
      # pagination_unresolved is optional — only present when variable method names exist
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("pagination.json", entry) do
    {:corrupt, "pagination.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry("unified_endpoints.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, endpoints} <-
           fetch_required_key(entry, "unified_endpoints", id, "unified_endpoints.json"),
         :ok <-
           validate_required_map_field("unified_endpoints.json", id, "unified_endpoints", endpoints) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("unified_endpoints.json", entry) do
    {:corrupt, "unified_endpoints.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry("url_templates.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, templates} <-
           fetch_required_key(entry, "url_templates", id, "url_templates.json"),
         :ok <-
           validate_required_map_field("url_templates.json", id, "url_templates", templates) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("url_templates.json", entry) do
    {:corrupt, "url_templates.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry(_filename, %{"id" => id} = entry) when is_binary(id), do: {:ok, id, entry}

  defp validate_exchange_lookup_entry(filename, entry) do
    {:corrupt, "#{filename} invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp fetch_required_key(entry, key, id, filename) do
    case Map.fetch(entry, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:corrupt, "#{filename}#id=#{inspect(id)} missing required #{key} key"}
    end
  end

  defp validate_required_map_field(_filename, _id, _field, value) when is_map(value), do: :ok

  defp validate_required_map_field(filename, id, field, value) do
    {:corrupt, "#{filename}#id=#{inspect(id)} invalid #{field}: expected map, got #{type_name(value)}"}
  end

  defp validate_optional_map_field(_filename, _id, _field, nil), do: :ok
  defp validate_optional_map_field(_filename, _id, _field, value) when is_map(value), do: :ok

  defp validate_optional_map_field(filename, id, field, value) do
    {:corrupt, "#{filename}#id=#{inspect(id)} invalid #{field}: expected map or null, got #{type_name(value)}"}
  end

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

  # Returns the full version info map from priv/ccxt_version.json, or an empty
  # map if the file is missing/corrupt. Used by build_manifest to include
  # source_git_sha for reproducibility traceability.
  defp read_ccxt_version_info do
    case read_json(Paths.version_file()) do
      {:ok, data} -> data
      {:error, _} -> %{}
    end
  end

  defp type_name(val) when is_binary(val), do: "string"
  defp type_name(val) when is_integer(val), do: "integer"
  defp type_name(val) when is_float(val), do: "float"
  defp type_name(val) when is_boolean(val), do: "boolean"
  defp type_name(val) when is_list(val), do: "list"
  defp type_name(val) when is_map(val), do: "map"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "unknown"

  # Remove JSON files from output dir that aren't in the current exchange set
  defp clean_stale_files(output_dir, exchanges) do
    current_ids = MapSet.new(exchanges, & &1["exchange"]["id"])

    output_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reject(&(&1 in ["_manifest.json", "exchange_v1.json", "_base_methods.json"]))
    |> Enum.each(fn filename ->
      id = String.trim_trailing(filename, ".json")

      if !MapSet.member?(current_ids, id) do
        File.rm!(Path.join(output_dir, filename))
      end
    end)
  end

  defp copy_schema!(output_dir) do
    schema_source = Paths.priv("schema/exchange_v1.json")
    schema_target = Path.join(output_dir, "exchange_v1.json")
    File.cp!(schema_source, schema_target)
  end

  # Copy _base_methods.json to the output directory as a shared artifact.
  # When the source is absent, removes stale target to prevent leftover artifacts.
  # Run `mix ccxt_extract.base_methods` to generate the source file.
  defp copy_base_methods!(output_dir, discoveries_dir) do
    source = Path.join(discoveries_dir, "_base_methods.json")
    target = Path.join(output_dir, "_base_methods.json")

    if File.exists?(source) do
      File.cp!(source, target)
    else
      File.rm(target)
    end
  end

  # Manifest derives ccxt_version from exchange data (the source of truth),
  # not from version_info on disk. version_info is only used for source_git_sha.
  defp build_manifest(exchanges, opts) do
    version_info = Keyword.get_lazy(opts, :version_info, fn -> read_ccxt_version_info() end)
    first = List.first(exchanges) || %{}

    %{
      "schema_version" => Schema.schema_version(),
      "ccxt_version" => first["ccxt_version"] || "unknown",
      "source_git_sha" => version_info["source_git_sha"],
      "extracted_at" => first["extracted_at"] || DateTime.to_iso8601(DateTime.utc_now()),
      "exchange_count" => length(exchanges),
      "exchanges" => exchanges |> Enum.map(& &1["exchange"]["id"]) |> Enum.sort()
    }
  end
end
