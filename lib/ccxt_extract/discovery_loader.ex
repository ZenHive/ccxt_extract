defmodule CcxtExtract.DiscoveryLoader do
  @moduledoc """
  Load and validate discovery artifacts produced by extractors.

  Reads the discovery files (global + per-exchange) from the
  discoveries directory, validates each entry against its expected
  shape, accumulates integrity stats (missing/corrupt/orphan/id-mismatch
  entries), and returns the data map that `CcxtExtract.Pipeline`
  consumes during assembly.

  ## Usage

      {:ok, exchanges_json} = CcxtExtract.JsonIO.read_json("priv/discoveries/exchanges.json")
      data = DiscoveryLoader.load_all!("priv/discoveries", exchanges_json)
      data.describe   # => %{"binance" => %{...}, ...}
      data.missing_entries  # => []

  `load_all!/2` raises when any discovery file is malformed JSON, or when
  a global/manifest file is present but missing its required top-level
  envelope (e.g. `"exchanges"`, `"succeeded"`), or when a manifest lists
  non-string IDs. Per-entry problems (missing, corrupt, id-mismatch) in
  per-exchange files are captured in integrity stats rather than raised.
  """

  alias CcxtExtract.JsonIO
  alias CcxtExtract.Schema

  @doc """
  Read all discovery files from `dir`, validate each, and return a map
  containing per-exchange lookups plus integrity stats.

  `exchanges_json` is the parsed `exchanges.json` envelope (caller-loaded
  so that the pipeline can short-circuit on missing-envelope before any
  loading work starts).
  """
  @spec load_all!(String.t(), map()) :: map()
  def load_all!(dir, exchanges_json) do
    expected_ids = expected_exchange_ids(exchanges_json)
    stats = empty_integrity_stats()

    {describe, stats} = load_describe_files(dir, stats)
    {load_markets, stats} = load_markets_files(dir, stats)
    {classes, stats} = load_classes(dir, expected_ids, stats)
    {error_class_hierarchy, stats} = load_error_class_hierarchy(dir, stats)
    {methods_rest, stats} = load_exchange_field(dir, "methods_rest.json", "methods", expected_ids, stats)
    {methods_ws, stats} = load_exchange_field(dir, "methods_ws.json", "methods", expected_ids, stats)
    {sign_methods, stats} = load_sign_methods(dir, expected_ids, stats)
    {handle_errors, stats} = load_exchange_lookup(dir, "handle_errors.json", expected_ids, stats)
    {parse_methods, stats} = load_exchange_lookup(dir, "parse_methods.json", expected_ids, stats)
    {ws_methods, stats} = load_exchange_lookup(dir, "ws_methods.json", expected_ids, stats)
    {interface_signatures, stats} = load_exchange_lookup(dir, "interface_signatures.json", expected_ids, stats)
    {pagination, stats} = load_exchange_lookup(dir, "pagination.json", expected_ids, stats)
    {unified_endpoints, stats} = load_exchange_lookup(dir, "unified_endpoints.json", expected_ids, stats)
    {request_defaults, stats} = load_exchange_lookup(dir, "request_defaults.json", expected_ids, stats)
    {raw_broadcast, stats} = load_exchange_lookup(dir, "raw_broadcast.json", expected_ids, stats)
    {url_templates, stats} = load_exchange_lookup(dir, "url_templates.json", expected_ids, stats)
    {request_headers, stats} = load_exchange_lookup(dir, "request_headers.json", expected_ids, stats)
    {rate_limit_buckets, stats} = load_exchange_lookup(dir, "rate_limit_buckets.json", expected_ids, stats)
    {rate_limit_costs, stats} = load_exchange_lookup(dir, "rate_limit_costs.json", expected_ids, stats)
    {fetch_methods, stats} = load_exchange_lookup(dir, "fetch_methods.json", expected_ids, stats)
    {ws_heartbeat, stats} = load_exchange_lookup(dir, "ws_heartbeat.json", expected_ids, stats)
    {ws_auth, stats} = load_exchange_lookup(dir, "ws_auth.json", expected_ids, stats)
    {ws_subscribe, stats} = load_exchange_lookup(dir, "ws_subscribe.json", expected_ids, stats)
    {ws_dispatch, stats} = load_exchange_lookup(dir, "ws_dispatch.json", expected_ids, stats)
    {ws_trades_semantics, stats} = load_exchange_lookup(dir, "ws_trades_semantics.json", expected_ids, stats)
    {ws_ohlcv_semantics, stats} = load_exchange_lookup(dir, "ws_ohlcv_semantics.json", expected_ids, stats)
    {overrides, stats} = load_overrides(dir, expected_ids, stats)

    %{
      exchanges: exchanges_json["exchanges"],
      describe: describe,
      load_markets: load_markets,
      classes: classes,
      error_class_hierarchy: error_class_hierarchy,
      methods_rest: methods_rest,
      methods_ws: methods_ws,
      sign_methods: sign_methods,
      handle_errors: handle_errors,
      parse_methods: parse_methods,
      fetch_methods: fetch_methods,
      ws_methods: ws_methods,
      ws_heartbeat: ws_heartbeat,
      ws_auth: ws_auth,
      ws_subscribe: ws_subscribe,
      ws_dispatch: ws_dispatch,
      ws_trades_semantics: ws_trades_semantics,
      ws_ohlcv_semantics: ws_ohlcv_semantics,
      interface_signatures: interface_signatures,
      pagination: pagination,
      unified_endpoints: unified_endpoints,
      request_defaults: request_defaults,
      raw_broadcast: raw_broadcast,
      url_templates: url_templates,
      request_headers: request_headers,
      rate_limit_buckets: rate_limit_buckets,
      rate_limit_costs: rate_limit_costs,
      overrides: overrides,
      canonical_has_keys: compute_canonical_has_keys(describe),
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

    case JsonIO.read_json(manifest_path) do
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

    case JsonIO.read_json(path) do
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

    case JsonIO.read_json(manifest_path) do
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

    case JsonIO.read_json(path) do
      {:ok, data} ->
        case validate_expected_id(path, "id", id, data["id"]) do
          :ok ->
            # currencies added in Task 97 (runtime ex.currencies after loadMarkets).
            # Old discovery files (pre-97) will lack the key; treat as nil so
            # Pipeline produces explicit null for markets.currencies (two-state contract).
            currencies = Map.get(data, "currencies")
            {:ok, id, %{"market_count" => data["market_count"], "markets" => data["markets"], "currencies" => currencies}}

          {:id_mismatch, detail} ->
            {:id_mismatch, id, detail}
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

  # Load the singleton error class hierarchy. Strips the envelope keys
  # (extracted_at / tier_scope / class_count) and returns just the
  # tree / flat_parents / ancestors record the pipeline injects into
  # every per-exchange JSON. Returns nil when the file is missing —
  # `Pipeline.build_exchange_data/3` then leaves
  # `/structure/error_class_hierarchy` as nil for that run, matching
  # the established two-state optionality contract.
  defp load_error_class_hierarchy(dir, stats) do
    path = Path.join(dir, "error_class_hierarchy.json")

    case JsonIO.read_json(path) do
      {:ok, data} when is_map(data) ->
        record = Map.take(data, ["tree", "flat_parents", "ancestors"])
        {record, stats}

      {:ok, _malformed} ->
        raise "Corrupt discovery artifact: #{path} is not a map"

      {:error, {:missing_input, _}} ->
        {nil, add_stat_entry(stats, :missing_files, "error_class_hierarchy.json")}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery artifact: #{detail}"
    end
  end

  # Load class hierarchy, group by class_name for rest/ws splitting
  defp load_classes(dir, expected_ids, stats) do
    path = Path.join(dir, "class_hierarchy.json")

    case JsonIO.read_json(path) do
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
    load_global_exchanges_file(
      dir,
      filename,
      expected_ids,
      stats,
      &validate_exchange_field_entry(filename, field, &1)
    )
  end

  # Load sign_methods — the value is the "sign" key (MethodAST or nil)
  defp load_sign_methods(dir, expected_ids, stats) do
    path = Path.join(dir, "sign_methods.json")

    case JsonIO.read_json(path) do
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
    load_global_exchanges_file(
      dir,
      filename,
      expected_ids,
      stats,
      &validate_exchange_lookup_entry(filename, &1)
    )
  end

  # Shared scaffold for global `_.json` files shaped as `%{"exchanges" => [...]}`.
  # The `validate_fn` decides how each entry becomes `{:ok, id, value}` or `{:corrupt, detail}`.
  defp load_global_exchanges_file(dir, filename, expected_ids, stats, validate_fn) do
    path = Path.join(dir, filename)

    case JsonIO.read_json(path) do
      {:ok, %{"exchanges" => entries}} when is_list(entries) ->
        stats = record_global_orphans(stats, filename, entries, expected_ids)
        reduce_validated(entries, stats, validate_fn)

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

    case JsonIO.read_json(path) do
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
        {:corrupt, "#{filename}#id=#{inspect(id)} invalid #{field}: expected list, got #{Schema.type_name(value)}"}

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

  defp validate_exchange_lookup_entry("request_defaults.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, defaults} <-
           fetch_required_key(entry, "request_defaults", id, "request_defaults.json"),
         :ok <-
           validate_required_map_field("request_defaults.json", id, "request_defaults", defaults) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("request_defaults.json", entry) do
    {:corrupt, "request_defaults.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
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

  defp validate_exchange_lookup_entry("request_headers.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, headers} <-
           fetch_required_key(entry, "request_headers", id, "request_headers.json"),
         :ok <-
           validate_required_map_field("request_headers.json", id, "request_headers", headers) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("request_headers.json", entry) do
    {:corrupt, "request_headers.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry("rate_limit_buckets.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, buckets} <-
           fetch_required_key(entry, "rate_limit_buckets", id, "rate_limit_buckets.json"),
         :ok <-
           validate_required_map_field(
             "rate_limit_buckets.json",
             id,
             "rate_limit_buckets",
             buckets
           ) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("rate_limit_buckets.json", entry) do
    {:corrupt, "rate_limit_buckets.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
  end

  defp validate_exchange_lookup_entry("rate_limit_costs.json", %{"id" => id} = entry) when is_binary(id) do
    with {:ok, costs} <-
           fetch_required_key(entry, "rate_limit_costs", id, "rate_limit_costs.json"),
         :ok <-
           validate_required_map_field("rate_limit_costs.json", id, "rate_limit_costs", costs) do
      {:ok, id, entry}
    end
  end

  defp validate_exchange_lookup_entry("rate_limit_costs.json", entry) do
    {:corrupt, "rate_limit_costs.json invalid exchange entry: expected string id, got #{inspect(entry)}"}
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
    {:corrupt, "#{filename}#id=#{inspect(id)} invalid #{field}: expected map, got #{Schema.type_name(value)}"}
  end

  defp validate_optional_map_field(_filename, _id, _field, nil), do: :ok
  defp validate_optional_map_field(_filename, _id, _field, value) when is_map(value), do: :ok

  defp validate_optional_map_field(filename, id, field, value) do
    {:corrupt, "#{filename}#id=#{inspect(id)} invalid #{field}: expected map or null, got #{Schema.type_name(value)}"}
  end

  defp compute_canonical_has_keys(describe) when is_map(describe) do
    Enum.reduce(describe, MapSet.new(), fn {_id, d}, acc ->
      case d do
        %{"has" => has} when is_map(has) ->
          Enum.reduce(Map.keys(has), acc, &MapSet.put(&2, &1))

        _ ->
          acc
      end
    end)
  end
end
