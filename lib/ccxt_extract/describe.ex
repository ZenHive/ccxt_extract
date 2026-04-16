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

  # Caller-specific JS for full describe() extraction. Shared helpers
  # (`_errorNameMap`, `getNonAliasIds`, `_prepare`) live in
  # `CcxtExtract.QuickbeamRuntime` and are installed via
  # `QuickbeamRuntime.install_extraction_helpers/1`.
  #
  # Security note: This JS code runs inside QuickBEAM (sandboxed Zig NIF runtime)
  # against the CCXT vendor bundle — no user input is involved.
  @js_setup """
  globalThis.getFullDescribe = function(id) {
    const ex = new ccxt[id]();
    return JSON.stringify(_prepare(ex.describe()));
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
      :ok = CcxtExtract.QuickbeamRuntime.install_extraction_helpers(rt)
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)
      {:ok, ids_json} = QuickBEAM.call(rt, "getNonAliasIds", [])

      ids =
        ids_json
        |> Jason.decode!()
        |> CcxtExtract.TaskScope.filter_ids(scope_opt)

      Logger.info("Extracting describe() for #{length(ids)} exchanges...")

      results = CcxtExtract.Progress.map(ids, &extract_one(rt, &1))

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
