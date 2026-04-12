# Compare ccxt_extract JSON output against old ccxt_client .exs specs
#
# Validates that the new extraction covers everything the old specs contained,
# minus consumer-specific keys that ccxt_ex computed.
#
# Usage: mix run examples/compare_old_specs.exs

new_dir = "priv/output"
old_dir = "clients/elixir/ccxt_client/priv/specs/extracted"

if !File.dir?(old_dir) do
  IO.puts("ERROR: Old specs directory not found: #{old_dir}")
  IO.puts("Expected ccxt_client at clients/elixir/ccxt_client/ (see clients/README.md).")
  System.halt(1)
end

# --- Key Classification ---
#
# Each covered key maps to {path_in_new_json, spot_check_type}
# Path is a list of string keys into the decoded JSON.

covered_keys = %{
  id: {["exchange", "id"], :exact},
  name: {["exchange", "name"], :exact},
  certified: {["exchange", "certified"], :exact},
  pro: {["exchange", "pro"], :exact},
  countries: {["exchange", "country"], :exact},
  dex: {["runtime", "describe", "dex"], :exact},
  version: {["exchange", "version"], :exact},
  currencies: {["runtime", "describe", "currencies"], :keys_subset},
  currency_aliases: {["runtime", "describe", "commonCurrencies"], :keys_subset},
  enable_rate_limit: {["runtime", "describe", "enableRateLimit"], :exact},
  exceptions: {["runtime", "describe", "exceptions"], :keys_subset},
  features: {["runtime", "describe", "features"], :keys_subset},
  fees: {["runtime", "describe", "fees"], :present},
  has: {["runtime", "describe", "has"], :keys_subset},
  markets: {["runtime", "markets"], :keys_subset},
  options: {["runtime", "describe", "options"], :present},
  required_credentials: {["runtime", "describe", "requiredCredentials"], :keys_subset},
  status: {["runtime", "describe", "status"], :present},
  timeframes: {["runtime", "describe", "timeframes"], :keys_subset},
  urls: {["runtime", "describe", "urls"], :keys_subset},
  rate_limits: {["runtime", "describe", "rateLimit"], :present},
  error_codes: {["runtime", "describe", "exceptions"], :present},
  error_code_details: {["runtime", "describe", "exceptions"], :present}
}

richer_keys = %{
  signing: {["structure", "sign_method"], "AST-level detail vs summary"},
  parse_methods: {["structure", "parse_methods"], "AST bodies vs names"},
  handle_errors_source: {["structure", "handle_errors"], "Full AST vs source string"},
  ws: {["structure", "ws_methods"], "Full method details"},
  overrides: {["structure", "overrides"], "AST-level per REST/WS"},
  raw_endpoints: {["runtime", "describe", "api"], "Full API tree vs intercepted list"},
  endpoints: {["runtime", "describe", "api"], "Full API tree vs intercepted list"}
}

consumer_specific_keys =
  MapSet.new([
    :classification,
    :comment,
    :api_param_requirements,
    :endpoint_extraction_stats,
    :order_mappings,
    :param_mappings,
    :ohlcv_timestamp_resolution,
    :spec_format_version,
    :extracted_metadata,
    :extended_metadata,
    :exchange_options,
    :forward_aliases,
    :handle_content_type_application_zip,
    :http_config,
    :path_prefix,
    :quote_json_numbers,
    :requires_eddsa,
    :response_error,
    :symbol_format,
    :symbol_formats,
    :symbol_patterns,
    :url_strategy
  ])

all_known_keys =
  MapSet.new(Map.keys(covered_keys) ++ Map.keys(richer_keys) ++ MapSet.to_list(consumer_specific_keys))

# --- Spot-Check Helpers ---

# Convert camelCase to snake_case for key comparison.
# Handles acronyms: "fetchOHLCV" → "fetch_ohlcv", "CORS" → "cors",
# "fetchL2OrderBook" → "fetch_l2_order_book", "fetchADLRank" → "fetch_adl_rank"
to_snake = fn str ->
  str
  |> to_string()
  # Insert underscore between a run of uppercase and an uppercase followed by lowercase: "OHLCVWs" → "OHLCV_Ws"
  |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
  # Insert underscore between lowercase/digit and uppercase: "fetchOrder" → "fetch_Order"
  |> String.replace(~r/([a-z\d])([A-Z])/, "\\1_\\2")
  |> String.downcase()
end

# Normalize map keys to snake_case strings for cross-format comparison
normalize_keys = fn
  map when is_map(map) ->
    map |> Map.keys() |> MapSet.new(&to_snake.(&1))

  _ ->
    MapSet.new()
end

# Fuzzy key normalization: strip all underscores and downcase for comparing
# keys that differ only in underscore placement (e.g. "c_o_r_s" vs "cors",
# "fetch_a_d_l_rank" vs "fetch_adl_rank")
fuzzy_normalize = fn key ->
  key |> to_string() |> String.downcase() |> String.replace("_", "")
end

# Dig into nested JSON by path
get_in_json = fn json, path ->
  Enum.reduce_while(path, json, fn key, acc ->
    case acc do
      %{} = m -> {:cont, Map.get(m, key)}
      _ -> {:halt, nil}
    end
  end)
end

spot_check = fn old_val, new_val, check_type ->
  case check_type do
    :exact ->
      if old_val == new_val, do: :pass, else: {:fail, "expected #{inspect(old_val)}, got #{inspect(new_val)}"}

    :keys_subset ->
      cond do
        is_nil(old_val) or old_val == %{} ->
          :pass

        not is_map(old_val) or not is_map(new_val) ->
          :pass

        true ->
          old_keys = normalize_keys.(old_val)
          new_keys = normalize_keys.(new_val)
          missing = MapSet.difference(old_keys, new_keys)

          # Fuzzy fallback: keys differing only in underscore placement
          # (e.g. old "c_o_r_s" vs new "cors") are not truly missing
          new_fuzzy = MapSet.new(new_keys, &fuzzy_normalize.(&1))

          truly_missing =
            Enum.reject(missing, fn k -> MapSet.member?(new_fuzzy, fuzzy_normalize.(k)) end)

          case truly_missing do
            [] ->
              :pass

            _ ->
              sample = truly_missing |> Enum.take(5) |> Enum.join(", ")
              {:fail, "#{Enum.count(truly_missing)} old keys not in new (e.g. #{sample})"}
          end
      end

    :present ->
      if new_val == nil, do: {:fail, "not present in new output"}, else: :pass
  end
end

# --- Discover overlapping exchanges ---

new_ids =
  new_dir
  |> Path.join("*.json")
  |> Path.wildcard()
  |> Enum.map(&Path.basename(&1, ".json"))
  |> Enum.reject(&String.starts_with?(&1, "_"))
  |> MapSet.new()

old_ids =
  old_dir
  |> Path.join("*.exs")
  |> Path.wildcard()
  |> MapSet.new(&Path.basename(&1, ".exs"))

overlap = new_ids |> MapSet.intersection(old_ids) |> MapSet.to_list() |> Enum.sort()

IO.puts("Exchanges in new output: #{MapSet.size(new_ids)}")
IO.puts("Exchanges in old specs:  #{MapSet.size(old_ids)}")
IO.puts("Overlapping:             #{length(overlap)}")
IO.puts("")

# --- Compare each exchange ---

results =
  Enum.map(overlap, fn id ->
    # Load new JSON
    new_path = Path.join(new_dir, "#{id}.json")
    new_json = new_path |> File.read!() |> Jason.decode!()

    # Load old spec — Code.eval_file returns {value, bindings}
    old_path = Path.join(old_dir, "#{id}.exs")

    old_spec =
      try do
        {spec, _bindings} = Code.eval_file(old_path)
        spec
      rescue
        e ->
          IO.puts("  WARNING: Failed to load #{old_path}: #{inspect(e)}")
          %{}
      end

    old_keys_present = old_spec |> Map.keys() |> MapSet.new()

    # Classify each old key
    {covered_results, richer_list, consumer_list, unknown_list, missing_list} =
      Enum.reduce(old_keys_present, {[], [], [], [], []}, fn key, {cov, rich, cons, unk, miss} ->
        cond do
          Map.has_key?(covered_keys, key) ->
            {path, check_type} = Map.fetch!(covered_keys, key)
            old_val = Map.get(old_spec, key)
            new_val = get_in_json.(new_json, path)
            result = spot_check.(old_val, new_val, check_type)
            {[{key, result} | cov], rich, cons, unk, miss}

          Map.has_key?(richer_keys, key) ->
            {path, _reason} = Map.fetch!(richer_keys, key)
            new_val = get_in_json.(new_json, path)
            present? = new_val != nil
            {cov, [{key, present?} | rich], cons, unk, miss}

          MapSet.member?(consumer_specific_keys, key) ->
            {cov, rich, [key | cons], unk, miss}

          MapSet.member?(all_known_keys, key) ->
            # Key is known but not present in this exchange — skip
            {cov, rich, cons, unk, miss}

          true ->
            {cov, rich, cons, [key | unk], miss}
        end
      end)

    # Check for covered/richer keys that should be present but aren't in old spec
    # (not needed — we only classify keys the old spec actually has)

    # Count spot-check results
    passed = Enum.count(covered_results, fn {_, r} -> r == :pass end)
    failed = Enum.filter(covered_results, fn {_, r} -> r != :pass end)

    %{
      id: id,
      covered: length(covered_results),
      passed: passed,
      failed: failed,
      richer: length(richer_list),
      richer_missing: Enum.filter(richer_list, fn {_, present?} -> not present? end),
      consumer_specific: length(consumer_list),
      unknown: unknown_list,
      missing: missing_list,
      total_old_keys: MapSet.size(old_keys_present)
    }
  end)

# --- Per-Exchange Output ---

IO.puts("=== Per-Exchange Results ===\n")

Enum.each(results, fn r ->
  has_issues? =
    r.failed != [] or r.unknown != [] or r.missing != [] or r.richer_missing != []

  if has_issues? do
    IO.puts("#{r.id}:")
    failed_count = Enum.count(r.failed)
    IO.puts("  Covered: #{r.covered} keys (#{r.passed} passed, #{failed_count} failed)")
    IO.puts("  Richer:  #{r.richer} keys")
    IO.puts("  Consumer-specific: #{r.consumer_specific} keys (excluded)")
    IO.puts("  Unknown: #{Enum.count(r.unknown)} keys")

    if r.failed != [] do
      Enum.each(r.failed, fn {key, {:fail, reason}} ->
        IO.puts("    FAIL #{key}: #{reason}")
      end)
    end

    if r.unknown != [] do
      IO.puts("    Unknown keys: #{Enum.map_join(r.unknown, ", ", &inspect/1)}")
    end

    if r.richer_missing != [] do
      names = Enum.map_join(r.richer_missing, ", ", fn {k, _} -> inspect(k) end)
      IO.puts("    Richer but missing in new: #{names}")
    end

    IO.puts("")
  end
end)

# Count clean exchanges
clean_count =
  Enum.count(results, fn r ->
    r.failed == [] and r.unknown == [] and r.missing == [] and r.richer_missing == []
  end)

IO.puts("(#{clean_count} exchanges with no issues omitted)\n")

# --- Cross-Exchange Summary ---

IO.puts("=== Summary ===\n")
IO.puts("Exchanges compared: #{length(overlap)}")

# Unknown keys across multiple exchanges
unknown_counts =
  results
  |> Enum.flat_map(fn r -> r.unknown end)
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_, count} -> -count end)

# Failed spot-checks across exchanges
fail_counts =
  results
  |> Enum.flat_map(fn r -> Enum.map(r.failed, fn {k, _} -> k end) end)
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_, count} -> -count end)

# Richer-but-missing across exchanges
richer_missing_counts =
  results
  |> Enum.flat_map(fn r -> Enum.map(r.richer_missing, fn {k, _} -> k end) end)
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_, count} -> -count end)

# Overall coverage per exchange (average)
coverages =
  Enum.map(results, fn r ->
    non_consumer = r.covered + r.richer + Enum.count(r.unknown) + Enum.count(r.missing)
    covered_or_richer = r.covered + r.richer

    if non_consumer > 0,
      do: covered_or_richer / non_consumer * 100,
      else: 100.0
  end)

avg_coverage = if coverages == [], do: 0, else: Enum.sum(coverages) / Enum.count(coverages)
min_coverage = Enum.min(coverages, fn -> 0 end)

IO.puts("Average coverage: #{:erlang.float_to_binary(avg_coverage, decimals: 1)}%")
IO.puts("Minimum coverage: #{:erlang.float_to_binary(min_coverage, decimals: 1)}%")
IO.puts("  (covered + richer keys as % of non-consumer keys)")
IO.puts("")

if unknown_counts != [] do
  IO.puts("Unknown keys (not in any category):")

  Enum.each(unknown_counts, fn {key, count} ->
    IO.puts("  #{inspect(key)}: seen in #{count} exchanges")
  end)

  IO.puts("")
end

if fail_counts != [] do
  IO.puts("Spot-check failures across exchanges:")

  Enum.each(fail_counts, fn {key, count} ->
    IO.puts("  #{inspect(key)}: failed in #{count} exchanges")
  end)

  IO.puts("")
end

if richer_missing_counts != [] do
  IO.puts("Richer keys missing from new output:")

  Enum.each(richer_missing_counts, fn {key, count} ->
    IO.puts("  #{inspect(key)}: missing in #{count} exchanges")
  end)

  IO.puts("")
end

IO.puts("Done.")
