defmodule CcxtExtract.LoadMarkets do
  @moduledoc """
  Extract `loadMarkets()` data for all CCXT exchanges via QuickBEAM.

  Calls `loadMarkets()` on each non-alias exchange — a real HTTP request to the
  exchange's public API. Most exchanges serve market data without authentication,
  though some may require credentials or fail for other reasons.

  Rate-limited: configurable delay between each call (default 200ms).

  Output is one JSON file per successful exchange in `priv/discoveries/load_markets/`,
  plus a manifest at `priv/discoveries/load_markets/_manifest.json`.

  As of Task 97 each entry also carries a `"currencies"` key (populated from
  the exchange instance after `loadMarkets()`). This is the runtime-enriched
  map with per-currency `networks` info (the static `describe().currencies`
  scaffold is already available via the separate describe extractor).

  ## Usage

      {:ok, results} = CcxtExtract.LoadMarkets.extract()
      CcxtExtract.LoadMarkets.write!(results)

      # With options
      {:ok, results} = CcxtExtract.LoadMarkets.extract(delay_ms: 500)
      {:ok, results} = CcxtExtract.LoadMarkets.extract(exchanges: ["binance", "dydx"])
  """

  require Logger

  @output_dir "discoveries/load_markets"

  @default_delay_ms 200
  @default_concurrency 5
  # 1GB per runtime — generous for dev machines, prevents OOM on large exchanges
  @runtime_memory_limit 1_073_741_824
  # Per-exchange loadMarkets() timeout — generous for slow exchanges
  @load_markets_timeout_ms 30_000

  # Caller-specific JS for loadMarkets() extraction. Shared helpers
  # (`_errorNameMap`, `getNonAliasIds`, `_prepare`) live in
  # `CcxtExtract.QuickbeamRuntime` and are installed via
  # `QuickbeamRuntime.install_extraction_helpers/1`.
  #
  # In practice market data contains only `__undefined` sentinels (no
  # `__function:` refs) — the error-name resolution inside `_prepare` is
  # defensive consistency with describe.ex's usage.
  #
  # Security note: This JS code runs inside QuickBEAM (sandboxed Zig NIF runtime)
  # against the CCXT vendor bundle — no user input is involved.
  @js_setup """
  globalThis.loadMarketsForExchange = async function(id) {
    try {
      const ex = new ccxt[id]();
      const markets = await ex.loadMarkets();
      // currencies is populated as a side-effect of loadMarkets() (Task 97).
      // We capture the runtime-enriched version (with networks) rather than the
      // static describe().currencies scaffold. _prepare strips __function refs.
      const currencies = ex.currencies || {};
      return JSON.stringify({
        ok: true,
        markets: _prepare(markets),
        currencies: _prepare(currencies),
        market_count: Object.keys(markets).length
      });
    } catch(e) {
      return JSON.stringify({ok: false, error: e.message || String(e)});
    }
  }
  """

  @doc """
  Extract loadMarkets() data for all (or specified) non-alias exchanges.

  ## Options

    * `:delay_ms` - milliseconds to sleep between exchange calls (default: #{@default_delay_ms})
    * `:exchanges` - list of exchange IDs to extract (default: all non-alias exchanges)

  Returns `{:ok, %{"succeeded" => [...], "failed" => [...]}}`.
  """
  @spec extract(keyword()) :: {:ok, map()}
  def extract(opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, @default_delay_ms)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    filter_exchanges = Keyword.get(opts, :exchanges, nil)

    validate_opts!(delay_ms, concurrency, filter_exchanges)

    ids = list_exchange_ids(filter_exchanges)
    total = length(ids)
    chunk_size = ceil(total / concurrency)

    Logger.info(
      "Extracting loadMarkets() for #{total} exchanges " <>
        "(delay: #{delay_ms}ms, concurrency: #{concurrency})..."
    )

    # Chunk exchanges across N parallel runtimes, each with 1GB heap.
    # Within each chunk, calls are sequential with delay between them.
    # Different chunks hit different exchanges, so parallelism is safe.
    results =
      ids
      |> Enum.chunk_every(chunk_size)
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {chunk, worker_idx} ->
          Logger.info("  Worker #{worker_idx}: #{length(chunk)} exchanges...")
          extract_chunk(chunk, delay_ms)
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.reduce({[], []}, fn {:ok, {ok, err}}, {ok_acc, err_acc} ->
        {ok_acc ++ ok, err_acc ++ err}
      end)

    {succeeded, failed} = results
    {:ok, %{"succeeded" => succeeded, "failed" => failed}}
  end

  @doc """
  Extract loadMarkets() for a single exchange from an active runtime.

  Returns `{:ok, result_map}` or `{:error, error_map}`.
  """
  @spec extract_one(pid(), String.t()) :: {:ok, map()} | {:error, map()}
  def extract_one(rt, id) do
    case QuickBEAM.call(rt, "loadMarketsForExchange", [id], timeout: @load_markets_timeout_ms) do
      {:ok, json} ->
        parsed = Jason.decode!(json)

        if parsed["ok"] do
          {:ok,
           %{
             "id" => id,
             "market_count" => parsed["market_count"],
             "markets" => parsed["markets"],
             "currencies" => parsed["currencies"]
           }}
        else
          {:error, %{"id" => id, "error" => parsed["error"]}}
        end

      {:error, reason} ->
        {:error, %{"id" => id, "error" => inspect(reason)}}
    end
  end

  @doc """
  Write per-exchange JSON files and a manifest.

  Creates `priv/discoveries/load_markets/<exchange_id>.json` for each
  succeeded exchange and `priv/discoveries/load_markets/_manifest.json`
  with success/failure summary.

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. When `:all`,
      per-exchange files not produced by this run are pruned via
      `ScopeCleanup.prune_out_of_scope/3` (universe reassertion). When a
      MapSet, out-of-scope per-exchange files and failed entries from
      prior runs are preserved.
    * `:tier_scope` — value from `CcxtExtract.Scope.to_manifest_value/1`,
      stamped into the manifest. Defaults to `"all"`.
    * `:output_dir` — override output directory (mostly for tests).

  The `succeeded` list is rebuilt from disk via
  `TaskScope.rebuild_manifest_exchanges/1` (each success corresponds to a
  file on disk). The `failed` list merges out-of-scope existing entries
  with this run's failures, dropping any entry whose ID now has a
  succeeded file. Counts are recomputed from the final lists.
  """
  @spec write!(map(), keyword()) :: :ok
  def write!(results, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    output_dir = Keyword.get(opts, :output_dir, CcxtExtract.Paths.out(@output_dir))

    File.mkdir_p!(output_dir)

    extracted_at = CcxtExtract.Clock.timestamp(:extracted_at)

    for result <- results["succeeded"] do
      path = Path.join(output_dir, "#{result["id"]}.json")

      output = %{
        "id" => result["id"],
        "extracted_at" => extracted_at,
        "market_count" => result["market_count"],
        "markets" => result["markets"],
        "currencies" => result["currencies"]
      }

      CcxtExtract.JsonIO.write_json!(path, output, pretty: true)
    end

    if scope == :all do
      produced = MapSet.new(results["succeeded"], & &1["id"])
      {:ok, _removed} = CcxtExtract.ScopeCleanup.prune_out_of_scope(output_dir, produced)
    end

    manifest_path = Path.join(output_dir, "_manifest.json")
    succeeded_ids = CcxtExtract.TaskScope.rebuild_manifest_exchanges(output_dir)
    succeeded_set = MapSet.new(succeeded_ids)

    existing_failed = read_existing_failed(manifest_path)

    merged_failed =
      existing_failed
      |> filter_failed_by_scope(scope)
      |> Enum.concat(results["failed"])
      |> Enum.reject(&MapSet.member?(succeeded_set, &1["id"]))
      |> dedup_failed_by_id()
      |> Enum.sort_by(& &1["id"])

    manifest = %{
      "extracted_at" => extracted_at,
      "tier_scope" => tier_scope,
      "succeeded_count" => length(succeeded_ids),
      "failed_count" => length(merged_failed),
      "succeeded" => succeeded_ids,
      "failed" => merged_failed
    }

    CcxtExtract.JsonIO.write_json!(manifest_path, manifest, pretty: true)
    :ok
  end

  # Best-effort: missing file, unreadable manifest, malformed JSON, or absent
  # "failed" key all degrade to []. Scoped merge then behaves like a full
  # rewrite for failed entries rather than crashing the pipeline on stale state.
  defp read_existing_failed(manifest_path) do
    case CcxtExtract.JsonIO.read_json(manifest_path) do
      {:ok, %{"failed" => failed}} when is_list(failed) -> failed
      _ -> []
    end
  end

  # `:all` reasserts the universe: existing failed entries are discarded so
  # the manifest's `failed` list is rebuilt from this run's failures only.
  # Ghost entries (exchanges CCXT dropped but still listed as failed in the
  # prior manifest) would otherwise linger silently across full-universe runs.
  defp filter_failed_by_scope(_existing, :all), do: []

  defp filter_failed_by_scope(existing, %MapSet{} = scope) do
    Enum.reject(existing, &MapSet.member?(scope, &1["id"]))
  end

  # When a scoped run produces both an "existing" out-of-scope entry and a
  # fresh entry for the same ID (pathological corrupt-state recovery), the
  # fresh one wins.
  defp dedup_failed_by_id(failed) do
    failed
    |> Enum.reduce(%{}, fn entry, acc -> Map.put(acc, entry["id"], entry) end)
    |> Map.values()
  end

  # Get exchange IDs — boots a temporary runtime if needed
  defp list_exchange_ids(nil) do
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      :ok = CcxtExtract.QuickbeamRuntime.install_extraction_helpers(rt)
      {:ok, ids_json} = QuickBEAM.call(rt, "getNonAliasIds", [])
      Jason.decode!(ids_json)
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  defp list_exchange_ids(exchanges) when is_list(exchanges), do: Enum.sort(exchanges)

  # Validates extract/1 options before any work begins
  defp validate_opts!(delay_ms, concurrency, filter_exchanges) do
    if !(is_integer(delay_ms) and delay_ms >= 0) do
      raise ArgumentError, "delay_ms must be a non-negative integer, got: #{inspect(delay_ms)}"
    end

    if !(is_integer(concurrency) and concurrency >= 1) do
      raise ArgumentError, "concurrency must be a positive integer, got: #{inspect(concurrency)}"
    end

    if is_list(filter_exchanges) and filter_exchanges == [] do
      raise ArgumentError, "exchanges must be a non-empty list when provided"
    end
  end

  # Extract a chunk of exchanges on a dedicated runtime with generous memory
  defp extract_chunk(ids, delay_ms) do
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start(memory_limit: @runtime_memory_limit)

    try do
      :ok = CcxtExtract.QuickbeamRuntime.install_extraction_helpers(rt)
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)

      ids
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {id, idx}, {ok_acc, err_acc} ->
        if idx > 1, do: Process.sleep(delay_ms)

        case extract_one(rt, id) do
          {:ok, result} -> {[result | ok_acc], err_acc}
          {:error, error} -> {ok_acc, [error | err_acc]}
        end
      end)
      |> then(fn {ok_acc, err_acc} -> {Enum.reverse(ok_acc), Enum.reverse(err_acc)} end)
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end
end
