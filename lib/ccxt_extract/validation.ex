defmodule CcxtExtract.Validation do
  @moduledoc """
  Full validation of per-exchange JSON output.

  Two validation layers:

  - **JSON Schema** — validate output against `exchange_v4.json` (draft 2020-12)
    using JSV. Catches type errors, extra properties, missing required fields.
  - **Round-trip** — compare pipeline output sections against source discovery
    data. Catches data loss or incorrect transformation in the pipeline.

  Findings have severity levels:

  - **error** — schema violation or data loss
  - **warning** — non-critical mismatch (e.g., expected null section)
  - **info** — informational note

  ## Usage

      {:ok, report} = CcxtExtract.Validation.validate_all(discoveries_dir: "priv/discoveries")
      CcxtExtract.Validation.write!(report)
  """

  alias CcxtExtract.JsonIO
  alias CcxtExtract.Paths
  alias CcxtExtract.Schema

  require Logger

  @output_file "output/_validation_report.json"

  @reference_exchanges ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid)

  # --- Public API ---

  @doc """
  Run full validation against emitted JSON files on disk.

  Reads per-exchange JSON from `output_dir`, validates each file against
  the JSON Schema, and optionally runs round-trip comparison against
  source discovery data.

  Options:
    * `:output_dir` — directory containing emitted JSON files (default: `priv/output`)
    * `:discoveries_dir` — override source discovery directory for round-trip checks
    * `:schema_only` — skip round-trip comparison (default: false)
    * `:reference_exchanges` — override which exchanges get round-trip checks
    * `:tier_scope` — `CcxtExtract.Scope.to_manifest_value/1` output; stamped on
      the report envelope. Defaults to `"all"`.
  """
  @spec validate_all(keyword()) :: {:ok, map()}
  def validate_all(opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, Paths.priv("output"))
    schema_only = Keyword.get(opts, :schema_only, false)
    ref_exchanges = Keyword.get(opts, :reference_exchanges, @reference_exchanges)
    tier_scope = Keyword.get(opts, :tier_scope, "all")

    {roundtrip_enabled?, roundtrip_skipped_reason} =
      if schema_only do
        {false, "schema_only requested"}
      else
        {true, nil}
      end

    # Load exchanges from emitted JSON files on disk
    {exchanges, file_stats} = load_output_files(output_dir)

    # Build JSON Schema root once (v4 only)
    root = build_schema_root()

    # Load source data for round-trip (reuse pipeline's loader)
    source_data =
      if roundtrip_enabled? do
        dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))
        load_source_data(dir)
      end

    # Validate each exchange
    exchange_results =
      Enum.map(exchanges, fn exchange ->
        id = exchange["exchange"]["id"]

        # JSON Schema validation
        schema_result = validate_schema(exchange, root)

        # Round-trip comparison (reference exchanges only)
        roundtrip_findings =
          if roundtrip_enabled? && id in ref_exchanges && source_data do
            validate_roundtrip(exchange, source_data, id)
          else
            []
          end

        %{
          "id" => id,
          "schema_valid" => schema_result == :ok,
          "schema_errors" => schema_errors_to_list(schema_result),
          "roundtrip_findings" => roundtrip_findings
        }
      end)

    report =
      build_report(
        exchange_results,
        ref_exchanges,
        file_stats,
        tier_scope,
        roundtrip_skipped_reason
      )

    {:ok, report}
  end

  @doc """
  Validate a single exchange map against `exchange_v4.json` using JSV.

  Returns `:ok` or `{:error, findings}` where findings is a list of
  JSON-serializable maps.
  """
  @spec validate_schema(map(), JSV.Root.t()) :: :ok | {:error, [map()]}
  def validate_schema(exchange_data, root) do
    case JSV.validate(exchange_data, root) do
      {:ok, _} ->
        :ok

      {:error, validation_error} ->
        findings =
          validation_error
          |> JSV.normalize_error()
          |> extract_jsv_errors()

        {:error, findings}
    end
  end

  @doc """
  Compare pipeline output against source discovery data for one exchange.

  Returns a list of finding maps (empty = clean).
  """
  @spec validate_roundtrip(map(), map(), String.t()) :: [map()]
  def validate_roundtrip(output, source_data, exchange_id) do
    []
    |> check_describe_roundtrip(output, source_data, exchange_id)
    |> check_symbols_index_roundtrip(output, source_data, exchange_id)
    |> check_class_info_roundtrip(output, source_data, exchange_id)
    |> check_methods_roundtrip(output, source_data, exchange_id)
    |> check_sign_method_roundtrip(output, source_data, exchange_id)
    |> check_handle_errors_roundtrip(output, source_data, exchange_id)
    |> check_interface_signatures_roundtrip(output, source_data, exchange_id)
    |> check_pagination_roundtrip(output, source_data, exchange_id)
    |> check_unified_endpoints_roundtrip(output, source_data, exchange_id)
    |> check_overrides_roundtrip(output, source_data, exchange_id)
    |> check_symbol_patterns_roundtrip(output, source_data, exchange_id)
    |> check_url_templates_roundtrip(output, source_data, exchange_id)
    |> Enum.reverse()
  end

  @doc """
  Build the compiled JSON Schema root for `exchange_v4.json`.
  """
  @spec build_schema_root() :: JSV.Root.t()
  def build_schema_root do
    schema_path = Paths.priv("schema/" <> Schema.schema_filename())
    raw_schema = JsonIO.read_json!(schema_path)
    JSV.build!(raw_schema)
  end

  @doc "Write validation report as JSON."
  @spec write!(map(), String.t()) :: :ok
  def write!(report, output_path \\ Paths.out(@output_file)) do
    File.mkdir_p!(Path.dirname(output_path))
    JsonIO.write_json!(output_path, report, pretty: true)
    :ok
  end

  # --- Output File Loading ---

  # Reads _manifest.json + per-exchange JSON files from output_dir.
  # Returns {exchanges, file_stats} where file_stats tracks integrity.
  defp load_output_files(output_dir) do
    manifest_path = Path.join(output_dir, "_manifest.json")

    manifest =
      case JsonIO.read_json(manifest_path) do
        {:ok, data} -> data
        {:error, _} -> nil
      end

    if is_nil(manifest) do
      Logger.warning("No valid _manifest.json found in #{output_dir}")
      stats = Map.put(empty_file_stats(), "manifest_error", "missing or corrupt _manifest.json")
      {[], stats}
    else
      load_exchanges_from_manifest(output_dir, manifest)
    end
  end

  # Load each exchange JSON listed in the manifest, tracking file-level integrity
  defp load_exchanges_from_manifest(output_dir, manifest) do
    manifest_ids = manifest["exchanges"] || []

    # Load each exchange file listed in manifest
    {exchanges, missing, corrupt, id_mismatches} =
      Enum.reduce(manifest_ids, {[], [], [], []}, fn id, acc ->
        read_exchange_file(output_dir, id, acc)
      end)

    # Detect orphan files (JSON files in output_dir not listed in manifest)
    # Also skip exchange_v4.json (schema copy) and _base_methods.json

    manifest_set = MapSet.new(manifest_ids)
    # Exclude metadata files and the v4 schema copy itself.
    known_files = MapSet.new(["exchange_v4"])

    orphans =
      output_dir
      |> File.ls!()
      |> Enum.filter(&(String.ends_with?(&1, ".json") && !String.starts_with?(&1, "_")))
      |> Enum.map(&String.trim_trailing(&1, ".json"))
      |> Enum.reject(&(MapSet.member?(manifest_set, &1) || MapSet.member?(known_files, &1)))

    file_stats = %{
      "missing_entries" => Enum.reverse(missing),
      "corrupt_entries" => Enum.reverse(corrupt),
      "orphan_entries" => Enum.sort(orphans),
      "id_mismatch_entries" => Enum.reverse(id_mismatches),
      "validation_errors" => []
    }

    {Enum.reverse(exchanges), file_stats}
  end

  # Read and decode a single exchange JSON file, classifying the result
  defp read_exchange_file(output_dir, id, {exs, miss, corr, mis}) do
    path = Path.join(output_dir, "#{id}.json")

    case JsonIO.read_json(path) do
      {:ok, data} ->
        file_id = get_in(data, ["exchange", "id"])

        if file_id == id do
          {[data | exs], miss, corr, mis}
        else
          {[data | exs], miss, corr, ["#{id} (file has id=#{file_id})" | mis]}
        end

      {:error, {:invalid_json, _}} ->
        {exs, miss, [id | corr], mis}

      {:error, {:missing_input, _}} ->
        {exs, [id | miss], corr, mis}
    end
  end

  defp empty_file_stats do
    %{
      "missing_entries" => [],
      "corrupt_entries" => [],
      "orphan_entries" => [],
      "id_mismatch_entries" => [],
      "validation_errors" => []
    }
  end

  # --- JSON Schema Error Extraction ---

  # Convert JSV normalized error to flat list of finding maps.
  # JSV.normalize_error/1 returns atom-keyed maps by default:
  #   %{valid: false, details: [error_unit]}
  # Each error_unit: %{valid: bool, instanceLocation: str, schemaLocation: str, errors: [kw_error]}
  # Each kw_error: %{kind: atom, message: str, details: [error_unit] (optional)}
  defp extract_jsv_errors(%{details: units}) when is_list(units) do
    Enum.flat_map(units, &extract_error_unit/1)
  end

  defp extract_jsv_errors(other) when is_map(other) do
    [%{"path" => "/", "message" => inspect(other)}]
  end

  defp extract_jsv_errors(_), do: []

  # Extract findings from a single error_unit (grouped by instance location)
  defp extract_error_unit(%{instanceLocation: instance_loc} = unit) do
    path = to_string(instance_loc)

    keyword_errors =
      case Map.get(unit, :errors) do
        errors when is_list(errors) -> Enum.flat_map(errors, &extract_keyword_error(path, &1))
        _ -> [%{"path" => path, "message" => "validation failed"}]
      end

    keyword_errors
  end

  defp extract_error_unit(other), do: [%{"path" => "/", "message" => inspect(other)}]

  # Extract findings from a keyword_error (the actual validation failure)
  defp extract_keyword_error(path, %{message: message} = kw_error) do
    nested =
      case Map.get(kw_error, :details) do
        details when is_list(details) -> Enum.flat_map(details, &extract_error_unit/1)
        _ -> []
      end

    [%{"path" => path, "message" => to_string(message)} | nested]
  end

  defp extract_keyword_error(path, other) do
    [%{"path" => path, "message" => inspect(other)}]
  end

  defp schema_errors_to_list(:ok), do: []
  defp schema_errors_to_list({:error, findings}), do: findings

  # --- Round-Trip Comparison ---

  # Compare raw.describe against source describe fixture.
  # Alias exchanges have no own source — compare against parent's source instead.
  defp check_describe_roundtrip(findings, output, source, id) do
    output_describe = get_in(output, ["raw", "describe"])
    source_describe = Map.get(source.describe, id) || resolve_parent_source(source, id, :describe)

    findings
    |> check_presence_match(output_describe, source_describe, id, "raw.describe")
    |> maybe_check_describe_keys(output_describe, source_describe, id)
  end

  defp maybe_check_describe_keys(findings, output, source, _id) when is_nil(output) or is_nil(source), do: findings

  defp maybe_check_describe_keys(findings, output_describe, source_describe, id) do
    output_keys = output_describe |> Map.keys() |> MapSet.new()
    source_keys = source_describe |> Map.keys() |> MapSet.new()

    findings
    |> check_key_diff(source_keys, output_keys, id, "raw.describe", "error", "missing keys from source")
    |> check_key_diff(output_keys, source_keys, id, "raw.describe", "warning", "extra keys not in source")
  end

  # Report if set_a has elements not in set_b
  defp check_key_diff(findings, set_a, set_b, id, path, severity, label) do
    diff = MapSet.difference(set_a, set_b)

    if MapSet.size(diff) > 0 do
      [roundtrip_finding(id, path, severity, "#{label}: #{inspect(MapSet.to_list(diff))}") | findings]
    else
      findings
    end
  end

  # Compare markets.symbols_index against source markets — symbol set only.
  # Per-market fields (price/precision/fees/limits/baseId/quoteId) are not
  # emitted since schema 3.0.0 (Task 117), so there's nothing to compare there.
  # Alias exchanges have no own source — resolve parent's source instead.
  defp check_symbols_index_roundtrip(findings, output, source, id) do
    output_index = get_in(output, ["markets", "symbols_index"])
    source_markets = Map.get(source.load_markets, id) || resolve_parent_source(source, id, :load_markets)
    source_failure = Map.get(source.load_markets_failed, id)

    case classify_symbols_state(output_index, source_markets, source_failure) do
      :both_absent ->
        findings

      :source_failed_upstream ->
        [
          roundtrip_finding(
            id,
            "markets.symbols_index",
            "info",
            "source load_markets failed upstream; round-trip skipped"
          )
          | findings
        ]

      :output_missing ->
        [roundtrip_finding(id, "markets.symbols_index", "error", "output is null but source has data") | findings]

      :source_failure_inherited ->
        [
          roundtrip_finding(
            id,
            "markets.symbols_index",
            "info",
            "source load_markets failed; output populated from parent class inheritance"
          )
          | findings
        ]

      :source_failure_mismatch ->
        [
          roundtrip_finding(
            id,
            "markets.symbols_index",
            "error",
            "output has data but source load_markets manifest recorded failure"
          )
          | findings
        ]

      :source_missing ->
        [roundtrip_finding(id, "markets.symbols_index", "warning", "output has data but no source artifact") | findings]

      :compare ->
        check_symbols_index_keys(findings, output_index, source_markets, id)
    end
  end

  # Classify the nil/present state of symbols_index vs source markets
  defp classify_symbols_state(nil, nil, nil), do: :both_absent
  defp classify_symbols_state(nil, nil, _failure), do: :source_failed_upstream
  defp classify_symbols_state(nil, _source, _failure), do: :output_missing
  defp classify_symbols_state(_output, nil, failure) when not is_nil(failure), do: :source_failure_mismatch
  defp classify_symbols_state(_output, _source, failure) when not is_nil(failure), do: :source_failure_inherited
  defp classify_symbols_state(_output, nil, _failure), do: :source_missing
  defp classify_symbols_state(_output, _source, _failure), do: :compare

  # Keyset-only comparison: since schema 3.0.0 the output no longer copies
  # per-market fields through from source, so there is no copy-correctness to
  # round-trip. The derived `{spot, swap}` booleans are covered by unit tests
  # on `CcxtExtract.SymbolsIndex.derive/1` (see test/ccxt_extract/symbols_index_test.exs);
  # `Schema` and pipeline tests cross-check them at assembly time. A sampled
  # cross-check here would duplicate derivation logic and invite drift.
  defp check_symbols_index_keys(findings, output_index, source_markets, id) do
    output_syms = output_index |> Map.keys() |> MapSet.new()
    source_syms = source_markets["markets"] |> Kernel.||(%{}) |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(source_syms, output_syms)
    extra = MapSet.difference(output_syms, source_syms)

    findings
    |> maybe_add_finding(missing, id, "markets.symbols_index", "error", "missing symbols from source")
    |> maybe_add_finding(extra, id, "markets.symbols_index", "warning", "extra symbols not in source")
  end

  defp maybe_add_finding(findings, set, id, path, severity, label) do
    if MapSet.size(set) > 0 do
      [roundtrip_finding(id, path, severity, "#{label}: #{MapSet.size(set)}") | findings]
    else
      findings
    end
  end

  # Compare raw.class_info
  defp check_class_info_roundtrip(findings, output, source, id) do
    output_info = get_in(output, ["raw", "class_info"])
    source_entries = Map.get(source.classes, id)

    cond do
      is_nil(output_info) && is_nil(source_entries) ->
        findings

      is_nil(output_info) && !is_nil(source_entries) ->
        [roundtrip_finding(id, "raw.class_info", "error", "output is null but source has class data") | findings]

      true ->
        findings
        |> check_class_entry(output_info["rest"], source_entries, "rest", id)
        |> check_class_entry(output_info["ws"], source_entries, "ws", id)
    end
  end

  defp check_class_entry(findings, nil, source_entries, type, id) do
    source_entry = source_entries && Enum.find(source_entries, &(&1["type"] == type))

    if source_entry do
      [
        roundtrip_finding(id, "raw.class_info.#{type}", "error", "output is null but source has #{type} class data")
        | findings
      ]
    else
      findings
    end
  end

  defp check_class_entry(findings, output_entry, source_entries, type, id) do
    source_entry = source_entries && Enum.find(source_entries, &(&1["type"] == type))

    if source_entry do
      output_mc = output_entry["method_count"]
      source_mc = source_entry["method_count"]

      if output_mc == source_mc do
        findings
      else
        [
          roundtrip_finding(
            id,
            "raw.class_info.#{type}",
            "error",
            "method_count mismatch: output=#{output_mc} source=#{source_mc}"
          )
          | findings
        ]
      end
    else
      findings
    end
  end

  # Compare raw.method_inventory (method name sets — REST and WS)
  defp check_methods_roundtrip(findings, output, source, id) do
    output_methods = get_in(output, ["raw", "method_inventory"])
    source_rest = Map.get(source.methods_rest, id)
    source_ws = Map.get(source.methods_ws, id)

    cond do
      is_nil(output_methods) && is_nil(source_rest) && is_nil(source_ws) ->
        findings

      is_nil(output_methods) && (!is_nil(source_rest) || !is_nil(source_ws)) ->
        [roundtrip_finding(id, "raw.method_inventory", "error", "output is null but source has method data") | findings]

      true ->
        findings
        |> check_method_name_set(output_methods["rest"], source_rest, id, "raw.method_inventory.rest")
        |> check_method_name_set(output_methods["ws"], source_ws, id, "raw.method_inventory.ws")
    end
  end

  # Compare a method signature list (REST or WS) — names + full signature equality
  defp check_method_name_set(findings, output_list, source_list, id, path) do
    output_list = output_list || []
    source_list = source_list || []

    findings
    |> check_method_names(output_list, source_list, id, path)
    |> check_method_signatures(output_list, source_list, id, path)
  end

  defp check_method_names(findings, output_list, source_list, id, path) do
    output_names = MapSet.new(output_list, & &1["name"])
    source_names = MapSet.new(source_list, & &1["name"])
    missing = MapSet.difference(source_names, output_names)
    maybe_add_finding(findings, missing, id, path, "error", "missing methods from source")
  end

  # Compare full signature data for methods present in both output and source
  defp check_method_signatures(findings, output_list, source_list, id, path) do
    output_by_name = Map.new(output_list, &{&1["name"], &1})

    Enum.reduce(source_list, findings, fn source_sig, acc ->
      name = source_sig["name"]
      output_sig = Map.get(output_by_name, name)
      check_single_signature(acc, output_sig, source_sig, id, path, name)
    end)
  end

  defp check_single_signature(findings, nil, _source, _id, _path, _name), do: findings
  defp check_single_signature(findings, output, source, _id, _path, _name) when output == source, do: findings

  defp check_single_signature(findings, _output, _source, id, path, name) do
    [roundtrip_finding(id, "#{path}.#{name}", "error", "signature mismatch for method #{name}") | findings]
  end

  # Compare auth.sign_method — presence + full MethodAST equality
  defp check_sign_method_roundtrip(findings, output, source, id) do
    output_sign = get_in(output, ["auth", "sign_method"])
    source_sign = Map.get(source.sign_methods, id)

    findings
    |> check_presence_match(output_sign, source_sign, id, "auth.sign_method")
    |> check_data_equality(output_sign, source_sign, id, "auth.sign_method")
  end

  # Compare errors.handle_errors — presence + method AST, exceptions, http_exceptions
  defp check_handle_errors_roundtrip(findings, output, source, id) do
    output_he = get_in(output, ["errors", "handle_errors"])
    raw_entry = Map.get(source.handle_errors, id)
    # Fall back to parent if this exchange has no handleErrors data
    source_entry =
      if source_has_handle_errors?(raw_entry),
        do: raw_entry,
        else: resolve_parent_source(source, id, :handle_errors)

    source_method = source_has_handle_errors?(source_entry)

    findings
    |> check_presence_match(output_he, source_method, id, "errors.handle_errors")
    |> check_handle_errors_content(output_he, source_entry, id)
  end

  defp source_has_handle_errors?(%{"handle_errors" => m}) when is_map(m), do: m
  defp source_has_handle_errors?(_), do: nil

  defp check_handle_errors_content(findings, nil, _, _id), do: findings
  defp check_handle_errors_content(findings, _, nil, _id), do: findings

  defp check_handle_errors_content(findings, output_he, source_entry, id) do
    source_method = source_entry["handle_errors"]

    # Re-derive error_code_fields and throw_dispatches from the source method AST
    expected_ecf = CcxtExtract.ErrorCodeFields.derive(source_method)
    expected_td = CcxtExtract.ThrowDispatches.derive(source_method)

    findings
    |> check_data_equality(output_he["method"], source_method, id, "errors.handle_errors.method")
    |> check_data_equality(output_he["exceptions"], source_entry["exceptions"], id, "errors.handle_errors.exceptions")
    |> check_data_equality(
      output_he["http_exceptions"],
      source_entry["http_exceptions"],
      id,
      "errors.handle_errors.http_exceptions"
    )
    |> check_data_equality(
      output_he["error_code_fields"],
      expected_ecf,
      id,
      "errors.handle_errors.error_code_fields"
    )
    |> check_data_equality(
      output_he["throw_dispatches"],
      expected_td,
      id,
      "errors.handle_errors.throw_dispatches"
    )
  end

  # structure.parse_methods and structure.ws_methods are no longer emitted
  # in the output (pruned in schema 3.0.0 / Task 117). The extractors still
  # run and write priv/discoveries/*.json for Phase 12 / Phase 15 internal
  # consumers — see source.parse_methods and source.ws_methods if needed.
  # No roundtrip check exists here because there is no output column to
  # compare against.

  # Compare endpoints.interfaces (signature name → signature map)
  defp check_interface_signatures_roundtrip(findings, output, source, id) do
    output_is = get_in(output, ["endpoints", "interfaces"])
    source_entry = Map.get(source.interface_signatures, id)
    source_is = source_entry && source_entry["interface_signatures"]
    check_method_map(findings, output_is, source_is, id, "endpoints.interfaces")
  end

  # Compare endpoints.pagination — mirrors Pipeline.build_pagination_output/1 transformation
  defp check_pagination_roundtrip(findings, output, source, id) do
    output_pag = get_in(output, ["endpoints", "pagination"])
    source_entry = Map.get(source.pagination, id)
    source_pag = build_source_pagination(source_entry)

    findings
    |> check_presence_match(output_pag, source_pag, id, "endpoints.pagination")
    |> check_data_equality(output_pag, source_pag, id, "endpoints.pagination")
  end

  # Reconstruct what Pipeline.build_pagination_output/1 produces from raw discovery data
  defp build_source_pagination(nil), do: nil

  defp build_source_pagination(exchange_data) do
    pagination = Map.get(exchange_data, "pagination", %{})
    unresolved = Map.get(exchange_data, "pagination_unresolved", [])

    case {map_size(pagination), unresolved} do
      {0, []} -> nil
      {_, []} -> pagination
      _ -> Map.put(pagination, "_unresolved", unresolved)
    end
  end

  # Compare endpoints.unified — mirrors Pipeline.get_unified_endpoints/2
  # Derived exchanges inherit parent endpoints via Pipeline.merge_parent_endpoints/3,
  # so output legitimately has MORE data than the source (inherited from parent).
  # We verify: (1) source data not lost, (2) source's own endpoints are a subset of output.
  defp check_unified_endpoints_roundtrip(findings, output, source, id) do
    output_ue = get_in(output, ["endpoints", "unified"])
    source_entry = Map.get(source.unified_endpoints, id)
    source_ue = build_source_unified_endpoints(source_entry)

    case {output_ue, source_ue} do
      # Both nil — fine
      {nil, nil} ->
        findings

      # Inherited from parent — not a roundtrip concern
      {_output, nil} ->
        findings

      # Source has data but output lost it — flag as error
      {nil, _source} ->
        check_presence_match(findings, nil, source_ue, id, "endpoints.unified")

      # Both present — verify source's own endpoints are all in output
      _ ->
        check_unified_endpoints_subset(findings, output_ue, source_ue, id)
    end
  end

  # Verify that every key+value from source appears in output.
  # Output may have additional inherited entries — that's expected.
  # Output may have fewer endpoint names per method due to interface_signatures filtering
  # (pipeline removes endpoint names not present in interface_signatures).
  defp check_unified_endpoints_subset(findings, output_ue, source_ue, id) do
    Enum.reduce(source_ue, findings, fn {method, source_calls}, acc ->
      check_unified_endpoint_entry(acc, Map.get(output_ue, method), source_calls, id, method)
    end)
  end

  # Method missing from output — acceptable if pipeline filtered all its endpoints
  defp check_unified_endpoint_entry(findings, nil, _source_calls, _id, _method), do: findings

  defp check_unified_endpoint_entry(findings, output_calls, source_calls, _id, _method) when output_calls == source_calls,
    do: findings

  # Output has fewer calls than source — acceptable if output is a subset (filtered by interface_signatures)
  defp check_unified_endpoint_entry(findings, output_calls, source_calls, id, method) do
    extra_in_output = output_calls -- source_calls

    if extra_in_output == [] do
      # Output is a subset of source — pipeline filtered some names, which is expected
      findings
    else
      msg = "output has entries not in source: #{inspect(extra_in_output)}"
      [roundtrip_finding(id, "endpoints.unified.#{method}", "error", msg) | findings]
    end
  end

  defp build_source_unified_endpoints(nil), do: nil

  defp build_source_unified_endpoints(exchange_data) do
    endpoints = Map.get(exchange_data, "unified_endpoints", %{})
    if map_size(endpoints) > 0, do: endpoints
  end

  # Compare raw.overrides_meta (REST and WS sides)
  defp check_overrides_roundtrip(findings, output, source, id) do
    output_ov = get_in(output, ["raw", "overrides_meta"])
    source_entries = Map.get(source.overrides, id)

    source_rest = overrides_entry_by_type(source_entries, "rest:")
    source_ws = overrides_entry_by_type(source_entries, "ws:")
    # Any source entry means overrides exist
    source_any = source_rest || source_ws

    # Use whichever source side exists for the extends check (REST preferred, WS fallback)
    source_primary = source_rest || source_ws

    findings
    |> check_presence_match(output_ov, source_any, id, "raw.overrides_meta")
    |> maybe_check_overrides_extends(output_ov, source_primary, id)
    |> maybe_check_override_entry(output_ov && output_ov["rest"], source_rest, id, "raw.overrides_meta.rest")
    |> maybe_check_override_entry(output_ov && output_ov["ws"], source_ws, id, "raw.overrides_meta.ws")
  end

  # Find a source override entry by parent_key prefix ("rest:" or "ws:")
  defp overrides_entry_by_type(entries, prefix) when is_list(entries) and entries != [] do
    Enum.find(entries, &String.starts_with?(&1["parent_key"] || "", prefix))
  end

  defp overrides_entry_by_type(_, _), do: nil

  defp maybe_check_overrides_extends(findings, nil, _, _id), do: findings
  defp maybe_check_overrides_extends(findings, _, nil, _id), do: findings

  defp maybe_check_overrides_extends(findings, output_ov, primary, id) do
    if output_ov["extends"] == primary["extends"] do
      findings
    else
      [
        roundtrip_finding(
          id,
          "raw.overrides_meta",
          "error",
          "extends mismatch: output=#{output_ov["extends"]} source=#{primary["extends"]}"
        )
        | findings
      ]
    end
  end

  # Check that override entry presence matches between output and source
  defp maybe_check_override_entry(findings, nil, nil, _id, _path), do: findings

  defp maybe_check_override_entry(findings, nil, _source, id, path),
    do: [roundtrip_finding(id, path, "error", "output is null but source has override data") | findings]

  defp maybe_check_override_entry(findings, _output, nil, id, path),
    do: [roundtrip_finding(id, path, "warning", "output has override data but no source") | findings]

  defp maybe_check_override_entry(findings, output_entry, source_entry, id, path) do
    if output_entry["parent_key"] == source_entry["parent_key"] do
      findings
    else
      [
        roundtrip_finding(
          id,
          path,
          "error",
          "parent_key mismatch: output=#{output_entry["parent_key"]} source=#{source_entry["parent_key"]}"
        )
        | findings
      ]
    end
  end

  # markets.patterns is derived from markets, not independently discovered.
  # Check presence consistency: if source has markets, patterns should
  # be emitted; if source lacks markets, patterns must be nil. Since
  # schema 3.0.0 (Task 117) output no longer carries the raw markets map, we
  # check against the source discovery data instead.
  defp check_symbol_patterns_roundtrip(findings, output, source, id) do
    source_markets = Map.get(source.load_markets, id) || resolve_parent_source(source, id, :load_markets)
    patterns = get_in(output, ["markets", "patterns"])

    findings
    |> check_symbol_patterns_presence(source_markets, patterns, id)
    |> check_symbol_patterns_shape(patterns, id)
  end

  defp check_symbol_patterns_presence(findings, nil, nil, _id), do: findings

  defp check_symbol_patterns_presence(findings, nil, _patterns, id),
    do: [
      roundtrip_finding(id, "markets.patterns", "error", "symbol_patterns present but source markets is null") | findings
    ]

  defp check_symbol_patterns_presence(findings, _markets, nil, id),
    do: [
      roundtrip_finding(id, "markets.patterns", "error", "source markets present but symbol_patterns is null") | findings
    ]

  defp check_symbol_patterns_presence(findings, _markets, _patterns, _id), do: findings

  defp check_symbol_patterns_shape(findings, patterns, _id) when not is_map(patterns), do: findings

  defp check_symbol_patterns_shape(findings, patterns, id) do
    if Map.has_key?(patterns, "currency_aliases") do
      findings
    else
      [roundtrip_finding(id, "markets.patterns", "error", "missing currency_aliases key") | findings]
    end
  end

  # Compare raw.url_templates — mirrors Pipeline.get_url_templates/2
  # Alias exchanges inherit parent url_templates via class hierarchy,
  # so output legitimately has data when source doesn't (same as unified_endpoints).
  defp check_url_templates_roundtrip(findings, output, source, id) do
    output_ut = get_in(output, ["raw", "url_templates"])
    source_entry = Map.get(source.url_templates, id)
    source_ut = build_source_url_templates(source_entry)

    case {output_ut, source_ut} do
      {nil, nil} ->
        findings

      # Inherited from parent — not a roundtrip concern
      {_output, nil} ->
        findings

      # Source has data but output lost it — flag as error
      {nil, _source} ->
        check_presence_match(findings, nil, source_ut, id, "raw.url_templates")

      # Both present — verify source data preserved in output
      _ ->
        check_data_equality(findings, output_ut, source_ut, id, "raw.url_templates")
    end
  end

  defp build_source_url_templates(nil), do: nil

  defp build_source_url_templates(entry) do
    case Map.get(entry, "url_templates", %{}) do
      templates when map_size(templates) > 0 -> templates
      _ -> nil
    end
  end

  # --- Shared Round-Trip Helpers ---

  # Compare two values for equality (skip if either is nil — presence check handles that)
  defp check_data_equality(findings, nil, _, _id, _path), do: findings
  defp check_data_equality(findings, _, nil, _id, _path), do: findings
  defp check_data_equality(findings, output, source, _id, _path) when output == source, do: findings

  defp check_data_equality(findings, _output, _source, id, path) do
    [roundtrip_finding(id, path, "error", "data mismatch between output and source") | findings]
  end

  # Check presence/absence match between output and source
  defp check_presence_match(findings, nil, nil, _id, _path), do: findings

  defp check_presence_match(findings, nil, _source, id, path),
    do: [roundtrip_finding(id, path, "error", "output is null but source has data") | findings]

  defp check_presence_match(findings, _output, nil, id, path),
    do: [roundtrip_finding(id, path, "warning", "output has data but no source") | findings]

  defp check_presence_match(findings, _output, _source, _id, _path), do: findings

  # Resolve parent's source data for alias exchanges that have no own discovery files.
  # Uses same parent lookup pattern as Pipeline.find_parent_exchange_id/2.
  defp resolve_parent_source(source, id, field) do
    case Map.get(source.classes, id) do
      nil ->
        nil

      entries ->
        rest = Enum.find(entries, &(&1["type"] == "rest"))
        parent_key = rest && rest["parent_key"]

        case parent_key do
          "rest:" <> parent_id -> Map.get(Map.get(source, field, %{}), parent_id)
          _ -> nil
        end
    end
  end

  # Compare method maps (name → MethodAST) — keys + full AST equality per method
  defp check_method_map(findings, output_map, source_map, id, path) do
    output_normalized = normalize_method_map(output_map)
    source_normalized = normalize_method_map(source_map)

    findings
    |> check_presence_match(output_normalized, source_normalized, id, path)
    |> maybe_check_method_map_content(output_normalized, source_normalized, id, path)
  end

  # Normalize nil and empty maps to nil for consistent presence checks
  defp normalize_method_map(nil), do: nil
  defp normalize_method_map(map) when is_map(map) and map_size(map) == 0, do: nil
  defp normalize_method_map(map) when is_map(map), do: map

  defp maybe_check_method_map_content(findings, nil, _, _id, _path), do: findings
  defp maybe_check_method_map_content(findings, _, nil, _id, _path), do: findings

  defp maybe_check_method_map_content(findings, output_map, source_map, id, path) do
    output_names = output_map |> Map.keys() |> MapSet.new()
    source_names = source_map |> Map.keys() |> MapSet.new()
    # Task 124: bybit/bybiteu intentionally drop discontinued spot/v3/private/*
    # interface methods from endpoints.interfaces (V3 Spot shutdown); do not
    # treat them as "missing" in roundtrip.
    source_names = exclude_bybit_dead_v3_spot_private(source_names, id, path)
    missing = MapSet.difference(source_names, output_names)

    findings
    |> maybe_add_finding(missing, id, path, "error", "missing methods from source")
    |> check_method_map_asts(output_map, source_map, id, path)
  end

  defp exclude_bybit_dead_v3_spot_private(names, id, "endpoints.interfaces") when id in ~w(bybit bybiteu) do
    MapSet.reject(names, &dead_spot_v3_private_interface_name?/1)
  end

  defp exclude_bybit_dead_v3_spot_private(names, _id, _path), do: names

  defp dead_spot_v3_private_interface_name?(name) when is_binary(name) do
    Regex.match?(~r/^private(Get|Post|Put|Delete|Patch)SpotV3Private/, name)
  end

  defp dead_spot_v3_private_interface_name?(_), do: false

  # Compare full MethodAST for each method present in both maps
  defp check_method_map_asts(findings, output_map, source_map, id, path) do
    Enum.reduce(source_map, findings, fn {name, source_ast}, acc ->
      output_ast = Map.get(output_map, name)
      check_data_equality(acc, output_ast, source_ast, id, "#{path}.#{name}")
    end)
  end

  defp roundtrip_finding(exchange_id, path, severity, message) do
    %{
      "exchange_id" => exchange_id,
      "layer" => "roundtrip",
      "severity" => severity,
      "path" => path,
      "message" => message
    }
  end

  # --- Source Data Loading ---

  # These loaders duplicate Pipeline's load_* pattern with weaker error handling (silently
  # returning %{} on error). Pipeline stats (missing_entries, corrupt_entries, orphan_entries,
  # id_mismatch_entries) are surfaced in the validation report, so integrity gaps are visible.
  # If a third consumer appears, extract shared loaders using Pipeline.read_json/1's robust
  # error-handling pattern.
  defp load_source_data(dir) do
    # We need to read the raw discovery files to compare against pipeline output.
    # The pipeline transforms data (renames, groups), so we read the raw sources.
    %{
      describe: load_describe_lookup(dir),
      load_markets: load_markets_lookup(dir),
      load_markets_failed: load_markets_failure_lookup(dir),
      classes: load_json_group_by(dir, "class_hierarchy.json", "classes", "class_name"),
      methods_rest: load_json_index_field(dir, "methods_rest.json", "methods"),
      methods_ws: load_json_index_field(dir, "methods_ws.json", "methods"),
      sign_methods: load_json_index_key(dir, "sign_methods.json", "sign"),
      handle_errors: load_json_index(dir, "handle_errors.json"),
      parse_methods: load_json_index(dir, "parse_methods.json"),
      ws_methods: load_json_index(dir, "ws_methods.json"),
      interface_signatures: load_json_index(dir, "interface_signatures.json"),
      pagination: load_json_index(dir, "pagination.json"),
      unified_endpoints: load_json_index(dir, "unified_endpoints.json"),
      overrides: load_json_group_by(dir, "overrides.json", "exchanges", "id"),
      url_templates: load_json_index(dir, "url_templates.json")
    }
  end

  # Load per-exchange describe files into %{id => describe_data}
  defp load_describe_lookup(dir) do
    manifest_path = Path.join(dir, "describe/_manifest.json")

    case JsonIO.read_json(manifest_path) do
      {:ok, %{"exchanges" => ids}} ->
        Map.new(ids, &read_describe_entry(dir, &1))

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt describe manifest: #{detail}"
    end
  end

  defp read_describe_entry(dir, id) do
    path = Path.join(dir, "describe/#{id}.json")

    case JsonIO.read_json(path) do
      {:ok, data} ->
        {id, data["describe"]}

      {:error, {:missing_input, _}} ->
        {id, nil}

      {:error, {:invalid_json, detail}} ->
        Logger.warning("Corrupt describe JSON for #{id}: #{detail}")
        {id, nil}
    end
  end

  # Load per-exchange markets files into %{id => markets_data}
  defp load_markets_lookup(dir) do
    manifest_path = Path.join(dir, "load_markets/_manifest.json")

    case JsonIO.read_json(manifest_path) do
      {:ok, %{"succeeded" => entries}} ->
        Map.new(entries, &read_markets_entry(dir, &1))

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt load_markets manifest: #{detail}"
    end
  end

  defp load_markets_failure_lookup(dir) do
    manifest_path = Path.join(dir, "load_markets/_manifest.json")

    case JsonIO.read_json(manifest_path) do
      {:ok, data} ->
        data
        |> Map.get("failed", [])
        |> Map.new(fn entry -> {entry["id"], entry["error"]} end)

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt load_markets manifest: #{detail}"
    end
  end

  defp read_markets_entry(dir, entry) do
    id = if is_map(entry), do: entry["id"], else: entry
    path = Path.join(dir, "load_markets/#{id}.json")

    case JsonIO.read_json(path) do
      {:ok, parsed} ->
        # currencies added in Task 97; keep the loader shape in sync with DiscoveryLoader
        currencies = Map.get(parsed, "currencies")
        {id, %{"market_count" => parsed["market_count"], "markets" => parsed["markets"], "currencies" => currencies}}

      {:error, {:missing_input, _}} ->
        {id, nil}

      {:error, {:invalid_json, detail}} ->
        Logger.warning("Corrupt load_markets JSON for #{id}: #{detail}")
        {id, nil}
    end
  end

  # Load global file, index exchanges by id
  defp load_json_index(dir, filename) do
    path = Path.join(dir, filename)

    case JsonIO.read_json(path) do
      {:ok, data} ->
        Map.new(data["exchanges"], fn entry -> {entry["id"], entry} end)

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery file #{filename}: #{detail}"
    end
  end

  # Load global file, index exchanges by id, extract a specific field as value
  defp load_json_index_field(dir, filename, field) do
    path = Path.join(dir, filename)

    case JsonIO.read_json(path) do
      {:ok, data} ->
        Map.new(data["exchanges"], fn entry -> {entry["id"], entry[field]} end)

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery file #{filename}: #{detail}"
    end
  end

  # Load global file, index exchanges by id, extract a specific key as value
  defp load_json_index_key(dir, filename, key) do
    path = Path.join(dir, filename)

    case JsonIO.read_json(path) do
      {:ok, data} ->
        Map.new(data["exchanges"], fn entry -> {entry["id"], entry[key]} end)

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery file #{filename}: #{detail}"
    end
  end

  # Load global file, group entries by a field
  defp load_json_group_by(dir, filename, list_key, group_field) do
    path = Path.join(dir, filename)

    case JsonIO.read_json(path) do
      {:ok, data} ->
        Enum.group_by(data[list_key], & &1[group_field])

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise "Corrupt discovery file #{filename}: #{detail}"
    end
  end

  # --- Report Building ---

  defp build_report(exchange_results, ref_exchanges, file_stats, tier_scope, roundtrip_skipped_reason) do
    all_findings =
      Enum.flat_map(exchange_results, fn r ->
        schema_findings =
          Enum.map(r["schema_errors"], fn f ->
            Map.merge(f, %{"exchange_id" => r["id"], "layer" => "json_schema", "severity" => "error"})
          end)

        schema_findings ++ r["roundtrip_findings"]
      end)

    schema_pass = Enum.count(exchange_results, & &1["schema_valid"])
    schema_fail = Enum.count(exchange_results, &(!&1["schema_valid"]))

    # Round-trip is skipped under :schema_only.
    # `roundtrip_skipped_reason` is the load-bearing flag — when present,
    # nothing ran and the counts collapse to 0.
    roundtrip_checked =
      if is_nil(roundtrip_skipped_reason),
        do: Enum.count(exchange_results, fn r -> r["id"] in ref_exchanges end),
        else: 0

    roundtrip_with_findings =
      exchange_results
      |> Enum.filter(fn r -> r["id"] in ref_exchanges end)
      |> Enum.count(fn r -> r["roundtrip_findings"] != [] end)

    by_severity = Enum.group_by(all_findings, & &1["severity"])

    %{
      "validated_at" => CcxtExtract.Clock.timestamp(:validated_at),
      "exchange_count" => length(exchange_results),
      "schema_version" => Schema.schema_version(),
      "tier_scope" => tier_scope,
      "roundtrip_skipped_reason" => roundtrip_skipped_reason,
      "summary" => %{
        "schema_pass" => schema_pass,
        "schema_fail" => schema_fail,
        "roundtrip_checked" => roundtrip_checked,
        "roundtrip_clean" => roundtrip_checked - roundtrip_with_findings,
        "roundtrip_with_findings" => roundtrip_with_findings,
        "total_errors" => length(Map.get(by_severity, "error", [])),
        "total_warnings" => length(Map.get(by_severity, "warning", [])),
        "total_info" => length(Map.get(by_severity, "info", []))
      },
      "pipeline_stats" => file_stats,
      "exchanges" => exchange_results,
      "findings_by_severity" => %{
        "error" => Map.get(by_severity, "error", []),
        "warning" => Map.get(by_severity, "warning", []),
        "info" => Map.get(by_severity, "info", [])
      }
    }
  end
end
