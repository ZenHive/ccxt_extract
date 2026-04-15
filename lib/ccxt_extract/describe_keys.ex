defmodule CcxtExtract.DescribeKeys do
  @moduledoc """
  Extract all top-level describe() keys and their value types per exchange.

  Uses QuickBEAM to call `describe()` on every non-alias exchange and record
  which keys exist and what type each value is. This inventory reveals what
  data Phase 2 will need to extract in full.

  ## Usage

      {:ok, exchanges} = CcxtExtract.DescribeKeys.extract()
      CcxtExtract.DescribeKeys.write!(exchanges)
  """

  # JS function that extracts top-level describe() keys with value types.
  # Type detection uses typeof + Array.isArray + null check to produce
  # JSON-friendly type strings: "string", "number", "boolean", "object",
  # "array", "null", "function", "undefined".
  # TODO: Exchange ID enumeration pattern duplicated from exchanges.ex — extract
  # shared JS helper when a third module needs the same enumeration logic.
  @js_extract_describe_keys """
  globalThis.extractDescribeKeys = function(idFilter) {
    function jsType(val) {
      if (val === null) return "null";
      if (val === undefined) return "undefined";
      if (Array.isArray(val)) return "array";
      return typeof val;
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

    return JSON.stringify(ids.map(id => {
      const ex = new ccxt[id]();
      const d = ex.describe();
      if (d.alias) return null;

      const keys = {};
      for (const k of Object.keys(d)) {
        keys[k] = jsType(d[k]);
      }
      return { id: d.id, keys: keys };
    }).filter(Boolean));
  }
  """

  @doc """
  Extract top-level describe() keys and value types for all non-alias exchanges.

  Accepts an optional `scope` from `CcxtExtract.TaskScope.parse_and_resolve!/3`.
  When narrowed, the JS extractor iterates only the in-scope class IDs (alias
  exchanges still produce no entry — they share `describe()` with their parent).

  Starts a QuickBEAM runtime, loads CCXT, calls `describe()` on each exchange,
  and records the key names with their JS value types.

  Raises if CCXT is not installed (run `mix ccxt_extract.setup` first).
  """
  @spec extract(:all | MapSet.t(String.t())) :: {:ok, [map()]}
  def extract(scope \\ :all) do
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      {:ok, _} = QuickBEAM.eval(rt, @js_extract_describe_keys)

      id_filter =
        case scope do
          :all -> []
          %MapSet{} -> Enum.sort(scope)
        end

      {:ok, json} = QuickBEAM.call(rt, "extractDescribeKeys", [id_filter])

      exchanges =
        json
        |> Jason.decode!()
        |> Enum.sort_by(& &1["id"])

      {:ok, exchanges}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Write extracted describe keys to JSON.

  Defaults to `priv/discoveries/describe_keys.json`. Pass `:output_path` to
  write elsewhere (useful in tests). Pass `:tier_scope` (the JSON-serialisable
  value from `CcxtExtract.TaskScope.parse_and_resolve!/3`) to stamp the
  envelope.

  Creates the output directory if needed. Wraps the data in a metadata
  envelope with timestamp, count, and all-keys summary.
  """
  @spec write!([map()], keyword()) :: :ok
  def write!(exchanges, opts \\ []) do
    output_path = Keyword.get(opts, :output_path, CcxtExtract.Paths.priv("discoveries/describe_keys.json"))
    tier_scope = Keyword.get(opts, :tier_scope, "all")

    File.mkdir_p!(Path.dirname(output_path))

    all_keys = collect_all_keys(exchanges)

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(exchanges),
      "tier_scope" => tier_scope,
      "all_keys" => all_keys,
      "exchanges" => exchanges
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Collect all unique keys across all exchanges, sorted alphabetically.
  """
  @spec collect_all_keys([map()]) :: [String.t()]
  def collect_all_keys(exchanges) do
    exchanges
    |> Enum.flat_map(fn ex -> Map.keys(ex["keys"] || %{}) end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
