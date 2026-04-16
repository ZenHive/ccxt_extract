defmodule CcxtExtract.MethodAnalysis do
  @moduledoc """
  Analyze method families, universality, and distribution across CCXT exchanges.

  Reads the output of `CcxtExtract.Methods` (Tasks 4a + 4b) and produces a
  family analysis: grouping methods by prefix (`fetch*`, `parse*`, `create*`,
  etc.), identifying universal vs unique vs rare methods, and computing method
  count distributions.

  Also performs cross-type analysis comparing REST and WS method sets.

  ## Usage

      {:ok, analysis} = CcxtExtract.MethodAnalysis.extract()
      CcxtExtract.MethodAnalysis.write!(analysis)
  """

  @rest_file "methods_rest.json"
  @ws_file "methods_ws.json"
  @output_file "method_analysis.json"

  # Known CCXT method prefixes, ordered by convention.
  # Methods not matching any prefix go into "other".
  @known_prefixes ~w(
    fetch parse create cancel edit watch handle
    set get load build encode decode sign
  )

  @doc """
  Run the full analysis: read methods_rest.json + methods_ws.json, compute families.

  Accepts an optional `scope` (from `CcxtExtract.TaskScope.parse_and_resolve!/3`).
  When narrowed, the `exchanges` lists in both REST and WS aggregates are
  filtered before the family/universality reduction.

  Returns `{:ok, analysis}`, `{:error, {:missing_input, path}}`, or
  `{:error, {:invalid_json, detail}}`.
  """
  @spec extract(:all | MapSet.t(String.t())) ::
          {:ok, map()} | {:error, CcxtExtract.JsonIO.read_error()}
  def extract(scope \\ :all) do
    rest_path = CcxtExtract.Paths.priv(Path.join("discoveries", @rest_file))
    ws_path = CcxtExtract.Paths.priv(Path.join("discoveries", @ws_file))

    with {:ok, rest_data} <- CcxtExtract.JsonIO.read_json(rest_path),
         {:ok, ws_data} <- CcxtExtract.JsonIO.read_json(ws_path) do
      filtered_rest = scope_data(rest_data, scope)
      filtered_ws = scope_data(ws_data, scope)
      analysis = analyze(filtered_rest, filtered_ws)
      {:ok, analysis}
    end
  end

  defp scope_data(data, :all), do: data

  defp scope_data(%{"exchanges" => exchanges} = data, %MapSet{} = scope) do
    %{data | "exchanges" => CcxtExtract.TaskScope.filter_entries(exchanges, scope, "id")}
  end

  defp scope_data(data, %MapSet{}), do: data

  @doc """
  Analyze method families, universality, and distribution for REST and WS data.

  Pure function — takes the parsed JSON maps from methods_rest.json and
  methods_ws.json. Returns a complete analysis map.
  """
  @spec analyze(map(), map()) :: map()
  def analyze(rest_data, ws_data) do
    rest_exchanges = rest_data["exchanges"] || []
    ws_exchanges = ws_data["exchanges"] || []

    rest_analysis = analyze_type(rest_exchanges)
    ws_analysis = analyze_type(ws_exchanges)

    rest_method_names = collect_all_method_names(rest_exchanges)
    ws_method_names = collect_all_method_names(ws_exchanges)
    cross_type = cross_type_analysis(rest_method_names, ws_method_names)

    %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "rest" => rest_analysis,
      "ws" => ws_analysis,
      "cross_type" => cross_type
    }
  end

  @doc """
  Analyze a single type (REST or WS) — families, universality, distribution.

  Pure function operating on a list of exchange maps.
  """
  @spec analyze_type([map()]) :: map()
  def analyze_type(exchanges) do
    exchange_count = length(exchanges)
    all_methods = collect_all_methods_with_counts(exchanges)
    families = group_by_family(all_methods)

    total_methods =
      exchanges
      |> Enum.map(&length(&1["methods"] || []))
      |> Enum.sum()

    %{
      "exchange_count" => exchange_count,
      "total_methods" => total_methods,
      "unique_method_names" => map_size(all_methods),
      "families" => format_families(families, exchange_count),
      "universal_methods" => universal_methods(all_methods, exchange_count),
      "unique_methods" => unique_methods(all_methods),
      "rare_methods" => rare_methods(all_methods),
      "method_count_distribution" => method_count_distribution(exchanges)
    }
  end

  @doc """
  Group method names by their camelCase prefix family.

  Known prefixes: #{Enum.join(@known_prefixes, ", ")}.
  Single-word methods and unrecognized prefixes go into `"other"`.

  Returns a map of `%{"prefix" => [%{"name" => method_name, "count" => N}]}`.
  """
  @spec group_by_family(%{String.t() => non_neg_integer()}) :: %{String.t() => [map()]}
  def group_by_family(methods_with_counts) do
    methods_with_counts
    |> Enum.map(fn {name, count} -> %{"name" => name, "count" => count} end)
    |> Enum.group_by(&extract_prefix(&1["name"]))
  end

  @doc """
  Extract the prefix family from a method name.

  Uses camelCase boundary detection: the prefix is the lowercase portion
  before the first uppercase letter, if it matches a known CCXT prefix.

      iex> CcxtExtract.MethodAnalysis.extract_prefix("fetchTicker")
      "fetch"
      iex> CcxtExtract.MethodAnalysis.extract_prefix("describe")
      "other"
      iex> CcxtExtract.MethodAnalysis.extract_prefix("parseTrade")
      "parse"
  """
  @spec extract_prefix(String.t()) :: String.t()
  def extract_prefix(name) do
    case Regex.run(~r/^([a-z]+)[A-Z]/, name) do
      [_, prefix] ->
        if prefix in @known_prefixes, do: prefix, else: "other"

      nil ->
        # Single-word method (no camelCase boundary) — check if it IS a known prefix
        if name in @known_prefixes, do: name, else: "other"
    end
  end

  @doc """
  Compute method count distribution statistics across exchanges.

  Returns min, max, median, mean, p25, p75 of per-exchange method counts.
  """
  @spec method_count_distribution([map()]) :: map()
  def method_count_distribution([]), do: %{"min" => 0, "max" => 0, "median" => 0, "mean" => 0.0, "p25" => 0, "p75" => 0}

  def method_count_distribution(exchanges) do
    counts =
      exchanges
      |> Enum.map(&length(&1["methods"] || []))
      |> Enum.sort()

    n = length(counts)

    %{
      "min" => List.first(counts),
      "max" => List.last(counts),
      "median" => percentile(counts, 50),
      "mean" => Float.round(Enum.sum(counts) / n, 1),
      "p25" => percentile(counts, 25),
      "p75" => percentile(counts, 75)
    }
  end

  @doc """
  Write analysis to `priv/discoveries/method_analysis.json`.

  Accepts `:tier_scope` option — the JSON-serialisable value from
  `CcxtExtract.TaskScope.parse_and_resolve!/3`, stamped into the analysis
  envelope as `tier_scope`.
  """
  @spec write!(map(), keyword()) :: :ok
  def write!(analysis, opts \\ []) do
    output_path =
      Keyword.get(opts, :output_path, CcxtExtract.Paths.priv(Path.join("discoveries", @output_file)))

    tier_scope = Keyword.get(opts, :tier_scope, "all")
    stamped = Map.put(analysis, "tier_scope", tier_scope)

    File.mkdir_p!(Path.dirname(output_path))

    json = Jason.encode!(stamped, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  # --- Private helpers ---

  # Collect all unique method names with their exchange count
  defp collect_all_methods_with_counts(exchanges) do
    Enum.reduce(exchanges, %{}, fn ex, acc ->
      methods = ex["methods"] || []

      Enum.reduce(methods, acc, fn method, inner_acc ->
        name = method["name"]
        Map.update(inner_acc, name, 1, &(&1 + 1))
      end)
    end)
  end

  # Collect the set of all unique method names
  defp collect_all_method_names(exchanges) do
    exchanges
    |> Enum.flat_map(fn ex -> Enum.map(ex["methods"] || [], & &1["name"]) end)
    |> MapSet.new()
  end

  # Format families with per-method exchange counts and percentages
  defp format_families(families, exchange_count) do
    Map.new(families, fn {prefix, methods} ->
      sorted =
        methods
        |> Enum.map(&format_method_entry(&1, exchange_count))
        |> Enum.sort_by(&{-&1["exchange_count"], &1["name"]})

      {prefix, %{"count" => length(methods), "methods" => sorted}}
    end)
  end

  defp format_method_entry(method, exchange_count) do
    pct = if exchange_count > 0, do: Float.round(method["count"] / exchange_count * 100, 1), else: 0.0
    %{"name" => method["name"], "exchange_count" => method["count"], "percentage" => pct}
  end

  # Methods present on 100% of exchanges
  defp universal_methods(all_methods, exchange_count) when exchange_count > 0 do
    all_methods
    |> Enum.filter(fn {_name, count} -> count == exchange_count end)
    |> Enum.map(fn {name, count} ->
      %{"name" => name, "count" => count, "percentage" => 100.0}
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp universal_methods(_all_methods, 0), do: []

  # Methods present on exactly 1 exchange
  defp unique_methods(all_methods) do
    all_methods
    |> Enum.filter(fn {_name, count} -> count == 1 end)
    |> Enum.map(fn {name, count} -> %{"name" => name, "count" => count} end)
    |> Enum.sort_by(& &1["name"])
  end

  # Methods present on fewer than 5 exchanges
  @rare_threshold 5
  defp rare_methods(all_methods) do
    all_methods
    |> Enum.filter(fn {_name, count} -> count < @rare_threshold end)
    |> Enum.map(fn {name, count} -> %{"name" => name, "count" => count} end)
    |> Enum.sort_by(&{-&1["count"], &1["name"]})
  end

  # Cross-type analysis: REST-only, WS-only, shared method names
  defp cross_type_analysis(rest_names, ws_names) do
    shared = MapSet.intersection(rest_names, ws_names)
    rest_only = MapSet.difference(rest_names, ws_names)
    ws_only = MapSet.difference(ws_names, rest_names)

    %{
      "shared_methods" => shared |> MapSet.to_list() |> Enum.sort(),
      "rest_only_methods" => rest_only |> MapSet.to_list() |> Enum.sort(),
      "ws_only_methods" => ws_only |> MapSet.to_list() |> Enum.sort(),
      "shared_count" => MapSet.size(shared),
      "rest_only_count" => MapSet.size(rest_only),
      "ws_only_count" => MapSet.size(ws_only)
    }
  end

  # Nearest-rank percentile calculation
  defp percentile(sorted_list, p) do
    n = length(sorted_list)
    rank = ceil(p / 100 * n)
    index = max(rank - 1, 0)
    Enum.at(sorted_list, index)
  end
end
