defmodule CcxtExtract.Pipeline do
  @moduledoc """
  Assemble per-exchange JSON files from all extraction outputs.

  Reads discovery data produced by individual extractors (QuickBEAM runtime
  values + OXC AST data) and combines them into validated per-exchange JSON
  files conforming to `exchange_v4.json`. After scoped
  overrides and sign-recipe / request-shape sync, each exchange is checked
  with `CcxtExtract.Validation.validate_schema/2` (JSV) — failures are logged
  and recorded in `stats.validation_errors` without dropping the exchange (same
  policy as preflight `Schema.validate*`).

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.Pipeline.extract()
      CcxtExtract.Pipeline.write!(exchanges)

  ## Options

    * `:discoveries_dir` — override input directory (for testing)
    * `:ccxt_version` — override version (auto-read from ccxt_version.json)
    * `:extracted_at` — override timestamp (defaults to now, use for determinism)
  """

  alias CcxtExtract.DiscoveryLoader
  alias CcxtExtract.Normalization
  alias CcxtExtract.OverrideRegistry
  alias CcxtExtract.Paths
  alias CcxtExtract.Provenance
  alias CcxtExtract.RateLimitCostBinding
  alias CcxtExtract.RequestShape
  alias CcxtExtract.Schema
  alias CcxtExtract.ScopeCleanup
  alias CcxtExtract.SignRecipe
  alias CcxtExtract.Validation
  alias CcxtExtract.WsAuth
  alias CcxtExtract.WsDispatch
  alias CcxtExtract.WsHeartbeat
  alias CcxtExtract.WsOhlcvSemantics
  alias CcxtExtract.WsOrderbookSemantics
  alias CcxtExtract.WsSubscribe

  require Logger

  @output_dir "output"

  # --- Public API ---

  @doc """
  Read all discovery data, assemble per-exchange output, validate each.

  Returns `{:ok, exchanges, stats}` where `exchanges` is a sorted list of
  validated exchange maps and `stats` tracks counts.

  ## Options

    * `:scope` — `:all` (default) assembles every known exchange, or a
      `MapSet` of exchange IDs to restrict assembly to. Integrity stats
      (`missing_entries`, `orphan_entries`, etc.) still reflect the full
      universe so we never hide real discovery drift.
    * `:allow_version_drift` — `true` bypasses the CCXT version-drift
      guard. Defaults to `false`.

  Raises if `check_version_drift!/1` detects that `priv/ccxt` or
  `priv/ccxt_bundle.js` no longer matches the baseline recorded in
  `priv/ccxt_version.json` (unless `:allow_version_drift` is set).
  """
  @spec extract(keyword()) :: {:ok, [map()], map()} | {:error, CcxtExtract.JsonIO.read_error()}
  def extract(opts \\ []) do
    check_version_drift!(opts)
    dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))
    exchanges_path = Path.join(dir, "exchanges.json")

    with {:ok, exchanges_json} <- CcxtExtract.JsonIO.read_json(exchanges_path) do
      data = DiscoveryLoader.load_all!(dir, exchanges_json)

      # fetch_methods.json (Task 83a) and raw_broadcast.json (Task 73f) are
      # optional. fetch_methods absence leaves per-fetcher entries flagged
      # `"no_fetcher_method_body"`; raw_broadcast absence just means no
      # transaction_classification promotions (name-only base still emits).
      missing_required = data.missing_files -- ["fetch_methods.json", "raw_broadcast.json"]

      if missing_required != [] do
        raise "Pipeline cannot run — missing required discovery files: #{Enum.join(missing_required, ", ")}"
      end

      version_info = Keyword.get_lazy(opts, :version_info, fn -> read_ccxt_version_info() end)
      ccxt_version = Keyword.get(opts, :ccxt_version) || version_info["npm_version"] || "unknown"

      extracted_at =
        Keyword.get_lazy(opts, :extracted_at, fn ->
          CcxtExtract.Clock.timestamp(:extracted_at)
        end)

      schema_opts = [
        ccxt_version: ccxt_version,
        extracted_at: extracted_at,
        version_info: version_info
      ]

      schema_root = Validation.build_schema_root()

      scope = Keyword.get(opts, :scope, :all)

      {exchanges, errors} =
        data.exchanges
        |> filter_scope(scope)
        |> Enum.sort_by(& &1["id"])
        |> Enum.reduce({[], []}, &assemble_and_validate(&1, data, schema_opts, &2))

      stats = %{
        exchange_count: length(exchanges),
        validation_errors: Enum.reverse(errors),
        missing_files: data.missing_files,
        missing_entries: data.missing_entries,
        corrupt_entries: data.corrupt_entries,
        orphan_entries: data.orphan_entries,
        id_mismatch_entries: data.id_mismatch_entries
      }

      final_exchanges =
        exchanges
        |> Enum.reverse()
        |> Enum.map(&apply_exchange_overrides/1)

      jsv_errors = Enum.flat_map(final_exchanges, &validate_one(&1, schema_root))

      stats = Map.update!(stats, :validation_errors, &(&1 ++ jsv_errors))

      {:ok, final_exchanges, stats}
    end
  end

  @doc """
  Write per-exchange JSON files, the schema, and a manifest.

  Prunes per-exchange JSON files outside the written set before writing,
  preserving the shared schema (`exchange_v4.json`) and any `_`-prefixed
  metadata file (manifests, base methods).

  ## Options

    * `:tier_scope` — value to stamp into `_manifest.json` as `tier_scope`.
      Use `CcxtExtract.Scope.to_manifest_value/1` to compute from parsed
      CLI opts. Defaults to `"all"` when omitted.
    * `:discoveries_dir` — override the source directory for
      `_base_methods.json` (used for testing).
    * `:pretty` — boolean. When true, emit per-exchange JSON with
      indentation (~2× size). Default `false`. Manifests, fixtures, and
      reports remain pretty-printed regardless of this flag.
  """
  @spec write!([map()], String.t(), keyword()) :: :ok
  def write!(exchanges, output_dir \\ Paths.out(@output_dir), opts \\ []) do
    discoveries_dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))
    schema_file = Schema.schema_filename()

    File.mkdir_p!(output_dir)

    in_scope = MapSet.new(exchanges, & &1["exchange"]["id"])
    {:ok, _removed} = ScopeCleanup.prune_out_of_scope(output_dir, in_scope, preserve: [schema_file])

    pretty? = Keyword.get(opts, :pretty, false)

    for exchange <- exchanges do
      id = exchange["exchange"]["id"]
      path = Path.join(output_dir, "#{id}.json")
      File.write!(path, Jason.encode!(CcxtExtract.AstNormalize.to_encodable(exchange), pretty: pretty?))
    end

    manifest = build_manifest(exchanges, opts)
    manifest_path = Path.join(output_dir, "_manifest.json")
    File.write!(manifest_path, Jason.encode!(CcxtExtract.AstNormalize.to_encodable(manifest), pretty: true))
    copy_schema!(output_dir)
    copy_base_methods!(output_dir, discoveries_dir)

    :ok
  end

  @doc """
  Guard against silent CCXT version drift. Raises on confirmed drift.

  Compares the on-disk CCXT corpus against the baseline that
  `mix ccxt_extract.setup` recorded in `priv/ccxt_version.json`:

    * **git SHA** — when `priv/ccxt/.git` is present, the current
      `priv/ccxt` HEAD must equal the recorded `source_git_sha`.
    * **bundle hash** — when the version file carries `bundle_sha256`,
      the sha256 of `priv/ccxt_bundle.js` must match it.

  A *missing* version file is a skip, not a failure — there is no
  recorded baseline to drift from (a fresh checkout before `setup`
  ran). A *malformed* version file is a hard failure: that is breakage,
  not absence. Any confirmed drift raises with a resync hint.

  Pass `allow_version_drift: true` (the `--allow-version-drift` CLI
  flag) to bypass the guard entirely — for advanced users running a
  custom bundle or a deliberately-pinned source tree.

  Runs at the top of `extract/1`; exposed publicly so it can be
  exercised in isolation.
  """
  @spec check_version_drift!(keyword()) :: :ok
  def check_version_drift!(opts) do
    if Keyword.get(opts, :allow_version_drift, false) do
      :ok
    else
      case read_version_file_strict() do
        :missing ->
          Logger.info(
            "No priv/ccxt_version.json — version-drift guard inactive. " <>
              "Run `mix ccxt_extract.setup` to record a baseline."
          )

        {:ok, version_info} ->
          check_git_sha_drift!(version_info)
          check_bundle_drift!(version_info)
      end
    end
  end

  @doc """
  Compute the lowercase-hex sha256 digest of a file's contents.

  Shared by `mix ccxt_extract.setup` (records `bundle_sha256` into
  `priv/ccxt_version.json`) and `check_version_drift!/1` (verifies it),
  so both sides hash identically.
  """
  @spec bundle_sha256(Path.t()) :: String.t()
  def bundle_sha256(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp filter_scope(exchanges, :all), do: exchanges

  defp filter_scope(exchanges, %MapSet{} = scope) do
    Enum.filter(exchanges, &MapSet.member?(scope, &1["id"]))
  end

  # Apply all curated overrides (priv/overrides/<id>.json) to the assembled
  # exchange map. Runs after assembly+validation so overrides replace whatever
  # derivation produced. Two-layer error handling: the outer rescue catches
  # OverrideRegistry.load/1 failures (bad JSON, schema violation) and the
  # inner per-entry rescue catches put_in/pointer_to_keys raises, naming the
  # failing pointer. Failures are surfaced two ways: a Logger.warning here
  # at assembly time, and as a finding from the contract-test invariants
  # override_registry_valid (file-level) and override_paths_present_in_output
  # (entry-level). The contract-test finding is the strict channel; this
  # assembly-time log keeps a single bad file from blocking a full-universe
  # build.
  #
  # Strict override failures: `mix ccxt_extract.validate_overrides --strict`
  # (assembly stays warn-and-continue so one file cannot brick the universe).
  defp apply_exchange_overrides(exchange) do
    id = exchange["exchange"]["id"]
    paths = recipe_path_map(exchange)

    case OverrideRegistry.load(id) do
      :none ->
        exchange |> sync_sign_recipe(paths) |> sync_request_shape(paths)

      overrides when is_list(overrides) ->
        {updated, applied_paths} =
          Enum.reduce(overrides, {exchange, []}, fn entry, {acc, paths_acc} ->
            apply_override_entry(entry, acc, paths_acc, id)
          end)

        updated
        |> sync_sign_recipe(paths)
        |> sync_request_shape(paths)
        |> stamp_override_provenance(applied_paths)
    end
  rescue
    e in [RuntimeError, File.Error, Jason.DecodeError] ->
      id = exchange["exchange"]["id"]

      Logger.warning(
        "Override load failed for #{id} (priv/overrides/#{id}.json): #{Exception.message(e)}; leaving exchange unchanged"
      )

      exchange
  end

  # Path map used by `sync_sign_recipe/2` and `sync_request_shape/2`.
  defp recipe_path_map(_exchange) do
    %{
      auth_sections: ["auth", "authenticated_sections"],
      sign_method: ["auth", "sign_method"],
      sign_recipe: ["auth", "sign_recipe"],
      request_shape: ["endpoints", "request", "shape"],
      describe_api: ["raw", "describe", "api"]
    }
  end

  # Keep `<sign_recipe>` keys in lockstep with `<authenticated_sections>`
  # after overrides may have mutated either. An override that flips
  # authenticated_sections (e.g. hyperliquid adding "private") without
  # touching sign_recipe would otherwise leave the recipe missing a
  # section, violating the sign_recipe_keys_match_auth_sections contract
  # invariant.
  #
  # This runs AFTER override application so that any override targeting
  # recipe sub-paths still survives the sync: keys that appear in both
  # the new auth_sections and the existing recipe are preserved
  # untouched. Keys added by auth_sections that have no recipe entry get
  defp sync_sign_recipe(exchange, paths) do
    auth_sections = get_in(exchange, paths.auth_sections)
    existing = get_in(exchange, paths.sign_recipe) || %{}
    sign_method = get_in(exchange, paths.sign_method)
    synced = synced_recipe_map(auth_sections, existing, sign_method)
    put_in(exchange, paths.sign_recipe, synced)
  end

  defp synced_recipe_map(nil, _existing, _sign_method), do: %{}
  defp synced_recipe_map([], _existing, _sign_method), do: %{}

  defp synced_recipe_map(auth_sections, existing, sign_method) when is_list(auth_sections) do
    # For sections that already exist (pre-override or derived), keep their
    # derived values. For sections newly introduced by an override that
    # bumped authenticated_sections, re-run Derive so the new section gets
    # a real crypto_op/placement rather than a permanent null_recipe.
    new_sections = Enum.reject(auth_sections, &Map.has_key?(existing, &1))
    new_recipes = SignRecipe.Derive.derive(sign_method, new_sections)

    Map.new(auth_sections, fn section ->
      {section, Map.get(existing, section) || Map.get(new_recipes, section) || SignRecipe.null_recipe()}
    end)
  end

  # Mirror of `sync_sign_recipe/2` for the request_shape map. Keeps
  # recipe keys aligned with authenticated_sections after overrides may
  # have mutated either, and re-runs derivation for any sections newly
  # introduced by an override (so they get a real verb/path triple
  # rather than a permanent null_record). Path map varies by schema
  # target (Task 130).
  defp sync_request_shape(exchange, paths) do
    auth_sections = get_in(exchange, paths.auth_sections)
    existing = get_in(exchange, paths.request_shape) || %{}
    sign_method = get_in(exchange, paths.sign_method)
    describe_api = get_in(exchange, paths.describe_api)
    synced = synced_request_shape_map(auth_sections, existing, sign_method, describe_api)
    put_in(exchange, paths.request_shape, synced)
  end

  defp synced_request_shape_map(nil, _existing, _sign_method, _describe_api), do: %{}
  defp synced_request_shape_map([], _existing, _sign_method, _describe_api), do: %{}

  defp synced_request_shape_map(auth_sections, existing, sign_method, describe_api) when is_list(auth_sections) do
    new_sections = Enum.reject(auth_sections, &Map.has_key?(existing, &1))
    new_records = RequestShape.Derive.derive(sign_method, new_sections, describe_api)

    Map.new(auth_sections, fn section ->
      {section, Map.get(existing, section) || Map.get(new_records, section) || RequestShape.null_record()}
    end)
  end

  # Apply a single override entry, threading the applied-path list so the
  # _provenance map can mark successfully-applied paths as "override".
  # Entries that raise are logged and dropped from the path list — failed
  # overrides must not claim override provenance for a raw value that was
  # never replaced.
  # Strict-mode pointer failures: `mix ccxt_extract.validate_overrides --strict`.
  defp apply_override_entry(entry, acc, paths, id) do
    translated = OverrideRegistry.translate_pointer(entry["path"])
    keys = OverrideRegistry.pointer_to_keys(translated)
    {put_in(acc, keys, entry["value"]), [translated | paths]}
  rescue
    e in [RuntimeError, KeyError, ArgumentError, FunctionClauseError] ->
      Logger.warning(
        "Override entry #{inspect(entry["path"])} failed for #{id} (priv/overrides/#{id}.json): #{Exception.message(e)}; entry not applied"
      )

      {acc, paths}
  end

  # Stamp "override" in the _provenance map for every path that successfully
  # applied. Default provenance already tags every known pointer as raw or
  # derived; this replaces those tags (or adds new ones for sub-tree paths
  # deeper than default granularity) for the overridden subset.
  defp stamp_override_provenance(exchange, []), do: exchange

  defp stamp_override_provenance(exchange, paths) do
    Map.update(exchange, "_provenance", Provenance.build_default(), fn provenance ->
      Provenance.stamp_overrides(provenance, paths)
    end)
  end

  # Same string-list shape as `Schema.validate/1` — Mix task counts rows only.
  @spec format_jsv_findings([map()] | []) :: [String.t()]
  defp format_jsv_findings(findings) when is_list(findings) do
    Enum.map(findings, fn
      %{"path" => path, "message" => msg} -> "JSV #{path}: #{msg}"
      map when is_map(map) -> "JSV #{inspect(map)}"
      other -> "JSV #{inspect(other)}"
    end)
  end

  @spec validate_one(map(), term()) :: [{String.t(), [String.t()]}]
  defp validate_one(exchange, schema_root) do
    id = exchange["exchange"]["id"]

    case Validation.validate_schema(exchange, schema_root) do
      :ok ->
        []

      {:error, findings} ->
        Logger.warning("JSV validation failed for #{id}: #{inspect(findings)}")
        [{id, format_jsv_findings(findings)}]
    end
  end

  # Reduce callback: build one exchange and validate it.
  defp assemble_and_validate(meta, data, schema_opts, {acc, errs}) do
    exchange = build_exchange_data(meta, data, schema_opts)

    case Schema.validate(exchange) do
      :ok ->
        {[exchange | acc], errs}

      {:error, reasons} ->
        Logger.warning("Validation failed for #{meta["id"]}: #{inspect(reasons)}")
        {[exchange | acc], [{meta["id"], reasons} | errs]}
    end
  end

  # --- Assembly ---

  @doc false
  @spec build_exchange_data(map(), map(), keyword()) :: map()
  def build_exchange_data(meta, data, opts) do
    id = meta["id"]

    markets = get_markets(id, data)
    describe = get_describe(id, data)

    runtime_data = %{
      "describe" => describe,
      "symbols_index" => CcxtExtract.SymbolsIndex.derive(markets),
      "symbol_patterns" => CcxtExtract.SymbolPatterns.derive(markets, describe),
      "currencies" => CcxtExtract.Currencies.derive(markets),
      "precision_mode" => CcxtExtract.PrecisionMode.derive(describe),
      "url_templates" => get_url_templates(id, data),
      "testnet_urls" => CcxtExtract.TestnetUrls.derive(describe),
      "request_headers" => get_request_headers(id, data)
    }

    sign_method = get_sign_method(id, data)
    effective_sign = sign_method || get_parent_sign_method(id, data)
    describe_api = get_in(describe, ["api"])

    # Curated overrides for `/structure/authenticated_sections` are applied
    # at the tail of extract/1 by apply_exchange_overrides/1, which threads
    # applied-pointer paths into the _provenance map.
    authenticated_sections = CcxtExtract.AuthenticatedSections.derive(effective_sign, describe_api)

    handle_errors = get_handle_errors(id, data)

    rl_buckets = get_rate_limit_buckets(id, data)
    rl_costs = get_rate_limit_costs(id, data)
    cost_binding = RateLimitCostBinding.derive(rl_buckets)

    structure_data = %{
      "class_info" => get_class_info(id, data),
      "methods" => get_methods(id, data),
      "sign_method" => sign_method,
      "authenticated_sections" => authenticated_sections,
      "describe_api" => describe_api,
      "handle_errors" => handle_errors,
      "error_class_hierarchy" => data.error_class_hierarchy,
      "interface_signatures" => get_interface_signatures(id, data),
      "pagination" => get_pagination(id, data),
      "unified_endpoints" => get_unified_endpoints(id, data),
      "raw_broadcast" => get_raw_broadcast(id, data),
      "request_defaults" => get_request_defaults(id, data),
      "overrides" => get_overrides(id, data),
      "error_dispatch" => get_error_dispatch(handle_errors),
      "sign_dispatch" => get_sign_dispatch(effective_sign),
      "parse_dispatch" => get_parse_dispatch(id, data),
      "rate_limit_buckets" => rl_buckets,
      "rate_limit_costs" => rl_costs,
      "endpoint_cost_binding" => cost_binding,
      "error_status_map" => CcxtExtract.HandleErrors.http_status_map(handle_errors),
      "error_retryable" => CcxtExtract.HandleErrors.retryable_buckets(handle_errors)
    }

    # v4-only path (Task 143). Normalization carrier is always populated for v4.
    # Map.get/3 on :fetch_methods because test fixtures may construct `data`
    # without the key (fetch_methods.json is optional).
    fetch_methods_lookup = Map.get(data, :fetch_methods, %{})

    normalization =
      Normalization.build(
        Map.get(data.parse_methods, id),
        Map.get(fetch_methods_lookup, id)
      )

    # WebSocket carrier (Tasks 93, 92, 91, 94, 95b). Map.get/3 on each lookup so
    # older test fixtures that omit a key resolve to the none_record.
    ws_heartbeat_lookup = Map.get(data, :ws_heartbeat, %{})
    ws_auth_lookup = Map.get(data, :ws_auth, %{})
    ws_subscribe_lookup = Map.get(data, :ws_subscribe, %{})
    ws_dispatch_lookup = Map.get(data, :ws_dispatch, %{})
    ws_orderbook_lookup = Map.get(data, :ws_orderbook_semantics, %{})
    ws_trades_semantics_lookup = Map.get(data, :ws_trades_semantics, %{})
    ws_ohlcv_semantics_lookup = Map.get(data, :ws_ohlcv_semantics, %{})

    websocket = %{
      "heartbeat" => WsHeartbeat.build(Map.get(ws_heartbeat_lookup, id), ws_heartbeat_lookup),
      "auth" => WsAuth.build(Map.get(ws_auth_lookup, id), ws_auth_lookup),
      "subscribe" => WsSubscribe.build(Map.get(ws_subscribe_lookup, id), ws_subscribe_lookup),
      "dispatch" => WsDispatch.build(Map.get(ws_dispatch_lookup, id), ws_dispatch_lookup),
      "orderbook_semantics" => WsOrderbookSemantics.build(Map.get(ws_orderbook_lookup, id), ws_orderbook_lookup),
      "trades_semantics" =>
        CcxtExtract.WsTradesSemantics.build(
          Map.get(ws_trades_semantics_lookup, id),
          ws_trades_semantics_lookup
        ),
      "ohlcv_semantics" =>
        WsOhlcvSemantics.build(
          Map.get(ws_ohlcv_semantics_lookup, id),
          ws_ohlcv_semantics_lookup
        )
    }

    v4_opts =
      opts
      |> Keyword.put(:normalization, normalization)
      |> Keyword.put(:websocket, websocket)

    exchange = Schema.build_exchange(meta, runtime_data, structure_data, v4_opts)
    prune_bybit_dead_spot_v3_private_endpoints(exchange)
  end

  # Derive error dispatch from the assembled handle_errors map. Consumes
  # the `method` MethodAST so alias exchanges that fall through to a
  # parent's handleErrors() (via get_handle_errors/2) inherit the dispatch
  # too. Returns nil when no method body is available.
  defp get_error_dispatch(%{"method" => method}) when is_map(method), do: CcxtExtract.ErrorDispatch.derive(method)

  defp get_error_dispatch(_), do: nil

  # Derive sign dispatch from the effective sign_method (own or inherited
  # via get_parent_sign_method/2). Returns nil when no sign() is reachable.
  defp get_sign_dispatch(nil), do: nil
  defp get_sign_dispatch(method), do: CcxtExtract.SignDispatch.derive(method)

  # Read parse_dispatch from the parse_methods discovery entry. Falls back
  # to the parent exchange when an alias has no own entry — same shape as
  # other AST-derived sections.
  defp get_parse_dispatch(id, data) do
    case Map.get(data.parse_methods, id) do
      nil ->
        get_parent_parse_dispatch(id, data)

      %{"parse_dispatch" => dispatch} when is_map(dispatch) and map_size(dispatch) > 0 ->
        dispatch

      _ ->
        get_parent_parse_dispatch(id, data)
    end
  end

  defp get_parent_parse_dispatch(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_parse_dispatch(parent_id, data)
    end
  end

  # --- Data Mapping (pure functions) ---

  # Describe: read the "describe" key from the per-exchange file.
  # Alias exchanges (e.g. coinbaseadvanced, huobi) have no own describe data —
  # fall back to parent exchange's describe via class hierarchy.
  defp get_describe(id, data) do
    case Map.get(data.describe, id) do
      nil -> get_parent_data(id, data, :describe)
      describe -> describe
    end
  end

  # Markets: read market_count + markets from per-exchange file.
  # Same parent fallback as describe for alias exchanges.
  defp get_markets(id, data) do
    case Map.get(data.load_markets, id) do
      nil -> get_parent_data(id, data, :load_markets)
      markets -> markets
    end
  end

  # Resolve parent data for alias exchanges that have no own discovery data.
  defp get_parent_data(id, data, field) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> Map.get(Map.get(data, field, %{}), parent_id)
    end
  end

  # Class info: group by type into %{"rest" => entry, "ws" => entry|nil}
  defp get_class_info(id, data) do
    case Map.get(data.classes, id) do
      nil -> nil
      entries -> build_class_info(entries)
    end
  end

  defp build_class_info(entries) do
    rest = Enum.find(entries, &(&1["type"] == "rest"))
    ws = Enum.find(entries, &(&1["type"] == "ws"))

    %{"rest" => rest, "ws" => ws}
  end

  # Methods: combine rest + ws into %{"rest" => [...], "ws" => [...]|nil}
  defp get_methods(id, data) do
    rest_present? = Map.has_key?(data.methods_rest, id)
    ws_present? = Map.has_key?(data.methods_ws, id)
    rest = Map.get(data.methods_rest, id)
    ws = Map.get(data.methods_ws, id)

    if rest_present? || ws_present? do
      %{
        "rest" => rest,
        "ws" => if(ws_present?, do: ws)
      }
    end
  end

  # Sign method: direct passthrough (already MethodAST or nil)
  defp get_sign_method(id, data), do: Map.get(data.sign_methods, id)

  # Resolve parent's sign_method when the child doesn't override it.
  # Walks the extends chain until a non-nil sign_method is found.
  defp get_parent_sign_method(id, data) do
    case find_parent_exchange_id(id, data) do
      nil ->
        nil

      parent_id ->
        case Map.get(data.sign_methods, parent_id) do
          nil -> get_parent_sign_method(parent_id, data)
          sign -> sign
        end
    end
  end

  # Handle errors: rename handle_errors → method, with parent fallback
  defp get_handle_errors(id, data) do
    case Map.get(data.handle_errors, id) do
      nil ->
        get_parent_handle_errors(id, data)

      %{"handle_errors" => nil} ->
        get_parent_handle_errors(id, data)

      %{"handle_errors" => method} = entry when is_map(method) ->
        %{
          "method" => method,
          "exceptions" => entry["exceptions"],
          "http_exceptions" => entry["http_exceptions"],
          "error_code_fields" => CcxtExtract.ErrorCodeFields.derive(method),
          "throw_dispatches" => CcxtExtract.ThrowDispatches.derive(method)
        }

      _ ->
        get_parent_handle_errors(id, data)
    end
  end

  # Recursive parent fallback for handle_errors
  defp get_parent_handle_errors(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_handle_errors(parent_id, data)
    end
  end

  # Interface signatures: extract the interface_signatures map.
  # For bybit/bybiteu, intentionally drop the discontinued spot/v3/private/* interface
  # methods (Bybit V3 Spot Open API shutdown 2024-08-31). Keeps both emitted
  # endpoints.interfaces and the valid set used to filter unified call lists clean.
  defp get_interface_signatures(id, data) do
    case Map.get(data.interface_signatures, id) do
      nil ->
        nil

      %{"interface_signatures" => sigs} when map_size(sigs) > 0 ->
        prune_dead_bybit_spot_v3_private_interfaces(sigs, id)

      _ ->
        nil
    end
  end

  # URL templates: extract the url_templates inner map.
  # Alias exchanges (e.g. coinbaseadvanced, huobi) have no own url_templates data —
  # fall back to parent exchange's url_templates via class hierarchy.
  defp get_url_templates(id, data) do
    case Map.get(data.url_templates, id) do
      nil -> get_parent_url_templates(id, data)
      %{"url_templates" => templates} when map_size(templates) > 0 -> templates
      _ -> nil
    end
  end

  # Recursion is safe: CCXT class hierarchy is a DAG (max depth ~3),
  # and find_parent_exchange_id returns nil for base Exchange class, terminating the chain.
  defp get_parent_url_templates(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_url_templates(parent_id, data)
    end
  end

  # Request headers: extract the request_headers wrapper map
  # (%{"user_agent" => ..., "default_headers" => ...}) from the discovery
  # lookup. Alias exchanges that didn't produce their own entry fall back
  # to the parent's value via class hierarchy. Returns nil only when the
  # entire chain has no entry — `Schema.build_exchange/4` substitutes
  # `RequestHeaders.empty_record()` so the schema-level always-emit
  # invariant survives.
  #
  # No deep-merge with parent: describe() inheritance already happened in
  # QuickBEAM (the alias's resolved values match the parent's at construction
  # time). Lookup-with-fallback is sufficient.
  defp get_request_headers(id, data) do
    case Map.get(data.request_headers, id) do
      nil -> get_parent_request_headers(id, data)
      %{"request_headers" => headers} when is_map(headers) -> headers
      _ -> nil
    end
  end

  defp get_parent_request_headers(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_request_headers(parent_id, data)
    end
  end

  # Rate-limit buckets: extract the rate_limit_buckets wrapper map. Always
  # returns a map (no nil). Alias exchanges fall back to parent — describe()
  # inheritance has already happened in QuickBEAM, but the per-exchange
  # discovery file is keyed by the alias's own id only when the alias
  # itself was instantiated, so a parent fallback handles families whose
  # alias didn't run through extract/1 (e.g. a scoped run that hit only the
  # root). Returns the always-emit `RateLimitBuckets.empty_record/0` shape
  # at the chain bottom so the schema-level always-emit invariant survives.
  defp get_rate_limit_buckets(id, data) do
    case data |> Map.get(:rate_limit_buckets, %{}) |> Map.get(id) do
      nil ->
        get_parent_rate_limit_buckets(id, data)

      %{"rate_limit_buckets" => buckets} when is_map(buckets) ->
        buckets

      _ ->
        get_parent_rate_limit_buckets(id, data)
    end
  end

  defp get_parent_rate_limit_buckets(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> CcxtExtract.RateLimitBuckets.empty_record()
      parent_id -> get_rate_limit_buckets(parent_id, data)
    end
  end

  # Per-endpoint cost weights from discovery (describe().api). Alias exchanges
  # inherit the parent's map via class hierarchy; nil when no row exists.
  defp get_rate_limit_costs(id, data) do
    case data |> Map.get(:rate_limit_costs, %{}) |> Map.get(id) do
      nil ->
        get_parent_rate_limit_costs(id, data)

      %{"rate_limit_costs" => costs} when is_map(costs) ->
        costs

      _ ->
        get_parent_rate_limit_costs(id, data)
    end
  end

  defp get_parent_rate_limit_costs(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_rate_limit_costs(parent_id, data)
    end
  end

  # Pagination: extract the pagination map (arrays of entries per method) + unresolved
  defp get_pagination(id, data) do
    data.pagination
    |> Map.get(id)
    |> build_pagination_output()
  end

  defp build_pagination_output(nil), do: nil

  defp build_pagination_output(exchange_data) do
    pagination = Map.get(exchange_data, "pagination", %{})
    unresolved = Map.get(exchange_data, "pagination_unresolved", [])

    case {map_size(pagination), unresolved} do
      {0, []} -> nil
      {_, []} -> pagination
      _ -> Map.put(pagination, "_unresolved", unresolved)
    end
  end

  # Unified endpoints: extract the unified_endpoints map, merge parent mappings for derived exchanges,
  # drop endpoints the child explicitly disables (has: false), restrict to the canonical CCXT
  # has-key vocabulary, then filter against interface_signatures to remove leaked helper method names.
  defp get_unified_endpoints(id, data) do
    parent_id = find_parent_exchange_id(id, data)
    disabled = exchange_disabled_has_keys(id, data)
    canonical = Map.get(data, :canonical_has_keys)
    valid_endpoints = collect_interface_signature_keys(id, parent_id, data)

    id
    |> extract_unified_endpoints_map(data)
    |> merge_parent_endpoints(parent_id, data)
    |> drop_disabled_endpoints(disabled)
    |> restrict_to_canonical_vocab(canonical)
    |> filter_unified_endpoints(valid_endpoints)
  end

  # Raw broadcast detection (Task 73f): the per-exchange raw_broadcast.json
  # entry, used by TransactionClassification.derive/3 to promote on-chain
  # broadcast endpoints. Falls back to the parent for DEX aliases that share
  # a source class. nil when the chain has no entry (most non-DEX exchanges).
  defp get_raw_broadcast(id, data) do
    case data |> Map.get(:raw_broadcast, %{}) |> Map.get(id) do
      nil -> get_parent_raw_broadcast(id, data)
      entry when is_map(entry) -> entry
      _ -> nil
    end
  end

  defp get_parent_raw_broadcast(id, data) do
    case find_parent_exchange_id(id, data) do
      nil -> nil
      parent_id -> get_raw_broadcast(parent_id, data)
    end
  end

  defp exchange_disabled_has_keys(id, data) do
    case get_describe(id, data) do
      %{"has" => has} when is_map(has) ->
        for {k, v} <- has, v == false, into: MapSet.new(), do: k

      _ ->
        MapSet.new()
    end
  end

  defp drop_disabled_endpoints(nil, _disabled), do: nil

  defp drop_disabled_endpoints(endpoints, disabled) do
    if MapSet.size(disabled) == 0 do
      endpoints
    else
      filtered = Map.reject(endpoints, fn {method, _calls} -> MapSet.member?(disabled, method) end)
      if map_size(filtered) > 0, do: filtered
    end
  end

  # Restrict endpoints to methods that appear as a `has` key somewhere in the CCXT corpus.
  # Kills internal routing helpers (fetchSpotMarkets, createSpotOrder, kucoin UTA variants, etc.)
  # that pass prefix-matching but are not part of the unified API vocabulary. Methods only
  # implemented outside the canonical vocabulary belong in override-tier once Phase 9 ships.
  defp restrict_to_canonical_vocab(nil, _canonical), do: nil
  defp restrict_to_canonical_vocab(endpoints, nil), do: endpoints

  defp restrict_to_canonical_vocab(endpoints, canonical) do
    filtered = Map.filter(endpoints, fn {method, _calls} -> MapSet.member?(canonical, method) end)
    if map_size(filtered) > 0, do: filtered
  end

  # Extract the raw unified_endpoints map from the discovery lookup
  defp extract_unified_endpoints_map(id, data) do
    case Map.get(data.unified_endpoints, id) do
      nil -> nil
      %{"unified_endpoints" => endpoints} when map_size(endpoints) > 0 -> endpoints
      _ -> nil
    end
  end

  # Request defaults: read the per-method default-request-body map from the
  # discovery lookup and fall back to the parent when the exchange is an alias
  # that didn't produce its own entry. No filtering against unified_endpoints
  # here — that invariant is enforced by the contract test. A method M appears
  # in the output iff the extractor found a resolvable literal body for it
  # (possibly via this.extend unwrap or const-trace); callers check the
  # per-entry `kind` to distinguish literal from unresolved.
  defp get_request_defaults(id, data) do
    id
    |> extract_request_defaults_map(data)
    |> merge_parent_request_defaults(find_parent_exchange_id(id, data), data)
  end

  defp extract_request_defaults_map(id, data) do
    case Map.get(data.request_defaults, id) do
      nil -> nil
      %{"request_defaults" => defaults} when map_size(defaults) > 0 -> defaults
      _ -> nil
    end
  end

  defp merge_parent_request_defaults(defaults, nil, _data), do: defaults

  defp merge_parent_request_defaults(nil, parent_id, data), do: extract_request_defaults_map(parent_id, data)

  defp merge_parent_request_defaults(defaults, parent_id, data) do
    case extract_request_defaults_map(parent_id, data) do
      nil -> defaults
      parent -> Map.merge(parent, defaults)
    end
  end

  # Find the parent exchange id from class hierarchy (REST class takes precedence).
  # Single-level lookup only: reads parent from discovery data, not merged pipeline output.
  # If B extends C, A extends B, and B has no own endpoints, A won't inherit C's endpoints.
  # Acceptable: CCXT's hierarchy is shallow and derived exchanges typically define own endpoints.
  defp find_parent_exchange_id(id, data) do
    case Map.get(data.classes, id) do
      nil ->
        nil

      entries ->
        rest = Enum.find(entries, &(&1["type"] == "rest"))
        parent_key = rest && rest["parent_key"]

        case parent_key do
          nil -> nil
          "Exchange" -> nil
          "rest:" <> parent_id -> parent_id
          _ -> nil
        end
    end
  end

  # Merge parent endpoints with child — child overrides take precedence
  defp merge_parent_endpoints(own, nil, _data), do: own
  defp merge_parent_endpoints(nil, parent_id, data), do: extract_unified_endpoints_map(parent_id, data)

  defp merge_parent_endpoints(own, parent_id, data) do
    case extract_unified_endpoints_map(parent_id, data) do
      nil -> own
      parent_endpoints -> Map.merge(parent_endpoints, own)
    end
  end

  # Collect valid interface signature keys for an exchange (own + parent).
  # Returns a MapSet for O(1) membership checks, or nil if no signatures available.
  defp collect_interface_signature_keys(id, parent_id, data) do
    own_sigs = get_interface_signature_keys(id, data)
    parent_sigs = if parent_id, do: get_interface_signature_keys(parent_id, data), else: MapSet.new()

    combined = MapSet.union(own_sigs, parent_sigs)
    if MapSet.size(combined) > 0, do: combined
  end

  defp get_interface_signature_keys(id, data) do
    case Map.get(data.interface_signatures, id) do
      %{"interface_signatures" => sigs} when map_size(sigs) > 0 ->
        sigs
        |> prune_dead_bybit_spot_v3_private_interfaces(id)
        |> Map.keys()
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # Filter unified_endpoints map: keep only endpoint names that exist in interface_signatures.
  # Removes unified methods that end up with empty endpoint lists after filtering.
  defp filter_unified_endpoints(nil, _valid), do: nil
  # TODO: All 110 exchanges should have interface_signatures (Task 30). If this fires,
  # investigate why signatures are missing rather than silently discarding endpoints.
  defp filter_unified_endpoints(endpoints, nil), do: endpoints

  defp filter_unified_endpoints(endpoints, valid_endpoints) do
    filtered =
      endpoints
      |> Map.new(fn {method, calls} ->
        {method, Enum.filter(calls, &MapSet.member?(valid_endpoints, &1))}
      end)
      |> Enum.reject(fn {_method, calls} -> calls == [] end)
      |> Map.new()

    if map_size(filtered) > 0, do: filtered
  end

  # --- Bybit V3 Spot private dead-endpoint pruning (Task 124) ---

  # Bybit discontinued the entire V3 Spot Open API 2024-08-31. CCXT still
  # carries the definitions under api.private.* and in the generated abstract
  # interface (SpotV3Private*), so we prune at assembly time from the consumer
  # surfaces (interfaces, unified call lists, request.shape endpoints). Raw
  # describe.api is left untouched; only the derived spec is cleaned.
  #
  # Affects bybit + bybiteu (the only current family members declaring them).

  defp bybit_family?(id) when id in ~w(bybit bybiteu), do: true
  defp bybit_family?(_), do: false

  defp dead_spot_v3_private_interface_name?(name) when is_binary(name) do
    Regex.match?(~r/^private(Get|Post|Put|Delete|Patch)SpotV3Private/, name)
  end

  defp dead_spot_v3_private_interface_name?(_), do: false

  defp dead_spot_v3_private_path?(path) when is_binary(path) do
    String.starts_with?(path, "spot/v3/private/")
  end

  defp dead_spot_v3_private_path?(_), do: false

  defp prune_dead_bybit_spot_v3_private_interfaces(sigs, id) when is_map(sigs) do
    if bybit_family?(id) do
      Map.reject(sigs, fn {name, _sig} -> dead_spot_v3_private_interface_name?(name) end)
    else
      sigs
    end
  end

  defp prune_bybit_dead_spot_v3_private_endpoints(%{"exchange" => %{"id" => id}} = exchange) when is_binary(id) do
    if bybit_family?(id), do: do_prune_bybit_shape(exchange), else: exchange
  end

  defp prune_bybit_dead_spot_v3_private_endpoints(exchange), do: exchange

  defp do_prune_bybit_shape(exchange) do
    shape_path = ["endpoints", "request", "shape"]
    shape = get_in(exchange, shape_path) || %{}
    pruned = Map.new(shape, &prune_section_endpoints/1)
    put_in(exchange, shape_path, pruned)
  end

  defp prune_section_endpoints({section, rec}) do
    case rec["endpoints"] do
      eps when is_list(eps) ->
        kept = Enum.reject(eps, fn ep -> dead_spot_v3_private_path?(ep["path_template"]) end)
        {section, Map.put(rec, "endpoints", kept)}

      _ ->
        {section, rec}
    end
  end

  # Overrides: group REST/WS entries, rename fields
  # Data is grouped by id (list of entries per exchange) because exchanges
  # with both REST and WS derived classes have two override records.
  defp get_overrides(id, data) do
    case Map.get(data.overrides, id) do
      nil -> nil
      [] -> nil
      entries when is_list(entries) -> build_overrides(entries)
    end
  end

  defp build_overrides(entries) do
    rest = Enum.find(entries, &String.starts_with?(&1["parent_key"] || "", "rest:"))
    ws = Enum.find(entries, &String.starts_with?(&1["parent_key"] || "", "ws:"))

    # Use REST entry as primary (or WS if no REST)
    primary = rest || ws

    %{
      "extends" => primary["extends"],
      "rest" => format_override_entry(rest),
      "ws" => format_override_entry(ws)
    }
  end

  defp format_override_entry(nil), do: nil

  defp format_override_entry(entry) do
    %{
      "parent_key" => entry["parent_key"],
      "overridden" => entry["overrides"],
      "new_methods" => entry["new_methods"],
      "inherited" => entry["inherited_methods"]
    }
  end

  # Returns the full version info map from priv/ccxt_version.json, or an empty
  # map if the file is missing/corrupt. Used by build_manifest to include
  # source_git_sha for reproducibility traceability.
  defp read_ccxt_version_info do
    case CcxtExtract.JsonIO.read_json(Paths.version_file()) do
      {:ok, data} -> data
      {:error, _} -> %{}
    end
  end

  # Strict read for the drift guard: distinguishes a genuinely-absent
  # version file (`:missing` — skip the guard, no baseline to drift
  # from) from a malformed one (raise — that is breakage, not absence).
  # `read_ccxt_version_info/0` above stays lenient because manifest
  # stamping degrades gracefully; the guard cannot.
  @spec read_version_file_strict() :: :missing | {:ok, map()}
  defp read_version_file_strict do
    path = Paths.version_file()

    case CcxtExtract.JsonIO.read_json(path) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, other} ->
        raise "Malformed #{path}: expected a JSON object, got #{inspect(other)}"

      {:error, {:missing_input, _}} ->
        :missing

      {:error, {:invalid_json, detail}} ->
        raise "Malformed priv/ccxt_version.json: #{detail}\n" <>
                "Run `mix ccxt_extract.setup --latest` to regenerate."
    end
  end

  # Compare the current `priv/ccxt` HEAD against the recorded
  # `source_git_sha`. Skips when there is no sha to compare against
  # (setup recorded "unknown") or no git metadata under `priv/ccxt`
  # (symlinked corpus, sparse checkout without `.git`) — neither is
  # drift, just an un-checkable state.
  @spec check_git_sha_drift!(map()) :: :ok
  defp check_git_sha_drift!(version_info) do
    recorded = version_info["source_git_sha"]
    ccxt_dir = Paths.priv("ccxt")

    cond do
      recorded in [nil, "", "unknown"] ->
        :ok

      not File.exists?(Path.join(ccxt_dir, ".git")) ->
        :ok

      true ->
        case current_ccxt_head(ccxt_dir) do
          {:ok, ^recorded} ->
            :ok

          {:ok, actual} ->
            raise """
            CCXT source drift detected.

              recorded source_git_sha: #{recorded}
              priv/ccxt current HEAD:  #{actual}

            Discovery data on disk was extracted from a different CCXT
            revision than the one recorded. Run `mix ccxt_extract.setup
            --latest` (or `--ccxt-version <v>`) to resync, or pass
            --allow-version-drift to proceed anyway.
            """

          :error ->
            Logger.warning(
              "Could not read `priv/ccxt` HEAD — skipping the git-SHA " <>
                "drift guard for this run."
            )
        end
    end
  end

  # Reads `priv/ccxt` HEAD via `git rev-parse`. `:error` on any non-zero
  # exit or a missing `git` binary — the caller treats that as
  # un-checkable (warn + continue), not as drift.
  @spec current_ccxt_head(String.t()) :: {:ok, String.t()} | :error
  defp current_ccxt_head(ccxt_dir) do
    case System.cmd("git", ["-C", ccxt_dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {_output, _code} -> :error
    end
  rescue
    ErlangError -> :error
  end

  # Compare the sha256 of `priv/ccxt_bundle.js` against the recorded
  # `bundle_sha256`. Absent field → skip: the version file predates the
  # Phase 5 field, and the next `mix ccxt_extract.setup` populates it
  # (the git-SHA check above still applies meanwhile). Field present but
  # bundle missing → raise: the recorded baseline cannot be honored.
  @spec check_bundle_drift!(map()) :: :ok
  defp check_bundle_drift!(version_info) do
    recorded = version_info["bundle_sha256"]
    bundle_path = Paths.bundle()

    cond do
      is_nil(recorded) ->
        :ok

      not File.exists?(bundle_path) ->
        raise """
        priv/ccxt_version.json records a bundle_sha256 but
        priv/ccxt_bundle.js is missing. Run `mix ccxt_extract.setup`
        to restore the bundle.
        """

      bundle_sha256(bundle_path) == recorded ->
        :ok

      true ->
        raise """
        CCXT bundle drift detected.

          recorded bundle_sha256: #{recorded}
          priv/ccxt_bundle.js:    #{bundle_sha256(bundle_path)}

        The browser bundle on disk differs from the one setup recorded.
        Run `mix ccxt_extract.setup --latest` to resync, or pass
        --allow-version-drift to proceed anyway.
        """
    end
  end

  defp copy_schema!(output_dir) do
    filename = Schema.schema_filename()
    schema_source = Paths.priv("schema/" <> filename)
    schema_dest = Path.join(output_dir, filename)
    File.cp!(schema_source, schema_dest)
  end

  # Copy _base_methods.json to the output directory as a shared artifact.
  # When the source is absent, removes stale target to prevent leftover artifacts.
  # Run `mix ccxt_extract.base_methods` to generate the source file.
  defp copy_base_methods!(output_dir, discoveries_dir) do
    source = Path.join(discoveries_dir, "_base_methods.json")
    target = Path.join(output_dir, "_base_methods.json")

    if File.exists?(source) do
      File.cp!(source, target)
    else
      File.rm(target)
    end
  end

  # Manifest derives ccxt_version from exchange data (the source of truth),
  # not from version_info on disk. version_info is only used for source_git_sha.
  defp build_manifest(exchanges, opts) do
    version_info = Keyword.get_lazy(opts, :version_info, fn -> read_ccxt_version_info() end)
    first = List.first(exchanges) || %{}

    %{
      "schema_version" => Schema.schema_version(),
      "ccxt_version" => first["ccxt_version"] || "unknown",
      "source_git_sha" => version_info["source_git_sha"],
      "extracted_at" => first["extracted_at"] || CcxtExtract.Clock.timestamp(:extracted_at),
      "tier_scope" => Keyword.get(opts, :tier_scope, "all"),
      "exchange_count" => length(exchanges),
      "exchanges" => exchanges |> Enum.map(& &1["exchange"]["id"]) |> Enum.sort()
    }
  end
end
