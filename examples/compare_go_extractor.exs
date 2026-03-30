# Compare ccxt_extract (TS/JS) vs ccxt_go_extractor (Go AST) output
#
# Quantifies what each extractor provides and where they overlap.
# Runs the Go extractor's `profile` command live for each exchange.
#
# Usage: mix run examples/compare_go_extractor.exs

go_binary = Path.expand("../ccxt_go_extractor/ccxt-extract")
new_dir = "priv/output"

if !File.exists?(go_binary) do
  IO.puts("ERROR: Go extractor binary not found: #{go_binary}")
  IO.puts("Build it: cd ../ccxt_go_extractor && go build -o ccxt-extract ./cmd/ccxt-extract")
  System.halt(1)
end

# --- Helpers ---

count_map = fn val -> if is_map(val), do: map_size(val), else: 0 end

# Count leaf paths in CCXT API tree
count_api_endpoints = fn api when is_map(api) ->
  Enum.reduce(api, 0, fn {_section, methods}, acc ->
    case methods do
      m when is_map(m) ->
        acc +
          Enum.reduce(m, 0, fn {_method, paths}, inner ->
            case paths do
              p when is_map(p) -> inner + map_size(p)
              p when is_number(p) -> inner + 1
              _ -> inner
            end
          end)

      _ ->
        acc
    end
  end)
end

# Sum list lengths across assembly sub-keys
count_assembly_items = fn assembly when is_map(assembly) ->
  Enum.reduce(assembly, 0, fn {_key, val}, acc ->
    case val do
      l when is_list(l) -> acc + length(l)
      _ -> acc
    end
  end)
end

# Normalize method name: PascalCase (Go) or camelCase (TS) → lowercase
normalize_method = fn name ->
  name |> to_string() |> String.downcase()
end

# --- Discover exchanges ---

ts_ids =
  new_dir
  |> Path.join("*.json")
  |> Path.wildcard()
  |> Enum.map(&Path.basename(&1, ".json"))
  |> Enum.reject(&String.starts_with?(&1, "_"))
  |> MapSet.new()

# Go extractor exchanges: files matching <id>.go in ccxt/go/v4/ (exclude _api, _wrapper, pro/)
go_ids =
  "../ccxt_go_extractor/ccxt/go/v4/*.go"
  |> Path.wildcard()
  |> Enum.map(&Path.basename(&1, ".go"))
  |> Enum.reject(fn name ->
    String.ends_with?(name, "_api") or String.ends_with?(name, "_wrapper") or
      String.starts_with?(name, "exchange") or name in ["base", "precise", "errors"]
  end)
  |> MapSet.new()

overlap = ts_ids |> MapSet.intersection(go_ids) |> MapSet.to_list() |> Enum.sort()

IO.puts("Exchanges in ccxt_extract:    #{MapSet.size(ts_ids)}")
IO.puts("Exchanges in go_extractor:    #{MapSet.size(go_ids)}")
IO.puts("Overlapping:                  #{length(overlap)}")
IO.puts("")
IO.puts("Generating Go profiles (this may take a moment)...")
IO.puts("")

# --- Compare each exchange ---

results =
  Enum.map(overlap, fn id ->
    # Load ccxt_extract JSON
    ts_json = new_dir |> Path.join("#{id}.json") |> File.read!() |> Jason.decode!()
    describe = get_in(ts_json, ["runtime", "describe"]) || %{}
    structure = ts_json["structure"] || %{}

    # Run Go extractor profile
    go_profile =
      case System.cmd(go_binary, ["profile", id],
             cd: Path.expand("../ccxt_go_extractor"),
             stderr_to_stdout: false
           ) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, profile} -> profile
            _ -> %{}
          end

        _ ->
          %{}
      end

    # --- Endpoints ---
    ts_endpoints = count_api_endpoints.(describe["api"] || %{})

    go_endpoints =
      go_profile
      |> get_in(["endpoints", "endpoints"])
      |> then(fn
        l when is_list(l) -> length(l)
        _ -> 0
      end)

    # --- Sign method ---
    ts_sign_present = structure["sign_method"] != nil
    go_sign = get_in(go_profile, ["sign", "assembly"]) || %{}
    go_sign_items = count_assembly_items.(go_sign)

    ts_sign_depth =
      case structure["sign_method"] do
        m when is_map(m) ->
          # Count total nodes in the TS AST sign method
          m |> Jason.encode!() |> byte_size()

        _ ->
          0
      end

    # --- Error handling ---
    ts_errors_present = structure["handle_errors"] != nil
    go_errors = get_in(go_profile, ["errors", "assembly"]) || %{}
    go_errors_items = count_assembly_items.(go_errors)

    ts_errors_depth =
      case structure["handle_errors"] do
        m when is_map(m) -> m |> Jason.encode!() |> byte_size()
        _ -> 0
      end

    # --- Parse methods ---
    ts_parse =
      case structure["parse_methods"] do
        m when is_map(m) -> Map.keys(m)
        l when is_list(l) -> Enum.map(l, fn e -> if is_map(e), do: e["name"], else: e end)
        _ -> []
      end

    go_parse =
      case get_in(go_profile, ["parse", "methods"]) do
        l when is_list(l) -> Enum.map(l, fn m -> m["name"] end)
        _ -> []
      end

    ts_parse_normalized = MapSet.new(ts_parse, &normalize_method.(&1))
    go_parse_normalized = MapSet.new(go_parse, &normalize_method.(&1))
    parse_overlap = MapSet.intersection(ts_parse_normalized, go_parse_normalized)

    # --- WS methods ---
    ts_ws =
      case structure["ws_methods"] do
        m when is_map(m) -> Map.keys(m)
        l when is_list(l) -> Enum.map(l, fn e -> if is_map(e), do: e["name"], else: e end)
        _ -> []
      end

    go_ws =
      case get_in(go_profile, ["watch", "methods"]) do
        l when is_list(l) -> Enum.map(l, fn m -> m["name"] end)
        _ -> []
      end

    ts_ws_normalized = MapSet.new(ts_ws, &normalize_method.(&1))
    go_ws_normalized = MapSet.new(go_ws, &normalize_method.(&1))
    ws_overlap = MapSet.intersection(ts_ws_normalized, go_ws_normalized)

    # --- Go-only categories ---
    go_handlers = count_assembly_items.(get_in(go_profile, ["handlers", "assembly"]) || %{})
    go_auth = count_assembly_items.(get_in(go_profile, ["auth", "assembly"]) || %{})

    go_pagination =
      case get_in(go_profile, ["pagination", "methods"]) do
        l when is_list(l) -> length(l)
        _ -> 0
      end

    go_normalizers =
      case get_in(go_profile, ["base_normalizers", "methods"]) do
        l when is_list(l) -> length(l)
        _ -> 0
      end

    go_interface_methods =
      case go_profile["interfaces"] do
        m when is_map(m) ->
          Enum.reduce(m, 0, fn {_, iface}, acc ->
            case iface["methods"] do
              l when is_list(l) -> acc + length(l)
              _ -> acc
            end
          end)

        _ ->
          0
      end

    # --- TS-only categories ---
    ts_has = count_map.(describe["has"])
    ts_describe_keys = count_map.(describe)
    ts_markets = count_map.(get_in(ts_json, ["runtime", "markets"]) || %{})

    ts_overrides =
      case structure["overrides"] do
        m when is_map(m) ->
          Enum.reduce(m, 0, fn {_, methods}, acc ->
            case methods do
              l when is_list(l) -> acc + length(l)
              mm when is_map(mm) -> acc + map_size(mm)
              _ -> acc
            end
          end)

        _ ->
          0
      end

    %{
      id: id,
      ts_endpoints: ts_endpoints,
      go_endpoints: go_endpoints,
      ts_sign: ts_sign_present,
      go_sign_items: go_sign_items,
      ts_sign_bytes: ts_sign_depth,
      ts_errors: ts_errors_present,
      go_errors_items: go_errors_items,
      ts_errors_bytes: ts_errors_depth,
      ts_parse_count: length(ts_parse),
      go_parse_count: length(go_parse),
      parse_overlap: MapSet.size(parse_overlap),
      ts_ws_count: length(ts_ws),
      go_ws_count: length(go_ws),
      ws_overlap: MapSet.size(ws_overlap),
      go_handlers: go_handlers,
      go_auth: go_auth,
      go_pagination: go_pagination,
      go_normalizers: go_normalizers,
      go_interface_methods: go_interface_methods,
      ts_has: ts_has,
      ts_describe_keys: ts_describe_keys,
      ts_markets: ts_markets,
      ts_overrides: ts_overrides
    }
  end)

# --- Aggregate ---

sum = fn key -> Enum.sum(Enum.map(results, &Map.get(&1, key))) end
count_nonzero = fn key -> Enum.count(results, fn r -> Map.get(r, key, 0) > 0 end) end
count_true = fn key -> Enum.count(results, fn r -> Map.get(r, key) == true end) end

IO.puts("=== Structural Data (AST Analysis) ===\n")

IO.puts(
  String.pad_trailing("Category", 30) <>
    String.pad_leading("ccxt_extract", 14) <>
    String.pad_leading("go_extractor", 14) <>
    String.pad_leading("Both", 8)
)

IO.puts(String.duplicate("-", 66))

# Endpoints
IO.puts(
  String.pad_trailing("API endpoints", 30) <>
    String.pad_leading("#{sum.(:ts_endpoints)}", 14) <>
    String.pad_leading("#{sum.(:go_endpoints)}", 14) <>
    String.pad_leading("both", 8)
)

# Sign method
both_sign = Enum.count(results, fn r -> r.ts_sign and r.go_sign_items > 0 end)

IO.puts(
  String.pad_trailing("Sign method (exchanges)", 30) <>
    String.pad_leading("#{count_true.(:ts_sign)}", 14) <>
    String.pad_leading("#{count_nonzero.(:go_sign_items)}", 14) <>
    String.pad_leading("#{both_sign}", 8)
)

# Error handling
both_errors = Enum.count(results, fn r -> r.ts_errors and r.go_errors_items > 0 end)

IO.puts(
  String.pad_trailing("Error handling (exchanges)", 30) <>
    String.pad_leading("#{count_true.(:ts_errors)}", 14) <>
    String.pad_leading("#{count_nonzero.(:go_errors_items)}", 14) <>
    String.pad_leading("#{both_errors}", 8)
)

# Parse methods
IO.puts(
  String.pad_trailing("Parse methods (total)", 30) <>
    String.pad_leading("#{sum.(:ts_parse_count)}", 14) <>
    String.pad_leading("#{sum.(:go_parse_count)}", 14) <>
    String.pad_leading("#{sum.(:parse_overlap)}", 8)
)

# WS methods
IO.puts(
  String.pad_trailing("WS methods (total)", 30) <>
    String.pad_leading("#{sum.(:ts_ws_count)}", 14) <>
    String.pad_leading("#{sum.(:go_ws_count)}", 14) <>
    String.pad_leading("#{sum.(:ws_overlap)}", 8)
)

IO.puts("")
IO.puts("=== Go Extractor Only ===\n")

IO.puts(
  String.pad_trailing("Category", 30) <>
    String.pad_leading("Total", 14) <>
    String.pad_leading("Exchanges", 14)
)

IO.puts(String.duplicate("-", 58))

for {label, key} <- [
      {"Handler routing items", :go_handlers},
      {"Auth assembly items", :go_auth},
      {"Pagination methods", :go_pagination},
      {"Base normalizer methods", :go_normalizers},
      {"Interface method sigs", :go_interface_methods}
    ] do
  IO.puts(
    String.pad_trailing(label, 30) <>
      String.pad_leading("#{sum.(key)}", 14) <>
      String.pad_leading("#{count_nonzero.(key)}", 14)
  )
end

IO.puts("")
IO.puts("=== ccxt_extract Only ===\n")

IO.puts(
  String.pad_trailing("Category", 30) <>
    String.pad_leading("Total", 14) <>
    String.pad_leading("Exchanges", 14)
)

IO.puts(String.duplicate("-", 58))

for {label, key} <- [
      {"Has/capability flags", :ts_has},
      {"Runtime describe keys", :ts_describe_keys},
      {"Markets (symbols)", :ts_markets},
      {"Override methods", :ts_overrides}
    ] do
  IO.puts(
    String.pad_trailing(label, 30) <>
      String.pad_leading("#{sum.(key)}", 14) <>
      String.pad_leading("#{count_nonzero.(key)}", 14)
  )
end

# --- Method name overlap detail ---

IO.puts("")
IO.puts("=== Method Name Overlap ===\n")

total_ts_parse = sum.(:ts_parse_count)
total_go_parse = sum.(:go_parse_count)
total_parse_overlap = sum.(:parse_overlap)
union_parse = total_ts_parse + total_go_parse - total_parse_overlap

IO.puts(
  "Parse methods: #{total_parse_overlap} in both / #{union_parse} union " <>
    "(#{if union_parse > 0, do: "#{Float.round(total_parse_overlap / union_parse * 100, 1)}%", else: "0%"} overlap)"
)

total_ts_ws = sum.(:ts_ws_count)
total_go_ws = sum.(:go_ws_count)
total_ws_overlap = sum.(:ws_overlap)
union_ws = total_ts_ws + total_go_ws - total_ws_overlap

IO.puts(
  "WS methods:    #{total_ws_overlap} in both / #{union_ws} union " <>
    "(#{if union_ws > 0, do: "#{Float.round(total_ws_overlap / union_ws * 100, 1)}%", else: "0%"} overlap)"
)

IO.puts("\nExchanges compared: #{length(overlap)}")
IO.puts("Done.")
