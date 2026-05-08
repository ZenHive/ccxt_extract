defmodule CcxtExtract.RateLimitBuckets do
  @moduledoc """
  Extract per-exchange rate-limit bucket configuration via QuickBEAM.

  CCXT throttles outbound requests via a token-bucket model assembled in
  `Exchange.initRestRateLimiter()` (see `priv/ccxt/ts/src/base/Exchange.ts`).
  After construction, every exchange instance carries a resolved bucket
  shape across four fields:

    * `this.rateLimit` (ms) — milliseconds between requests at the bucket's
      drain rate. Single-axis canonical throttle.
    * `this.rollingWindowSize` (ms) — non-zero for rolling-window-style
      exchanges (e.g. binance's 60s weight window).
    * `this.rateLimiterAlgorithm` (`"leakyBucket"` | `"rollingWindow"`).
    * `this.tokenBucket` — the merged bucket map after deepExtend with the
      base defaults: `{delay, capacity, cost, refillRate, algorithm,
      windowSize, rateLimit}`.

  ## Output shape

      %{
        "id" => "binance",
        "rate_limit_buckets" => %{
          "buckets" => [
            %{
              "axes" => ["request"],
              "rate_limit_ms" => 50.0,
              "refill_per_sec" => 20.0,
              "max_size" => 1.0,
              "cost_default" => 1.0,
              "algorithm" => "leakyBucket",
              "rolling_window_ms" => 60_000.0
            }
          ],
          "source" => "describe",
          "unresolved_reason" => nil
        }
      }

  Each bucket entry is an independent throttle dimension. Today every
  exchange resolves to exactly one bucket (the default request-rate
  throttle); the wrapper is shipped as a list to leave room for
  multi-bucket exchanges (binance UID/IP, okx per-account) that A-2's
  per-method cost weighting and follow-on tasks may surface.

  `axes` lists the call-shape attributes that count against the bucket.
  Today always `["request"]`; `["weight"]` is reserved for A-2 method-cost
  weighting.

  `source` records where the bucket data came from (always `"describe"`
  today — `tokenBucket` and `method_body` are reserved for future-proofing).

  `unresolved_reason` is non-null when the extractor could not produce a
  usable bucket — `"instantiation_failed"` (constructor threw, e.g.
  describe lookup mid-construction blew up) or `"rate_limit_unset"`
  (rateLimit is missing/-1 — base CCXT requires it but a misconfigured
  override could still emit the field).

  ## Out of scope

  Per-method cost weighting (e.g. binance's `weight=10` on
  `account/snapshot`) is A-2 (Task 88)'s territory — it lives in
  `describe.api[*]` leaf values, not in the bucket config.

  The "multi-axis" cases the issue mentions (binance UID/IP buckets,
  okx per-account, kraken counter increments) are NOT modeled in
  CCXT's runtime — CCXT throttles every request through the single
  resolved bucket. Capturing those wire-level distinctions would
  require parsing exchange API responses, which is well outside this
  extractor's surface. The shape leaves room for a later task to
  promote `axes` to `["uid", "ip"]` etc. without a schema break.

  ## Usage

      {:ok, results} = CcxtExtract.RateLimitBuckets.extract()
      CcxtExtract.RateLimitBuckets.write!(results)
  """

  require Logger

  @output_file "discoveries/rate_limit_buckets.json"

  # JS function for rate-limit bucket extraction.
  #
  # extractRateLimitBuckets(id): instantiates the exchange (which triggers
  # the deepExtend(super.describe(), {...}) merge AND
  # initRestRateLimiter() in the base Exchange constructor), then reads
  # the resolved instance fields. Per `priv/ccxt/ts/src/base/Exchange.ts`
  # lines 339-345 + 3531-3553, a healthy instance always carries:
  #
  #   - rateLimit: number (ms; default 2000, throws if undefined or -1)
  #   - rateLimiterAlgorithm: string ("leakyBucket" default)
  #   - rollingWindowSize: number (default undefined → falsy)
  #   - tokenBucket: { delay, capacity, cost, refillRate, algorithm,
  #                    windowSize, rateLimit }  (built by initRestRateLimiter)
  #
  # We surface rate_limit_ms / rolling_window_ms / algorithm verbatim, plus
  # the merged tokenBucket-derived size + cost. refill_per_sec is derived
  # (1000 / rate_limit_ms) so consumers don't have to recompute it.
  #
  # Try/catch wraps instantiation so a single broken exchange surfaces as
  # an honest empty record (`unresolved_reason: "instantiation_failed"`)
  # rather than killing the whole extraction run.
  #
  # Security note: this JS source runs inside QuickBEAM (sandboxed Zig NIF
  # runtime) against the CCXT vendor bundle — no user input involved.
  # Mirrors the pattern in `CcxtExtract.RequestHeaders` and
  # `CcxtExtract.UrlTemplates`.
  @js_setup """
  globalThis.extractRateLimitBuckets = function(id) {
    try {
      const ex = new ccxt[id]();
      const rl = ex.rateLimit;
      const rws = ex.rollingWindowSize;
      const algo = ex.rateLimiterAlgorithm;
      const tb = (ex.tokenBucket && typeof ex.tokenBucket === 'object') ? ex.tokenBucket : {};

      const rateLimitMs = (typeof rl === 'number' && rl > 0) ? rl : null;
      const refillPerSec = (rateLimitMs !== null) ? (1000.0 / rateLimitMs) : null;
      const hasRolling = (typeof rws === 'number' && rws > 0);
      const tbAlgo = (typeof tb.algorithm === 'string') ? tb.algorithm : null;
      const fieldAlgo = (typeof algo === 'string') ? algo : null;

      const bucket = {
        axes: ["request"],
        rate_limit_ms: rateLimitMs,
        refill_per_sec: refillPerSec,
        max_size: (typeof tb.capacity === 'number' && tb.capacity > 0) ? tb.capacity : 1,
        cost_default: (typeof tb.cost === 'number' && tb.cost > 0) ? tb.cost : 1,
        algorithm: tbAlgo || fieldAlgo || 'leakyBucket',
        rolling_window_ms: hasRolling ? rws : null
      };

      return JSON.stringify({
        id: id,
        rate_limit_buckets: {
          buckets: (rateLimitMs === null) ? [] : [bucket],
          source: "describe",
          unresolved_reason: (rateLimitMs === null) ? "rate_limit_unset" : null
        }
      });
    } catch (e) {
      return JSON.stringify({
        id: id,
        rate_limit_buckets: {
          buckets: [],
          source: "describe",
          unresolved_reason: "instantiation_failed"
        }
      });
    }
  }
  """

  @doc """
  Always-present wrapper used by the pipeline when an exchange has no
  discovery entry. Mirrors the JS extractor's empty shape.
  """
  @spec empty_record() :: %{String.t() => term()}
  def empty_record do
    %{
      "buckets" => [],
      "source" => "describe",
      "unresolved_reason" => "no_discovery_entry"
    }
  end

  @doc """
  Closed-vocabulary list of `unresolved_reason` values. Exposed for
  contract-test invariants.
  """
  @spec unresolved_reasons() :: [String.t()]
  def unresolved_reasons, do: ["instantiation_failed", "rate_limit_unset", "no_discovery_entry"]

  @doc """
  Closed-vocabulary list of `source` values. Exposed for contract-test
  invariants.
  """
  @spec sources() :: [String.t()]
  def sources, do: ["describe", "tokenBucket", "method_body"]

  @doc """
  Required keys for the rate_limit_buckets wrapper map.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: ["buckets", "source", "unresolved_reason"]

  @doc """
  Required keys for a single bucket entry.
  """
  @spec required_bucket_keys() :: [String.t()]
  def required_bucket_keys, do: ~w(axes rate_limit_ms refill_per_sec max_size cost_default algorithm rolling_window_ms)

  @doc """
  Pure derivation: convert a CCXT-style describe map (or instance-field
  shape) into the same bucket record the JS extractor emits.

  Used by unit tests to verify the bucket shape without spinning up
  QuickBEAM. The pipeline reads the JS-extracted discovery file directly,
  but `derive/1` is the single source of truth for the *interpretation*
  of the four CCXT runtime fields:

    * `"rateLimit"` (ms)
    * `"rollingWindowSize"` (ms; may be absent)
    * `"rateLimiterAlgorithm"` (`"leakyBucket"` default)
    * `"tokenBucket"` — merged map from initRestRateLimiter

  Accepts `nil` (returns the empty wrapper with `unresolved_reason =
  "instantiation_failed"`) and a map (returns a populated wrapper).
  """
  @spec derive(map() | nil) :: map()
  def derive(nil) do
    %{
      "buckets" => [],
      "source" => "describe",
      "unresolved_reason" => "instantiation_failed"
    }
  end

  def derive(describe) when is_map(describe) do
    rate_limit_ms = numeric_positive(Map.get(describe, "rateLimit"))

    if is_nil(rate_limit_ms) do
      %{
        "buckets" => [],
        "source" => "describe",
        "unresolved_reason" => "rate_limit_unset"
      }
    else
      token_bucket =
        case Map.get(describe, "tokenBucket") do
          %{} = tb -> tb
          _ -> %{}
        end

      rolling_ms = numeric_positive(Map.get(describe, "rollingWindowSize"))

      tb_algorithm = string_or_nil(Map.get(token_bucket, "algorithm"))
      field_algorithm = string_or_nil(Map.get(describe, "rateLimiterAlgorithm"))

      bucket = %{
        "axes" => ["request"],
        "rate_limit_ms" => rate_limit_ms,
        "refill_per_sec" => 1000.0 / rate_limit_ms,
        "max_size" => numeric_positive(Map.get(token_bucket, "capacity")) || 1,
        "cost_default" => numeric_positive(Map.get(token_bucket, "cost")) || 1,
        "algorithm" => tb_algorithm || field_algorithm || "leakyBucket",
        "rolling_window_ms" => rolling_ms
      }

      %{
        "buckets" => [bucket],
        "source" => "describe",
        "unresolved_reason" => nil
      }
    end
  end

  def derive(_), do: derive(nil)

  @doc """
  Extract rate-limit buckets for all (or scoped) non-alias exchanges.

  Starts a QuickBEAM runtime, enumerates non-alias exchange IDs, filters
  by `:scope` if a `MapSet` is supplied, then probes each exchange's
  resolved rate-limit fields. Returns a sorted list of
  `%{"id" => id, "rate_limit_buckets" => %{...}}` maps.

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

      Logger.info("Extracting rate_limit_buckets for #{length(ids)} exchanges...")

      results = CcxtExtract.Progress.map(ids, &extract_one(rt, &1))

      {:ok, results}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Extract rate-limit buckets for a single exchange from an active runtime.
  """
  @spec extract_one(pid(), String.t()) :: map()
  def extract_one(rt, id) do
    {:ok, json} = QuickBEAM.call(rt, "extractRateLimitBuckets", [id])
    Jason.decode!(json)
  end

  @doc """
  Write rate_limit_buckets to `priv/discoveries/rate_limit_buckets.json`.

  Routes through `CcxtExtract.AggregateWriter` so scoped runs merge with
  any existing aggregate: in-scope entries are replaced, out-of-scope
  entries are preserved, and `count` is recomputed from the final merged
  list.

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
    output_path = Keyword.get(opts, :output_path, CcxtExtract.Paths.out(@output_file))

    CcxtExtract.AggregateWriter.write!(output_path, results,
      entry_key: "exchanges",
      id_key: "id",
      scope: scope,
      tier_scope: tier_scope,
      stats_fn: &compute_stats/1
    )
  end

  # Envelope stats: how many exchanges produced a usable bucket and how
  # many resolved to rolling-window mode (binance et al.). Both stats are
  # purely descriptive — no decision logic depends on the totals — so the
  # invariant is "stats recompute from final merged entries", enforced by
  # AggregateWriter.
  defp compute_stats(entries) do
    {with_bucket, with_rolling} =
      Enum.reduce(entries, {0, 0}, fn entry, {bw, br} ->
        buckets = get_in(entry, ["rate_limit_buckets", "buckets"]) || []
        rolling? = Enum.any?(buckets, &has_rolling_window?/1)
        {bw + bucket_increment(buckets), br + boolean_increment(rolling?)}
      end)

    %{
      "with_bucket" => with_bucket,
      "with_rolling_window" => with_rolling
    }
  end

  defp bucket_increment([]), do: 0
  defp bucket_increment(_), do: 1

  defp boolean_increment(true), do: 1
  defp boolean_increment(false), do: 0

  defp has_rolling_window?(%{"rolling_window_ms" => ms}) when is_number(ms) and ms > 0, do: true
  defp has_rolling_window?(_), do: false

  defp numeric_positive(value) when is_integer(value) and value > 0, do: value
  defp numeric_positive(value) when is_float(value) and value > 0, do: value
  defp numeric_positive(_), do: nil

  defp string_or_nil(value) when is_binary(value) and byte_size(value) > 0, do: value
  defp string_or_nil(_), do: nil
end
