defmodule CcxtExtract.SigningFixtures do
  @moduledoc """
  Generate language-agnostic signing test vectors by calling CCXT JS's
  `exchange.sign()` under frozen credentials, timestamps, and nonces.

  For each non-alias exchange, emits one JSON fixture at
  `priv/fixtures/signing/<id>.json` capturing CCXT's exact `sign()` output
  (URL, method, headers, body) for a representative matrix of requests:

    * `public_get_ticker` — a public GET endpoint
    * `private_get_balance` — a private GET endpoint (if discoverable)
    * `private_post_order` — a private POST endpoint (if discoverable)

  Each case picks a realistic path from `describe().api` rather than hardcoding
  per-exchange values. If a case is not applicable (sign() throws, endpoint
  not present), it is recorded in `skipped` with the reason — never silently
  dropped.

  These fixtures are the handoff between CCXT truth and any port (Elixir,
  Rust, Go, Python). Consumers replay the frozen inputs against their own
  signing implementation and assert byte-equal output.

  ## Frozen environment

    * `Date.now()` returns `1_700_000_000_000`
    * `Math.random()` returns `0.42`
    * `ex.nonce()` and `ex.milliseconds()` overridden to return the same
    * Credentials are conventional placeholders (`TEST_API_KEY`, 32-zero-byte
      base64 secret, etc.)

  ## Determinism

  Output is byte-identical across runs except the top-level `generated_at`.
  """

  require Logger

  @output_dir "fixtures/signing"

  # 32 zero bytes, base64-encoded.
  @secret_b64 "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  @wallet_address "0x0000000000000000000000000000000000000000"

  @frozen_ts_ms 1_700_000_000_000
  @frozen_nonce 1_700_000_000

  # JS setup: freeze time/random, define helpers to build a fixture per exchange.
  # Called once per runtime after the CCXT bundle is loaded.
  # Note: QuickBEAM.eval / sandbox pattern is identical to CcxtExtract.UrlTemplates.
  @js_setup """
  (function() {
    const FROZEN_MS = #{@frozen_ts_ms};
    const FROZEN_NONCE = #{@frozen_nonce};
    const SECRET_B64 = "#{@secret_b64}";
    const WALLET_ADDR = "#{@wallet_address}";

    // Freeze time + randomness globally.
    globalThis.Date.now = () => FROZEN_MS;
    const FrozenDate = class extends Date {
      constructor(...args) {
        if (args.length === 0) super(FROZEN_MS); else super(...args);
      }
    };
    FrozenDate.now = () => FROZEN_MS;
    FrozenDate.parse = Date.parse;
    FrozenDate.UTC = Date.UTC;
    globalThis.Date = FrozenDate;
    globalThis.Math.random = () => 0.42;

    // Freeze crypto.getRandomValues so random-nonce generators (Coinbase JWT,
    // etc.) produce deterministic output. Safe: HMAC is deterministic given
    // key + message, so this only affects paths that truly consume randomness.
    if (globalThis.crypto && globalThis.crypto.getRandomValues) {
      globalThis.crypto.getRandomValues = function(arr) {
        for (let i = 0; i < arr.length; i++) arr[i] = 0;
        return arr;
      };
    }

    // getNonAliasIds is installed by QuickbeamRuntime.install_extraction_helpers/1.

    // Walk describe().api to find leaf sections (nodes with HTTP method keys).
    function collectLeaves(api) {
      const httpMethods = new Set(['get', 'post', 'put', 'delete', 'patch']);
      const leaves = [];

      function isLeafSection(node) {
        if (!node || typeof node !== 'object') return false;
        return Object.keys(node).some(k => httpMethods.has(k));
      }

      function extractPaths(endpoints) {
        if (Array.isArray(endpoints)) {
          return endpoints.map(ep => typeof ep === 'string' ? ep : (ep && ep.path ? ep.path : String(ep)));
        }
        if (endpoints && typeof endpoints === 'object') {
          return Object.keys(endpoints);
        }
        return [];
      }

      function walk(node, path) {
        if (!node || typeof node !== 'object') return;
        if (isLeafSection(node)) {
          const methods = {};
          for (const m of httpMethods) {
            if (node[m] !== undefined) {
              const paths = extractPaths(node[m]);
              if (paths.length > 0) methods[m.toUpperCase()] = paths;
            }
          }
          if (Object.keys(methods).length > 0) {
            leaves.push({
              key_path: [...path],
              api_param: path.length === 1 ? path[0] : [...path],
              http_methods: methods
            });
          }
          return;
        }
        for (const key of Object.keys(node)) {
          if (httpMethods.has(key)) continue;
          walk(node[key], [...path, key]);
        }
      }

      walk(api, []);
      return leaves;
    }

    // Tokenize a CCXT path into lowercase tokens.
    // Splits on separators (`_ - / .`) and CamelCase transitions
    // (`aB`, `ABc`). Tokenization avoids the case-insensitive regex boundary
    // trap: a naive `(?<=[a-z])(?=[A-Z])` under `/i` degrades to "any letter
    // to any letter", which falsely matched `account` inside
    // `change_subaccount_name` (the `b→a` transition).
    function tokenize(path) {
      const out = [];
      for (const seg of path.split(/[_\\-\\/.]+/)) {
        if (!seg) continue;
        // Split CamelCase: e.g. "GetTickerHistory" -> ["Get","Ticker","History"];
        // "URLParser" -> ["URL","Parser"]; "getticker" -> ["getticker"].
        const parts = seg.split(/(?=[A-Z][a-z])|(?<=[a-z])(?=[A-Z])/);
        for (const p of parts) if (p) out.push(p.toLowerCase());
      }
      return out;
    }

    const VERB_PREFIX = '(?:get|post|send|place|submit|create|cancel|list)';

    // Two-pass token matcher. Pass 1: any tokenized segment equals one of
    // the target keywords (handles separator-split and CamelCase-split
    // paths). Pass 2: a single concatenated lowercase token begins with a
    // CCXT verb and ends with the target (handles `getticker`,
    // `sendchildorder`). Pass 2 only fires when pass 1 misses across all
    // candidate paths, preserving strictness where possible.
    function pickCase(leaves, visibility, httpMethod, exactTokens, fuzzyTargets) {
      // Visibility is matched exact-first, substring-second. Exchanges like
      // aster (`fapiPrivate`) and grvt (`privateEdge`, `privateTrading`)
      // encode visibility as a prefix/suffix rather than a standalone
      // segment; substring fallback covers those without loosening far
      // enough to leak unrelated segments in.
      const matching = leaves.filter(function(leaf) {
        return leaf.key_path.some(function(seg) {
          const s = seg.toLowerCase();
          return s === visibility || s.indexOf(visibility) >= 0;
        });
      });
      const exactSet = new Set(exactTokens);
      const fuzzyRx = new RegExp('^' + VERB_PREFIX + '[a-z0-9]*(?:' + fuzzyTargets.join('|') + ')$');

      for (const leaf of matching) {
        const paths = leaf.http_methods[httpMethod];
        if (!paths) continue;
        for (const p of paths) {
          const toks = tokenize(p);
          if (toks.some(t => exactSet.has(t))) {
            return { api_param: leaf.api_param, method: httpMethod, path: p };
          }
        }
      }
      for (const leaf of matching) {
        const paths = leaf.http_methods[httpMethod];
        if (!paths) continue;
        for (const p of paths) {
          const toks = tokenize(p);
          if (toks.length === 1 && fuzzyRx.test(toks[0])) {
            return { api_param: leaf.api_param, method: httpMethod, path: p };
          }
        }
      }
      return null;
    }

    function toPlain(v) {
      if (v === undefined || v === null) return null;
      if (typeof v !== 'object') return v;
      if (Array.isArray(v)) return v.map(toPlain);
      const out = {};
      for (const k of Object.keys(v)) out[k] = toPlain(v[k]);
      return out;
    }

    function buildCase(ex, name, picked, params) {
      if (!picked) return { skipped: { name: name, reason: 'no matching endpoint in describe().api' } };
      const input = {
        path: picked.path,
        api: picked.api_param,
        method: picked.method,
        params: params || {},
        headers: null,
        body: null
      };
      function doSign() {
        const signed = ex.sign(picked.path, picked.api_param, picked.method, params || {});
        return {
          url: signed && signed.url != null ? signed.url : null,
          method: signed && signed.method != null ? signed.method : picked.method,
          headers: signed && signed.headers != null ? toPlain(signed.headers) : null,
          body: signed && signed.body != null ? signed.body : null
        };
      }
      function fmtErr(e) {
        return (e && e.constructor ? e.constructor.name : 'Error') +
               ': ' + (e && e.message ? e.message : String(e));
      }
      // TODO: Secret-format retry is a workaround for CCXT not exposing the
      // expected secret format declaratively. Orderly-family exchanges
      // (woofipro, modetrade) run `secret` through a base58 decoder and
      // reject base64 `=` padding. When a format-specific decode error fires,
      // re-seed with a base58-safe 32-zero placeholder and retry once. If
      // CCXT ever exposes `secretFormat` (or similar) per exchange, replace
      // this retry with an upfront format-aware placeholder lookup.
      try {
        return { case: { name: name, input: input, output: doSign() } };
      } catch (e) {
        const msg = e && e.message ? String(e.message) : String(e);
        if (/Unknown letter|not valid base58|base58/i.test(msg)) {
          try {
            // Base58 string decoding to 32 bytes: 31 leading "1"s = 31 zero
            // bytes, then "2" = 0x01. Matches woofipro.ts:2975's
            // `base58ToBinary(secret)` → ed25519 32-byte seed requirement.
            ex.secret = '1'.repeat(31) + '2';
            return { case: { name: name, input: input, output: doSign() } };
          } catch (e2) {
            return { skipped: { name: name, reason: fmtErr(e2), input: input } };
          }
        }
        return { skipped: { name: name, reason: fmtErr(e), input: input } };
      }
    }

    globalThis.buildSigningFixture = function(id) {
      const fixture = {
        exchange: id,
        ccxt_version: ccxt.version || null,
        generated_at: null,
        credentials: {
          apiKey: "account-TEST_API_KEY",
          secret: SECRET_B64,
          password: null,
          uid: null
        },
        frozen: {
          timestamp_ms: FROZEN_MS,
          nonce: FROZEN_NONCE
        },
        cases: [],
        skipped: []
      };

      let ex;
      try {
        ex = new ccxt[id]();
      } catch (e) {
        fixture.errors = [{
          phase: 'instantiation',
          reason: (e && e.constructor ? e.constructor.name : 'Error') +
                  ': ' + (e && e.message ? e.message : String(e))
        }];
        return JSON.stringify(fixture);
      }

      // Iterate requiredCredentials so custom fields (accountId, login, etc.)
      // are seeded alongside the common ones. Known credentials get purpose-
      // built placeholders; unknown required credentials get a generic string
      // so private cases are at least attempted rather than silently skipped.
      const req = ex.requiredCredentials || {};
      // apiKey contains the literal substring "account" so Gemini's master-key
      // guard (priv/ccxt/ts/src/gemini.ts:1950: `apiKey.indexOf('account') < 0`)
      // accepts it. Other exchanges treat apiKey opaquely, so the prefix is
      // harmless elsewhere.
      // privateKey is 64-char hex (valid 32-byte key) so derive's parser
      // (`private key must be 32 bytes, hex or bigint`) accepts it.
      const placeholders = {
        apiKey: "account-TEST_API_KEY",
        secret: SECRET_B64,
        password: "TEST_PASSPHRASE",
        uid: "TEST_UID",
        login: "TEST_LOGIN",
        accountId: "TEST_ACCOUNT_ID",
        privateKey: "0".repeat(63) + "1",
        walletAddress: WALLET_ADDR,
        twofa: "TEST_TWOFA",
        token: "TEST_TOKEN"
      };
      // apiKey + secret are seeded regardless (most exchanges require them,
      // and CCXT's `checkRequiredCredentials` treats false entries as opt-out
      // rather than forbid-set).
      ex.apiKey = placeholders.apiKey;
      ex.secret = placeholders.secret;
      for (const key of Object.keys(req)) {
        if (!req[key]) continue;
        const value = placeholders[key] != null ? placeholders[key] : ("TEST_" + key.toUpperCase());
        ex[key] = value;
        fixture.credentials[key] = value;
      }

      // Freeze nonces on the instance.
      ex.nonce = () => FROZEN_NONCE;
      ex.milliseconds = () => FROZEN_MS;
      ex.seconds = () => Math.floor(FROZEN_MS / 1000);
      ex.microseconds = () => FROZEN_MS * 1000;
      ex.iso8601 = (ts) => new Date(ts == null ? FROZEN_MS : ts).toISOString();
      // Freeze CCXT's random helpers (used by Coinbase JWT nonce, etc.).
      ex.randomBytes = (n) => '0'.repeat(n * 2);
      ex.uuid = () => "00000000-0000-0000-0000-000000000000";
      ex.uuid16 = () => "00000000000000000000000000000000";
      ex.uuid22 = () => "0000000000000000000000";

      let leaves;
      try {
        leaves = collectLeaves(ex.describe().api);
      } catch (e) {
        fixture.errors = [{
          phase: 'describe',
          reason: (e && e.constructor ? e.constructor.name : 'Error') +
                  ': ' + (e && e.message ? e.message : String(e))
        }];
        return JSON.stringify(fixture);
      }

      // Exact tokens are matched against tokenize(path) entries (case-folded).
      // Fuzzy targets are regex fragments matched against a single-token path
      // that starts with a verb (handles `getticker`, `sendchildorder`).
      const tickerCase = pickCase(leaves, 'public',  'GET',
        ['tick', 'ticker', 'tickers', 'symbol', 'symbols', 'market', 'markets', 'instrument', 'instruments'],
        ['ticker?s?', 'symbols?', 'markets?', 'instruments?']);
      const balanceCase = pickCase(leaves, 'private', 'GET',
        ['balance', 'balances', 'account', 'accounts', 'wallet', 'wallets', 'portfolio', 'portfolios'],
        ['balances?', 'accounts?', 'wallets?', 'portfolios?']);
      const orderCase = pickCase(leaves, 'private', 'POST',
        ['order', 'orders'],
        ['orders?']);

      const orderParams = { symbol: "BTC/USDT", type: "limit", side: "buy", amount: 1, price: 1 };

      const specs = [
        ['public_get_ticker',   tickerCase,  {}],
        ['private_get_balance', balanceCase, {}],
        ['private_post_order',  orderCase,   orderParams]
      ];

      for (const [name, picked, params] of specs) {
        const r = buildCase(ex, name, picked, params);
        if (r.case)    fixture.cases.push(r.case);
        if (r.skipped) fixture.skipped.push(r.skipped);
      }

      return JSON.stringify(fixture);
    }
  })();
  """

  @doc """
  Extract signing fixtures for all (or scoped) non-alias exchanges.

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. Applied
      Elixir-side after the JS runtime reports the full universe.
  """
  @spec extract(keyword()) :: {:ok, [map()]}
  def extract(extract_opts \\ []) do
    scope = Keyword.get(extract_opts, :scope, :all)
    {:ok, rt} = CcxtExtract.QuickbeamRuntime.start()

    try do
      :ok = CcxtExtract.QuickbeamRuntime.install_extraction_helpers(rt)
      {:ok, _} = QuickBEAM.eval(rt, @js_setup)
      {:ok, ids_json} = QuickBEAM.call(rt, "getNonAliasIds", [])

      ids =
        ids_json
        |> Jason.decode!()
        |> CcxtExtract.TaskScope.filter_ids(scope)

      Logger.info("Building signing fixtures for #{length(ids)} exchanges...")

      results = CcxtExtract.Progress.map(ids, &extract_one(rt, &1))

      {:ok, results}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  defp existing_ccxt_version(manifest_path) do
    with true <- File.exists?(manifest_path),
         {:ok, body} <- File.read(manifest_path),
         {:ok, %{"ccxt_version" => v}} <- Jason.decode(body) do
      v
    else
      _ -> nil
    end
  end

  @doc """
  Extract a single exchange fixture from an active runtime.
  """
  @spec extract_one(pid(), String.t()) :: map()
  def extract_one(rt, id) do
    {:ok, json} = QuickBEAM.call(rt, "buildSigningFixture", [id])
    Jason.decode!(json)
  end

  @doc """
  Write fixtures to `priv/fixtures/signing/<id>.json` plus a `_manifest.json`.

  Injects `generated_at` (ISO8601) and re-encodes each fixture with
  `pretty: true`. All other fields are byte-identical across runs.

  Options:

    * `:scope` — `:all` (default) or `MapSet.t(String.t())`. When `:all`,
      prunes fixtures on disk not produced by this run via
      `ScopeCleanup.prune_out_of_scope/3` (universe reassertion). When a
      MapSet, out-of-scope fixtures from prior runs are preserved.
    * `:tier_scope` — value from `CcxtExtract.Scope.to_manifest_value/1`,
      stamped into the manifest. Defaults to `"all"`.
    * `:output_dir` — override output directory (mostly for tests).

  The manifest's `exchanges`, `count`, and `ccxt_version` are rebuilt from
  disk after the write: `exchanges` comes from
  `TaskScope.rebuild_manifest_exchanges/1`; `ccxt_version` comes from this
  run's first fixture (CCXT bundle is global per run, so scoped runs
  inherit the current bundle version); if this run produced no fixtures,
  the existing manifest's `ccxt_version` is preserved.
  """
  @spec write!([map()], keyword()) :: :ok
  def write!(results, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    output_dir = Keyword.get(opts, :output_dir, CcxtExtract.Paths.priv(@output_dir))

    File.mkdir_p!(output_dir)

    generated_at = DateTime.to_iso8601(DateTime.utc_now())

    Enum.each(results, fn fixture ->
      id = fixture["exchange"]
      path = Path.join(output_dir, "#{id}.json")
      stamped = Map.put(fixture, "generated_at", generated_at)
      File.write!(path, Jason.encode!(stamped, pretty: true))
    end)

    if scope == :all do
      produced = MapSet.new(results, & &1["exchange"])
      {:ok, _removed} = CcxtExtract.ScopeCleanup.prune_out_of_scope(output_dir, produced)
    end

    manifest_ids = CcxtExtract.TaskScope.rebuild_manifest_exchanges(output_dir)
    manifest_path = Path.join(output_dir, "_manifest.json")

    ccxt_version =
      case results do
        [first | _] -> first["ccxt_version"]
        [] -> existing_ccxt_version(manifest_path)
      end

    manifest = %{
      "generated_at" => generated_at,
      "ccxt_version" => ccxt_version,
      "count" => length(manifest_ids),
      "tier_scope" => tier_scope,
      "exchanges" => manifest_ids
    }

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    :ok
  end
end
