defmodule CcxtExtract.LoadMarkets do
  @moduledoc """
  Extract `loadMarkets()` data for all CCXT exchanges via QuickBEAM.

  Calls `loadMarkets()` on each non-alias exchange — a real HTTP request to the
  exchange's public API. Most exchanges serve market data without authentication,
  though some may require credentials or fail for other reasons.

  Rate-limited: configurable delay between each call (default 200ms).

  Output is one JSON file per successful exchange in `priv/discoveries/load_markets/`,
  plus a manifest at `priv/discoveries/load_markets/_manifest.json`.

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

  # JS functions for loadMarkets() extraction.
  #
  # getNonAliasIds: returns sorted list of exchange IDs that are not aliases.
  #   (Same pattern as Describe — duplicated per TODO in describe.ex)
  #
  # loadMarketsForExchange: instantiates an exchange, calls loadMarkets(),
  #   and returns the full market data as JSON. Uses the prepare() sentinel
  #   pattern from Describe to preserve functions and undefined values.
  #   In practice, market data contains only __undefined sentinels (no
  #   __function: refs) — the error name resolution is defensive consistency
  #   with describe.ex's prepare().
  #   Wrapped in try/catch — returns {ok: data} or {error: message}.
  #
  # Security note: This JS code runs inside QuickBEAM (sandboxed Zig NIF runtime)
  # against the CCXT vendor bundle — no user input is involved.
  @js_setup """
  // Build map: minified Function.name → real error class name.
  // Same pattern as describe.ex — each runtime needs its own map.
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

  globalThis.loadMarketsForExchange = async function(id) {
    try {
      const ex = new ccxt[id]();
      const markets = await ex.loadMarkets();

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

      return JSON.stringify({ok: true, markets: prepare(markets), market_count: Object.keys(markets).length});
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
             "markets" => parsed["markets"]
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

  Creates `priv/discoveries/load_markets/<exchange_id>.json` for each succeeded
  exchange and `priv/discoveries/load_markets/_manifest.json` with success/failure summary.
  """
  @spec write!(map(), String.t()) :: :ok
  def write!(results, output_dir \\ CcxtExtract.Paths.priv(@output_dir)) do
    File.mkdir_p!(output_dir)

    # Remove stale .json files from previous runs
    output_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)

    extracted_at = DateTime.to_iso8601(DateTime.utc_now())

    # Write per-exchange files for succeeded exchanges
    for result <- results["succeeded"] do
      path = Path.join(output_dir, "#{result["id"]}.json")

      output = %{
        "id" => result["id"],
        "extracted_at" => extracted_at,
        "market_count" => result["market_count"],
        "markets" => result["markets"]
      }

      File.write!(path, Jason.encode!(output, pretty: true))
    end

    # Write manifest
    manifest = %{
      "extracted_at" => extracted_at,
      "succeeded_count" => length(results["succeeded"]),
      "failed_count" => length(results["failed"]),
      "succeeded" => Enum.map(results["succeeded"], & &1["id"]),
      "failed" => results["failed"]
    }

    File.write!(Path.join(output_dir, "_manifest.json"), Jason.encode!(manifest, pretty: true))
    :ok
  end

  # Get exchange IDs — boots a temporary runtime if needed
  defp list_exchange_ids(nil) do
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)
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
