defmodule CcxtExtract.RateLimitCosts do
  @moduledoc """
  Extract per-endpoint rate-limit cost from each CCXT exchange's resolved
  `describe().api` map via QuickBEAM.

  CCXT exchanges declare per-endpoint rate-limit cost under
  `api.<group>.<verb>.<endpoint>`. The endpoint config is one of three
  shapes (per `priv/ccxt/ts/src/base/Exchange.ts`'s `defineRestApi/3`):

    * **Number** — the cost weight (e.g. `1`, `0.5`, `2`).
    * **Object** with a `cost` key plus optional weight-axis variants
      (e.g. `{cost: 0.1, noCoin: 0.5}`,
      `{cost: 1, byLimit: [[99, 1], [499, 2], …]}`).
    * **Array of paths** — bare list of endpoint strings, no per-endpoint
      cost. Effective cost is the CCXT default `1` (verified at
      `Exchange.ts:1399` via `this.safeValue(options, 'cost', 1)`).

  The bucket configuration (refill rate, axes — Task 89/A-4) is a
  separate concern and not extracted here. This module reports per-
  endpoint **cost weights only**; `rate_limit` (the base millisecond
  throttle) lives in `runtime.describe.rateLimit`.

  ## Output shape

  Per exchange:

      %{
        "id" => "binance",
        "rate_limit_costs" => %{
          "sapi.get.system/status" => %{"cost" => 0.1, "axes" => %{}},
          "sapi.get.margin/crossMarginData" =>
            %{"cost" => 0.1, "axes" => %{"noCoin" => 0.5}},
          "public.get.market/tickers" => %{"cost" => 1, "axes" => %{}}
        }
      }

  Section path is dot-joined: `<section_path>.<http_verb>.<endpoint_path>`.
  Nested sections (e.g. OKX's `public.get.*`) join their parent keys with
  dots; flat sections (e.g. binance's `sapi.get.*`) start at the
  top-level group name. Mirrors the dot-join convention used by
  `CcxtExtract.UrlTemplates`.

  Each entry's `cost` is a number (never `null` in practice — endpoints
  with no declared cost get the CCXT default of `1`). `axes` is an
  object mapping axis name (e.g. `"noCoin"`, `"noSymbol"`, `"byLimit"`)
  to its variant cost. Axis values can be numbers, arrays, or other
  shapes — preserved verbatim from CCXT.

  ## Out of scope

  The bucket configuration (Task 89/A-4) — refill rate, axis identity
  (IP / UID / order-weight) — is not extracted here. CCXT's
  `rateLimit` field (top-level on each exchange's describe) is the
  base throttle in milliseconds; per-endpoint cost is a multiplier
  against that bucket. The two concerns ship in sibling tasks of the
  same 11+14 bundle.

  Computed costs (e.g. paradex's `cost: () => …` lambda) cannot be
  resolved by static `describe()` walk and surface as `cost: null`
  with `axes: %{}`. This is rare — the vast majority of CCXT exchanges
  declare static cost values.

  Output is a single JSON file at `priv/discoveries/rate_limit_costs.json`
  with the standard envelope: `{extracted_at, count, exchanges: [...]}`.

  ## Usage

      {:ok, results} = CcxtExtract.RateLimitCosts.extract()
      CcxtExtract.RateLimitCosts.write!(results)

  ## Scope

  `extract/1` accepts `:scope` (default `:all`, or a `MapSet` of exchange
  IDs) to narrow the probe list. `write!/2` accepts `:scope` and
  `:tier_scope` and delegates to `CcxtExtract.AggregateWriter` so scoped
  runs merge cleanly with any existing aggregate.
  """

  require Logger

  @output_file "discoveries/rate_limit_costs.json"

  # JS function for per-endpoint rate-limit cost extraction.
  #
  # extractRateLimitCosts(id): instantiates exchange, walks describe().api
  # recursively to find HTTP-verb keys (get/post/put/delete/head/patch),
  # enumerates each endpoint and captures its cost configuration. Output
  # keys are dot-joined section paths (mirrors UrlTemplates convention).
  #
  # CCXT's defineRestApi (priv/ccxt/ts/src/base/Exchange.ts:731) walks the
  # api tree the same way: any non-HTTP-verb key recurses into a sub-map;
  # any HTTP-verb key reads its endpoints. The endpoint config is one of:
  #   - number → cost = N, axes = {}
  #   - object → cost = obj.cost (default 1), axes = obj minus 'cost'
  #   - bare array of strings → cost = 1, axes = {} (CCXT default per
  #     safeValue(options, 'cost', 1) in Exchange.ts:1399)
  #
  # We use the JSON sentinel "__undefined" for non-resolvable values
  # (functions, undefined). Consumers reading the discovery JSON treat
  # any non-numeric `cost` as the "computed cost" sentinel.
  #
  # Security note: This JS code runs inside QuickBEAM (sandboxed Zig NIF
  # runtime) against the CCXT vendor bundle — no user input is involved.
  @js_setup """
  globalThis.extractRateLimitCosts = function(id) {
    const ex = new ccxt[id]();
    const d = ex.describe();
    const api = d.api;
    const httpMethods = new Set(['get', 'post', 'put', 'delete', 'head', 'patch']);
    const result = {};

    function isLeafSection(node) {
      if (!node || typeof node !== 'object' || Array.isArray(node)) return false;
      return Object.keys(node).some(k => httpMethods.has(k));
    }

    // Normalize an endpoint config into {cost, axes}. Returns null when
    // config is unresolvable (function literal, undefined, malformed).
    function normalizeConfig(config) {
      if (typeof config === 'number') {
        return { cost: config, axes: {} };
      }
      if (config && typeof config === 'object' && !Array.isArray(config)) {
        const cost = (typeof config.cost === 'number') ? config.cost : null;
        const axes = {};
        for (const k of Object.keys(config)) {
          if (k === 'cost') continue;
          axes[k] = config[k];
        }
        return { cost: cost, axes: axes };
      }
      // Functions, undefined, unsupported shapes — surface as null cost
      // with no axes. The Honesty Rule: null + empty axes signals
      // "unresolvable from describe()" rather than fabricating a cost.
      return { cost: null, axes: {} };
    }

    function recordEndpoints(sectionPath, verb, endpoints) {
      if (Array.isArray(endpoints)) {
        // Bare array of paths — CCXT's defineRestApi calls
        // defineRestApiEndpoint without a config, so the throttle uses
        // the default cost = 1 (Exchange.ts:1399).
        for (let i = 0; i < endpoints.length; i++) {
          const path = endpoints[i];
          if (typeof path !== 'string') continue;
          const key = sectionPath + '.' + verb + '.' + path;
          result[key] = { cost: 1, axes: {} };
        }
        return;
      }
      if (endpoints && typeof endpoints === 'object') {
        for (const path of Object.keys(endpoints)) {
          const key = sectionPath + '.' + verb + '.' + path;
          result[key] = normalizeConfig(endpoints[path]);
        }
      }
    }

    // Walk the api tree recursively, collecting endpoints under each
    // HTTP-verb key. Mirrors CCXT defineRestApi's traversal exactly.
    function walkApi(node, path) {
      if (!node || typeof node !== 'object' || Array.isArray(node)) return;

      if (isLeafSection(node)) {
        const sectionPath = path.join('.');
        for (const verb of Object.keys(node)) {
          if (httpMethods.has(verb)) {
            recordEndpoints(sectionPath, verb, node[verb]);
          }
        }
        return;
      }

      for (const key of Object.keys(node)) {
        if (httpMethods.has(key)) continue;
        walkApi(node[key], [...path, key]);
      }
    }

    if (api && typeof api === 'object') {
      walkApi(api, []);
    }

    return JSON.stringify({ id: id, rate_limit_costs: result });
  }
  """

  @doc """
  Always-present empty record used by callers that want a stable shape
  for an exchange with no extracted entry. Mirrors the JS extractor's
  output for an exchange with no api map (e.g. some pure-WS aliases).
  """
  @spec empty_record() :: %{}
  def empty_record, do: %{}

  @doc """
  Extract per-endpoint rate-limit costs for all (or scoped) non-alias
  exchanges.

  Starts a QuickBEAM runtime, enumerates non-alias exchange IDs, filters
  by `:scope` if a `MapSet` is supplied, then extracts each exchange's
  per-endpoint cost map. Returns a sorted list of
  `%{"id" => id, "rate_limit_costs" => costs_map}` maps.

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. Applied
      Elixir-side after the JS runtime reports the full universe.
  """
  @spec extract(keyword()) :: {:ok, [map()]}
  def extract(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      :ok = CcxtExtract.QuickbeamRuntime.install_extraction_helpers(rt)
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)
      {:ok, ids_json} = QuickBEAM.call(rt, "getNonAliasIds", [])

      ids =
        ids_json
        |> Jason.decode!()
        |> CcxtExtract.TaskScope.filter_ids(scope)

      Logger.info("Extracting rate-limit costs for #{length(ids)} exchanges...")

      results = CcxtExtract.Progress.map(ids, &extract_one(rt, &1))

      {:ok, results}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Extract per-endpoint rate-limit costs for a single exchange from an
  active runtime.
  """
  @spec extract_one(pid(), String.t()) :: map()
  def extract_one(rt, id) do
    {:ok, json} = QuickBEAM.call(rt, "extractRateLimitCosts", [id])
    Jason.decode!(json)
  end

  @doc """
  Write per-endpoint rate-limit costs to
  `priv/discoveries/rate_limit_costs.json`.

  Routes through `CcxtExtract.AggregateWriter` so scoped runs merge with
  any existing aggregate: in-scope entries are replaced, out-of-scope
  entries are preserved, and `count` is recomputed from the final
  merged list. Envelope `total_endpoints` is also recomputed from the
  merged entries (drift-guard).

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. Forwarded
      to `AggregateWriter`.
    * `:tier_scope` — value from `CcxtExtract.Scope.to_manifest_value/1`.
      Stamped into the envelope. Defaults to `"all"`.
    * `:output_path` — override output location (mostly for tests).
  """
  @spec write!([map()], keyword()) :: :ok
  def write!(results, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    output_path = Keyword.get(opts, :output_path, CcxtExtract.Paths.out(@output_file))

    CcxtExtract.AggregateWriter.write!(output_path, results,
      entry_key: "exchanges",
      id_key: "id",
      scope: scope,
      tier_scope: tier_scope,
      stats_fn: &compute_stats/1
    )
  end

  # Drift-guard envelope stats: counts derive from the final merged
  # entries, not whatever the in-memory caller computed pre-merge.
  @spec compute_stats([map()]) :: map()
  defp compute_stats(entries) do
    total =
      Enum.reduce(entries, 0, fn entry, acc ->
        case Map.get(entry, "rate_limit_costs") do
          costs when is_map(costs) -> acc + map_size(costs)
          _ -> acc
        end
      end)

    with_costs =
      Enum.count(entries, fn entry ->
        case Map.get(entry, "rate_limit_costs") do
          costs when is_map(costs) and map_size(costs) > 0 -> true
          _ -> false
        end
      end)

    %{"with_rate_limit_costs" => with_costs, "total_endpoints" => total}
  end
end
