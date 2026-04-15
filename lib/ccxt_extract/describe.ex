defmodule CcxtExtract.Describe do
  @moduledoc """
  Extract the complete `describe()` output for all CCXT exchanges via QuickBEAM.

  Each exchange's `describe()` contains the full configuration: `has`, `api`,
  `exceptions`, `fees`, `timeframes`, `options`, `commonCurrencies`,
  `requiredCredentials`, and more. This module extracts every key and every
  nested value — nothing is filtered.

  Output is one JSON file per exchange in `priv/discoveries/describe/`, plus a
  manifest at `priv/discoveries/describe/_manifest.json`.

  ## Usage

      {:ok, results} = CcxtExtract.Describe.extract()
      CcxtExtract.Describe.write!(results)
  """

  require Logger

  @output_dir "discoveries/describe"

  # TODO: Exchange ID enumeration pattern duplicated from exchanges.ex and describe_keys.ex —
  # now 3 modules use the same getNonAliasIds logic. Extract shared JS helper.
  #
  # JS functions for full describe() extraction.
  #
  # getNonAliasIds: returns sorted list of exchange IDs that are not aliases.
  # getFullDescribe: returns one exchange's complete describe() as JSON.
  #
  # The prepare() function handles two edge cases before JSON serialization:
  # - Functions (error classes) -> "__function:<name>" with resolved class names
  # - undefined values (which JSON.stringify would silently drop) -> "__undefined"
  #
  # _errorNameMap resolves minified Function.name (e.g. "h") to real error class
  # names (e.g. "ExchangeError") by instantiating each Error subclass and reading
  # the this.name property set in CCXT's error constructors.
  #
  # Security note: This JS code runs inside QuickBEAM (sandboxed Zig NIF runtime)
  # against the CCXT vendor bundle — no user input is involved.
  @js_setup """
  // Build map: minified Function.name → real error class name.
  // CCXT error classes set this.name = 'ExchangeError' in their constructors,
  // which survives minification (string literals are never mangled).
  globalThis._errorNameMap = {};
  for (const k of Object.keys(ccxt)) {
    const v = ccxt[k];
    if (typeof v === 'function') {
      try {
        const inst = new v();
        if (inst instanceof Error && inst.name) {
          _errorNameMap[v.name] = inst.name;
        }
      } catch(e) {}
    }
  }

  globalThis.getNonAliasIds = function() {
    const ids = Object.keys(ccxt).filter(k => {
      try {
        return typeof ccxt[k] === 'function' &&
               k !== 'Exchange' && k !== 'Precise' &&
               new ccxt[k]().id;
      } catch(e) { return false; }
    });
    return JSON.stringify(ids.filter(id => {
      const d = new ccxt[id]().describe();
      return !d.alias;
    }).sort());
  }

  globalThis.getFullDescribe = function(id) {
    const ex = new ccxt[id]();
    const d = ex.describe();

    // Walk the object tree, converting undefined to sentinel and functions to names.
    // We must do this before JSON.stringify because stringify silently drops undefined.
    function prepare(val) {
      if (val === undefined) return '__undefined';
      if (val === null) return null;
      if (typeof val === 'function') {
        const resolved = _errorNameMap[val.name] || val.name || 'anonymous';
        return '__function:' + resolved;
      }
      if (Array.isArray(val)) return val.map(prepare);
      if (typeof val === 'object') {
        const out = {};
        for (const k of Object.keys(val)) {
          out[k] = prepare(val[k]);
        }
        return out;
      }
      return val;
    }

    return JSON.stringify(prepare(d));
  }
  """

  @doc """
  Extract the complete describe() for all non-alias exchanges.

  Starts a QuickBEAM runtime, enumerates non-alias exchange IDs, then extracts
  each exchange's full describe() one at a time. Returns a sorted list of
  `%{"id" => id, "describe" => describe_map}` maps.
  """
  @spec extract(keyword()) :: {:ok, [map()]}
  def extract(extract_opts \\ []) do
    scope_opt = Keyword.get(extract_opts, :scope, :all)
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)
      {:ok, ids_json} = QuickBEAM.call(rt, "getNonAliasIds", [])

      ids =
        ids_json
        |> Jason.decode!()
        |> CcxtExtract.TaskScope.filter_ids(scope_opt)

      Logger.info("Extracting describe() for #{length(ids)} exchanges...")

      results =
        ids
        |> Enum.with_index(1)
        |> Enum.map(fn {id, idx} ->
          if rem(idx, 20) == 0, do: Logger.info("  #{idx}/#{length(ids)}...")
          extract_one(rt, id)
        end)

      {:ok, results}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Extract a single exchange's complete describe() from an active runtime.
  """
  @spec extract_one(pid(), String.t()) :: map()
  def extract_one(rt, id) do
    {:ok, json} = QuickBEAM.call(rt, "getFullDescribe", [id])

    %{
      "id" => id,
      "describe" => Jason.decode!(json)
    }
  end

  @doc """
  Write per-exchange JSON files and a manifest.

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. When `:all`,
      per-exchange files not in `results` are pruned via
      `ScopeCleanup.prune_out_of_scope/3` (universe reassertion). When a
      MapSet, out-of-scope files from prior runs are preserved.
    * `:tier_scope` — value from `CcxtExtract.Scope.to_manifest_value/1`,
      stamped into the manifest. Defaults to `"all"`.
    * `:output_dir` — override output directory (mostly for tests).
  """
  @spec write!([map()], keyword()) :: :ok
  def write!(results, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    output_dir = Keyword.get(opts, :output_dir, CcxtExtract.Paths.priv(@output_dir))

    File.mkdir_p!(output_dir)

    extracted_at = DateTime.to_iso8601(DateTime.utc_now())

    for result <- results do
      path = Path.join(output_dir, "#{result["id"]}.json")

      output = %{
        "id" => result["id"],
        "extracted_at" => extracted_at,
        "describe" => result["describe"]
      }

      File.write!(path, Jason.encode!(output, pretty: true))
    end

    if scope == :all do
      produced = MapSet.new(results, & &1["id"])
      {:ok, _removed} = CcxtExtract.ScopeCleanup.prune_out_of_scope(output_dir, produced)
    end

    manifest_ids = CcxtExtract.TaskScope.rebuild_manifest_exchanges(output_dir)
    manifest_path = Path.join(output_dir, "_manifest.json")

    manifest = %{
      "extracted_at" => extracted_at,
      "count" => length(manifest_ids),
      "tier_scope" => tier_scope,
      "exchanges" => manifest_ids
    }

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    :ok
  end
end
