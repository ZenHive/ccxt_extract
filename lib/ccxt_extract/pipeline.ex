defmodule CcxtExtract.Pipeline do
  @moduledoc """
  Assemble per-exchange JSON files from all extraction outputs.

  Reads discovery data produced by individual extractors (QuickBEAM runtime
  values + OXC AST data) and combines them into validated per-exchange JSON
  files conforming to `exchange_v3.json` schema.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.Pipeline.extract()
      CcxtExtract.Pipeline.write!(exchanges)

  ## Options

    * `:discoveries_dir` — override input directory (for testing)
    * `:ccxt_version` — override version (auto-read from ccxt_version.json)
    * `:extracted_at` — override timestamp (defaults to now, use for determinism)
  """

  alias CcxtExtract.DiscoveryLoader
  alias CcxtExtract.OverrideRegistry
  alias CcxtExtract.Paths
  alias CcxtExtract.Provenance
  alias CcxtExtract.Schema
  alias CcxtExtract.ScopeCleanup
  alias CcxtExtract.SignRecipe

  require Logger

  @output_dir "output"

  # --- Public API ---

  @doc """
  Read all discovery data, assemble per-exchange output, validate each.

  Returns `{:ok, exchanges, stats}` where `exchanges` is a sorted list of
  validated exchange maps and `stats` tracks counts.

  ## Options

    * `:scope` — `:all` (default) assembles every known exchange, or a
      `MapSet` of exchange IDs to restrict assembly to. Integrity stats
      (`missing_entries`, `orphan_entries`, etc.) still reflect the full
      universe so we never hide real discovery drift.
  """
  @spec extract(keyword()) :: {:ok, [map()], map()} | {:error, CcxtExtract.JsonIO.read_error()}
  def extract(opts \\ []) do
    dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))
    exchanges_path = Path.join(dir, "exchanges.json")

    with {:ok, exchanges_json} <- CcxtExtract.JsonIO.read_json(exchanges_path) do
      data = DiscoveryLoader.load_all!(dir, exchanges_json)

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
      scope = Keyword.get(opts, :scope, :all)

      {exchanges, errors} =
        data.exchanges
        |> filter_scope(scope)
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

      final_exchanges =
        exchanges
        |> Enum.reverse()
        |> Enum.map(&apply_exchange_overrides/1)

      {:ok, final_exchanges, stats}
    end
  end

  @doc """
  Write per-exchange JSON files, the schema, and a manifest.

  Prunes per-exchange JSON files outside the written set before writing,
  preserving the shared schema (`exchange_v3.json`) and any `_`-prefixed
  metadata file (manifests, base methods).

  ## Options

    * `:tier_scope` — value to stamp into `_manifest.json` as `tier_scope`.
      Use `CcxtExtract.Scope.to_manifest_value/1` to compute from parsed
      CLI opts. Defaults to `"all"` when omitted.
    * `:discoveries_dir` — override the source directory for
      `_base_methods.json` (used for testing).
    * `:pretty` — boolean. When true, emit per-exchange JSON with
      indentation (~2× size). Default `false`. Manifests, fixtures, and
      reports remain pretty-printed regardless of this flag.
  """
  @spec write!([map()], String.t(), keyword()) :: :ok
  def write!(exchanges, output_dir \\ Paths.out(@output_dir), opts \\ []) do
    discoveries_dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))

    File.mkdir_p!(output_dir)

    in_scope = MapSet.new(exchanges, & &1["exchange"]["id"])
    {:ok, _removed} = ScopeCleanup.prune_out_of_scope(output_dir, in_scope, preserve: [Schema.schema_filename()])

    pretty? = Keyword.get(opts, :pretty, false)

    for exchange <- exchanges do
      id = exchange["exchange"]["id"]
      path = Path.join(output_dir, "#{id}.json")
      File.write!(path, Jason.encode!(CcxtExtract.AstNormalize.normalize(exchange), pretty: pretty?))
    end

    manifest = build_manifest(exchanges, opts)
    manifest_path = Path.join(output_dir, "_manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    copy_schema!(output_dir)
    copy_base_methods!(output_dir, discoveries_dir)

    :ok
  end

  defp filter_scope(exchanges, :all), do: exchanges

  defp filter_scope(exchanges, %MapSet{} = scope) do
    Enum.filter(exchanges, &MapSet.member?(scope, &1["id"]))
  end

  # Apply all curated overrides (priv/overrides/<id>.json) to the assembled
  # exchange map. Runs after assembly+validation so overrides replace whatever
  # derivation produced. Two-layer error handling: the outer rescue catches
  # OverrideRegistry.load/1 failures (bad JSON, schema violation) and the
  # inner per-entry rescue catches put_in/pointer_to_keys raises, naming the
  # failing pointer. Failures are surfaced two ways: a Logger.warning here
  # at assembly time, and as a finding from the contract-test invariants
  # override_registry_valid (file-level) and override_paths_present_in_output
  # (entry-level). The contract-test finding is the strict channel; this
  # assembly-time log keeps a single bad file from blocking a full-universe
  # build.
  #
  # TODO(Task 62): `mix ccxt_extract.validate_overrides` will offer a strict
  # mode that propagates these errors — that task is where fail-hard
  # semantics belong.
  defp apply_exchange_overrides(exchange) do
    id = exchange["exchange"]["id"]

    case OverrideRegistry.load(id) do
      :none ->
        sync_sign_recipe(exchange)

      overrides when is_list(overrides) ->
        {updated, applied_paths} =
          Enum.reduce(overrides, {exchange, []}, fn entry, {acc, paths} ->
            apply_override_entry(entry, acc, paths, id)
          end)

        updated
        |> sync_sign_recipe()
        |> stamp_override_provenance(applied_paths)
    end
  rescue
    e in [RuntimeError, File.Error, Jason.DecodeError] ->
      id = exchange["exchange"]["id"]

      Logger.warning(
        "Override load failed for #{id} (priv/overrides/#{id}.json): #{Exception.message(e)}; leaving exchange unchanged"
      )

      exchange
  end

  # Keep `structure.sign_recipe` keys in lockstep with
  # `structure.authenticated_sections` after overrides may have mutated
  # either. An override that flips authenticated_sections (e.g. hyperliquid
  # adding "private") without touching sign_recipe would otherwise leave
  # the recipe missing a section, violating the
  # sign_recipe_keys_match_auth_sections contract invariant.
  #
  # This runs AFTER override application so that any override targeting
  # recipe sub-paths (e.g. /structure/sign_recipe/private/crypto_op) still
  # survives the sync: keys that appear in both the new auth_sections and
  # the existing recipe are preserved untouched. Keys added by auth_sections
  # that have no recipe entry get a fresh `null_recipe`.
  defp sync_sign_recipe(exchange) do
    auth_sections = get_in(exchange, ["structure", "authenticated_sections"])
    existing = get_in(exchange, ["structure", "sign_recipe"]) || %{}
    sign_method = get_in(exchange, ["structure", "sign_method"])
    synced = synced_recipe_map(auth_sections, existing, sign_method)
    put_in(exchange, ["structure", "sign_recipe"], synced)
  end

  defp synced_recipe_map(nil, _existing, _sign_method), do: %{}
  defp synced_recipe_map([], _existing, _sign_method), do: %{}

  defp synced_recipe_map(auth_sections, existing, sign_method) when is_list(auth_sections) do
    # For sections that already exist (pre-override or derived), keep their
    # derived values. For sections newly introduced by an override that
    # bumped authenticated_sections, re-run Derive so the new section gets
    # a real crypto_op/placement rather than a permanent null_recipe.
    new_sections = Enum.reject(auth_sections, &Map.has_key?(existing, &1))
    new_recipes = SignRecipe.Derive.derive(sign_method, new_sections)

    Map.new(auth_sections, fn section ->
      {section, Map.get(existing, section) || Map.get(new_recipes, section) || SignRecipe.null_recipe()}
    end)
  end

  # Apply a single override entry, threading the applied-path list so the
  # _provenance map can mark successfully-applied paths as "override".
  # Entries that raise are logged and dropped from the path list — failed
  # overrides must not claim override provenance for a raw value that was
  # never replaced.
  # TODO(Task 62): strict-mode validate_overrides will propagate these
  # instead of logging; see apply_exchange_overrides/1 header for rationale.
  defp apply_override_entry(entry, acc, paths, id) do
    keys = OverrideRegistry.pointer_to_keys(entry["path"])
    {put_in(acc, keys, entry["value"]), [entry["path"] | paths]}
  rescue
    e in [RuntimeError, KeyError, ArgumentError, FunctionClauseError] ->
      Logger.warning(
        "Override entry #{inspect(entry["path"])} failed for #{id} (priv/overrides/#{id}.json): #{Exception.message(e)}; entry not applied"
      )

      {acc, paths}
  end

  # Stamp "override" in the _provenance map for every path that successfully
  # applied. Default provenance already tags every known pointer as raw or
  # derived; this replaces those tags (or adds new ones for sub-tree paths
  # deeper than default granularity) for the overridden subset.
  defp stamp_override_provenance(exchange, []), do: exchange

  defp stamp_override_provenance(exchange, paths) do
    Map.update(exchange, "_provenance", Provenance.build_default(), fn provenance ->
      Provenance.stamp_overrides(provenance, paths)
    end)
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
      "symbols_index" => CcxtExtract.SymbolsIndex.derive(markets),
      "symbol_patterns" => CcxtExtract.SymbolPatterns.derive(markets, describe),
      "url_templates" => get_url_templates(id, data),
      "testnet_urls" => CcxtExtract.TestnetUrls.derive(describe)
    }

    sign_method = get_sign_method(id, data)
    effective_sign = sign_method || get_parent_sign_method(id, data)
    api_keys = describe_api_keys(describe)

    # Curated overrides for `/structure/authenticated_sections` are applied
    # at the tail of extract/1 by apply_exchange_overrides/1, which threads
    # applied-pointer paths into the _provenance map.
    authenticated_sections = CcxtExtract.AuthenticatedSections.derive(effective_sign, api_keys)

    structure_data = %{
      "class_info" => get_class_info(id, data),
      "methods" => get_methods(id, data),
      "sign_method" => sign_method,
      "authenticated_sections" => authenticated_sections,
      "handle_errors" => get_handle_errors(id, data),
      "interface_signatures" => get_interface_signatures(id, data),
      "pagination" => get_pagination(id, data),
      "unified_endpoints" => get_unified_endpoints(id, data),
      "request_defaults" => get_request_defaults(id, data),
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

  # Resolve parent's sign_method when the child doesn't override it.
  # Walks the extends chain until a non-nil sign_method is found.
  defp get_parent_sign_method(id, data) do
    case find_parent_exchange_id(id, data) do
      nil ->
        nil

      parent_id ->
        case Map.get(data.sign_methods, parent_id) do
          nil -> get_parent_sign_method(parent_id, data)
          sign -> sign
        end
    end
  end

  # Top-level keys of describe.api (section names routed through sign()).
  defp describe_api_keys(%{"api" => api}) when is_map(api), do: Map.keys(api)
  defp describe_api_keys(_), do: nil

  # Handle errors: rename handle_errors → method, with parent fallback
  defp get_handle_errors(id, data) do
    case Map.get(data.handle_errors, id) do
      nil ->
        get_parent_handle_errors(id, data)

      %{"handle_errors" => nil} ->
        get_parent_handle_errors(id, data)

      %{"handle_errors" => method} = entry when is_map(method) ->
        %{
          "method" => method,
          "exceptions" => entry["exceptions"],
          "http_exceptions" => entry["http_exceptions"],
          "error_code_fields" => CcxtExtract.ErrorCodeFields.derive(method),
          "throw_dispatches" => CcxtExtract.ThrowDispatches.derive(method)
        }

      _ ->
        get_parent_handle_errors(id, data)
    end
  end

  # Recursive parent fallback for handle_errors
  defp get_parent_handle_errors(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_handle_errors(parent_id, data)
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
  # drop endpoints the child explicitly disables (has: false), restrict to the canonical CCXT
  # has-key vocabulary, then filter against interface_signatures to remove leaked helper method names.
  defp get_unified_endpoints(id, data) do
    parent_id = find_parent_exchange_id(id, data)
    disabled = exchange_disabled_has_keys(id, data)
    canonical = Map.get(data, :canonical_has_keys)
    valid_endpoints = collect_interface_signature_keys(id, parent_id, data)

    id
    |> extract_unified_endpoints_map(data)
    |> merge_parent_endpoints(parent_id, data)
    |> drop_disabled_endpoints(disabled)
    |> restrict_to_canonical_vocab(canonical)
    |> filter_unified_endpoints(valid_endpoints)
  end

  defp exchange_disabled_has_keys(id, data) do
    case get_describe(id, data) do
      %{"has" => has} when is_map(has) ->
        for {k, v} <- has, v == false, into: MapSet.new(), do: k

      _ ->
        MapSet.new()
    end
  end

  defp drop_disabled_endpoints(nil, _disabled), do: nil

  defp drop_disabled_endpoints(endpoints, disabled) do
    if MapSet.size(disabled) == 0 do
      endpoints
    else
      filtered = Map.reject(endpoints, fn {method, _calls} -> MapSet.member?(disabled, method) end)
      if map_size(filtered) > 0, do: filtered
    end
  end

  # Restrict endpoints to methods that appear as a `has` key somewhere in the CCXT corpus.
  # Kills internal routing helpers (fetchSpotMarkets, createSpotOrder, kucoin UTA variants, etc.)
  # that pass prefix-matching but are not part of the unified API vocabulary. Methods only
  # implemented outside the canonical vocabulary belong in override-tier once Phase 9 ships.
  defp restrict_to_canonical_vocab(nil, _canonical), do: nil
  defp restrict_to_canonical_vocab(endpoints, nil), do: endpoints

  defp restrict_to_canonical_vocab(endpoints, canonical) do
    filtered = Map.filter(endpoints, fn {method, _calls} -> MapSet.member?(canonical, method) end)
    if map_size(filtered) > 0, do: filtered
  end

  # Extract the raw unified_endpoints map from the discovery lookup
  defp extract_unified_endpoints_map(id, data) do
    case Map.get(data.unified_endpoints, id) do
      nil -> nil
      %{"unified_endpoints" => endpoints} when map_size(endpoints) > 0 -> endpoints
      _ -> nil
    end
  end

  # Request defaults: read the per-method default-request-body map from the
  # discovery lookup and fall back to the parent when the exchange is an alias
  # that didn't produce its own entry. No filtering against unified_endpoints
  # here — that invariant is enforced by the contract test. A method M appears
  # in the output iff the extractor found a resolvable literal body for it
  # (possibly via this.extend unwrap or const-trace); callers check the
  # per-entry `kind` to distinguish literal from unresolved.
  defp get_request_defaults(id, data) do
    id
    |> extract_request_defaults_map(data)
    |> merge_parent_request_defaults(find_parent_exchange_id(id, data), data)
  end

  defp extract_request_defaults_map(id, data) do
    case Map.get(data.request_defaults, id) do
      nil -> nil
      %{"request_defaults" => defaults} when map_size(defaults) > 0 -> defaults
      _ -> nil
    end
  end

  defp merge_parent_request_defaults(defaults, nil, _data), do: defaults

  defp merge_parent_request_defaults(nil, parent_id, data), do: extract_request_defaults_map(parent_id, data)

  defp merge_parent_request_defaults(defaults, parent_id, data) do
    case extract_request_defaults_map(parent_id, data) do
      nil -> defaults
      parent -> Map.merge(parent, defaults)
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

  # Returns the full version info map from priv/ccxt_version.json, or an empty
  # map if the file is missing/corrupt. Used by build_manifest to include
  # source_git_sha for reproducibility traceability.
  defp read_ccxt_version_info do
    case CcxtExtract.JsonIO.read_json(Paths.version_file()) do
      {:ok, data} -> data
      {:error, _} -> %{}
    end
  end

  defp copy_schema!(output_dir) do
    schema_source = Paths.priv("schema/" <> Schema.schema_filename())
    schema_target = Path.join(output_dir, Schema.schema_filename())
    # TODO(Task 127): explicit read+write (not `File.cp!/2`) so the
    # `paths_rw_split` contract invariant sees a sanitized flow:
    # `Paths.priv → File.read! → File.write!`. `File.cp!` is a writer that
    # also receives a read-side arg, which the chop-level taint check can't
    # position-distinguish. Restore `File.cp!` once Task 127 lands
    # position-aware sinks. Mode preservation isn't load-bearing for a JSON
    # schema file.
    File.write!(schema_target, File.read!(schema_source))
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
      "tier_scope" => Keyword.get(opts, :tier_scope, "all"),
      "exchange_count" => length(exchanges),
      "exchanges" => exchanges |> Enum.map(& &1["exchange"]["id"]) |> Enum.sort()
    }
  end
end
