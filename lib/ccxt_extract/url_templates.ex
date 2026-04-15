defmodule CcxtExtract.UrlTemplates do
  @moduledoc """
  Extract URL templates for all CCXT exchanges via QuickBEAM.

  For each exchange, walks the `describe().api` tree to find leaf sections
  (those with HTTP method keys like `get`, `post`, etc.), picks the first
  endpoint from each section, and calls `sign()` to capture the fully
  resolved URL. This reveals path prefixes injected by `sign()` that aren't
  visible in the describe data alone (e.g., OKX's `/api/v5/`, KuCoin's
  `/api/v2/`, Gate's `/spot/`).

  Output per section includes the raw probe inputs (`api_param`, `http_method`,
  `sample_path`) and the authoritative result (`resolved_url`), plus a derived
  `url_prefix` (stripped `sample_path` from `resolved_url`) when provably correct.
  Suffix-mutation exchanges (bit2c adds `.json`, lbank adds `.do`) get
  `url_prefix: null` — honest signal that the prefix can't be proven.

  Output is a single JSON file at `priv/discoveries/url_templates.json`
  with the standard envelope: `{extracted_at, count, exchanges: [...]}`.

  ## Usage

      {:ok, results} = CcxtExtract.UrlTemplates.extract()
      CcxtExtract.UrlTemplates.write!(results)

  ## Scope

  `extract/1` accepts `:scope` (default `:all`, or a `MapSet` of exchange IDs)
  to narrow the probe list. `write!/2` accepts `:scope` and `:tier_scope` and
  delegates to `CcxtExtract.AggregateWriter` so scoped runs merge cleanly with
  any existing aggregate.
  """

  require Logger

  @output_file "discoveries/url_templates.json"

  # JS functions for URL template extraction.
  #
  # extractUrlTemplates(id): instantiates exchange, walks describe().api
  # recursively to find leaf sections, picks first endpoint from each,
  # calls sign() to capture the resolved URL.
  #
  # Section keys are dot-joined for nested sections: "public.spot", "private.delivery".
  # The api param passed to sign() is a string for flat sections or an array for nested ones.
  #
  # Gate-style exchanges use array api params: sign(path, ["public", "spot"], ...).
  # Most exchanges use string api params: sign(path, "public", ...).
  #
  # Security note: This JS code runs inside QuickBEAM (sandboxed Zig NIF runtime)
  # against the CCXT vendor bundle — no user input is involved.
  @js_setup """
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

  globalThis.extractUrlTemplates = function(id) {
    const ex = new ccxt[id]();
    const d = ex.describe();
    const api = d.api;
    const httpMethods = new Set(['get', 'post', 'put', 'delete', 'patch']);
    const result = {};

    // Check if a node is a leaf section (has HTTP method keys)
    function isLeafSection(node) {
      if (!node || typeof node !== 'object') return false;
      return Object.keys(node).some(k => httpMethods.has(k));
    }

    // Derive url_prefix: strip sample_path from end of resolved_url.
    // Only when resolved_url cleanly ends with sample_path — null otherwise.
    // Suffix-mutation exchanges (bit2c adds .json, lbank adds .do, zonda adds .json)
    // get null — honest signal that the prefix can't be proven.
    // Empty sample_path means the section has no path component — resolved_url is the prefix.
    function deriveUrlPrefix(resolvedUrl, samplePath) {
      if (!resolvedUrl) return null;
      if (typeof samplePath !== 'string') return null;
      if (samplePath === '') return resolvedUrl;
      if (resolvedUrl.endsWith(samplePath)) {
        return resolvedUrl.substring(0, resolvedUrl.length - samplePath.length);
      }
      return null;
    }

    // Walk the api tree recursively
    function walkApi(node, path) {
      if (!node || typeof node !== 'object') return;

      if (isLeafSection(node)) {
        // Found a leaf — pick the first endpoint from the first HTTP method
        let samplePath = null;
        let sampleMethod = 'GET';
        for (const method of httpMethods) {
          const endpoints = node[method];
          if (Array.isArray(endpoints) && endpoints.length > 0) {
            // Endpoints can be strings or objects with path key
            const ep = endpoints[0];
            samplePath = typeof ep === 'string' ? ep : (ep && ep.path ? ep.path : String(ep));
            sampleMethod = method.toUpperCase();
            break;
          } else if (typeof endpoints === 'object' && endpoints !== null && !Array.isArray(endpoints)) {
            // Object-style endpoints (key = path)
            const keys = Object.keys(endpoints);
            if (keys.length > 0) {
              samplePath = keys[0];
              sampleMethod = method.toUpperCase();
              break;
            }
          }
        }

        if (samplePath === null) return;

        const sectionKey = path.join('.');

        // Build the api param: string for single-level, array for multi-level
        const apiParam = path.length === 1 ? path[0] : [...path];

        let resolvedUrl = null;
        try {
          const signed = ex.sign(samplePath, apiParam, sampleMethod);
          resolvedUrl = signed.url || null;
        } catch(e) {
          // Expected failures — sign() throws for private sections without
          // credentials, sections missing from urls.api, or malformed paths.
          // resolved_url stays null — honest signal that sign() could not resolve.
          // Consumers can cross-reference runtime.describe.urls.api for the base URL.
        }

        // Normalize resolved URL for stable consumer derivation:
        // 1. Strip query strings — sign() may append auth params (timestamps, signatures)
        // 2. Normalize doubled slashes in path (e.g., big.one/api//v3 → big.one/api/v3)
        if (resolvedUrl) {
          const qIdx = resolvedUrl.indexOf('?');
          if (qIdx !== -1) resolvedUrl = resolvedUrl.substring(0, qIdx);
          const proto = resolvedUrl.indexOf('://');
          if (proto !== -1) {
            resolvedUrl = resolvedUrl.substring(0, proto + 3) +
                          resolvedUrl.substring(proto + 3).split('//').join('/');
          }
        }

        result[sectionKey] = {
          api_param: apiParam,
          http_method: sampleMethod,
          sample_path: samplePath,
          resolved_url: resolvedUrl,
          url_prefix: deriveUrlPrefix(resolvedUrl, samplePath)
        };
        return;
      }

      // Not a leaf — recurse into children
      for (const key of Object.keys(node)) {
        if (httpMethods.has(key)) continue;
        walkApi(node[key], [...path, key]);
      }
    }

    walkApi(api, []);
    return JSON.stringify({ id: id, url_templates: result });
  }
  """

  @doc """
  Extract URL templates for all (or scoped) non-alias exchanges.

  Starts a QuickBEAM runtime, enumerates non-alias exchange IDs, filters by
  `:scope` if a `MapSet` is supplied, then extracts each exchange's URL
  templates. Returns a sorted list of
  `%{"id" => id, "url_templates" => templates_map}` maps.

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. Applied
      Elixir-side after the JS runtime reports the full universe.
  """
  @spec extract(keyword()) :: {:ok, [map()]}
  def extract(opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)
      {:ok, ids_json} = QuickBEAM.call(rt, "getNonAliasIds", [])

      ids =
        ids_json
        |> Jason.decode!()
        |> CcxtExtract.TaskScope.filter_ids(scope)

      Logger.info("Extracting URL templates for #{length(ids)} exchanges...")

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
  Extract URL templates for a single exchange from an active runtime.
  """
  @spec extract_one(pid(), String.t()) :: map()
  def extract_one(rt, id) do
    {:ok, json} = QuickBEAM.call(rt, "extractUrlTemplates", [id])
    Jason.decode!(json)
  end

  @doc """
  Write URL templates to `priv/discoveries/url_templates.json`.

  Routes through `CcxtExtract.AggregateWriter` so scoped runs merge with any
  existing aggregate: in-scope entries are replaced, out-of-scope entries are
  preserved, and `count` is recomputed from the final merged list.

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. Forwarded to
      `AggregateWriter`.
    * `:tier_scope` — value from `CcxtExtract.Scope.to_manifest_value/1`.
      Stamped into the envelope. Defaults to `"all"`.
    * `:output_path` — override output location (mostly for tests).
  """
  @spec write!([map()], keyword()) :: :ok
  def write!(results, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    output_path = Keyword.get(opts, :output_path, CcxtExtract.Paths.priv(@output_file))

    CcxtExtract.AggregateWriter.write!(output_path, results,
      entry_key: "exchanges",
      id_key: "id",
      scope: scope,
      tier_scope: tier_scope,
      stats_fn: fn _entries -> %{} end
    )
  end
end
