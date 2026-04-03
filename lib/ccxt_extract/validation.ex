defmodule CcxtExtract.Validation do
  @moduledoc """
  Full validation of per-exchange JSON output.

  Two validation layers:

  - **JSON Schema** — validate output against `exchange_v1.json` (draft 2020-12)
    using JSV. Catches type errors, extra properties, missing required fields.
  - **Round-trip** — compare pipeline output sections against source discovery
    data. Catches data loss or incorrect transformation in the pipeline.

  Findings have severity levels:

  - **error** — schema violation or data loss
  - **warning** — non-critical mismatch (e.g., expected null section)
  - **info** — informational note

  ## Usage

      {:ok, report} = CcxtExtract.Validation.validate_all(discoveries_dir: "test/fixtures/discoveries")
      CcxtExtract.Validation.write!(report)
  """

  alias CcxtExtract.Paths
  alias CcxtExtract.Pipeline

  require Logger

  @schema_path "schema/exchange_v1.json"
  @output_file "output/_validation_report.json"

  @reference_exchanges ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid)

  # --- Public API ---

  @doc """
  Run full validation: JSON Schema + round-trip comparison.

  Options:
    * `:discoveries_dir` — override fixture directory
    * `:ccxt_version` — override version string
    * `:extracted_at` — override timestamp
    * `:schema_only` — skip round-trip comparison (default: false)
    * `:reference_exchanges` — override which exchanges get round-trip checks
  """
  @spec validate_all(keyword()) :: {:ok, map()}
  def validate_all(opts \\ []) do
    schema_only = Keyword.get(opts, :schema_only, false)
    ref_exchanges = Keyword.get(opts, :reference_exchanges, @reference_exchanges)

    # Run pipeline to get assembled exchange data
    pipeline_opts =
      opts
      |> Keyword.take([:discoveries_dir, :ccxt_version, :extracted_at])
      |> Keyword.put_new(:ccxt_version, "unknown")
      |> Keyword.put_new(:extracted_at, DateTime.to_iso8601(DateTime.utc_now()))

    {:ok, exchanges, pipeline_stats} = Pipeline.extract(pipeline_opts)

    # Build JSON Schema root once
    root = build_schema_root()

    # Load source data for round-trip (reuse pipeline's loader)
    source_data =
      if schema_only do
        nil
      else
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
          if !schema_only && id in ref_exchanges && source_data do
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

    report = build_report(exchange_results, ref_exchanges, schema_only, pipeline_stats)
    {:ok, report}
  end

  @doc """
  Validate a single exchange map against `exchange_v1.json` using JSV.

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
    |> check_markets_roundtrip(output, source_data, exchange_id)
    |> check_class_info_roundtrip(output, source_data, exchange_id)
    |> check_methods_roundtrip(output, source_data, exchange_id)
    |> check_sign_method_roundtrip(output, source_data, exchange_id)
    |> check_handle_errors_roundtrip(output, source_data, exchange_id)
    |> check_parse_methods_roundtrip(output, source_data, exchange_id)
    |> check_ws_methods_roundtrip(output, source_data, exchange_id)
    |> check_interface_signatures_roundtrip(output, source_data, exchange_id)
    |> check_overrides_roundtrip(output, source_data, exchange_id)
    |> Enum.reverse()
  end

  @doc """
  Build the compiled JSON Schema root from `exchange_v1.json`.

  Exposed for reuse — callers validating many exchanges should build once.
  """
  @spec build_schema_root() :: JSV.Root.t()
  def build_schema_root do
    schema_path = Paths.priv(@schema_path)
    raw_schema = schema_path |> File.read!() |> Jason.decode!()
    JSV.build!(raw_schema)
  end

  @doc "Write validation report as JSON."
  @spec write!(map(), String.t()) :: :ok
  def write!(report, output_path \\ Paths.priv(@output_file)) do
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode!(report, pretty: true))
    :ok
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

  # Compare runtime.describe against source describe fixture
  defp check_describe_roundtrip(findings, output, source, id) do
    output_describe = get_in(output, ["runtime", "describe"])
    source_describe = Map.get(source.describe, id)

    findings
    |> check_presence_match(output_describe, source_describe, id, "runtime.describe")
    |> maybe_check_describe_keys(output_describe, source_describe, id)
  end

  defp maybe_check_describe_keys(findings, output, source, _id) when is_nil(output) or is_nil(source), do: findings

  defp maybe_check_describe_keys(findings, output_describe, source_describe, id) do
    output_keys = output_describe |> Map.keys() |> MapSet.new()
    source_keys = source_describe |> Map.keys() |> MapSet.new()

    findings
    |> check_key_diff(source_keys, output_keys, id, "runtime.describe", "error", "missing keys from source")
    |> check_key_diff(output_keys, source_keys, id, "runtime.describe", "warning", "extra keys not in source")
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

  # Compare runtime.markets — count, symbol set, and full market data
  defp check_markets_roundtrip(findings, output, source, id) do
    output_markets = get_in(output, ["runtime", "markets"])
    source_markets = Map.get(source.load_markets, id)
    source_failure = Map.get(source.load_markets_failed, id)

    case classify_markets_state(output_markets, source_markets, source_failure) do
      :both_absent ->
        findings

      :source_failed_upstream ->
        [
          roundtrip_finding(id, "runtime.markets", "info", "source load_markets failed upstream; round-trip skipped")
          | findings
        ]

      :output_missing ->
        [roundtrip_finding(id, "runtime.markets", "error", "output is null but source has data") | findings]

      :source_failure_mismatch ->
        [
          roundtrip_finding(
            id,
            "runtime.markets",
            "error",
            "output has data but source load_markets manifest recorded failure"
          )
          | findings
        ]

      :source_missing ->
        [roundtrip_finding(id, "runtime.markets", "warning", "output has data but no source artifact") | findings]

      :compare ->
        findings
        |> check_market_count(output_markets, source_markets, id)
        |> check_market_symbols(output_markets, source_markets, id)
        |> check_market_data(output_markets, source_markets, id)
    end
  end

  # Classify the nil/present state of markets data via tuple matching
  defp classify_markets_state(nil, nil, nil), do: :both_absent
  defp classify_markets_state(nil, nil, _failure), do: :source_failed_upstream
  defp classify_markets_state(nil, _source, _failure), do: :output_missing
  defp classify_markets_state(_output, _source, failure) when not is_nil(failure), do: :source_failure_mismatch
  defp classify_markets_state(_output, nil, _failure), do: :source_missing
  defp classify_markets_state(_output, _source, _failure), do: :compare

  defp check_market_count(findings, output_markets, source_markets, id) do
    output_count = output_markets["market_count"]
    source_count = source_markets["market_count"]

    if output_count == source_count do
      findings
    else
      [
        roundtrip_finding(
          id,
          "runtime.markets",
          "error",
          "market_count mismatch: output=#{output_count} source=#{source_count}"
        )
        | findings
      ]
    end
  end

  defp check_market_symbols(findings, output_markets, source_markets, id) do
    output_syms = market_keys(output_markets["markets"])
    source_syms = market_keys(source_markets["markets"])

    missing = MapSet.difference(source_syms, output_syms)
    extra = MapSet.difference(output_syms, source_syms)

    findings
    |> maybe_add_finding(missing, id, "runtime.markets", "error", "missing symbols from source")
    |> maybe_add_finding(extra, id, "runtime.markets", "warning", "extra symbols not in source")
  end

  defp check_market_data(findings, output_markets, source_markets, id) do
    output_map = output_markets["markets"] || %{}
    source_map = source_markets["markets"] || %{}

    if output_map == source_map do
      findings
    else
      # Count how many individual markets differ
      diff_count =
        Enum.count(source_map, fn {sym, src_market} -> Map.get(output_map, sym) != src_market end)

      [
        roundtrip_finding(
          id,
          "runtime.markets",
          "error",
          "market data mismatch: #{diff_count} market(s) differ between output and source"
        )
        | findings
      ]
    end
  end

  defp market_keys(nil), do: MapSet.new()
  defp market_keys(map) when is_map(map), do: map |> Map.keys() |> MapSet.new()

  defp maybe_add_finding(findings, set, id, path, severity, label) do
    if MapSet.size(set) > 0 do
      [roundtrip_finding(id, path, severity, "#{label}: #{MapSet.size(set)}") | findings]
    else
      findings
    end
  end

  # Compare structure.class_info
  defp check_class_info_roundtrip(findings, output, source, id) do
    output_info = get_in(output, ["structure", "class_info"])
    source_entries = Map.get(source.classes, id)

    cond do
      is_nil(output_info) && is_nil(source_entries) ->
        findings

      is_nil(output_info) && !is_nil(source_entries) ->
        [roundtrip_finding(id, "structure.class_info", "error", "output is null but source has class data") | findings]

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
        roundtrip_finding(id, "structure.class_info.#{type}", "error", "output is null but source has #{type} class data")
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
            "structure.class_info.#{type}",
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

  # Compare structure.methods (method name sets — REST and WS)
  defp check_methods_roundtrip(findings, output, source, id) do
    output_methods = get_in(output, ["structure", "methods"])
    source_rest = Map.get(source.methods_rest, id)
    source_ws = Map.get(source.methods_ws, id)

    cond do
      is_nil(output_methods) && is_nil(source_rest) && is_nil(source_ws) ->
        findings

      is_nil(output_methods) && (!is_nil(source_rest) || !is_nil(source_ws)) ->
        [roundtrip_finding(id, "structure.methods", "error", "output is null but source has method data") | findings]

      true ->
        findings
        |> check_method_name_set(output_methods["rest"], source_rest, id, "structure.methods.rest")
        |> check_method_name_set(output_methods["ws"], source_ws, id, "structure.methods.ws")
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

  # Compare structure.sign_method — presence + full MethodAST equality
  defp check_sign_method_roundtrip(findings, output, source, id) do
    output_sign = get_in(output, ["structure", "sign_method"])
    source_sign = Map.get(source.sign_methods, id)

    findings
    |> check_presence_match(output_sign, source_sign, id, "structure.sign_method")
    |> check_data_equality(output_sign, source_sign, id, "structure.sign_method")
  end

  # Compare structure.handle_errors — presence + method AST, exceptions, http_exceptions
  defp check_handle_errors_roundtrip(findings, output, source, id) do
    output_he = get_in(output, ["structure", "handle_errors"])
    source_entry = Map.get(source.handle_errors, id)
    source_method = source_has_handle_errors?(source_entry)

    findings
    |> check_presence_match(output_he, source_method, id, "structure.handle_errors")
    |> check_handle_errors_content(output_he, source_entry, id)
  end

  defp source_has_handle_errors?(%{"handle_errors" => m}) when is_map(m), do: m
  defp source_has_handle_errors?(_), do: nil

  defp check_handle_errors_content(findings, nil, _, _id), do: findings
  defp check_handle_errors_content(findings, _, nil, _id), do: findings

  defp check_handle_errors_content(findings, output_he, source_entry, id) do
    source_method = source_entry["handle_errors"]

    findings
    |> check_data_equality(output_he["method"], source_method, id, "structure.handle_errors.method")
    |> check_data_equality(output_he["exceptions"], source_entry["exceptions"], id, "structure.handle_errors.exceptions")
    |> check_data_equality(
      output_he["http_exceptions"],
      source_entry["http_exceptions"],
      id,
      "structure.handle_errors.http_exceptions"
    )
  end

  # Compare structure.parse_methods (method name set)
  defp check_parse_methods_roundtrip(findings, output, source, id) do
    output_pm = get_in(output, ["structure", "parse_methods"])

    source_entry = Map.get(source.parse_methods, id)
    source_pm = source_entry && source_entry["parse_methods"]

    check_method_map(findings, output_pm, source_pm, id, "structure.parse_methods")
  end

  # Compare structure.ws_methods (method name set)
  defp check_ws_methods_roundtrip(findings, output, source, id) do
    output_wm = get_in(output, ["structure", "ws_methods"])

    source_entry = Map.get(source.ws_methods, id)
    source_wm = source_entry && source_entry["ws_methods"]

    check_method_map(findings, output_wm, source_wm, id, "structure.ws_methods")
  end

  # Compare structure.interface_signatures (signature name → signature map)
  defp check_interface_signatures_roundtrip(findings, output, source, id) do
    output_is = get_in(output, ["structure", "interface_signatures"])
    source_entry = Map.get(source.interface_signatures, id)
    source_is = source_entry && source_entry["interface_signatures"]
    check_method_map(findings, output_is, source_is, id, "structure.interface_signatures")
  end

  # Compare structure.overrides (REST and WS sides)
  defp check_overrides_roundtrip(findings, output, source, id) do
    output_ov = get_in(output, ["structure", "overrides"])
    source_entries = Map.get(source.overrides, id)

    source_rest = overrides_entry_by_type(source_entries, "rest:")
    source_ws = overrides_entry_by_type(source_entries, "ws:")
    # Any source entry means overrides exist
    source_any = source_rest || source_ws

    # Use whichever source side exists for the extends check (REST preferred, WS fallback)
    source_primary = source_rest || source_ws

    findings
    |> check_presence_match(output_ov, source_any, id, "structure.overrides")
    |> maybe_check_overrides_extends(output_ov, source_primary, id)
    |> maybe_check_override_entry(output_ov && output_ov["rest"], source_rest, id, "structure.overrides.rest")
    |> maybe_check_override_entry(output_ov && output_ov["ws"], source_ws, id, "structure.overrides.ws")
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
          "structure.overrides",
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
    missing = MapSet.difference(source_names, output_names)

    findings
    |> maybe_add_finding(missing, id, path, "error", "missing methods from source")
    |> check_method_map_asts(output_map, source_map, id, path)
  end

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
      overrides: load_json_group_by(dir, "overrides.json", "exchanges", "id")
    }
  end

  # Load per-exchange describe files into %{id => describe_data}
  defp load_describe_lookup(dir) do
    manifest_path = Path.join(dir, "describe/_manifest.json")

    case File.read(manifest_path) do
      {:ok, content} ->
        %{"exchanges" => ids} = Jason.decode!(content)
        Map.new(ids, &read_describe_entry(dir, &1))

      {:error, _} ->
        %{}
    end
  end

  defp read_describe_entry(dir, id) do
    path = Path.join(dir, "describe/#{id}.json")

    case File.read(path) do
      {:ok, data} ->
        {id, Jason.decode!(data)["describe"]}

      {:error, _} ->
        {id, nil}
    end
  rescue
    e in Jason.DecodeError ->
      Logger.warning("Corrupt describe JSON for #{id}: #{Exception.message(e)}")
      {id, nil}
  end

  # Load per-exchange markets files into %{id => markets_data}
  defp load_markets_lookup(dir) do
    manifest_path = Path.join(dir, "load_markets/_manifest.json")

    case File.read(manifest_path) do
      {:ok, content} ->
        %{"succeeded" => entries} = Jason.decode!(content)
        Map.new(entries, &read_markets_entry(dir, &1))

      {:error, _} ->
        %{}
    end
  end

  defp load_markets_failure_lookup(dir) do
    manifest_path = Path.join(dir, "load_markets/_manifest.json")

    case File.read(manifest_path) do
      {:ok, content} ->
        content
        |> Jason.decode!()
        |> Map.get("failed", [])
        |> Map.new(fn entry -> {entry["id"], entry["error"]} end)

      {:error, _} ->
        %{}
    end
  end

  defp read_markets_entry(dir, entry) do
    id = if is_map(entry), do: entry["id"], else: entry

    try do
      path = Path.join(dir, "load_markets/#{id}.json")

      case File.read(path) do
        {:ok, data} ->
          parsed = Jason.decode!(data)
          {id, %{"market_count" => parsed["market_count"], "markets" => parsed["markets"]}}

        {:error, _} ->
          {id, nil}
      end
    rescue
      e in Jason.DecodeError ->
        Logger.warning("Corrupt load_markets JSON for #{id}: #{Exception.message(e)}")
        {id, nil}
    end
  end

  # Load global file, index exchanges by id
  defp load_json_index(dir, filename) do
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} ->
        data = Jason.decode!(content)
        Map.new(data["exchanges"], fn entry -> {entry["id"], entry} end)

      {:error, _} ->
        %{}
    end
  end

  # Load global file, index exchanges by id, extract a specific field as value
  defp load_json_index_field(dir, filename, field) do
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} ->
        data = Jason.decode!(content)
        Map.new(data["exchanges"], fn entry -> {entry["id"], entry[field]} end)

      {:error, _} ->
        %{}
    end
  end

  # Load global file, index exchanges by id, extract a specific key as value
  defp load_json_index_key(dir, filename, key) do
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} ->
        data = Jason.decode!(content)
        Map.new(data["exchanges"], fn entry -> {entry["id"], entry[key]} end)

      {:error, _} ->
        %{}
    end
  end

  # Load global file, group entries by a field
  defp load_json_group_by(dir, filename, list_key, group_field) do
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} ->
        data = Jason.decode!(content)
        Enum.group_by(data[list_key], & &1[group_field])

      {:error, _} ->
        %{}
    end
  end

  # --- Report Building ---

  defp build_report(exchange_results, ref_exchanges, schema_only, pipeline_stats) do
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

    roundtrip_checked =
      if schema_only,
        do: 0,
        else: Enum.count(exchange_results, fn r -> r["id"] in ref_exchanges end)

    roundtrip_with_findings =
      exchange_results
      |> Enum.filter(fn r -> r["id"] in ref_exchanges end)
      |> Enum.count(fn r -> r["roundtrip_findings"] != [] end)

    by_severity = Enum.group_by(all_findings, & &1["severity"])

    %{
      "validated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "exchange_count" => length(exchange_results),
      "schema_version" => "1.0.0",
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
      "pipeline_stats" => %{
        "missing_entries" => pipeline_stats.missing_entries,
        "corrupt_entries" => pipeline_stats.corrupt_entries,
        "orphan_entries" => pipeline_stats.orphan_entries,
        "id_mismatch_entries" => pipeline_stats.id_mismatch_entries,
        "validation_errors" => pipeline_stats.validation_errors
      },
      "exchanges" => exchange_results,
      "findings_by_severity" => %{
        "error" => Map.get(by_severity, "error", []),
        "warning" => Map.get(by_severity, "warning", []),
        "info" => Map.get(by_severity, "info", [])
      }
    }
  end
end
