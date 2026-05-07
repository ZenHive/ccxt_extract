defmodule CcxtExtract.RequestHeaders do
  @moduledoc """
  Extract per-exchange `userAgent` and default `headers` via QuickBEAM.

  For each non-alias exchange, instantiates the CCXT class to trigger the
  `deepExtend(super.describe(), {...})` merge in the constructor, then reads
  the resolved `userAgent` (string | undefined | false) and `headers` (flat
  string-to-string map) instance fields.

  Output uses an **always-emit wrapper** so consumers don't need nil-checks
  on `runtime.request_headers`:

      %{
        "id" => "binance",
        "request_headers" => %{"user_agent" => nil, "default_headers" => %{}}
      }

  …vs. an exchange that overrides:

      %{
        "id" => "coinbase",
        "request_headers" => %{
          "user_agent" => "Mozilla/5.0 ...",
          "default_headers" => %{"CB-VERSION" => "2018-05-30"}
        }
      }

  Coverage is sparse: ~8% of exchanges override `userAgent` (observed:
  `bitstamp`, `bittrade`, `coinbase` + 2 variants, `delta`, `hibachi`, `htx`)
  and ~4% override `headers` (observed: `alpaca`, `coinbase`,
  `coinbaseinternational`, `gate`). Most exchanges produce the empty wrapper.

  Output is a single JSON file at `priv/discoveries/request_headers.json`
  with the standard envelope: `{extracted_at, count, exchanges: [...]}`.

  ## Out of scope

  Two known QuickBEAM-side blind spots that this extractor does NOT capture
  (resolved-describe() can't see them):

    * `bigone.ts` constructs its `User-Agent` header inside `sign()` as
      `'ccxt/' + this.id + '-' + this.version`. Never appears in describe().
    * `okx.ts` mutates `this.headers` at runtime via `setSandboxMode(true)`
      to inject `x-simulated-trading: 1`. Not in describe().

  TODO(Task 73e): An OXC-side pass over sign-method bodies could catch
  both. Out of scope for Task 73b — affects 2 known exchanges.

  ## Usage

      {:ok, results} = CcxtExtract.RequestHeaders.extract()
      CcxtExtract.RequestHeaders.write!(results)

  ## Scope

  `extract/1` accepts `:scope` (default `:all`, or a `MapSet` of exchange IDs)
  to narrow the probe list. `write!/2` accepts `:scope` and `:tier_scope`
  and delegates to `CcxtExtract.AggregateWriter` so scoped runs merge cleanly
  with any existing aggregate.
  """

  require Logger

  @output_file "discoveries/request_headers.json"

  # JS function for request-headers extraction.
  #
  # extractRequestHeaders(id): instantiates exchange (which triggers the
  # describe-into-instance-fields merge in the base Exchange constructor),
  # reads `ex.userAgent` and `ex.headers`. Per `priv/ccxt/ts/src/base/Exchange.ts`,
  # `userAgent` is typed `{User-Agent: string} | false` (default undefined)
  # and `headers` is typed `Dictionary<string>` (default `{}`).
  #
  # The `typeof === 'string'` guard normalizes false / undefined / object
  # forms to null. If a future exchange ships `userAgent: {User-Agent: '...'}`
  # the extractor will record null — surfacing the divergence as a missing
  # value rather than a parse error or silent passthrough.
  #
  # Security note: this JS source runs inside QuickBEAM (sandboxed Zig NIF
  # runtime) against the CCXT vendor bundle — no user input involved. This
  # mirrors the pattern in `CcxtExtract.UrlTemplates`.
  @js_setup """
  globalThis.extractRequestHeaders = function(id) {
    const ex = new ccxt[id]();
    const ua = ex.userAgent;
    const headers = ex.headers || {};

    return JSON.stringify({
      id: id,
      request_headers: {
        user_agent: (typeof ua === 'string' && ua.length > 0) ? ua : null,
        default_headers: headers
      }
    });
  }
  """

  @doc """
  Always-present wrapper used by the pipeline when an exchange has no
  discovery entry. Mirrors the JS extractor's output shape for an exchange
  with no overrides.
  """
  @spec empty_record() :: %{String.t() => nil | %{}}
  def empty_record, do: %{"user_agent" => nil, "default_headers" => %{}}

  @doc """
  Extract `request_headers` for all (or scoped) non-alias exchanges.

  Starts a QuickBEAM runtime, enumerates non-alias exchange IDs, filters by
  `:scope` if a `MapSet` is supplied, then extracts each exchange's
  `request_headers`. Returns a sorted list of
  `%{"id" => id, "request_headers" => %{"user_agent" => ..., "default_headers" => %{...}}}`
  maps.

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

      Logger.info("Extracting request_headers for #{length(ids)} exchanges...")

      results = CcxtExtract.Progress.map(ids, &extract_one(rt, &1))

      {:ok, results}
    after
      CcxtExtract.QuickbeamRuntime.stop(rt)
    end
  end

  @doc """
  Extract `request_headers` for a single exchange from an active runtime.
  """
  @spec extract_one(pid(), String.t()) :: map()
  def extract_one(rt, id) do
    {:ok, json} = QuickBEAM.call(rt, "extractRequestHeaders", [id])
    Jason.decode!(json)
  end

  @doc """
  Write request_headers to `priv/discoveries/request_headers.json`.

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
    output_path = Keyword.get(opts, :output_path, CcxtExtract.Paths.out(@output_file))

    CcxtExtract.AggregateWriter.write!(output_path, results,
      entry_key: "exchanges",
      id_key: "id",
      scope: scope,
      tier_scope: tier_scope,
      stats_fn: fn _entries -> %{} end
    )
  end
end
