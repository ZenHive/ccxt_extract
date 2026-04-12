# Compare data volume between ccxt_extract JSON and old ccxt_client .exs specs
#
# Counts API endpoints, capability flags, exception mappings, and other
# normalization data across all overlapping exchanges.
#
# Usage: mix run examples/compare_old_counts.exs

new_dir = "priv/output"
old_dir = "clients/elixir/ccxt_client/priv/specs/extracted"

if !File.dir?(old_dir) do
  IO.puts("ERROR: Old specs directory not found: #{old_dir}")
  IO.puts("Expected ccxt_client at clients/elixir/ccxt_client/ (see clients/README.md).")
  System.halt(1)
end

# --- Helpers ---

count_map = fn val -> if is_map(val), do: map_size(val), else: 0 end

# Count leaf paths in CCXT API tree: section -> http_method -> path -> cost
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

# Count entries across nested exception categories (broad/exact/spot/linear/etc.)
count_exceptions = fn val ->
  case val do
    m when is_map(m) ->
      Enum.reduce(m, 0, fn {_, entries}, acc ->
        if is_map(entries), do: acc + map_size(entries), else: acc
      end)

    _ ->
      0
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

# --- Count per exchange ---

results =
  Enum.map(overlap, fn id ->
    new_json = new_dir |> Path.join("#{id}.json") |> File.read!() |> Jason.decode!()
    describe = get_in(new_json, ["runtime", "describe"]) || %{}

    old_spec =
      try do
        {spec, _} = Code.eval_file(Path.join(old_dir, "#{id}.exs"))
        spec
      rescue
        _ -> %{}
      end

    # Old exceptions: deduplicate across error_codes + exceptions maps
    # (old pipeline stored the same codes in multiple overlapping maps)
    old_exc_keys = MapSet.new()

    old_exc_keys =
      if is_map(old_spec[:error_codes]),
        do: MapSet.union(old_exc_keys, MapSet.new(Map.keys(old_spec[:error_codes]), &to_string/1)),
        else: old_exc_keys

    old_exc_keys =
      if is_map(old_spec[:exceptions]) do
        Enum.reduce(old_spec[:exceptions], old_exc_keys, fn {_, entries}, acc ->
          if is_map(entries),
            do: MapSet.union(acc, MapSet.new(Map.keys(entries), &to_string/1)),
            else: acc
        end)
      else
        old_exc_keys
      end

    %{
      id: id,
      old_endpoints:
        case old_spec[:endpoints] do
          l when is_list(l) -> length(l)
          _ -> 0
        end,
      new_endpoints: count_api_endpoints.(describe["api"] || %{}),
      old_has: count_map.(old_spec[:has]),
      new_has: count_map.(describe["has"]),
      old_exceptions: MapSet.size(old_exc_keys),
      new_exceptions: count_exceptions.(describe["exceptions"]),
      old_options: count_map.(old_spec[:options]),
      new_options: count_map.(describe["options"]),
      old_currencies: count_map.(old_spec[:currencies]),
      new_currencies: count_map.(describe["currencies"]),
      old_common_currencies: count_map.(old_spec[:currency_aliases]),
      new_common_currencies: count_map.(describe["commonCurrencies"]),
      old_markets: count_map.(old_spec[:markets]),
      new_markets: count_map.(get_in(new_json, ["runtime", "markets"]) || %{})
    }
  end)

# --- Summary table ---

categories = [
  {"API endpoints", :old_endpoints, :new_endpoints},
  {"Capability flags (has)", :old_has, :new_has},
  {"Exception mappings*", :old_exceptions, :new_exceptions},
  {"Options keys", :old_options, :new_options},
  {"Currencies", :old_currencies, :new_currencies},
  {"Common currencies", :old_common_currencies, :new_common_currencies},
  {"Markets", :old_markets, :new_markets}
]

IO.puts(
  String.pad_trailing("Category", 28) <>
    String.pad_leading("Old", 10) <>
    String.pad_leading("New", 10) <>
    String.pad_leading("Delta", 10) <>
    String.pad_leading("Ratio", 8)
)

IO.puts(String.duplicate("-", 66))

for {label, old_key, new_key} <- categories do
  old_total = Enum.sum(Enum.map(results, &Map.get(&1, old_key)))
  new_total = Enum.sum(Enum.map(results, &Map.get(&1, new_key)))
  delta = new_total - old_total
  sign = if delta >= 0, do: "+", else: ""
  ratio = if old_total > 0, do: "#{Float.round(new_total / old_total, 1)}x", else: "new"

  IO.puts(
    String.pad_trailing(label, 28) <>
      String.pad_leading("#{old_total}", 10) <>
      String.pad_leading("#{new_total}", 10) <>
      String.pad_leading("#{sign}#{delta}", 10) <>
      String.pad_leading(ratio, 8)
  )
end

IO.puts(
  "\n* Exception counts deduplicated — old specs stored same codes in error_codes + error_code_details + exceptions"
)

IO.puts("\nExchanges compared: #{length(overlap)}")

# --- Top 10 endpoint gains ---

IO.puts("\n=== Top 10 Endpoint Gains ===\n")

IO.puts(
  String.pad_trailing("Exchange", 22) <>
    String.pad_leading("Old", 8) <>
    String.pad_leading("New", 8) <>
    String.pad_leading("Gain", 8)
)

IO.puts(String.duplicate("-", 46))

results
|> Enum.sort_by(&(-(&1.new_endpoints - &1.old_endpoints)))
|> Enum.take(10)
|> Enum.each(fn r ->
  IO.puts(
    String.pad_trailing(r.id, 22) <>
      String.pad_leading("#{r.old_endpoints}", 8) <>
      String.pad_leading("#{r.new_endpoints}", 8) <>
      String.pad_leading("+#{r.new_endpoints - r.old_endpoints}", 8)
  )
end)
