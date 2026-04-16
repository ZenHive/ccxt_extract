defmodule CcxtExtract.DescribeKeyAnalysis do
  @moduledoc """
  Analyze describe() key frequency, type consistency, and nesting depth.

  Reads the output of `CcxtExtract.DescribeKeys` (Task 3a) and produces a
  frequency analysis: which keys are universal across all exchanges, which
  are common (>90%), frequent (>50%), uncommon, or rare (<5 exchanges).

  Also measures max nesting depth per key via QuickBEAM, since the
  describe_keys.json only stores top-level type strings.

  ## Usage

      {:ok, analysis} = CcxtExtract.DescribeKeyAnalysis.extract()
      CcxtExtract.DescribeKeyAnalysis.write!(analysis)
  """

  @describe_keys_file "describe_keys.json"
  @output_file "discoveries/describe_key_analysis.json"

  # JS function that computes max nesting depth for each top-level describe() key.
  # Walks the value tree recursively, tracking depth. Reports the maximum depth
  # seen across all non-alias exchanges for each key.
  # Depth 0 = primitive (string, number, boolean, null, undefined, function)
  # Depth 1 = flat object or array of primitives
  # Depth N = nested N levels deep
  @js_extract_nesting_depths """
  globalThis.extractNestingDepths = function(idFilter) {
    function maxDepth(val, depth) {
      if (val === null || val === undefined) return depth;
      if (typeof val !== 'object') return depth;
      if (Array.isArray(val)) {
        if (val.length === 0) return depth + 1;
        let max = depth + 1;
        for (const item of val.slice(0, 10)) {
          const d = maxDepth(item, depth + 1);
          if (d > max) max = d;
        }
        return max;
      }
      const keys = Object.keys(val);
      if (keys.length === 0) return depth + 1;
      let max = depth + 1;
      for (const k of keys.slice(0, 50)) {
        const d = maxDepth(val[k], depth + 1);
        if (d > max) max = d;
      }
      return max;
    }

    const allIds = Object.keys(ccxt).filter(k => {
      try {
        return typeof ccxt[k] === 'function' &&
               k !== 'Exchange' && k !== 'Precise' &&
               new ccxt[k]().id;
      } catch(e) { return false; }
    });

    const ids = (idFilter && idFilter.length > 0)
      ? allIds.filter(k => idFilter.includes(new ccxt[k]().id))
      : allIds;

    const depths = {};
    for (const id of ids) {
      const ex = new ccxt[id]();
      const d = ex.describe();
      if (d.alias) continue;
      for (const k of Object.keys(d)) {
        const keyDepth = maxDepth(d[k], 0);
        if (depths[k] === undefined || keyDepth > depths[k]) {
          depths[k] = keyDepth;
        }
      }
    }
    return JSON.stringify(depths);
  }
  """

  @doc """
  Run the full analysis: read describe_keys.json, compute frequency, extract nesting depths.

  Accepts an optional `scope` from `CcxtExtract.TaskScope.parse_and_resolve!/3`.
  When narrowed, the `exchanges` list from describe_keys.json is filtered
  before the frequency reduction, and the QuickBEAM nesting-depth scan
  iterates only the in-scope class IDs.

  Returns `{:ok, analysis}`, `{:error, {:missing_input, path}}` if the
  describe_keys.json file doesn't exist, or `{:error, {:invalid_json, detail}}`
  if it is malformed.
  """
  @spec extract(:all | MapSet.t(String.t())) ::
          {:ok, map()} | {:error, CcxtExtract.JsonIO.read_error()}
  def extract(scope \\ :all) do
    input_path = CcxtExtract.Paths.priv(Path.join("discoveries", @describe_keys_file))

    # NOTE: Combines two data sources — describe_keys.json (from Task 3a) and a fresh
    # QuickBEAM nesting depth scan. Both must be from the same CCXT snapshot.
    # All mix tasks run against the same priv/ccxt/ checkout, so this holds in practice.
    with {:ok, data} <- CcxtExtract.JsonIO.read_json(input_path) do
      exchanges = CcxtExtract.TaskScope.filter_entries(data["exchanges"], scope, "id")
      nesting_depths = extract_nesting_depths(scope)
      analysis = analyze(exchanges, nesting_depths)
      {:ok, analysis}
    end
  end

  @doc """
  Analyze key frequency and type consistency from exchange describe key data.

  Pure function — takes the exchanges list and an optional nesting depth map.
  Returns a complete analysis map with per-key stats and tier groupings.
  """
  @spec analyze([map()], map()) :: map()
  def analyze(exchanges, nesting_depths \\ %{}) do
    exchange_count = length(exchanges)
    key_stats = build_key_stats(exchanges, exchange_count, nesting_depths)

    tiers =
      key_stats
      |> Enum.group_by(& &1["tier"])
      |> Map.new(fn {tier, keys} ->
        {tier, keys |> Enum.map(& &1["key"]) |> Enum.sort()}
      end)

    %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "exchange_count" => exchange_count,
      "key_count" => length(key_stats),
      "keys" => key_stats,
      "tiers" => tiers
    }
  end

  @doc """
  Write analysis to `priv/discoveries/describe_key_analysis.json`.

  Accepts `:tier_scope` option — the JSON-serialisable value from
  `CcxtExtract.TaskScope.parse_and_resolve!/3`, stamped into the analysis
  envelope as `tier_scope`.
  """
  @spec write!(map(), keyword()) :: :ok
  def write!(analysis, opts \\ []),
    do: CcxtExtract.DiscoveryWriter.write!(analysis, CcxtExtract.Paths.out(@output_file), opts)

  @doc """
  Extract max nesting depth per describe() key via QuickBEAM.

  Accepts an optional `scope` from `CcxtExtract.TaskScope.parse_and_resolve!/3`.
  When narrowed, the JS scan iterates only the in-scope class IDs.

  Returns a map of `%{"key_name" => depth_integer}`.
  """
  @spec extract_nesting_depths(:all | MapSet.t(String.t())) :: map()
  def extract_nesting_depths(scope \\ :all) do
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      {:ok, _} = QuickBEAM.eval(rt, @js_extract_nesting_depths)

      id_filter =
        case scope do
          :all -> []
          %MapSet{} -> Enum.sort(scope)
        end

      {:ok, json} = QuickBEAM.call(rt, "extractNestingDepths", [id_filter])
      Jason.decode!(json)
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Build per-key statistics: count, percentage, tier, type breakdown, nesting depth.

  ## Tier thresholds

  - `"universal"` — 100% of exchanges
  - `"common"` — >90% of exchanges
  - `"frequent"` — >50% of exchanges
  - `"uncommon"` — ≥5 exchanges but ≤50%
  - `"rare"` — <5 exchanges
  """
  @spec build_key_stats([map()], non_neg_integer(), map()) :: [map()]
  def build_key_stats(exchanges, exchange_count, nesting_depths) do
    # Count occurrences and types per key
    key_data =
      Enum.reduce(exchanges, %{}, fn ex, acc ->
        keys = ex["keys"] || %{}

        Enum.reduce(keys, acc, fn {key, type}, inner_acc ->
          entry = Map.get(inner_acc, key, %{"count" => 0, "types" => %{}})
          type_count = Map.get(entry["types"], type, 0)

          updated = %{
            "count" => entry["count"] + 1,
            "types" => Map.put(entry["types"], type, type_count + 1)
          }

          Map.put(inner_acc, key, updated)
        end)
      end)

    key_data
    |> Enum.map(fn {key, data} ->
      percentage = if exchange_count > 0, do: Float.round(data["count"] / exchange_count * 100, 1), else: 0.0

      %{
        "key" => key,
        "count" => data["count"],
        "percentage" => percentage,
        "tier" => classify_tier(data["count"], exchange_count),
        "max_nesting_depth" => Map.get(nesting_depths, key),
        "types" => data["types"]
      }
    end)
    |> Enum.sort_by(&{-&1["count"], &1["key"]})
  end

  @doc """
  Classify a key into a frequency tier based on count and total.

  - `"universal"` — present on 100% of exchanges
  - `"common"` — present on >90%
  - `"frequent"` — present on >50%
  - `"uncommon"` — present on ≥5 exchanges but ≤50%
  - `"rare"` — present on <5 exchanges
  """
  @spec classify_tier(non_neg_integer(), non_neg_integer()) :: String.t()
  def classify_tier(count, total) when total > 0 do
    percentage = count / total * 100

    cond do
      count == total -> "universal"
      percentage > 90 -> "common"
      percentage > 50 -> "frequent"
      count >= 5 -> "uncommon"
      true -> "rare"
    end
  end

  def classify_tier(_count, 0), do: "rare"
end
