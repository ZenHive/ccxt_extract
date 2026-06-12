defmodule CcxtExtract.ContractTest do
  @moduledoc """
  Cross-field semantic invariants over emitted per-exchange JSON.

  Distinct from `CcxtExtract.Validation` (JSON Schema conformance + round-trip
  against source discovery). This module catches drift that stays schema-valid
  but breaks consumer assumptions — e.g. a capability flag declared without a
  corresponding endpoint mapping, or an error-field root no extractor has ever
  produced before.

  ## Seed invariants

    * `unified_endpoints_claimed_in_has` — every key of
      `endpoints.unified` must appear in `raw.describe.has` with
      value `true` or `"emulated"`.

    * `authenticated_sections_reachable_in_api` — every entry in
      `auth.authenticated_sections` must be reachable as a map key at
      some depth within `raw.describe.api`.

    * `error_code_fields_root_in_observed_set` — every
      `error_code_fields` entry's root (first element of `object_path`, or
      `object` when `object_path` is null) must appear in the committed
      baseline at `priv/contract_test/error_code_fields_roots.json`. The
      baseline is the authority: deriving the safelist from the same corpus
      being validated would make the invariant tautological. When a new
      root legitimately appears, update the baseline file intentionally.

    * `error_class_hierarchy_content_equals_baseline` — `errors.class_hierarchy`
      (the tree/flat_parents/ancestors record copied into every exchange) must
      equal the committed baseline at `priv/contract_test/error_class_hierarchy.json`
      exactly. Shape + JSV only see keys and map-of-string; this catches value
      drift (added/removed/renamed classes, parent changes, order).

    * `rate_limits_endpoint_cost_binding_coherent` — v4 emit only;
      `rate_limits.endpoint_cost_binding` equals
      `RateLimitCostBinding.derive(rate_limits.buckets)` (null when the wrapper
      is unresolved or has no buckets).

  New invariants append to `@invariants`; the runner is registry-driven.
  """

  alias CcxtExtract.ContractTest.Finding
  alias CcxtExtract.ErrorHierarchy
  alias CcxtExtract.JsonIO
  alias CcxtExtract.Normalization
  alias CcxtExtract.RateLimitCostBinding
  alias CcxtExtract.RequestShape
  alias CcxtExtract.SignRecipe
  alias CcxtExtract.TestnetUrls
  alias CcxtExtract.WsAuth
  alias CcxtExtract.WsDispatch
  alias CcxtExtract.WsHeartbeat
  alias CcxtExtract.WsOhlcvSemantics
  alias CcxtExtract.WsOrderbookSemantics
  alias CcxtExtract.WsSubscribe
  alias CcxtExtract.WsTradesSemantics

  @type finding :: Finding.t()

  @type report :: %{
          String.t() => term()
        }

  @invariants [
    {"unified_endpoints_claimed_in_has", :check_unified_endpoints_claimed_in_has},
    {"authenticated_sections_reachable_in_api", :check_authenticated_sections_reachable_in_api},
    {"error_code_fields_root_in_observed_set", :check_error_code_fields_root},
    {"override_registry_valid", :check_override_registry_valid},
    {"override_paths_present_in_output", :check_override_paths_present_in_output},
    {"provenance_covers_schema", :check_provenance_covers_schema},
    {"request_defaults_resolvable_reachable_from_unified", :check_request_defaults_resolvable_reachable_from_unified},
    {"sign_recipe_keys_match_auth_sections", :check_sign_recipe_keys_match_auth_sections},
    {"sign_recipe_shape_valid", :check_sign_recipe_shape_valid},
    {"sign_recipe_honesty_valid", :check_sign_recipe_honesty_valid},
    {"request_shape_keys_match_auth_sections", :check_request_shape_keys_match_auth_sections},
    {"request_shape_valid", :check_request_shape_valid},
    {"request_shape_honesty_valid", :check_request_shape_honesty_valid},
    {"unified_method_descriptors_shape_valid", :check_unified_method_descriptors_shape_valid},
    {"testnet_urls_shape_valid", :check_testnet_urls_shape_valid},
    {"websocket_heartbeat_shape_valid", :check_websocket_heartbeat_shape_valid},
    {"websocket_auth_shape_valid", :check_websocket_auth_shape_valid},
    {"websocket_subscribe_shape_valid", :check_websocket_subscribe_shape_valid},
    {"websocket_dispatch_shape_valid", :check_websocket_dispatch_shape_valid},
    {"websocket_orderbook_semantics_shape_valid", :check_websocket_orderbook_semantics_shape_valid},
    {"websocket_trades_semantics_shape_valid", :check_websocket_trades_semantics_shape_valid},
    {"websocket_ohlcv_semantics_shape_valid", :check_websocket_ohlcv_semantics_shape_valid},
    {"error_class_hierarchy_shape_valid", :check_error_class_hierarchy_shape_valid},
    {"error_classes_covered_by_hierarchy", :check_error_classes_covered_by_hierarchy},
    {"error_class_hierarchy_content_equals_baseline", :check_error_class_hierarchy_content_equals_baseline},
    {"normalization_shape_valid", :check_normalization_shape_valid},
    {"parse_methods_digest_covers_inventory", :check_parse_methods_digest_covers_inventory},
    {"handle_errors_retryable_shape_valid", :check_handle_errors_retryable_shape_valid},
    {"handler_dispatch_shape_valid", :check_handler_dispatch_shape_valid},
    {"rate_limits_endpoint_cost_binding_coherent", :check_rate_limits_endpoint_cost_binding_coherent},
    {"transaction_classification_promoted_flags_consistent", :check_transaction_classification_promoted_flags_consistent}
  ]

  # Corpus-level invariants run once per run_all/1 (not per-exchange). Used
  # for architectural truths about the codebase itself — e.g. Paths
  # read-vs-write split — where no individual exchange is the subject.
  # Findings use `exchange: "_corpus"` as a stable sentinel so downstream
  # sorting and reporting treat them as a peer row, not per-exchange noise.
  @corpus_invariants [
    {"paths_rw_split", :check_paths_rw_split}
  ]

  @paths_read_helpers [:priv, :priv_dir, :discoveries, :ts_src, :bundle, :version_file]

  # Content readers: functions that consume a filesystem path and return file
  # CONTENT (bytes, a stream, a handle) rather than a path. Once a path flows
  # through one of these the downstream value is no longer a path, so feeding
  # it to a writer is legitimate — e.g. reading a committed JSON schema and
  # writing its bytes into the output dir. Used as taint sanitizers.
  #
  # Narrowed to content readers only: path-inspection probes
  # (`exists?`/`stat`/`ls`) are deliberately NOT sanitizers. The
  # "inspect a path, then write somewhere unrelated" pattern is handled by the
  # position-aware sink registry below (the inspected path never reaches the
  # writer's write-position argument), so it no longer needs a chop-level
  # sanitizer that would also mask a genuine `File.write!(inspected_path, …)`.
  @file_reader_fns [:read, :read!, :stream!, :open, :open!]

  # Position-aware writer-sink registry, keyed on `{function, arity}` → the
  # argument indices that name a WRITE target. A `File` call is a paths_rw sink
  # only when its `{function, arity}` is a key here, and a flow is a leak only
  # when a read-helper path reaches one of the listed write-position arguments.
  # This distinguishes `File.cp!/2` arg 0 (the read source — legitimate for a
  # `Paths.priv(...)` path) from arg 1 (the write destination). `File.rename/2`
  # mutates both its source (removed) and destination, so both are writes.
  @writer_sinks %{
    {:write, 2} => [0],
    {:write, 3} => [0],
    {:write!, 2} => [0],
    {:write!, 3} => [0],
    {:mkdir_p, 1} => [0],
    {:mkdir_p!, 1} => [0],
    {:cp, 2} => [1],
    {:cp, 3} => [1],
    {:cp!, 2} => [1],
    {:cp!, 3} => [1],
    {:cp_r, 2} => [1],
    {:cp_r, 3} => [1],
    {:cp_r!, 2} => [1],
    {:cp_r!, 3} => [1],
    {:rm, 1} => [0],
    {:rm!, 1} => [0],
    {:rm_rf, 1} => [0],
    {:rm_rf!, 1} => [0],
    {:rename, 2} => [0, 1],
    {:touch, 1} => [0],
    {:touch, 2} => [0],
    {:touch!, 1} => [0],
    {:touch!, 2} => [0]
  }

  @doc """
  Load every `priv/output/<exchange>.json` (skipping `_*.json` manifests),
  run all invariants, return a deterministic report.

  ## Options

    * `:output_dir` — directory of emitted JSON (default: `priv/output`).
    * `:baseline_path` — committed baseline file for
      `error_code_fields_roots` (default:
      `priv/contract_test/error_code_fields_roots.json`).
    * `:baseline_roots` — inline baseline list (tests). Takes precedence
      over `:baseline_path`.
    * `:hierarchy_baseline` — inline 3-key hierarchy map for the
      `error_class_hierarchy_content_equals_baseline` check (tests). Takes
      precedence over the file at `priv/contract_test/error_class_hierarchy.json`.
    * `:request_defaults_reachable_baseline` — inline `{exchange_id =>
      [method, …]}` allowlist for
      `request_defaults_resolvable_reachable_from_unified` (tests). Takes
      precedence over `:request_defaults_baseline_path`.
    * `:request_defaults_baseline_path` — override the committed allowlist
      path (default: `priv/contract_test/request_defaults_reachable_baseline.json`).
    * `:exchanges` — optional list/MapSet of exchange IDs to load. When
      given, only matching `<id>.json` files are loaded. Missing files
      are silently skipped — callers that need strict "missing" detection
      should diff their requested set against the emitted
      `summary.exchanges_checked` / `findings` set.
    * `:tier_scope` — `CcxtExtract.Scope.to_manifest_value/1` output;
      stamped on the report envelope. Defaults to `"all"`.
  """
  @spec run_all(keyword()) :: {:ok, report()}
  def run_all(opts \\ []) do
    output_dir = opts[:output_dir] || CcxtExtract.Paths.out("output")
    baseline_roots = opts[:baseline_roots] || load_baseline_roots(opts)
    exchanges = load_exchanges(output_dir, opts[:exchanges])
    parse_methods_inventory = opts[:parse_methods_inventory] || load_parse_methods_inventory(opts)

    hierarchy_baseline =
      case Keyword.fetch(opts, :hierarchy_baseline) do
        {:ok, v} -> v
        :error -> load_hierarchy_baseline(opts)
      end

    baseline = %{
      error_code_fields_roots: baseline_roots,
      parse_methods_inventory: parse_methods_inventory,
      error_class_hierarchy: hierarchy_baseline,
      request_defaults_reachable_baseline:
        opts[:request_defaults_reachable_baseline] || load_request_defaults_reachable_baseline(opts)
    }

    tier_scope = Keyword.get(opts, :tier_scope, "all")

    per_exchange_findings = Enum.flat_map(exchanges, &run_invariants(&1, baseline))
    corpus_findings = run_corpus_invariants(opts)

    findings = Enum.sort_by(per_exchange_findings ++ corpus_findings, &{&1.exchange, &1.invariant, &1.path})

    {:ok, build_report(exchanges, findings, baseline, tier_scope)}
  end

  @doc """
  Write a report to disk as pretty-printed JSON.
  """
  @spec write!(report(), Path.t()) :: :ok
  def write!(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(report, pretty: true))
    :ok
  end

  @doc "Registry of per-exchange `{name, function_atom}` tuples. Public for test introspection."
  @spec invariants() :: [{String.t(), atom()}]
  def invariants, do: @invariants

  @doc "Registry of corpus-level `{name, function_atom}` tuples. Public for test introspection."
  @spec corpus_invariants() :: [{String.t(), atom()}]
  def corpus_invariants, do: @corpus_invariants

  ## Invariants

  @doc """
  Flag unified_endpoints entries that aren't claimed as supported in
  `raw.describe.has`. Public for registry-based dispatch and direct
  test introspection.
  """
  # TODO(Task 57c): Baseline run surfaces ~341 legitimate drift findings —
  # unified_endpoints over-declares vs raw.describe.has. Triage in 57c.
  @spec check_unified_endpoints_claimed_in_has(map(), map()) :: [finding()]
  def check_unified_endpoints_claimed_in_has(exchange, _observed) do
    id = exchange_id(exchange)
    has = get_in(exchange, ["raw", "describe", "has"]) || %{}
    unified = get_in(exchange, ["endpoints", "unified"]) || %{}

    unified
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&has_claims_support?(has, &1))
    |> Enum.map(fn name ->
      actual = Map.get(has, name, :missing)

      %Finding{
        exchange: id,
        invariant: "unified_endpoints_claimed_in_has",
        path: "endpoints.unified.#{name}",
        message: "endpoints.unified declares #{name} but raw.describe.has.#{name} = #{inspect(actual)}"
      }
    end)
  end

  # CCXT uses true for direct support and "emulated" for composed support
  # (a method implemented via other unified calls). Both claim support.
  defp has_claims_support?(has, name) do
    Map.get(has, name) in [true, "emulated"]
  end

  @doc """
  Flag `endpoints.transaction_classification` entries that declare
  `on_chain: true` without `transactional: true`.

  `on_chain` is strictly narrower than `transactional` — every on-chain
  endpoint mutates state, so the inverse implication is incoherent. The
  raw-broadcast classifier (Task 73f) promotes detected broadcast endpoints
  to BOTH flags; this invariant guards that promotion so a consumer can rely
  on `on_chain == false` as a negative safety gate (a broadcast endpoint can
  never hide behind `on_chain: false`, and an `on_chain: true` entry always
  carries `transactional: true`).
  """
  @spec check_transaction_classification_promoted_flags_consistent(map(), map()) :: [finding()]
  def check_transaction_classification_promoted_flags_consistent(exchange, _observed) do
    id = exchange_id(exchange)
    classification = get_in(exchange, ["endpoints", "transaction_classification"]) || %{}

    classification
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.filter(fn {_name, flags} -> incoherent_on_chain?(flags) end)
    |> Enum.map(fn {name, flags} ->
      %Finding{
        exchange: id,
        invariant: "transaction_classification_promoted_flags_consistent",
        path: "endpoints.transaction_classification.#{name}",
        message:
          "transaction_classification.#{name} declares on_chain=true but transactional=#{inspect(Map.get(flags, "transactional"))} (on_chain must imply transactional)"
      }
    end)
  end

  defp incoherent_on_chain?(%{"on_chain" => true} = flags), do: Map.get(flags, "transactional") != true
  defp incoherent_on_chain?(_), do: false

  @doc """
  Flag `request_defaults` methods that contain at least one `kind: "literal"`
  entry but aren't reachable from `endpoints.unified` — where
  "reachable" means: the method name is either a key of `endpoints.unified`
  OR appears as a value in some `endpoints.unified[*]` list. Helper methods
  like hyperliquid.fetchSwapMarkets — not directly unified but called from
  a unified `fetchMarkets` entry — stay in bounds.

  Unresolved-only method entries are ignored because their presence is
  informational (the Honesty Rule preserves them so consumers know the
  endpoint has a structured body); they don't assert a consumer contract
  the way literal entries do.

  ## Baseline allowlist (Task 110)

  `endpoints.unified` is the *filtered* unified-call map: `Pipeline`'s
  `restrict_to_canonical_vocab` strips internal routing helpers
  (`fetchSpotMarkets`, `modifyMarginHelper`, …) that aren't canonical
  `has` keys, and `filter_unified_endpoints` drops methods whose interface
  calls aren't captured. So two legitimate method classes carry resolvable
  literal bodies yet never appear in `endpoints.unified`:

    1. **Transitive helpers** — `this.fetchSpotMarkets()` called from a
       unified `fetchMarkets`; the call chain is invisible because unified
       values store *interface* names (`publicGetX`), never helper names.
    2. **Unified methods absent from the map** — real `has`-true methods
       (`binance.fetchFundingHistory`, `kraken.fetchOrdersByIds`) whose
       interface call the unified extractor didn't surface.

  Neither is resolvable structurally from the emitted JSON, so a committed
  per-exchange allowlist at
  `priv/contract_test/request_defaults_reachable_baseline.json`
  (`{exchange_id => [method, …]}`) exempts the known-legitimate set. The
  baseline is the authority — update it intentionally when a CCXT bump adds
  or removes such methods (a *new* unreachable literal method that isn't in
  the baseline still flags). Scoping is per-`{exchange, method}` pair, so a
  helper named for one exchange can't mask a genuine orphan in another.
  """
  @spec check_request_defaults_resolvable_reachable_from_unified(map(), map()) :: [finding()]
  def check_request_defaults_resolvable_reachable_from_unified(exchange, observed) do
    id = exchange_id(exchange)
    defaults = get_in(exchange, ["endpoints", "request", "defaults"]) || %{}
    unified = get_in(exchange, ["endpoints", "unified"]) || %{}
    reachable = unified_reachable_names(unified)
    allowed = baseline_allowed_methods(observed, id)

    defaults
    |> Enum.sort_by(fn {method, _} -> method end)
    |> Enum.filter(fn {_method, body} -> has_literal_entry?(body) end)
    |> Enum.reject(fn {method, _} -> MapSet.member?(reachable, method) or MapSet.member?(allowed, method) end)
    |> Enum.map(fn {method, _} ->
      %Finding{
        exchange: id,
        invariant: "request_defaults_resolvable_reachable_from_unified",
        path: "endpoints.request.defaults.#{method}",
        message:
          "endpoints.request.defaults.#{method} has a resolvable literal entry but #{method} is not reachable from endpoints.unified (neither a key nor a value)"
      }
    end)
  end

  defp unified_reachable_names(unified) when is_map(unified) do
    keys = Map.keys(unified)

    values =
      Enum.flat_map(unified, fn
        {_k, names} when is_list(names) -> Enum.filter(names, &is_binary/1)
        _ -> []
      end)

    MapSet.new(keys ++ values)
  end

  defp unified_reachable_names(_), do: MapSet.new()

  # Per-exchange Task 110 allowlist: methods known to carry resolvable literal
  # bodies but legitimately absent from the filtered `endpoints.unified` map
  # (transitive helpers + unified methods the extractor didn't surface).
  defp baseline_allowed_methods(%{request_defaults_reachable_baseline: baseline}, id) when is_map(baseline) do
    case Map.get(baseline, id) do
      methods when is_list(methods) -> MapSet.new(methods)
      _ -> MapSet.new()
    end
  end

  defp baseline_allowed_methods(_observed, _id), do: MapSet.new()

  defp has_literal_entry?(body) when is_map(body) do
    Enum.any?(body, fn
      {_k, %{"kind" => "literal"}} -> true
      _ -> false
    end)
  end

  defp has_literal_entry?(_), do: false

  @doc """
  Flag `authenticated_sections` entries that aren't reachable in
  `raw.describe.api` at any nesting depth.
  """
  # TODO(Task 57d): Tokocrypto findings show inherited sign() gates pointing
  # at parent-class api sections. Walk inheritance + intersect in 57d.
  @spec check_authenticated_sections_reachable_in_api(map(), map()) :: [finding()]
  def check_authenticated_sections_reachable_in_api(exchange, _observed) do
    id = exchange_id(exchange)
    sections = get_in(exchange, ["auth", "authenticated_sections"]) || []
    api = get_in(exchange, ["raw", "describe", "api"]) || %{}
    reachable = collect_map_keys(api)

    sections
    |> Enum.with_index()
    |> Enum.reject(fn {name, _i} -> reachable_in_api?(name, api, reachable) end)
    |> Enum.map(fn {name, i} ->
      %Finding{
        exchange: id,
        invariant: "authenticated_sections_reachable_in_api",
        path: "auth.authenticated_sections[#{i}]",
        message: "authenticated section #{inspect(name)} not reachable in raw.describe.api tree"
      }
    end)
  end

  defp reachable_in_api?(name, api, reachable) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [flat] -> MapSet.member?(reachable, flat)
      [parent, child] -> is_map(get_in(api, [parent, child]))
    end
  end

  defp reachable_in_api?(_name, _api, _reachable), do: false

  @doc """
  Flag drift between `auth.sign_recipe` keys and
  `auth.authenticated_sections`. The two must agree as sets: every
  authenticated section gets one recipe; no recipe exists for a
  non-authenticated section.

  Expected clean under the Task 64 scaffold (`SignRecipe.build_default/1`
  builds the recipe directly from `authenticated_sections`). Future
  derivation tasks (65–69) flip recipe values but must not add or remove
  recipe keys.
  """
  @spec check_sign_recipe_keys_match_auth_sections(map(), map()) :: [finding()]
  def check_sign_recipe_keys_match_auth_sections(exchange, _observed) do
    id = exchange_id(exchange)
    recipe = get_in(exchange, ["auth", "sign_recipe"]) || %{}
    sections = get_in(exchange, ["auth", "authenticated_sections"]) || []

    recipe_keys = recipe |> Map.keys() |> MapSet.new()
    section_keys = MapSet.new(sections)

    missing =
      section_keys
      |> MapSet.difference(recipe_keys)
      |> Enum.sort()
      |> Enum.map(fn name ->
        %Finding{
          exchange: id,
          invariant: "sign_recipe_keys_match_auth_sections",
          path: "auth.sign_recipe.#{name}",
          message: "authenticated section #{inspect(name)} has no sign_recipe entry"
        }
      end)

    extra =
      recipe_keys
      |> MapSet.difference(section_keys)
      |> Enum.sort()
      |> Enum.map(fn name ->
        %Finding{
          exchange: id,
          invariant: "sign_recipe_keys_match_auth_sections",
          path: "auth.sign_recipe.#{name}",
          message: "sign_recipe has entry #{inspect(name)} but it is not in authenticated_sections"
        }
      end)

    missing ++ extra
  end

  @doc """
  Structural belt-and-suspenders check over each `auth.sign_recipe`
  record:
    * the eight required keys are present (no missing / no extras),
    * `patch_count` is a non-negative integer,
    * `unresolved_reason` is either `null` or in the closed vocabulary.

  Deeper per-field enum/shape validation is done by
  `CcxtExtract.Validation.validate_schema/2` against `exchange_v4.json#/$defs/SignRecipeRecord`.
  This invariant catches the narrow case where JSV validation was skipped
  or the schema drifted.
  """
  @spec check_sign_recipe_shape_valid(map(), map()) :: [finding()]
  def check_sign_recipe_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    recipe = get_in(exchange, ["auth", "sign_recipe"]) || %{}

    recipe
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.flat_map(fn {section, record} -> sign_recipe_record_findings(id, section, record) end)
  end

  defp sign_recipe_record_findings(id, section, record) when is_map(record) do
    missing = SignRecipe.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- SignRecipe.required_keys()

    missing_findings =
      Enum.map(missing, fn key ->
        sign_recipe_finding(id, section, "missing required key #{inspect(key)}")
      end)

    extra_findings =
      Enum.map(extra, fn key ->
        sign_recipe_finding(id, section, "unexpected key #{inspect(key)}")
      end)

    value_findings =
      Enum.reject(
        [
          patch_count_finding(id, section, Map.get(record, "patch_count")),
          unresolved_reason_finding(id, section, Map.get(record, "unresolved_reason"))
        ],
        &is_nil/1
      )

    missing_findings ++ extra_findings ++ value_findings
  end

  defp sign_recipe_record_findings(id, section, _record) do
    [sign_recipe_finding(id, section, "recipe record must be a map")]
  end

  defp sign_recipe_finding(id, section, message) do
    %Finding{
      exchange: id,
      invariant: "sign_recipe_shape_valid",
      path: "auth.sign_recipe.#{section}",
      message: message
    }
  end

  @method_descriptor_keys ~w(async description errors name params_doc returns signature source unresolved_reason)
  @method_descriptor_signature_keys ~w(params return_type)
  @method_descriptor_param_keys ~w(default name optional type)
  @method_descriptor_typed_doc_keys ~w(description type)
  @method_descriptor_error_keys ~w(class description)
  @method_descriptor_unresolved_reasons ~w(no_jsdoc)

  @doc """
  Validate `endpoints.descriptors`, the per-unified-method descriptor map
  projected from `priv/discoveries/method_descriptors.json`.

  JSON Schema enforces the basic object shape. This invariant catches the
  cross-field honesty rules: map key matches descriptor name, `errors: null`
  only occurs with `unresolved_reason: "no_jsdoc"`, and a `no_jsdoc`
  descriptor keeps every JSDoc-derived field null.
  """
  @spec check_unified_method_descriptors_shape_valid(map(), map()) :: [finding()]
  def check_unified_method_descriptors_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    descriptors = get_in(exchange, ["endpoints", "descriptors"])

    method_descriptors_findings(id, descriptors)
  end

  defp method_descriptors_findings(_id, nil), do: []

  defp method_descriptors_findings(id, descriptors) when is_map(descriptors) do
    descriptors
    |> Enum.sort_by(fn {method, _descriptor} -> inspect(method) end)
    |> Enum.flat_map(fn {method, descriptor} ->
      method_descriptor_findings(id, method, descriptor)
    end)
  end

  defp method_descriptors_findings(id, descriptors) do
    [
      method_descriptor_finding(
        id,
        "endpoints.descriptors",
        "descriptors must be a map or null, got #{inspect(descriptors)}"
      )
    ]
  end

  defp method_descriptor_findings(id, method, descriptor) when is_binary(method) and is_map(descriptor) do
    path = "endpoints.descriptors.#{method}"
    missing = @method_descriptor_keys -- Map.keys(descriptor)
    extra = Map.keys(descriptor) -- @method_descriptor_keys

    key_findings =
      Enum.map(missing, &method_descriptor_finding(id, path, "missing required key #{inspect(&1)}")) ++
        Enum.map(extra, &method_descriptor_finding(id, path, "unexpected key #{inspect(&1)}"))

    value_findings =
      if missing == [] do
        [
          descriptor_name_finding(id, method, descriptor["name"]),
          descriptor_boolean_finding(id, "#{path}.async", descriptor["async"]),
          nullable_string_finding(id, "#{path}.description", descriptor["description"]),
          params_doc_findings(id, "#{path}.params_doc", descriptor["params_doc"]),
          typed_doc_findings(id, "#{path}.returns", descriptor["returns"], true),
          descriptor_errors_findings(id, "#{path}.errors", descriptor["errors"], descriptor["unresolved_reason"]),
          descriptor_source_finding(id, "#{path}.source", descriptor["source"]),
          descriptor_unresolved_reason_finding(id, "#{path}.unresolved_reason", descriptor["unresolved_reason"])
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)
        |> Kernel.++(signature_findings(id, "#{path}.signature", descriptor["signature"]))
        |> Kernel.++(no_jsdoc_consistency_findings(id, path, descriptor))
      else
        []
      end

    key_findings ++ value_findings
  end

  defp method_descriptor_findings(id, method, descriptor) do
    method_descriptor_finding(
      id,
      "endpoints.descriptors.#{inspect(method)}",
      "descriptor record must be a map keyed by method name, got #{inspect(descriptor)}"
    )
  end

  defp descriptor_name_finding(id, method, name) do
    cond do
      name == method ->
        nil

      is_binary(name) ->
        method_descriptor_finding(
          id,
          "endpoints.descriptors.#{method}.name",
          "descriptor name #{inspect(name)} must match map key #{inspect(method)}"
        )

      true ->
        method_descriptor_finding(
          id,
          "endpoints.descriptors.#{method}.name",
          "name must be a string, got #{inspect(name)}"
        )
    end
  end

  defp descriptor_boolean_finding(_id, _path, value) when is_boolean(value), do: nil

  defp descriptor_boolean_finding(id, path, value) do
    method_descriptor_finding(id, path, "must be a boolean, got #{inspect(value)}")
  end

  defp nullable_string_finding(_id, _path, value) when is_binary(value) or is_nil(value), do: nil

  defp nullable_string_finding(id, path, value) do
    method_descriptor_finding(id, path, "must be a string or null, got #{inspect(value)}")
  end

  defp params_doc_findings(_id, _path, nil), do: []

  defp params_doc_findings(id, path, docs) when is_map(docs) do
    docs
    |> Enum.reject(fn {key, value} -> is_binary(key) and (is_binary(value) or is_nil(value)) end)
    |> Enum.map(fn {key, value} ->
      method_descriptor_finding(id, "#{path}.#{inspect(key)}", "param doc must be string or null, got #{inspect(value)}")
    end)
  end

  defp params_doc_findings(id, path, value) do
    [method_descriptor_finding(id, path, "params_doc must be a map or null, got #{inspect(value)}")]
  end

  defp typed_doc_findings(_id, _path, nil, true), do: []

  defp typed_doc_findings(id, path, doc, _nullable?) when is_map(doc) do
    missing = @method_descriptor_typed_doc_keys -- Map.keys(doc)
    extra = Map.keys(doc) -- @method_descriptor_typed_doc_keys

    key_findings =
      Enum.map(missing, &method_descriptor_finding(id, path, "missing required key #{inspect(&1)}")) ++
        Enum.map(extra, &method_descriptor_finding(id, path, "unexpected key #{inspect(&1)}"))

    value_findings =
      Enum.flat_map(@method_descriptor_typed_doc_keys, fn key ->
        case nullable_string_finding(id, "#{path}.#{key}", Map.get(doc, key)) do
          nil -> []
          finding -> [finding]
        end
      end)

    key_findings ++ value_findings
  end

  defp typed_doc_findings(id, path, value, _nullable?) do
    [method_descriptor_finding(id, path, "typed doc must be a map or null, got #{inspect(value)}")]
  end

  defp descriptor_errors_findings(_id, _path, nil, "no_jsdoc"), do: []

  defp descriptor_errors_findings(id, path, nil, reason) do
    [
      method_descriptor_finding(
        id,
        path,
        "errors may be null only when unresolved_reason=\"no_jsdoc\", got #{inspect(reason)}"
      )
    ]
  end

  defp descriptor_errors_findings(id, path, errors, _reason) when is_list(errors) do
    errors
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} -> descriptor_error_entry_findings(id, "#{path}[#{index}]", entry) end)
  end

  defp descriptor_errors_findings(id, path, value, _reason) do
    [method_descriptor_finding(id, path, "errors must be a list or null, got #{inspect(value)}")]
  end

  defp descriptor_error_entry_findings(id, path, entry) when is_map(entry) do
    missing = @method_descriptor_error_keys -- Map.keys(entry)
    extra = Map.keys(entry) -- @method_descriptor_error_keys

    key_findings =
      Enum.map(missing, &method_descriptor_finding(id, path, "missing required key #{inspect(&1)}")) ++
        Enum.map(extra, &method_descriptor_finding(id, path, "unexpected key #{inspect(&1)}"))

    value_findings =
      Enum.flat_map(@method_descriptor_error_keys, fn key ->
        case nullable_string_finding(id, "#{path}.#{key}", Map.get(entry, key)) do
          nil -> []
          finding -> [finding]
        end
      end)

    key_findings ++ value_findings
  end

  defp descriptor_error_entry_findings(id, path, value) do
    [method_descriptor_finding(id, path, "error entry must be a map, got #{inspect(value)}")]
  end

  defp descriptor_source_finding(_id, _path, source) when is_binary(source) and byte_size(source) > 0, do: nil

  defp descriptor_source_finding(id, path, source) do
    method_descriptor_finding(id, path, "source must be a non-empty string, got #{inspect(source)}")
  end

  defp descriptor_unresolved_reason_finding(_id, _path, nil), do: nil

  defp descriptor_unresolved_reason_finding(id, path, reason) do
    if reason in @method_descriptor_unresolved_reasons do
      nil
    else
      method_descriptor_finding(id, path, "unresolved_reason must be null or \"no_jsdoc\", got #{inspect(reason)}")
    end
  end

  defp signature_findings(id, path, signature) when is_map(signature) do
    missing = @method_descriptor_signature_keys -- Map.keys(signature)
    extra = Map.keys(signature) -- @method_descriptor_signature_keys

    key_findings =
      Enum.map(missing, &method_descriptor_finding(id, path, "missing required key #{inspect(&1)}")) ++
        Enum.map(extra, &method_descriptor_finding(id, path, "unexpected key #{inspect(&1)}"))

    value_findings =
      if missing == [] do
        id
        |> nullable_string_finding("#{path}.return_type", signature["return_type"])
        |> List.wrap()
        |> Enum.reject(&is_nil/1)
        |> Kernel.++(signature_params_findings(id, "#{path}.params", signature["params"]))
      else
        []
      end

    key_findings ++ value_findings
  end

  defp signature_findings(id, path, value) do
    [method_descriptor_finding(id, path, "signature must be a map, got #{inspect(value)}")]
  end

  defp signature_params_findings(id, path, params) when is_list(params) do
    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {param, index} -> signature_param_findings(id, "#{path}[#{index}]", param) end)
  end

  defp signature_params_findings(id, path, value) do
    [method_descriptor_finding(id, path, "params must be a list, got #{inspect(value)}")]
  end

  defp signature_param_findings(id, path, param) when is_map(param) do
    missing = @method_descriptor_param_keys -- Map.keys(param)
    extra = Map.keys(param) -- @method_descriptor_param_keys

    key_findings =
      Enum.map(missing, &method_descriptor_finding(id, path, "missing required key #{inspect(&1)}")) ++
        Enum.map(extra, &method_descriptor_finding(id, path, "unexpected key #{inspect(&1)}"))

    value_findings =
      if missing == [] do
        Enum.reject(
          [
            required_string_finding(id, "#{path}.name", param["name"]),
            nullable_string_finding(id, "#{path}.type", param["type"]),
            descriptor_boolean_finding(id, "#{path}.optional", param["optional"]),
            nullable_string_finding(id, "#{path}.default", param["default"])
          ],
          &is_nil/1
        )
      else
        []
      end

    key_findings ++ value_findings
  end

  defp signature_param_findings(id, path, value) do
    [method_descriptor_finding(id, path, "param must be a map, got #{inspect(value)}")]
  end

  defp required_string_finding(_id, _path, value) when is_binary(value) and byte_size(value) > 0, do: nil

  defp required_string_finding(id, path, value) do
    method_descriptor_finding(id, path, "must be a non-empty string, got #{inspect(value)}")
  end

  defp no_jsdoc_consistency_findings(id, path, %{"unresolved_reason" => "no_jsdoc"} = descriptor) do
    ~w(description params_doc returns errors)
    |> Enum.reject(&is_nil(descriptor[&1]))
    |> Enum.map(fn key ->
      method_descriptor_finding(id, "#{path}.#{key}", "must be null when unresolved_reason=\"no_jsdoc\"")
    end)
  end

  defp no_jsdoc_consistency_findings(_id, _path, _descriptor), do: []

  defp method_descriptor_finding(id, path, message) do
    %Finding{
      exchange: id,
      invariant: "unified_method_descriptors_shape_valid",
      path: path,
      message: message
    }
  end

  defp patch_count_finding(_id, _section, v) when is_integer(v) and v >= 0, do: nil

  defp patch_count_finding(id, section, v),
    do: sign_recipe_finding(id, section, "patch_count must be a non-negative integer, got #{inspect(v)}")

  defp unresolved_reason_finding(_id, _section, nil), do: nil

  defp unresolved_reason_finding(id, section, v) do
    if v in SignRecipe.unresolved_reasons() do
      nil
    else
      sign_recipe_finding(
        id,
        section,
        "unresolved_reason must be null or one of #{inspect(SignRecipe.unresolved_reasons())}, got #{inspect(v)}"
      )
    end
  end

  @doc """
  Validate the `auth.sign_recipe` honesty biconditional (Task 69):

      unresolved_reason == nil  ⇔  every derivation field non-nil

  One half is enforced in `SignRecipe.Derive` (the write-side flip),
  the other half here. Any record that escapes with a null tag but a
  null derivation field (a consumer would mistakenly trust the recipe
  as fully resolved), or with a populated tag but all-six fields
  non-null (the tag is lying about what's known), is flagged.

  Terminal tags (`"custom_signing_family"`, `"ambiguous_ast"`,
  `"no_sign_method"`) coexist with any null derivation field by
  construction — those records are honestly partial and pass cleanly.
  The `"not_yet_derived"` tag is the scaffold default; records
  carrying it with all seven fields populated are the bug this invariant
  catches when Derive is bypassed (e.g. through an override chain).
  """
  @spec check_sign_recipe_honesty_valid(map(), map()) :: [finding()]
  def check_sign_recipe_honesty_valid(exchange, _observed) do
    id = exchange_id(exchange)
    recipe = get_in(exchange, ["auth", "sign_recipe"]) || %{}

    recipe
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.flat_map(fn {section, record} -> sign_recipe_honesty_record_findings(id, section, record) end)
  end

  defp sign_recipe_honesty_record_findings(id, section, record) when is_map(record) do
    tag = Map.get(record, "unresolved_reason")
    all_populated? = SignRecipe.all_derivation_fields_populated?(record)

    cond do
      is_nil(tag) and not all_populated? ->
        missing = null_derivation_fields(record)

        [
          sign_recipe_honesty_finding(
            id,
            section,
            "unresolved_reason is null but derivation field(s) #{inspect(missing)} are null"
          )
        ]

      not is_nil(tag) and all_populated? ->
        [
          sign_recipe_honesty_finding(
            id,
            section,
            "unresolved_reason is #{inspect(tag)} but all seven derivation fields are populated " <>
              "(tag should be null)"
          )
        ]

      true ->
        []
    end
  end

  defp sign_recipe_honesty_record_findings(_id, _section, _record), do: []

  defp null_derivation_fields(record) do
    Enum.filter(SignRecipe.derivation_fields(), fn key ->
      case Map.fetch(record, key) do
        {:ok, nil} -> true
        :error -> true
        _ -> false
      end
    end)
  end

  defp sign_recipe_honesty_finding(id, section, message) do
    %Finding{
      exchange: id,
      invariant: "sign_recipe_honesty_valid",
      path: "auth.sign_recipe.#{section}",
      message: message
    }
  end

  @doc """
  Flag drift between `endpoints.request.shape` keys and
  `auth.authenticated_sections`. Mirror of the sign_recipe
  variant — the two key sets must agree exactly.
  """
  @spec check_request_shape_keys_match_auth_sections(map(), map()) :: [finding()]
  def check_request_shape_keys_match_auth_sections(exchange, _observed) do
    id = exchange_id(exchange)
    record_map = get_in(exchange, ["endpoints", "request", "shape"]) || %{}
    sections = get_in(exchange, ["auth", "authenticated_sections"]) || []

    record_keys = record_map |> Map.keys() |> MapSet.new()
    section_keys = MapSet.new(sections)

    missing =
      section_keys
      |> MapSet.difference(record_keys)
      |> Enum.sort()
      |> Enum.map(fn name ->
        %Finding{
          exchange: id,
          invariant: "request_shape_keys_match_auth_sections",
          path: "endpoints.request.shape.#{name}",
          message: "authenticated section #{inspect(name)} has no request_shape entry"
        }
      end)

    extra =
      record_keys
      |> MapSet.difference(section_keys)
      |> Enum.sort()
      |> Enum.map(fn name ->
        %Finding{
          exchange: id,
          invariant: "request_shape_keys_match_auth_sections",
          path: "endpoints.request.shape.#{name}",
          message: "request_shape has entry #{inspect(name)} but it is not in authenticated_sections"
        }
      end)

    missing ++ extra
  end

  @doc """
  Structural belt-and-suspenders check over each
  `endpoints.request.shape` record — the five required keys are
  present, `patch_count` is a non-negative integer,
  `unresolved_reason` is null or in the closed vocabulary,
  `body_encoding` is null or in the closed vocabulary, and every
  endpoint record has the required HTTP-verb / path-template /
  path-params triple.

  Deeper enum / shape validation is done by JSV against
  `exchange_v4.json#/$defs/RequestShapeRecord` —
  this invariant catches the narrow case where JSV validation was
  skipped or the schema drifted.
  """
  @spec check_request_shape_valid(map(), map()) :: [finding()]
  def check_request_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    record_map = get_in(exchange, ["endpoints", "request", "shape"]) || %{}

    record_map
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.flat_map(fn {section, record} -> request_shape_record_findings(id, section, record) end)
  end

  defp request_shape_record_findings(id, section, record) when is_map(record) do
    missing = RequestShape.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- RequestShape.required_keys()

    missing_findings =
      Enum.map(missing, fn key ->
        request_shape_finding(id, section, "missing required key #{inspect(key)}")
      end)

    extra_findings =
      Enum.map(extra, fn key ->
        request_shape_finding(id, section, "unexpected key #{inspect(key)}")
      end)

    value_findings =
      Enum.reject(
        [
          request_shape_patch_count_finding(id, section, Map.get(record, "patch_count")),
          request_shape_unresolved_reason_finding(id, section, Map.get(record, "unresolved_reason")),
          request_shape_body_encoding_finding(id, section, Map.get(record, "body_encoding"))
        ],
        &is_nil/1
      )

    endpoint_findings = request_shape_endpoint_findings(id, section, Map.get(record, "endpoints"))

    missing_findings ++ extra_findings ++ value_findings ++ endpoint_findings
  end

  defp request_shape_record_findings(id, section, _record) do
    [request_shape_finding(id, section, "request_shape record must be a map")]
  end

  defp request_shape_finding(id, section, message) do
    %Finding{
      exchange: id,
      invariant: "request_shape_valid",
      path: "endpoints.request.shape.#{section}",
      message: message
    }
  end

  defp request_shape_patch_count_finding(_id, _section, v) when is_integer(v) and v >= 0, do: nil

  defp request_shape_patch_count_finding(id, section, v) do
    request_shape_finding(id, section, "patch_count must be a non-negative integer, got #{inspect(v)}")
  end

  defp request_shape_unresolved_reason_finding(_id, _section, nil), do: nil

  defp request_shape_unresolved_reason_finding(id, section, v) do
    if v in RequestShape.unresolved_reasons() do
      nil
    else
      request_shape_finding(
        id,
        section,
        "unresolved_reason must be null or one of #{inspect(RequestShape.unresolved_reasons())}, got #{inspect(v)}"
      )
    end
  end

  defp request_shape_body_encoding_finding(_id, _section, nil), do: nil

  defp request_shape_body_encoding_finding(id, section, v) do
    if v in RequestShape.body_encodings() do
      nil
    else
      request_shape_finding(
        id,
        section,
        "body_encoding must be null or one of #{inspect(RequestShape.body_encodings())}, got #{inspect(v)}"
      )
    end
  end

  @request_shape_endpoint_keys ~w(http_verb path_template path_params)
  @request_shape_verbs ~w(GET POST PUT DELETE PATCH)

  defp request_shape_endpoint_findings(_id, _section, nil), do: []

  defp request_shape_endpoint_findings(id, section, endpoints) when is_list(endpoints) do
    endpoints
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, i} -> request_shape_endpoint_entry_findings(id, section, entry, i) end)
  end

  defp request_shape_endpoint_findings(id, section, _other) do
    [request_shape_finding(id, section, "endpoints must be null or a list")]
  end

  defp request_shape_endpoint_entry_findings(id, section, entry, index) when is_map(entry) do
    missing = @request_shape_endpoint_keys -- Map.keys(entry)

    missing_findings =
      Enum.map(missing, fn key ->
        request_shape_finding(id, section, "endpoints[#{index}] missing required key #{inspect(key)}")
      end)

    verb_finding =
      case Map.get(entry, "http_verb") do
        v when v in @request_shape_verbs ->
          nil

        other ->
          request_shape_finding(
            id,
            section,
            "endpoints[#{index}].http_verb must be one of #{inspect(@request_shape_verbs)}, got #{inspect(other)}"
          )
      end

    path_finding =
      case Map.get(entry, "path_template") do
        v when is_binary(v) ->
          nil

        other ->
          request_shape_finding(id, section, "endpoints[#{index}].path_template must be a string, got #{inspect(other)}")
      end

    params_findings =
      case Map.get(entry, "path_params") do
        nil ->
          [request_shape_finding(id, section, "endpoints[#{index}].path_params must be a list, got nil")]

        list when is_list(list) ->
          request_shape_path_params_findings(id, section, list, index)

        other ->
          [request_shape_finding(id, section, "endpoints[#{index}].path_params must be a list, got #{inspect(other)}")]
      end

    Enum.reject([verb_finding, path_finding | missing_findings ++ params_findings], &is_nil/1)
  end

  defp request_shape_endpoint_entry_findings(id, section, _other, index) do
    [request_shape_finding(id, section, "endpoints[#{index}] must be a map")]
  end

  defp request_shape_path_params_findings(id, section, params, index) do
    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {param, j} ->
      cond do
        not is_map(param) ->
          [request_shape_finding(id, section, "endpoints[#{index}].path_params[#{j}] must be a map")]

        not is_binary(Map.get(param, "name")) ->
          [request_shape_finding(id, section, "endpoints[#{index}].path_params[#{j}].name must be a string")]

        Map.get(param, "source") != "params" ->
          [
            request_shape_finding(
              id,
              section,
              "endpoints[#{index}].path_params[#{j}].source must be \"params\", got #{inspect(Map.get(param, "source"))}"
            )
          ]

        true ->
          []
      end
    end)
  end

  @doc """
  Validate the `endpoints.request.shape` honesty biconditional —
  mirror of the sign_recipe variant (Task 69 pattern):

      unresolved_reason == nil  ⇔  every derivation field populated

  where "populated" is defined by
  `RequestShape.all_derivation_fields_populated?/1`. Records that
  escape with a null tag but a null derivation field, OR with a
  populated tag but every derivation field set, are flagged.

  Terminal tags (`"no_sign_method"`, `"no_describe_api"`,
  `"section_not_in_api"`) coexist with at least one null derivation
  field by construction — those records are honestly partial and
  pass cleanly. The `"not_yet_derived"` tag is the scaffold default;
  records carrying it with all three derivation fields populated are
  the bug this invariant catches when Derive is bypassed (e.g.
  through an override chain).
  """
  @spec check_request_shape_honesty_valid(map(), map()) :: [finding()]
  def check_request_shape_honesty_valid(exchange, _observed) do
    id = exchange_id(exchange)
    record_map = get_in(exchange, ["endpoints", "request", "shape"]) || %{}

    record_map
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.flat_map(fn {section, record} -> request_shape_honesty_record_findings(id, section, record) end)
  end

  defp request_shape_honesty_record_findings(id, section, record) when is_map(record) do
    tag = Map.get(record, "unresolved_reason")
    all_populated? = RequestShape.all_derivation_fields_populated?(record)

    cond do
      is_nil(tag) and not all_populated? ->
        missing = null_request_shape_fields(record)

        [
          request_shape_honesty_finding(
            id,
            section,
            "unresolved_reason is null but derivation field(s) #{inspect(missing)} are null"
          )
        ]

      not is_nil(tag) and all_populated? ->
        [
          request_shape_honesty_finding(
            id,
            section,
            "unresolved_reason is #{inspect(tag)} but all derivation fields are populated " <>
              "(tag should be null)"
          )
        ]

      true ->
        []
    end
  end

  defp request_shape_honesty_record_findings(_id, _section, _record), do: []

  defp null_request_shape_fields(record) do
    Enum.filter(RequestShape.derivation_fields(), fn key ->
      case Map.fetch(record, key) do
        # `content_type: nil` paired with `body_encoding: "none"` is honest-
        # empty per the predicate; only flag truly-null fields.
        {:ok, nil} when key == "content_type" -> Map.get(record, "body_encoding") != "none"
        {:ok, nil} -> true
        :error -> true
        _ -> false
      end
    end)
  end

  defp request_shape_honesty_finding(id, section, message) do
    %Finding{
      exchange: id,
      invariant: "request_shape_honesty_valid",
      path: "endpoints.request.shape.#{section}",
      message: message
    }
  end

  @doc """
  Validate top-level `testnet` structural invariants that JSON Schema
  can't easily express:

    * `pattern` is one of `TestnetUrls.patterns/0`
    * key set matches `TestnetUrls.required_keys/0` exactly (no extras, no missing)
    * pattern/field population is consistent:
      - `pattern: "separate_host"` → `urls` is a non-empty map, `unresolved_reason` is nil
      - `pattern: "sandbox_flag"` → `urls` is nil, `sandbox_flag_field` is a non-empty string, `unresolved_reason` is nil
      - `pattern: "none"` → `urls` and `sandbox_flag_field` are nil,
        `unresolved_reason` is `"no_testnet_data"`
    * No `{hostname}` placeholder leakage in resolved URL strings.

  JSON Schema catches shape/enum drift; this invariant catches
  cross-field inconsistencies and unresolved hostname templates —
  both of which are extraction bugs, not schema violations.
  """
  @spec check_testnet_urls_shape_valid(map(), map()) :: [finding()]
  def check_testnet_urls_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    record = Map.get(exchange, "testnet")

    testnet_urls_record_findings(id, record)
  end

  defp testnet_urls_record_findings(id, record) when is_map(record) do
    missing = TestnetUrls.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- TestnetUrls.required_keys()

    missing_findings =
      Enum.map(missing, fn key -> testnet_urls_finding(id, "missing required key #{inspect(key)}") end)

    extra_findings =
      Enum.map(extra, fn key -> testnet_urls_finding(id, "unexpected key #{inspect(key)}") end)

    consistency_findings =
      case missing do
        [] -> testnet_urls_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp testnet_urls_record_findings(id, _record) do
    [testnet_urls_finding(id, "testnet must be a map")]
  end

  defp testnet_urls_consistency_findings(id, record) do
    pattern = Map.get(record, "pattern")

    pattern_finding =
      if pattern in TestnetUrls.patterns() do
        nil
      else
        testnet_urls_finding(id, "pattern must be one of #{inspect(TestnetUrls.patterns())}, got #{inspect(pattern)}")
      end

    field_findings = pattern_field_findings(id, pattern, record)
    hostname_findings = hostname_leak_findings(id, Map.get(record, "urls"))

    Enum.reject([pattern_finding | field_findings ++ hostname_findings], &is_nil/1)
  end

  defp pattern_field_findings(id, "separate_host", record) do
    urls = Map.get(record, "urls")
    reason = Map.get(record, "unresolved_reason")

    [
      if(is_map(urls) and map_size(urls) > 0,
        do: nil,
        else: testnet_urls_finding(id, "pattern=separate_host requires urls to be a non-empty map, got #{inspect(urls)}")
      ),
      if(is_nil(reason),
        do: nil,
        else: testnet_urls_finding(id, "pattern=separate_host requires unresolved_reason=nil, got #{inspect(reason)}")
      )
    ]
  end

  defp pattern_field_findings(id, "sandbox_flag", record) do
    urls = Map.get(record, "urls")
    flag = Map.get(record, "sandbox_flag_field")
    reason = Map.get(record, "unresolved_reason")

    [
      if(is_nil(urls),
        do: nil,
        else: testnet_urls_finding(id, "pattern=sandbox_flag requires urls=nil, got #{inspect(urls)}")
      ),
      if(is_binary(flag) and byte_size(flag) > 0,
        do: nil,
        else:
          testnet_urls_finding(
            id,
            "pattern=sandbox_flag requires sandbox_flag_field to be a non-empty string, got #{inspect(flag)}"
          )
      ),
      if(is_nil(reason),
        do: nil,
        else: testnet_urls_finding(id, "pattern=sandbox_flag requires unresolved_reason=nil, got #{inspect(reason)}")
      )
    ]
  end

  defp pattern_field_findings(id, "none", record) do
    urls = Map.get(record, "urls")
    flag = Map.get(record, "sandbox_flag_field")
    reason = Map.get(record, "unresolved_reason")

    [
      if(is_nil(urls), do: nil, else: testnet_urls_finding(id, "pattern=none requires urls=nil, got #{inspect(urls)}")),
      if(is_nil(flag),
        do: nil,
        else: testnet_urls_finding(id, "pattern=none requires sandbox_flag_field=nil, got #{inspect(flag)}")
      ),
      if(reason == "no_testnet_data",
        do: nil,
        else:
          testnet_urls_finding(id, "pattern=none requires unresolved_reason=\"no_testnet_data\", got #{inspect(reason)}")
      )
    ]
  end

  defp pattern_field_findings(_id, _pattern, _record), do: []

  # Walk leaves; any string containing {hostname} is a resolution leak.
  defp hostname_leak_findings(_id, nil), do: []

  defp hostname_leak_findings(id, urls) do
    urls
    |> collect_strings()
    |> Enum.filter(&String.contains?(&1, "{hostname}"))
    |> Enum.map(fn s ->
      testnet_urls_finding(id, "unresolved {hostname} placeholder in URL #{inspect(s)}")
    end)
  end

  defp collect_strings(value) when is_binary(value), do: [value]
  defp collect_strings(value) when is_map(value), do: Enum.flat_map(value, fn {_k, v} -> collect_strings(v) end)
  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings(_), do: []

  defp testnet_urls_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "testnet_urls_shape_valid",
      path: "testnet",
      message: message
    }
  end

  @doc """
  `websocket.heartbeat` must carry exactly the `WsHeartbeat` key set with
  closed-vocabulary `ping_kind` / `source` / `unresolved_reason` values, and
  satisfy the cross-field honesty rule JSV cannot express: the no-WS and
  unknown-ping states must agree across `ping_kind`, `source`,
  `keep_alive_ms` nullity, and `unresolved_reason`.
  """
  @spec check_websocket_heartbeat_shape_valid(map(), map()) :: [finding()]
  def check_websocket_heartbeat_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    ws_heartbeat_record_findings(id, get_in(exchange, ["websocket", "heartbeat"]))
  end

  defp ws_heartbeat_record_findings(id, record) when is_map(record) do
    missing = WsHeartbeat.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- WsHeartbeat.required_keys()

    missing_findings = Enum.map(missing, &ws_heartbeat_finding(id, "missing required key #{inspect(&1)}"))
    extra_findings = Enum.map(extra, &ws_heartbeat_finding(id, "unexpected key #{inspect(&1)}"))

    consistency_findings =
      case missing do
        [] -> ws_heartbeat_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp ws_heartbeat_record_findings(id, _record) do
    [ws_heartbeat_finding(id, "websocket.heartbeat must be a map")]
  end

  defp ws_heartbeat_consistency_findings(id, record) do
    vocab_findings =
      [
        ws_heartbeat_vocab_finding(id, record, "ping_kind", WsHeartbeat.ping_kinds()),
        ws_heartbeat_vocab_finding(id, record, "source", WsHeartbeat.sources()),
        ws_heartbeat_vocab_finding(id, record, "unresolved_reason", [nil | WsHeartbeat.unresolved_reasons()])
      ]

    Enum.reject(vocab_findings ++ ws_heartbeat_honesty_findings(id, record), &is_nil/1)
  end

  defp ws_heartbeat_vocab_finding(id, record, key, allowed) do
    value = Map.get(record, key)

    if value in allowed do
      nil
    else
      ws_heartbeat_finding(id, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  # The honesty rule JSV cannot express: the no-WS state (ping_kind=none)
  # and the unknown-ping state must agree across every field that encodes
  # them, so a build/2 regression can't emit an internally-contradictory
  # record that still passes structural schema validation. The no-WS state
  # additionally requires every heartbeat field to be empty — a `none`
  # record carrying a populated payload/handler is dishonest about having
  # no WebSocket support even though structural JSV validation accepts it.
  defp ws_heartbeat_honesty_findings(id, record) do
    kind = Map.get(record, "ping_kind")
    none? = kind == "none"

    [
      ws_heartbeat_coherence(
        id,
        none? == (Map.get(record, "unresolved_reason") == "no_ws_support"),
        "ping_kind=none must agree with unresolved_reason=no_ws_support"
      ),
      ws_heartbeat_coherence(
        id,
        none? == (Map.get(record, "source") == "none"),
        "ping_kind=none must agree with source=none"
      ),
      ws_heartbeat_coherence(
        id,
        none? == is_nil(Map.get(record, "keep_alive_ms")),
        "ping_kind=none must agree with keep_alive_ms=null"
      ),
      ws_heartbeat_coherence(
        id,
        not none? or is_nil(Map.get(record, "ping_payload")),
        "ping_kind=none must agree with ping_payload=null"
      ),
      ws_heartbeat_coherence(
        id,
        not none? or is_nil(Map.get(record, "ping_payload_kind")),
        "ping_kind=none must agree with ping_payload_kind=null"
      ),
      ws_heartbeat_coherence(
        id,
        not none? or is_nil(Map.get(record, "max_ping_pong_misses")),
        "ping_kind=none must agree with max_ping_pong_misses=null"
      ),
      ws_heartbeat_coherence(
        id,
        not none? or is_nil(Map.get(record, "keep_alive_resolved_from")),
        "ping_kind=none must agree with keep_alive_resolved_from=null"
      ),
      ws_heartbeat_coherence(
        id,
        not none? or Map.get(record, "has_pong_handler") == false,
        "ping_kind=none must agree with has_pong_handler=false"
      ),
      ws_heartbeat_coherence(
        id,
        kind == "unknown" == (Map.get(record, "unresolved_reason") == "ping_return_not_literal"),
        "ping_kind=unknown must agree with unresolved_reason=ping_return_not_literal"
      )
    ]
  end

  defp ws_heartbeat_coherence(_id, true, _message), do: nil
  defp ws_heartbeat_coherence(id, false, message), do: ws_heartbeat_finding(id, message)

  defp ws_heartbeat_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "websocket_heartbeat_shape_valid",
      path: "websocket/heartbeat",
      message: message
    }
  end

  @doc """
  `websocket.auth` must carry exactly the `WsAuth` key set with
  closed-vocabulary `mechanism` / `source` / `unresolved_reason` values, and
  satisfy the cross-field honesty rule JSV cannot express: the no-auth,
  sign-in-message, and unknown states must agree across `mechanism`,
  `source`, `authenticate_defined`, `message` nullity, and
  `unresolved_reason`.
  """
  @spec check_websocket_auth_shape_valid(map(), map()) :: [finding()]
  def check_websocket_auth_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    ws_auth_record_findings(id, get_in(exchange, ["websocket", "auth"]))
  end

  defp ws_auth_record_findings(id, record) when is_map(record) do
    missing = WsAuth.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- WsAuth.required_keys()

    missing_findings = Enum.map(missing, &ws_auth_finding(id, "missing required key #{inspect(&1)}"))
    extra_findings = Enum.map(extra, &ws_auth_finding(id, "unexpected key #{inspect(&1)}"))

    consistency_findings =
      case missing do
        [] -> ws_auth_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp ws_auth_record_findings(id, _record) do
    [ws_auth_finding(id, "websocket.auth must be a map")]
  end

  defp ws_auth_consistency_findings(id, record) do
    vocab_findings =
      [
        ws_auth_vocab_finding(id, record, "mechanism", WsAuth.mechanisms()),
        ws_auth_vocab_finding(id, record, "source", WsAuth.sources()),
        ws_auth_vocab_finding(id, record, "unresolved_reason", [nil | WsAuth.unresolved_reasons()])
      ]

    Enum.reject(vocab_findings ++ ws_auth_honesty_findings(id, record), &is_nil/1)
  end

  defp ws_auth_vocab_finding(id, record, key, allowed) do
    value = Map.get(record, key)

    if value in allowed do
      nil
    else
      ws_auth_finding(id, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  # The honesty rule JSV cannot express: the no-auth state (mechanism=none),
  # the sign-in-message state, and the unknown state must agree across every
  # field that encodes them, so a build/2 regression can't emit an
  # internally-contradictory record that still passes structural validation.
  defp ws_auth_honesty_findings(id, record) do
    mechanism = Map.get(record, "mechanism")

    [
      ws_auth_coherence(
        id,
        mechanism == "none" == (Map.get(record, "authenticate_defined") == false),
        "mechanism=none must agree with authenticate_defined=false"
      ),
      ws_auth_coherence(
        id,
        mechanism == "none" == (Map.get(record, "source") == "none"),
        "mechanism=none must agree with source=none"
      ),
      ws_auth_coherence(
        id,
        mechanism == "none" == Map.get(record, "unresolved_reason") in ["no_ws_support", "no_ws_auth"],
        "mechanism=none must agree with unresolved_reason no_ws_support/no_ws_auth"
      ),
      ws_auth_coherence(
        id,
        mechanism == "sign_in_message" == is_map(Map.get(record, "message")),
        "mechanism=sign_in_message must agree with a non-null message"
      ),
      ws_auth_coherence(
        id,
        mechanism == "unknown" == (Map.get(record, "unresolved_reason") == "auth_not_classifiable"),
        "mechanism=unknown must agree with unresolved_reason=auth_not_classifiable"
      )
    ]
  end

  defp ws_auth_coherence(_id, true, _message), do: nil
  defp ws_auth_coherence(id, false, message), do: ws_auth_finding(id, message)

  defp ws_auth_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "websocket_auth_shape_valid",
      path: "websocket/auth",
      message: message
    }
  end

  @doc """
  `websocket.subscribe` must carry exactly the `WsSubscribe` key set with
  closed-vocabulary `mechanism` / `source` / `unresolved_reason` values, and
  satisfy the cross-field honesty rule JSV cannot express: the no-WS,
  json-message, and unknown states must agree across `mechanism`, `source`,
  `discriminant` nullity, `channels`/`envelope_keys` emptiness, and
  `unresolved_reason`.
  """
  @spec check_websocket_subscribe_shape_valid(map(), map()) :: [finding()]
  def check_websocket_subscribe_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    ws_subscribe_record_findings(id, get_in(exchange, ["websocket", "subscribe"]))
  end

  defp ws_subscribe_record_findings(id, record) when is_map(record) do
    missing = WsSubscribe.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- WsSubscribe.required_keys()

    missing_findings = Enum.map(missing, &ws_subscribe_finding(id, "missing required key #{inspect(&1)}"))
    extra_findings = Enum.map(extra, &ws_subscribe_finding(id, "unexpected key #{inspect(&1)}"))

    consistency_findings =
      case missing do
        [] -> ws_subscribe_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp ws_subscribe_record_findings(id, _record) do
    [ws_subscribe_finding(id, "websocket.subscribe must be a map")]
  end

  defp ws_subscribe_consistency_findings(id, record) do
    vocab_findings =
      [
        ws_subscribe_vocab_finding(id, record, "mechanism", WsSubscribe.mechanisms()),
        ws_subscribe_vocab_finding(id, record, "source", WsSubscribe.sources()),
        ws_subscribe_vocab_finding(id, record, "unresolved_reason", [nil | WsSubscribe.unresolved_reasons()])
      ]

    Enum.reject(vocab_findings ++ ws_subscribe_honesty_findings(id, record), &is_nil/1)
  end

  defp ws_subscribe_vocab_finding(id, record, key, allowed) do
    value = Map.get(record, key)

    if value in allowed do
      nil
    else
      ws_subscribe_finding(id, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  # The honesty rule JSV cannot express: the no-WS state (mechanism=none), the
  # json-message state, and the unknown state must agree across every field
  # that encodes them, so a build/2 regression can't emit an
  # internally-contradictory record that still passes structural validation.
  # The no-WS state additionally requires every subscribe field to be empty.
  defp ws_subscribe_honesty_findings(id, record) do
    mechanism = Map.get(record, "mechanism")
    none? = mechanism == "none"

    [
      ws_subscribe_coherence(
        id,
        none? == (Map.get(record, "source") == "none"),
        "mechanism=none must agree with source=none"
      ),
      ws_subscribe_coherence(
        id,
        none? == (Map.get(record, "unresolved_reason") == "no_ws_support"),
        "mechanism=none must agree with unresolved_reason=no_ws_support"
      ),
      ws_subscribe_coherence(
        id,
        not none? or Map.get(record, "channels") == %{},
        "mechanism=none must agree with empty channels"
      ),
      ws_subscribe_coherence(
        id,
        not none? or Map.get(record, "envelope_keys") == [],
        "mechanism=none must agree with empty envelope_keys"
      ),
      ws_subscribe_coherence(
        id,
        mechanism == "json_message" == is_binary(Map.get(record, "discriminant")),
        "mechanism=json_message must agree with a non-null discriminant"
      ),
      ws_subscribe_coherence(
        id,
        mechanism == "json_message" == is_binary(Map.get(record, "subscribe_op")),
        "mechanism=json_message must agree with a non-null subscribe_op"
      ),
      ws_subscribe_coherence(
        id,
        mechanism == "unknown" == (Map.get(record, "unresolved_reason") == "subscribe_not_classifiable"),
        "mechanism=unknown must agree with unresolved_reason=subscribe_not_classifiable"
      )
    ]
  end

  defp ws_subscribe_coherence(_id, true, _message), do: nil
  defp ws_subscribe_coherence(id, false, message), do: ws_subscribe_finding(id, message)

  defp ws_subscribe_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "websocket_subscribe_shape_valid",
      path: "websocket/subscribe",
      message: message
    }
  end

  @doc """
  `websocket.dispatch` must carry exactly the `WsDispatch` key set with
  closed-vocabulary `kind` / `source` / `unresolved_reason` values, valid
  `entries` / `unresolved` element shapes, and satisfy the cross-field honesty
  rule JSV cannot express: the no-dispatch, routed, and opaque states must
  agree across `kind`, `source`, `handle_message_defined`, `entries`,
  `resolved_from`, and `unresolved_reason`. REST-only exchanges carry the
  honest-empty record.
  """
  @spec check_websocket_dispatch_shape_valid(map(), map()) :: [finding()]
  def check_websocket_dispatch_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    ws_dispatch_record_findings(id, get_in(exchange, ["websocket", "dispatch"]))
  end

  defp ws_dispatch_record_findings(id, record) when is_map(record) do
    missing = WsDispatch.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- WsDispatch.required_keys()

    missing_findings = Enum.map(missing, &ws_dispatch_finding(id, "missing required key #{inspect(&1)}"))
    extra_findings = Enum.map(extra, &ws_dispatch_finding(id, "unexpected key #{inspect(&1)}"))

    consistency_findings =
      case missing do
        [] -> ws_dispatch_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp ws_dispatch_record_findings(id, _record) do
    [ws_dispatch_finding(id, "websocket.dispatch must be a map")]
  end

  defp ws_dispatch_consistency_findings(id, record) do
    vocab_findings =
      [
        ws_dispatch_vocab_finding(id, record, "kind", WsDispatch.kinds()),
        ws_dispatch_vocab_finding(id, record, "source", WsDispatch.sources()),
        ws_dispatch_vocab_finding(id, record, "unresolved_reason", [nil | WsDispatch.unresolved_reasons()])
      ]

    element_findings = ws_dispatch_element_findings(id, record)

    Enum.reject(vocab_findings ++ element_findings ++ ws_dispatch_honesty_findings(id, record), &is_nil/1)
  end

  defp ws_dispatch_vocab_finding(id, record, key, allowed) do
    value = Map.get(record, key)

    if value in allowed do
      nil
    else
      ws_dispatch_finding(id, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  # entries are {channel, handler} string pairs; unresolved reasons are
  # drawn from the closed per-shape vocabulary. JSV enforces the same shape,
  # but the invariant double-guards a build/2 regression that emits a list
  # element JSV can't reach (e.g. a stray atom-keyed map in a unit fixture).
  defp ws_dispatch_element_findings(id, record) do
    entry_findings =
      record |> Map.get("entries", []) |> List.wrap() |> Enum.flat_map(&ws_dispatch_entry_findings(id, &1))

    unresolved_findings =
      record |> Map.get("unresolved", []) |> List.wrap() |> Enum.flat_map(&ws_dispatch_unresolved_findings(id, &1))

    entry_findings ++ unresolved_findings
  end

  defp ws_dispatch_entry_findings(id, %{"channel" => channel, "handler" => handler}) do
    cond do
      not is_binary(channel) -> [ws_dispatch_finding(id, "entry channel must be a string, got #{inspect(channel)}")]
      not is_binary(handler) -> [ws_dispatch_finding(id, "entry handler must be a string, got #{inspect(handler)}")]
      true -> []
    end
  end

  defp ws_dispatch_entry_findings(id, other) do
    [ws_dispatch_finding(id, "entry must carry channel + handler, got #{inspect(other)}")]
  end

  defp ws_dispatch_unresolved_findings(id, %{"reason" => reason}) do
    if reason in WsDispatch.unresolved_entry_reasons() do
      []
    else
      [
        ws_dispatch_finding(
          id,
          "unresolved reason must be one of #{inspect(WsDispatch.unresolved_entry_reasons())}, got #{inspect(reason)}"
        )
      ]
    end
  end

  defp ws_dispatch_unresolved_findings(id, other) do
    [ws_dispatch_finding(id, "unresolved entry must carry a reason, got #{inspect(other)}")]
  end

  # The honesty rule JSV cannot express: the three classification states
  # must agree across every field that encodes them, so a build/2 regression
  # can't emit an internally-contradictory record that still passes
  # structural validation.
  defp ws_dispatch_honesty_findings(id, record) do
    kind = Map.get(record, "kind")
    none? = kind == "none"

    [
      ws_dispatch_coherence(
        id,
        none? == (Map.get(record, "handle_message_defined") == false),
        "kind=none must agree with handle_message_defined=false"
      ),
      ws_dispatch_coherence(
        id,
        none? == (Map.get(record, "source") == "none"),
        "kind=none must agree with source=none"
      ),
      ws_dispatch_coherence(
        id,
        none? == Map.get(record, "unresolved_reason") in ["no_ws_support", "no_ws_dispatch"],
        "kind=none must agree with unresolved_reason no_ws_support/no_ws_dispatch"
      ),
      ws_dispatch_coherence(
        id,
        none? == is_nil(Map.get(record, "resolved_from")),
        "kind=none must agree with resolved_from=null"
      ),
      ws_dispatch_coherence(
        id,
        kind == "routed" == (Map.get(record, "entries", []) != []),
        "kind=routed must agree with a non-empty entries list"
      ),
      ws_dispatch_coherence(
        id,
        kind == "opaque" == (Map.get(record, "unresolved_reason") == "dispatch_not_classifiable"),
        "kind=opaque must agree with unresolved_reason=dispatch_not_classifiable"
      )
    ]
  end

  defp ws_dispatch_coherence(_id, true, _message), do: nil
  defp ws_dispatch_coherence(id, false, message), do: ws_dispatch_finding(id, message)

  defp ws_dispatch_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "websocket_dispatch_shape_valid",
      path: "websocket/dispatch",
      message: message
    }
  end

  @doc """
  `websocket.trades_semantics` must carry exactly the
  `WsTradesSemantics` key set with closed-vocabulary `update_model` /
  `source` / `unresolved_reason` values, valid unresolved reason elements,
  and an honest-empty record for exchanges with no WS trades channel.
  """
  @spec check_websocket_trades_semantics_shape_valid(map(), map()) :: [finding()]
  def check_websocket_trades_semantics_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    ws_trades_semantics_record_findings(id, get_in(exchange, ["websocket", "trades_semantics"]))
  end

  defp ws_trades_semantics_record_findings(id, record) when is_map(record) do
    missing = WsTradesSemantics.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- WsTradesSemantics.required_keys()

    missing_findings = Enum.map(missing, &ws_trades_semantics_finding(id, "missing required key #{inspect(&1)}"))
    extra_findings = Enum.map(extra, &ws_trades_semantics_finding(id, "unexpected key #{inspect(&1)}"))

    consistency_findings =
      case missing do
        [] -> ws_trades_semantics_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp ws_trades_semantics_record_findings(id, _record) do
    [ws_trades_semantics_finding(id, "websocket.trades_semantics must be a map")]
  end

  defp ws_trades_semantics_consistency_findings(id, record) do
    vocab_findings =
      [
        ws_trades_semantics_vocab_finding(id, record, "update_model", WsTradesSemantics.update_models()),
        ws_trades_semantics_vocab_finding(id, record, "source", WsTradesSemantics.sources()),
        ws_trades_semantics_vocab_finding(
          id,
          record,
          "unresolved_reason",
          [nil | WsTradesSemantics.unresolved_reasons()]
        )
      ]

    element_findings = ws_trades_semantics_element_findings(id, record)

    Enum.reject(vocab_findings ++ element_findings ++ ws_trades_semantics_honesty_findings(id, record), &is_nil/1)
  end

  defp ws_trades_semantics_vocab_finding(id, record, key, allowed) do
    value = Map.get(record, key)

    if value in allowed do
      nil
    else
      ws_trades_semantics_finding(id, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  defp ws_trades_semantics_element_findings(id, record) do
    unresolved_findings =
      record
      |> Map.get("unresolved", [])
      |> List.wrap()
      |> Enum.flat_map(&ws_trades_semantics_unresolved_findings(id, &1))

    my_trades_findings(id, Map.get(record, "my_trades")) ++ unresolved_findings
  end

  defp ws_trades_semantics_unresolved_findings(id, %{"reason" => reason}) do
    if reason in WsTradesSemantics.unresolved_entry_reasons() do
      []
    else
      [
        ws_trades_semantics_finding(
          id,
          "unresolved reason must be one of #{inspect(WsTradesSemantics.unresolved_entry_reasons())}, got #{inspect(reason)}"
        )
      ]
    end
  end

  defp ws_trades_semantics_unresolved_findings(id, other) do
    [ws_trades_semantics_finding(id, "unresolved entry must carry a reason, got #{inspect(other)}")]
  end

  defp my_trades_findings(id, %{"defined" => defined} = record) when is_boolean(defined) do
    fields = ~w(cache_type dedup_key cache_limit_field cache_limit_default)
    required = ["defined" | fields]
    missing = required -- Map.keys(record)
    extra = Map.keys(record) -- required

    key_findings =
      Enum.map(missing, &ws_trades_semantics_finding(id, "my_trades missing required key #{inspect(&1)}")) ++
        Enum.map(extra, &ws_trades_semantics_finding(id, "my_trades unexpected key #{inspect(&1)}"))

    null_findings =
      if defined do
        []
      else
        fields
        |> Enum.reject(&is_nil(Map.get(record, &1)))
        |> Enum.map(&ws_trades_semantics_finding(id, "my_trades.#{&1} must be null when defined=false"))
      end

    key_findings ++ null_findings
  end

  defp my_trades_findings(id, other) do
    [ws_trades_semantics_finding(id, "my_trades must carry defined boolean, got #{inspect(other)}")]
  end

  defp ws_trades_semantics_honesty_findings(id, record) do
    update_model = Map.get(record, "update_model")
    none? = update_model == "none"

    [
      ws_trades_semantics_coherence(
        id,
        none? == (Map.get(record, "trades_defined") == false),
        "update_model=none must agree with trades_defined=false"
      ),
      ws_trades_semantics_coherence(
        id,
        not none? or is_nil(Map.get(record, "cache_type")),
        "update_model=none requires cache_type=null"
      ),
      ws_trades_semantics_coherence(
        id,
        not none? or is_nil(Map.get(record, "dedup_key")),
        "update_model=none requires dedup_key=null"
      ),
      ws_trades_semantics_coherence(
        id,
        not none? or is_nil(Map.get(record, "cache_limit_field")),
        "update_model=none requires cache_limit_field=null"
      ),
      ws_trades_semantics_coherence(
        id,
        none? == is_nil(Map.get(record, "resolved_from")),
        "update_model=none must agree with resolved_from=null"
      ),
      ws_trades_semantics_coherence(
        id,
        update_model == "unknown" == (Map.get(record, "unresolved_reason") == "trades_not_classifiable"),
        "update_model=unknown must agree with unresolved_reason=trades_not_classifiable"
      )
    ]
  end

  defp ws_trades_semantics_coherence(_id, true, _message), do: nil
  defp ws_trades_semantics_coherence(id, false, message), do: ws_trades_semantics_finding(id, message)

  defp ws_trades_semantics_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "websocket_trades_semantics_shape_valid",
      path: "websocket/trades_semantics",
      message: message
    }
  end

  @doc """
  `websocket.ohlcv_semantics` must carry exactly the `WsOhlcvSemantics` key set
  with closed-vocabulary `update_model` / `source` / `unresolved_reason` values,
  valid unresolved reason elements, and an honest-empty record for exchanges
  with no WS OHLCV channel.
  """
  @spec check_websocket_ohlcv_semantics_shape_valid(map(), map()) :: [finding()]
  def check_websocket_ohlcv_semantics_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    ws_ohlcv_semantics_record_findings(id, get_in(exchange, ["websocket", "ohlcv_semantics"]))
  end

  defp ws_ohlcv_semantics_record_findings(id, record) when is_map(record) do
    missing = WsOhlcvSemantics.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- WsOhlcvSemantics.required_keys()

    missing_findings = Enum.map(missing, &ws_ohlcv_semantics_finding(id, "missing required key #{inspect(&1)}"))
    extra_findings = Enum.map(extra, &ws_ohlcv_semantics_finding(id, "unexpected key #{inspect(&1)}"))

    consistency_findings =
      case missing do
        [] -> ws_ohlcv_semantics_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp ws_ohlcv_semantics_record_findings(id, _record) do
    [ws_ohlcv_semantics_finding(id, "websocket.ohlcv_semantics must be a map")]
  end

  defp ws_ohlcv_semantics_consistency_findings(id, record) do
    vocab_findings =
      [
        ws_ohlcv_semantics_vocab_finding(id, record, "update_model", WsOhlcvSemantics.update_models()),
        ws_ohlcv_semantics_vocab_finding(id, record, "source", WsOhlcvSemantics.sources()),
        ws_ohlcv_semantics_vocab_finding(
          id,
          record,
          "unresolved_reason",
          [nil | WsOhlcvSemantics.unresolved_reasons()]
        )
      ]

    element_findings = ws_ohlcv_semantics_element_findings(id, record)

    Enum.reject(vocab_findings ++ element_findings ++ ws_ohlcv_semantics_honesty_findings(id, record), &is_nil/1)
  end

  defp ws_ohlcv_semantics_vocab_finding(id, record, key, allowed) do
    value = Map.get(record, key)

    if value in allowed do
      nil
    else
      ws_ohlcv_semantics_finding(id, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  defp ws_ohlcv_semantics_element_findings(id, record) do
    unresolved = Map.get(record, "unresolved", [])

    Enum.flat_map(unresolved, &ws_ohlcv_semantics_unresolved_findings(id, &1))
  end

  defp ws_ohlcv_semantics_unresolved_findings(id, %{"reason" => reason}) do
    if reason in WsOhlcvSemantics.unresolved_entry_reasons() do
      []
    else
      [
        ws_ohlcv_semantics_finding(
          id,
          "unresolved reason must be one of #{inspect(WsOhlcvSemantics.unresolved_entry_reasons())}, got #{inspect(reason)}"
        )
      ]
    end
  end

  defp ws_ohlcv_semantics_unresolved_findings(id, other) do
    [ws_ohlcv_semantics_finding(id, "unresolved entry must carry a reason, got #{inspect(other)}")]
  end

  defp ws_ohlcv_semantics_honesty_findings(id, record) do
    defined = Map.get(record, "ohlcv_defined")
    update_model = Map.get(record, "update_model")
    unresolved_reason = Map.get(record, "unresolved_reason")
    source = Map.get(record, "source")
    resolved_from = Map.get(record, "resolved_from")

    [
      ws_ohlcv_semantics_coherence(
        id,
        is_boolean(defined),
        "ohlcv_defined must be boolean"
      ),
      ws_ohlcv_semantics_coherence(
        id,
        ohlcv_defined_agrees_model?(defined, update_model),
        "ohlcv_defined must agree with update_model"
      ),
      ws_ohlcv_semantics_coherence(
        id,
        update_model == "none" == (source == "none"),
        "update_model=none must agree with source=none"
      ),
      ws_ohlcv_semantics_coherence(
        id,
        ohlcv_none_reason_coherent?(update_model, unresolved_reason),
        "update_model=none must pair with no_ws_support or no_ws_ohlcv; non-none must not"
      ),
      ws_ohlcv_semantics_coherence(
        id,
        update_model == "unknown" == (unresolved_reason == "ohlcv_not_classifiable"),
        "update_model=unknown must agree with unresolved_reason=ohlcv_not_classifiable"
      ),
      ws_ohlcv_semantics_coherence(
        id,
        ohlcv_resolved_from_coherent?(defined, resolved_from),
        "resolved_from must be self/ancestor when ohlcv_defined, nil otherwise"
      )
    ]
  end

  @ohlcv_none_reasons ["no_ws_support", "no_ws_ohlcv"]

  defp ohlcv_defined_agrees_model?(defined, update_model) do
    (defined == true and update_model in ["replace_latest_then_append", "unknown"]) or
      (defined == false and update_model == "none")
  end

  defp ohlcv_none_reason_coherent?(update_model, unresolved_reason) do
    (update_model == "none" and unresolved_reason in @ohlcv_none_reasons) or
      (update_model != "none" and unresolved_reason not in @ohlcv_none_reasons)
  end

  defp ohlcv_resolved_from_coherent?(defined, resolved_from) do
    (defined == true and is_binary(resolved_from)) or (defined == false and is_nil(resolved_from))
  end

  defp ws_ohlcv_semantics_coherence(_id, true, _message), do: nil
  defp ws_ohlcv_semantics_coherence(id, false, message), do: ws_ohlcv_semantics_finding(id, message)

  defp ws_ohlcv_semantics_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "websocket_ohlcv_semantics_shape_valid",
      path: "websocket/ohlcv_semantics",
      message: message
    }
  end

  @doc """
  `websocket.orderbook_semantics` must carry exactly the
  `WsOrderbookSemantics` key set with closed-vocabulary `apply_mode` /
  `source` / `unresolved_reason` / `checksum.algorithm` values, valid nested
  `discriminator` / `checksum` shapes, `sequence_fields` and discriminator
  literals drawn from their recognized vocabularies, and satisfy the
  cross-field honesty rule JSV cannot express: the no-orderbook and
  unclassifiable states must agree across `apply_mode`, `source`,
  `handle_orderbook_defined`, `resolved_from`, and `unresolved_reason`.
  REST-only exchanges carry the honest-empty record.
  """
  @spec check_websocket_orderbook_semantics_shape_valid(map(), map()) :: [finding()]
  def check_websocket_orderbook_semantics_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    ws_ob_record_findings(id, get_in(exchange, ["websocket", "orderbook_semantics"]))
  end

  defp ws_ob_record_findings(id, record) when is_map(record) do
    missing = WsOrderbookSemantics.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- WsOrderbookSemantics.required_keys()

    missing_findings = Enum.map(missing, &ws_ob_finding(id, "missing required key #{inspect(&1)}"))
    extra_findings = Enum.map(extra, &ws_ob_finding(id, "unexpected key #{inspect(&1)}"))

    consistency_findings =
      case missing do
        [] -> ws_ob_consistency_findings(id, record)
        _ -> []
      end

    missing_findings ++ extra_findings ++ consistency_findings
  end

  defp ws_ob_record_findings(id, _record) do
    [ws_ob_finding(id, "websocket.orderbook_semantics must be a map")]
  end

  defp ws_ob_consistency_findings(id, record) do
    vocab_findings = [
      ws_ob_vocab_finding(id, record, "apply_mode", WsOrderbookSemantics.apply_modes()),
      ws_ob_vocab_finding(id, record, "source", WsOrderbookSemantics.sources()),
      ws_ob_vocab_finding(id, record, "unresolved_reason", [nil | WsOrderbookSemantics.unresolved_reasons()])
    ]

    element_findings =
      ws_ob_discriminator_findings(id, record) ++
        ws_ob_sequence_findings(id, record) ++ ws_ob_checksum_findings(id, record)

    Enum.reject(vocab_findings ++ element_findings ++ ws_ob_honesty_findings(id, record), &is_nil/1)
  end

  defp ws_ob_vocab_finding(id, record, key, allowed) do
    value = Map.get(record, key)

    if value in allowed do
      nil
    else
      ws_ob_finding(id, "#{key} must be one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  # discriminator: a map carrying field (string|null) + snapshot/delta value
  # lists drawn from the recognized vocabularies.
  defp ws_ob_discriminator_findings(id, record) do
    case Map.get(record, "discriminator") do
      %{"field" => field, "snapshot_values" => snap, "delta_values" => delta} = disc ->
        extra = Map.keys(disc) -- ["field", "snapshot_values", "delta_values"]

        Enum.reject(
          [
            if(!(is_nil(field) or is_binary(field)),
              do: ws_ob_finding(id, "discriminator.field must be a string or null, got #{inspect(field)}")
            ),
            ws_ob_value_list_finding(id, "snapshot_values", snap, WsOrderbookSemantics.snapshot_value_vocab()),
            ws_ob_value_list_finding(id, "delta_values", delta, WsOrderbookSemantics.delta_value_vocab()),
            if(extra != [], do: ws_ob_finding(id, "discriminator has unexpected keys #{inspect(extra)}"))
          ],
          &is_nil/1
        )

      other ->
        [ws_ob_finding(id, "discriminator must carry field + snapshot_values + delta_values, got #{inspect(other)}")]
    end
  end

  defp ws_ob_value_list_finding(id, key, values, vocab) when is_list(values) do
    case Enum.reject(values, &(&1 in vocab)) do
      [] -> nil
      bad -> ws_ob_finding(id, "discriminator.#{key} must be drawn from #{inspect(vocab)}, got #{inspect(bad)}")
    end
  end

  defp ws_ob_value_list_finding(id, key, other, _vocab) do
    ws_ob_finding(id, "discriminator.#{key} must be a list, got #{inspect(other)}")
  end

  # sequence_fields: a list whose every element is in the recognized vocabulary.
  defp ws_ob_sequence_findings(id, record) do
    case Map.get(record, "sequence_fields") do
      fields when is_list(fields) ->
        case Enum.reject(fields, &(&1 in WsOrderbookSemantics.sequence_field_vocab())) do
          [] -> []
          bad -> [ws_ob_finding(id, "sequence_fields must be drawn from the recognized vocabulary, got #{inspect(bad)}")]
        end

      other ->
        [ws_ob_finding(id, "sequence_fields must be a list, got #{inspect(other)}")]
    end
  end

  # checksum: present (bool) + field (string|null) + algorithm (closed vocab|null).
  defp ws_ob_checksum_findings(id, record) do
    case Map.get(record, "checksum") do
      %{"present" => present, "field" => field, "algorithm" => algorithm} = checksum ->
        extra = Map.keys(checksum) -- ["present", "field", "algorithm"]

        Enum.reject(
          [
            if(!is_boolean(present),
              do: ws_ob_finding(id, "checksum.present must be a boolean, got #{inspect(present)}")
            ),
            if(!(is_nil(field) or is_binary(field)),
              do: ws_ob_finding(id, "checksum.field must be a string or null, got #{inspect(field)}")
            ),
            if(algorithm not in [nil | WsOrderbookSemantics.algorithms()],
              do:
                ws_ob_finding(
                  id,
                  "checksum.algorithm must be one of #{inspect([nil | WsOrderbookSemantics.algorithms()])}, got #{inspect(algorithm)}"
                )
            ),
            if(extra != [], do: ws_ob_finding(id, "checksum has unexpected keys #{inspect(extra)}"))
          ],
          &is_nil/1
        )

      other ->
        [ws_ob_finding(id, "checksum must carry present + field + algorithm, got #{inspect(other)}")]
    end
  end

  # The honesty rule JSV cannot express: the no-orderbook (apply_mode=none)
  # and unclassifiable (apply_mode=unknown) states must agree across every
  # field that encodes them, and the none state must be empty of every
  # populated fact.
  defp ws_ob_honesty_findings(id, record) do
    apply_mode = Map.get(record, "apply_mode")
    none? = apply_mode == "none"
    discriminator = Map.get(record, "discriminator", %{})
    checksum = Map.get(record, "checksum", %{})

    [
      ws_ob_coherence(
        id,
        none? == (Map.get(record, "source") == "none"),
        "apply_mode=none must agree with source=none"
      ),
      ws_ob_coherence(
        id,
        none? == (Map.get(record, "handle_orderbook_defined") == false),
        "apply_mode=none must agree with handle_orderbook_defined=false"
      ),
      ws_ob_coherence(
        id,
        none? == Map.get(record, "unresolved_reason") in ["no_ws_support", "no_ws_orderbook"],
        "apply_mode=none must agree with unresolved_reason no_ws_support/no_ws_orderbook"
      ),
      ws_ob_coherence(
        id,
        none? == is_nil(Map.get(record, "resolved_from")),
        "apply_mode=none must agree with resolved_from=null"
      ),
      ws_ob_coherence(
        id,
        not none? or is_nil(Map.get(discriminator, "field")),
        "apply_mode=none must agree with discriminator.field=null"
      ),
      ws_ob_coherence(
        id,
        not none? or Map.get(record, "sequence_fields") == [],
        "apply_mode=none must agree with empty sequence_fields"
      ),
      ws_ob_coherence(
        id,
        not none? or Map.get(checksum, "present") == false,
        "apply_mode=none must agree with checksum.present=false"
      ),
      ws_ob_coherence(
        id,
        apply_mode == "unknown" == (Map.get(record, "unresolved_reason") == "orderbook_not_classifiable"),
        "apply_mode=unknown must agree with unresolved_reason=orderbook_not_classifiable"
      )
    ]
  end

  defp ws_ob_coherence(_id, true, _message), do: nil
  defp ws_ob_coherence(id, false, message), do: ws_ob_finding(id, message)

  defp ws_ob_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "websocket_orderbook_semantics_shape_valid",
      path: "websocket/orderbook_semantics",
      message: message
    }
  end

  @doc """
  Flag `errors.class_hierarchy` records that don't satisfy the
  intrinsic shape contract:

    * required keys `tree`, `flat_parents`, `ancestors` all present and of
      the correct shape (object/object/object);
    * `flat_parents` and `ancestors` cover exactly the same set of classes;
    * exactly one root (a class whose `flat_parents` value is `nil`) named
      `"BaseError"`;
    * every `ancestors[c]` chain starts with `flat_parents[c]` and is
      derivable by walking the parent chain (so the two projections agree).

  Null records skip — the field is documented as null only when the
  discovery file is missing (caught upstream by Pipeline integrity stats).
  """
  @spec check_error_class_hierarchy_shape_valid(map(), map()) :: [finding()]
  def check_error_class_hierarchy_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    record = get_in(exchange, ["errors", "class_hierarchy"])

    error_class_hierarchy_record_findings(id, record)
  end

  defp error_class_hierarchy_record_findings(_id, nil), do: []

  defp error_class_hierarchy_record_findings(id, record) when is_map(record) do
    required = ~w(tree flat_parents ancestors)
    missing = required -- Map.keys(record)

    case missing do
      [] -> error_class_hierarchy_full_check(id, record)
      _ -> [error_class_hierarchy_finding(id, "missing required keys #{inspect(missing)}")]
    end
  end

  defp error_class_hierarchy_record_findings(id, _record) do
    [error_class_hierarchy_finding(id, "errors.class_hierarchy must be a map or null")]
  end

  defp error_class_hierarchy_full_check(id, record) do
    tree = record["tree"]
    flat_parents = record["flat_parents"]
    ancestors = record["ancestors"]

    cond do
      not is_map(tree) ->
        [error_class_hierarchy_finding(id, "tree must be a map, got #{inspect(tree)}")]

      not is_map(flat_parents) ->
        [error_class_hierarchy_finding(id, "flat_parents must be a map, got #{inspect(flat_parents)}")]

      not is_map(ancestors) ->
        [error_class_hierarchy_finding(id, "ancestors must be a map, got #{inspect(ancestors)}")]

      true ->
        coverage_findings(id, flat_parents, ancestors) ++
          root_findings(id, flat_parents) ++
          ancestor_chain_findings(id, flat_parents, ancestors)
    end
  end

  defp coverage_findings(id, flat_parents, ancestors) do
    fp_keys = MapSet.new(Map.keys(flat_parents))
    anc_keys = MapSet.new(Map.keys(ancestors))

    fp_only = MapSet.difference(fp_keys, anc_keys)
    anc_only = MapSet.difference(anc_keys, fp_keys)

    Enum.reject(
      [
        if(MapSet.size(fp_only) == 0,
          do: nil,
          else:
            error_class_hierarchy_finding(
              id,
              "flat_parents has #{MapSet.size(fp_only)} class(es) missing from ancestors: #{inspect(Enum.sort(MapSet.to_list(fp_only)))}"
            )
        ),
        if(MapSet.size(anc_only) == 0,
          do: nil,
          else:
            error_class_hierarchy_finding(
              id,
              "ancestors has #{MapSet.size(anc_only)} class(es) missing from flat_parents: #{inspect(Enum.sort(MapSet.to_list(anc_only)))}"
            )
        )
      ],
      &is_nil/1
    )
  end

  defp root_findings(id, flat_parents) do
    roots = for {class, nil} <- flat_parents, do: class

    case Enum.sort(roots) do
      ["BaseError"] ->
        []

      [] ->
        [
          error_class_hierarchy_finding(
            id,
            "no root class found (every flat_parents entry has a non-nil parent — cycle?)"
          )
        ]

      [single] ->
        [error_class_hierarchy_finding(id, "single root #{inspect(single)} expected \"BaseError\"")]

      multiple ->
        [error_class_hierarchy_finding(id, "expected exactly one root \"BaseError\", got #{inspect(multiple)}")]
    end
  end

  defp ancestor_chain_findings(id, flat_parents, ancestors) do
    Enum.flat_map(ancestors, fn {class, chain} ->
      ancestor_chain_entry_findings(id, flat_parents, class, chain)
    end)
  end

  defp ancestor_chain_entry_findings(id, _flat_parents, class, chain) when not is_list(chain) do
    [error_class_hierarchy_finding(id, "ancestors[#{inspect(class)}] must be a list, got #{inspect(chain)}")]
  end

  defp ancestor_chain_entry_findings(id, flat_parents, class, chain) do
    expected = walk_parent_chain(class, flat_parents, [])

    if expected == chain do
      []
    else
      [
        error_class_hierarchy_finding(
          id,
          "ancestors[#{inspect(class)}] = #{inspect(chain)} disagrees with flat_parents walk #{inspect(expected)}"
        )
      ]
    end
  end

  defp walk_parent_chain(class, flat_parents, acc) do
    walk_parent_chain(class, flat_parents, acc, MapSet.new([class]))
  end

  defp walk_parent_chain(class, flat_parents, acc, visited) do
    case Map.get(flat_parents, class) do
      nil ->
        Enum.reverse(acc)

      parent ->
        if MapSet.member?(visited, parent) do
          Enum.reverse(acc)
        else
          walk_parent_chain(parent, flat_parents, [parent | acc], MapSet.put(visited, parent))
        end
    end
  end

  defp error_class_hierarchy_finding(id, message) do
    %Finding{
      exchange: id,
      invariant: "error_class_hierarchy_shape_valid",
      path: "errors.class_hierarchy",
      message: message
    }
  end

  @doc """
  Flag class names referenced by `handle_errors` that do NOT appear as a
  key of `errors.class_hierarchy.flat_parents`. Two surfaces:

    * `handle_errors.exceptions[group][message]` — values are class names.
    * `handle_errors.http_exceptions[status]` — values are class names.

  Skips when either side is null (no handle_errors data, or no hierarchy
  data — the shape invariant catches the latter). Catches drift between
  CCXT's `errorHierarchy.ts` and `BaseError.ts` (a class added to
  exception maps but missing from the taxonomy export).
  """
  @spec check_error_classes_covered_by_hierarchy(map(), map()) :: [finding()]
  def check_error_classes_covered_by_hierarchy(exchange, _observed) do
    id = exchange_id(exchange)
    handle_errors = get_in(exchange, ["errors", "handle_errors"])
    flat_parents = get_in(exchange, ["errors", "class_hierarchy", "flat_parents"])

    if is_map(handle_errors) and is_map(flat_parents) do
      known = MapSet.new(Map.keys(flat_parents))

      exceptions_findings(id, handle_errors["exceptions"], known) ++
        http_exceptions_findings(id, handle_errors["http_exceptions"], known)
    else
      []
    end
  end

  defp exceptions_findings(id, exceptions, known) when is_map(exceptions) do
    Enum.flat_map(exceptions, fn
      {group, mapping} when is_map(mapping) ->
        for {message, class} <- mapping,
            is_binary(class),
            not MapSet.member?(known, class) do
          coverage_finding(
            id,
            "errors.handle_errors.exceptions[#{inspect(group)}][#{inspect(message)}]",
            "class #{inspect(class)} not in errors.class_hierarchy.flat_parents"
          )
        end

      _ ->
        []
    end)
  end

  defp exceptions_findings(_id, _exceptions, _known), do: []

  defp http_exceptions_findings(id, http_exceptions, known) when is_map(http_exceptions) do
    for {status, class} <- http_exceptions,
        is_binary(class),
        not MapSet.member?(known, class) do
      coverage_finding(
        id,
        "errors.handle_errors.http_exceptions[#{inspect(status)}]",
        "class #{inspect(class)} not in errors.class_hierarchy.flat_parents"
      )
    end
  end

  defp http_exceptions_findings(_id, _http_exceptions, _known), do: []

  defp coverage_finding(id, path, message) do
    %Finding{
      exchange: id,
      invariant: "error_classes_covered_by_hierarchy",
      path: path,
      message: message
    }
  end

  @doc """
  Content-equality invariant over the corpus-global error class hierarchy
  (Task 133). The `errors.class_hierarchy` value embedded in every
  per-exchange JSON must be byte-for-byte content-identical to the
  committed baseline. Outer shape is already checked by
  `check_error_class_hierarchy_shape_valid`; JSV only constrains map
  structure. This catches value-level drift (reparenting, added/removed
  classes, child order, renames) that would otherwise only surface on
  cosmetic schema changes or manual inspection.
  """
  @spec check_error_class_hierarchy_content_equals_baseline(map(), map()) :: [finding()]
  def check_error_class_hierarchy_content_equals_baseline(exchange, observed) do
    id = exchange_id(exchange)
    record = get_in(exchange, ["errors", "class_hierarchy"])
    baseline = Map.get(observed, :error_class_hierarchy)

    cond do
      is_nil(record) -> []
      is_nil(baseline) -> []
      record == baseline -> []
      true -> [hierarchy_content_finding(id)]
    end
  end

  defp hierarchy_content_finding(id) do
    %Finding{
      exchange: id,
      invariant: "error_class_hierarchy_content_equals_baseline",
      path: "errors.class_hierarchy",
      message:
        "class_hierarchy content differs from baseline (update priv/contract_test/error_class_hierarchy.json intentionally on taxonomy changes)"
    }
  end

  @doc """
  Validate the `normalization` block scaffold (Task 129):

    * `parse_methods_digest`, `field_maps`, `response_envelopes` are all
      present and shaped as maps.
    * Every digest record carries the four required keys
      (`params`/`return_type`/`async`/`statement_count`) with the
      expected types.
    * `field_maps` and `response_envelopes` carry one entry per parser
      type plus `_unresolved_reason` (and only those keys), with values
      either `null` (Task 129 scaffold) or a map (Phase 12 populated).

  Missing `normalization` top-level key is now a finding (post-Task 143)
  — v4 is the only emitted schema, so an absent `normalization` group is
  an extractor regression, not a v3-compat short-circuit.
  """
  @spec check_normalization_shape_valid(map(), map()) :: [finding()]
  def check_normalization_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)

    case Map.fetch(exchange, "normalization") do
      :error ->
        [normalization_finding(id, "normalization", "missing required top-level key")]

      # Honesty Rule: nil means the extractor produced nothing; matches the
      # nil-parent branch in `check_provenance_covers_schema/2` and
      # `check_parse_methods_digest_covers_inventory/2`.
      {:ok, nil} ->
        []

      {:ok, record} ->
        normalization_record_findings(id, record)
    end
  end

  defp normalization_record_findings(id, record) when is_map(record) do
    missing = Normalization.required_keys() -- Map.keys(record)
    extra = Map.keys(record) -- Normalization.required_keys()

    missing_findings =
      Enum.map(missing, fn key -> normalization_finding(id, "normalization", "missing required key #{inspect(key)}") end)

    extra_findings =
      Enum.map(extra, fn key -> normalization_finding(id, "normalization", "unexpected key #{inspect(key)}") end)

    digest_findings =
      digest_findings(id, Map.get(record, "parse_methods_digest"))

    field_maps_findings =
      stub_record_findings(id, "normalization.field_maps", Map.get(record, "field_maps"))

    response_envelopes_findings =
      stub_record_findings(id, "normalization.response_envelopes", Map.get(record, "response_envelopes"))

    missing_findings ++
      extra_findings ++
      digest_findings ++
      field_maps_findings ++
      response_envelopes_findings
  end

  defp normalization_record_findings(id, _record) do
    [normalization_finding(id, "normalization", "normalization must be a map")]
  end

  defp digest_findings(id, digest) when is_map(digest) do
    digest
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.flat_map(fn {name, record} -> digest_record_findings(id, name, record) end)
  end

  defp digest_findings(id, _other) do
    [normalization_finding(id, "normalization.parse_methods_digest", "must be a map")]
  end

  defp digest_record_findings(id, name, record) when is_map(record) do
    path = "normalization.parse_methods_digest.#{name}"
    missing = Normalization.digest_record_keys() -- Map.keys(record)
    extra = Map.keys(record) -- Normalization.digest_record_keys()

    List.flatten([
      Enum.map(missing, fn key -> normalization_finding(id, path, "missing required key #{inspect(key)}") end),
      Enum.map(extra, fn key -> normalization_finding(id, path, "unexpected key #{inspect(key)}") end),
      digest_field_findings(id, path, record)
    ])
  end

  defp digest_record_findings(id, name, _record) do
    [normalization_finding(id, "normalization.parse_methods_digest.#{name}", "digest record must be a map")]
  end

  defp digest_field_findings(id, path, record) do
    Enum.reject(
      [
        digest_params_finding(id, path, Map.get(record, "params")),
        digest_return_type_finding(id, path, Map.get(record, "return_type")),
        digest_async_finding(id, path, Map.get(record, "async")),
        digest_statement_count_finding(id, path, Map.get(record, "statement_count"))
      ],
      &is_nil/1
    )
  end

  defp digest_params_finding(_id, _path, list) when is_list(list), do: nil

  defp digest_params_finding(id, path, other) do
    normalization_finding(id, path, "params must be a list, got #{inspect(other)}")
  end

  defp digest_return_type_finding(_id, _path, nil), do: nil
  defp digest_return_type_finding(_id, _path, v) when is_binary(v), do: nil

  defp digest_return_type_finding(id, path, other) do
    normalization_finding(id, path, "return_type must be a string or null, got #{inspect(other)}")
  end

  defp digest_async_finding(_id, _path, v) when is_boolean(v), do: nil

  defp digest_async_finding(id, path, other) do
    normalization_finding(id, path, "async must be a boolean, got #{inspect(other)}")
  end

  defp digest_statement_count_finding(_id, _path, n) when is_integer(n) and n >= 0, do: nil

  defp digest_statement_count_finding(id, path, other) do
    normalization_finding(id, path, "statement_count must be a non-negative integer, got #{inspect(other)}")
  end

  defp stub_record_findings(id, path, record) when is_map(record) do
    missing = Normalization.stub_record_keys() -- Map.keys(record)
    extra = Map.keys(record) -- Normalization.stub_record_keys()

    List.flatten([
      Enum.map(missing, fn key -> normalization_finding(id, path, "missing required key #{inspect(key)}") end),
      Enum.map(extra, fn key -> normalization_finding(id, path, "unexpected key #{inspect(key)}") end),
      stub_value_findings(id, path, record)
    ])
  end

  defp stub_record_findings(id, path, _other) do
    [normalization_finding(id, path, "must be a map")]
  end

  defp stub_value_findings(id, path, record) do
    parser_findings =
      Enum.flat_map(Normalization.parser_types(), fn key ->
        case Map.fetch(record, key) do
          {:ok, nil} ->
            []

          {:ok, v} when is_map(v) ->
            []

          {:ok, other} ->
            [normalization_finding(id, "#{path}.#{key}", "must be null or a map, got #{inspect(other)}")]

          :error ->
            []
        end
      end)

    parser_findings ++ unresolved_reason_findings(id, path, record)
  end

  @spec unresolved_reason_findings(String.t(), String.t(), map()) :: [finding()]
  defp unresolved_reason_findings(id, path, record) do
    case Map.fetch(record, "_unresolved_reason") do
      :error ->
        []

      {:ok, nil} ->
        []

      {:ok, "not_yet_derived"} ->
        []

      {:ok, other} ->
        [
          normalization_finding(
            id,
            "#{path}._unresolved_reason",
            "must be null or the sentinel string \"not_yet_derived\", got #{inspect(other)}"
          )
        ]
    end
  end

  defp normalization_finding(id, path, message) do
    %Finding{
      exchange: id,
      invariant: "normalization_shape_valid",
      path: path,
      message: message
    }
  end

  @doc """
  Flag drift between `priv/discoveries/parse_methods.json` per-exchange
  inventory and the emitted `normalization.parse_methods_digest`.
  Every method named in the discovery entry must surface in the digest;
  otherwise the compact projection is lossy and consumers reading the
  digest miss methods that the inventory says exist.

  Skipped when `normalization` is missing or `nil` (Honesty Rule — the
  extractor produced nothing; same handling as the nil-parent branch in
  `check_provenance_covers_schema/2`). Also skipped when the inventory
  loader produced no entry for the exchange (e.g. alias exchange that
  inherits its parent's parse methods, or a scoped run that didn't
  extract this exchange).
  """
  @spec check_parse_methods_digest_covers_inventory(map(), map()) :: [finding()]
  def check_parse_methods_digest_covers_inventory(exchange, observed) do
    id = exchange_id(exchange)

    case Map.get(exchange, "normalization") do
      norm when is_map(norm) ->
        digest = Map.get(norm, "parse_methods_digest") || %{}
        inventory = Map.get(observed[:parse_methods_inventory] || %{}, id)
        digest_inventory_findings(id, digest, inventory)

      # Honesty Rule: missing OR nil normalization means the extractor
      # produced nothing for this exchange — no findings. (Matches the
      # nil-parent handling in `check_provenance_covers_schema/2`.)
      _ ->
        []
    end
  end

  defp digest_inventory_findings(_id, _digest, nil), do: []
  defp digest_inventory_findings(_id, digest, _inventory) when not is_map(digest), do: []

  defp digest_inventory_findings(id, digest, inventory) when is_list(inventory) do
    digest_keys = digest |> Map.keys() |> MapSet.new()

    inventory
    |> Enum.reject(&MapSet.member?(digest_keys, &1))
    |> Enum.sort()
    |> Enum.map(fn name ->
      %Finding{
        exchange: id,
        invariant: "parse_methods_digest_covers_inventory",
        path: "normalization.parse_methods_digest.#{name}",
        message:
          "method #{inspect(name)} is in priv/discoveries/parse_methods.json#id=#{inspect(id)} but missing from the emitted digest"
      }
    end)
  end

  defp digest_inventory_findings(_id, _digest, _other), do: []

  @doc """
  Validate `errors.status_map` and `errors.retry_classification`
  structural invariants that JSON Schema can't easily express:

    * `status_map` keys are numeric strings (HTTP status codes)
    * Each entry has `class: <string>` and `source` ∈ {`http_exceptions`,
      `throw_dispatch_predicate`}
    * `retry_classification` carries the constant five-bucket key set
      (`rate_limit`, `auth`, `server_busy`, `network`, `non_retryable`).
      No extras, no missing.
    * Each bucket value is a sorted unique list of strings.
    * Cross-section consistency: every class in `retry_classification[bucket]`
      is in the bucket the `ErrorHierarchy.bucket_for/1` classifier
      assigns it (catches drift between the classifier and the emitter).

  Both fields are nullable per schema — null values short-circuit (no
  finding). `class_hierarchy` content is NOT validated here —
  JSON Schema only enforces the outer shape (`{string => string}`) via
  `additionalProperties`, not equality with the canonical
  `ErrorHierarchy.hierarchy/0` map. Content equality is guaranteed by
  construction at emission time (Schema stamps the constant directly);
  a drift would only surface if the emitter mutates the map, which
  this invariant does not catch. Adding an explicit content check is
  tracked as a follow-up.
  """
  @spec check_handle_errors_retryable_shape_valid(map(), map()) :: [finding()]
  def check_handle_errors_retryable_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)

    status_findings = error_status_map_findings(id, get_in(exchange, ["errors", "status_map"]))
    retryable_findings = error_retryable_findings(id, get_in(exchange, ["errors", "retry_classification"]))

    status_findings ++ retryable_findings
  end

  defp error_status_map_findings(_id, nil), do: []

  defp error_status_map_findings(id, record) when is_map(record) do
    Enum.flat_map(record, fn {status, entries} -> error_status_entry_findings(id, status, entries) end)
  end

  defp error_status_map_findings(id, other) do
    [error_finding(id, "status_map", "must be a map or null, got #{inspect(other)}")]
  end

  defp error_status_entry_findings(id, status, entries) do
    key_findings =
      if numeric_string?(status) do
        []
      else
        [error_finding(id, "status_map", "key #{inspect(status)} is not a numeric HTTP status string")]
      end

    list_findings =
      if is_list(entries) do
        Enum.flat_map(entries, &error_status_entry_shape_findings(id, status, &1))
      else
        [error_finding(id, "status_map.#{status}", "value must be a list, got #{inspect(entries)}")]
      end

    key_findings ++ list_findings
  end

  defp error_status_entry_shape_findings(id, status, %{"class" => class, "source" => source}) do
    class_findings =
      if is_binary(class) and class != "" do
        []
      else
        [error_finding(id, "status_map.#{status}", "entry class must be a non-empty string, got #{inspect(class)}")]
      end

    source_findings =
      if source in ~w(http_exceptions throw_dispatch_predicate) do
        []
      else
        [error_finding(id, "status_map.#{status}", "entry source #{inspect(source)} not in vocabulary")]
      end

    class_findings ++ source_findings
  end

  defp error_status_entry_shape_findings(id, status, other) do
    [
      error_finding(
        id,
        "status_map.#{status}",
        "entry must be a map with class+source keys, got #{inspect(other)}"
      )
    ]
  end

  defp error_retryable_findings(_id, nil), do: []

  defp error_retryable_findings(id, record) when is_map(record) do
    expected = ErrorHierarchy.buckets()
    actual = Map.keys(record)
    missing = expected -- actual
    extra = actual -- expected

    missing_findings =
      Enum.map(missing, fn key ->
        error_finding(id, "retry_classification", "missing required bucket #{inspect(key)}")
      end)

    extra_findings =
      Enum.map(extra, fn key -> error_finding(id, "retry_classification", "unexpected bucket #{inspect(key)}") end)

    bucket_findings =
      Enum.flat_map(record, fn {bucket, classes} -> error_retryable_bucket_findings(id, bucket, classes) end)

    missing_findings ++ extra_findings ++ bucket_findings
  end

  defp error_retryable_findings(id, other) do
    [error_finding(id, "retry_classification", "must be a map or null, got #{inspect(other)}")]
  end

  defp error_retryable_bucket_findings(id, bucket, classes) when is_list(classes) do
    if Enum.all?(classes, &is_binary/1) do
      bucket_mismatch_findings(id, bucket, classes) ++ bucket_sort_findings(id, bucket, classes)
    else
      [error_finding(id, "retry_classification.#{bucket}", "all entries must be strings, got #{inspect(classes)}")]
    end
  end

  defp error_retryable_bucket_findings(id, bucket, other) do
    [error_finding(id, "retry_classification.#{bucket}", "value must be a list, got #{inspect(other)}")]
  end

  defp bucket_mismatch_findings(id, bucket, classes) do
    if bucket in ErrorHierarchy.buckets() do
      Enum.flat_map(classes, &class_mismatch_finding(id, bucket, &1))
    else
      []
    end
  end

  defp class_mismatch_finding(id, bucket, class) do
    actual_bucket = ErrorHierarchy.bucket_for(class)

    if actual_bucket == bucket do
      []
    else
      [
        error_finding(
          id,
          "retry_classification.#{bucket}",
          "class #{inspect(class)} classified as #{inspect(actual_bucket)} by ErrorHierarchy, " <>
            "but emitted under bucket #{inspect(bucket)}"
        )
      ]
    end
  end

  defp bucket_sort_findings(id, bucket, classes) do
    if classes == Enum.sort(Enum.uniq(classes)) do
      []
    else
      [error_finding(id, "retry_classification.#{bucket}", "class list must be sorted and unique")]
    end
  end

  defp numeric_string?(s) when is_binary(s), do: s != "" and String.match?(s, ~r/^[0-9]+$/)
  defp numeric_string?(_), do: false

  defp error_finding(id, section, message) do
    %Finding{
      exchange: id,
      invariant: "handle_errors_retryable_shape_valid",
      path: "errors.#{section}",
      message: message
    }
  end

  @doc """
  Validate the `endpoints.handlers` reshape (Tasks 88a/88b/88c, finalized in Task 142).

  The error/sign/parse dispatch tables route into
  `endpoints.handlers.{error,signing,parse}`. Asserts:

    * `endpoints.handlers` exists and is a map.
    * The three keys (`error`, `signing`, `parse`) are present.
    * No extra keys.
    * Each value's content matches the expected nullable shape (the
      JSON Schema enforces deeper structural shape — this invariant
      catches presence drift, not entry shape).

  Mirrors `testnet_urls_shape_valid`'s structure: per-key audit with a
  finding per drift type. JSON Schema catches the array-of-records and
  object-of-arrays leaf shapes; this invariant catches the
  reorganization integrity.

  Post-Task-143: no v3-shape short-circuit — every emitted exchange is
  v4-shaped, so a missing `endpoints.handlers` map is a real finding,
  not a v3 fallback.
  """
  @spec check_handler_dispatch_shape_valid(map(), map()) :: [finding()]
  def check_handler_dispatch_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)
    handlers = get_in(exchange, ["endpoints", "handlers"])
    handler_dispatch_findings(id, handlers)
  end

  @handler_keys ~w(error signing parse)

  defp handler_dispatch_findings(id, nil) do
    [handler_finding(id, "endpoints.handlers", "missing — v4 emission requires endpoints.handlers map")]
  end

  defp handler_dispatch_findings(id, handlers) when is_map(handlers) do
    expected = @handler_keys
    actual = Map.keys(handlers)
    missing = expected -- actual
    extra = actual -- expected

    missing_findings =
      Enum.map(missing, fn k -> handler_finding(id, "endpoints.handlers", "missing required key #{inspect(k)}") end)

    extra_findings =
      Enum.map(extra, fn k -> handler_finding(id, "endpoints.handlers", "unexpected key #{inspect(k)}") end)

    leaf_findings = handler_leaf_findings(id, handlers)

    missing_findings ++ extra_findings ++ leaf_findings
  end

  defp handler_dispatch_findings(id, other) do
    [handler_finding(id, "endpoints.handlers", "must be a map, got #{inspect(other)}")]
  end

  # `error` -> nullable list, `signing` -> nullable map with sections+branches,
  # `parse` -> nullable map of method->[parse helpers]. JSON Schema validates
  # the deeper shape; this catches the wrong-Elixir-type case.
  defp handler_leaf_findings(id, handlers) do
    Enum.flat_map(handlers, fn
      {"error", nil} ->
        []

      {"error", value} when is_list(value) ->
        []

      {"error", other} ->
        [handler_finding(id, "endpoints.handlers.error", "must be list or null, got #{inspect(other)}")]

      {"signing", nil} ->
        []

      {"signing", value} when is_map(value) ->
        []

      {"signing", other} ->
        [handler_finding(id, "endpoints.handlers.signing", "must be map or null, got #{inspect(other)}")]

      {"parse", nil} ->
        []

      {"parse", value} when is_map(value) ->
        []

      {"parse", other} ->
        [handler_finding(id, "endpoints.handlers.parse", "must be map or null, got #{inspect(other)}")]

      _ ->
        []
    end)
  end

  defp handler_finding(id, path, message) do
    %Finding{
      exchange: id,
      invariant: "handler_dispatch_shape_valid",
      path: path,
      message: message
    }
  end

  @doc """
  `rate_limits.endpoint_cost_binding` must match
  `CcxtExtract.RateLimitCostBinding.derive/1` applied to the bucket wrapper at
  `rate_limits.buckets` — non-null only when the wrapper has a resolved,
  non-empty `buckets` list; otherwise null.
  """
  @spec check_rate_limits_endpoint_cost_binding_coherent(map(), map()) :: [finding()]
  def check_rate_limits_endpoint_cost_binding_coherent(exchange, _observed) do
    endpoint_cost_binding_findings(exchange)
  end

  defp endpoint_cost_binding_findings(exchange) do
    id = exchange_id(exchange)

    case Map.get(exchange, "rate_limits") do
      %{} = rl -> binding_finding(id, rl)
      _ -> []
    end
  end

  defp binding_finding(id, rl) do
    wrapper = Map.get(rl, "buckets")
    binding = Map.get(rl, "endpoint_cost_binding")
    expected = RateLimitCostBinding.derive(wrapper)

    if binding == expected do
      []
    else
      [
        %Finding{
          exchange: id,
          invariant: "rate_limits_endpoint_cost_binding_coherent",
          path: "rate_limits.endpoint_cost_binding",
          message:
            "endpoint_cost_binding must equal RateLimitCostBinding.derive(rate_limits.buckets); expected #{inspect(expected)}, got #{inspect(binding)}"
        }
      ]
    end
  end

  @doc """
  Flag `error_code_fields` entries whose root (first of `object_path`, or
  `object`) is not in the committed baseline set.
  """
  @spec check_error_code_fields_root(map(), map()) :: [finding()]
  def check_error_code_fields_root(exchange, %{error_code_fields_roots: roots}) do
    id = exchange_id(exchange)
    entries = get_in(exchange, ["errors", "handle_errors", "error_code_fields"]) || []

    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, i} -> root_finding(id, entry, i, roots) end)
  end

  defp root_finding(id, entry, index, roots) do
    root = entry_root(entry)

    cond do
      is_nil(root) -> []
      root in roots -> []
      true -> [root_finding_map(id, entry, root, index, roots)]
    end
  end

  defp root_finding_map(id, entry, root, index, roots) do
    %Finding{
      exchange: id,
      invariant: "error_code_fields_root_in_observed_set",
      path: error_code_fields_path(index, entry),
      message: "root #{inspect(root)} not in baseline roots #{inspect(roots)}"
    }
  end

  @doc """
  Flag `priv/overrides/<exchange>.json` files that fail the v1 registry
  contract (`CcxtExtract.OverrideRegistry.load/1` raises). Exchanges
  without an override file emit nothing.
  """
  @spec check_override_registry_valid(map(), map()) :: [finding()]
  def check_override_registry_valid(exchange, _observed) do
    id = exchange_id(exchange)

    try do
      _ = CcxtExtract.OverrideRegistry.load(id)
      []
    rescue
      e ->
        [
          %Finding{
            exchange: id,
            invariant: "override_registry_valid",
            path: "priv/overrides/#{id}.json",
            message: Exception.message(e)
          }
        ]
    end
  end

  @doc """
  Flag `priv/overrides/<exchange>.json` entries whose `value` is not
  present at its RFC 6901 `path` in the emitted exchange map. Complements
  `override_registry_valid` (which only verifies files load) by checking
  the merge stage (`OverrideRegistry.apply_all/2`) actually landed each
  entry end-to-end.
  """
  @spec check_override_paths_present_in_output(map(), map()) :: [finding()]
  def check_override_paths_present_in_output(exchange, _observed) do
    id = exchange_id(exchange)

    # TODO(Task 61a): load overrides once in run_all/1 and thread through
    # `observed` instead of re-reading per invariant. Negligible at 14 files
    # today; revisit when override count grows or invariant set expands.
    case CcxtExtract.OverrideRegistry.load(id) do
      :none ->
        []

      overrides when is_list(overrides) ->
        Enum.flat_map(overrides, &safe_override_path_finding(id, &1, exchange))
    end
  rescue
    e in [RuntimeError, File.Error, Jason.DecodeError] ->
      [
        %Finding{
          exchange: exchange_id(exchange),
          invariant: "override_paths_present_in_output",
          path: "priv/overrides/#{exchange_id(exchange)}.json",
          message: Exception.message(e)
        }
      ]
  end

  # Findings are this invariant's native reporting channel — a raise from
  # pointer_to_keys/1 (Task 104: unsupported numeric segment) or
  # get_in/2 on a mis-typed path must surface as a finding, not bubble
  # up and abort sibling entries in the same file. The enumerated
  # exception list is deliberate; unrelated exceptions (e.g. SystemLimit)
  # still propagate.
  defp safe_override_path_finding(id, entry, exchange) do
    override_path_finding(id, entry, exchange)
  rescue
    e in [RuntimeError, KeyError, ArgumentError, FunctionClauseError] ->
      [
        %Finding{
          exchange: id,
          invariant: "override_paths_present_in_output",
          path: entry["path"] || "<unknown>",
          message: Exception.message(e)
        }
      ]
  end

  defp override_path_finding(id, entry, exchange) do
    # Override files carry v3 pointers (`/structure/...`); v4-shaped output
    # lives under `/auth`, `/errors`, etc. Translate before walking so the
    # invariant doesn't silently miss-resolve against v4 corpus. The pipeline
    # does the same translation at apply-time (`Pipeline.apply_override_entry/5`).
    pointer = entry["path"]
    translated = CcxtExtract.OverrideRegistry.translate_pointer(pointer)
    keys = CcxtExtract.OverrideRegistry.pointer_to_keys(translated)
    actual = get_in(exchange, keys)

    if actual == entry["value"] do
      []
    else
      [
        %Finding{
          exchange: id,
          invariant: "override_paths_present_in_output",
          path: translated,
          message: "override value not present at path; got #{inspect(actual)}"
        }
      ]
    end
  end

  @doc """
  Flag drift between the `CcxtExtract.Provenance` declared pointer lists
  (`raw_pointers/0 ++ derived_pointers/0`) and the sections actually
  emitted under the v4 top-level groups (`/exchange`, `/raw`, `/auth`,
  `/errors`, `/endpoints`, `/markets`, `/rate_limits`, `/normalization`)
  in each output exchange JSON. Catches three drift types:

    * `uncovered_section` — Pipeline emits a section but Provenance has
      no matching pointer (and `_provenance` doesn't tag it `"override"`).
    * `orphan_declaration` — Provenance declares a pointer whose key path
      doesn't exist in the emitted exchange map.
    * `tag_mismatch` — `exchange._provenance[pointer]` is present but its
      value doesn't match the predicted tag (and isn't `"override"`,
      which is always allowed).

  Granularity mirrors Provenance's own split: most sections compare at
  depth-2 (`/section/key`); parents with deeper declared children
  (`/errors/handle_errors`, `/endpoints/request`, `/endpoints/handlers`)
  compare at depth-3. Derived from the declared set itself, not
  hardcoded — adding a deeper pointer to `Provenance` automatically
  shifts enumeration for that prefix. `/testnet` is a depth-1 pointer
  (the section IS the leaf) — coverage for it relies on the orphan
  check, not the emit enumeration.
  """
  @spec check_provenance_covers_schema(map(), map()) :: [finding()]
  def check_provenance_covers_schema(exchange, _observed) do
    id = exchange_id(exchange)
    declared = declared_tags()
    deep = deep_prefixes(declared)
    provenance = Map.get(exchange, "_provenance", %{})
    emitted = enumerate_emitted_pointers(exchange, deep)

    uncovered_findings(id, emitted, declared, provenance) ++
      orphan_findings(id, exchange, declared) ++
      tag_mismatch_findings(id, declared, provenance)
  end

  ## Internals

  # v4 top-level groups iterated by `enumerate_emitted_pointers/2`.
  # `testnet` is intentionally excluded — it's a depth-1 pointer
  # (`/testnet`) and the walker emits sub-keys for everything in this
  # list, so including it would spam uncovered_findings for every
  # `/testnet/<subkey>`. Orphan coverage still validates that `/testnet`
  # resolves in the emitted exchange.
  @provenance_section_roots ~w(exchange raw auth errors endpoints markets rate_limits normalization)

  defp declared_tags do
    raw = Map.new(CcxtExtract.Provenance.raw_pointers(), &{&1, "raw"})
    derived = Map.new(CcxtExtract.Provenance.derived_pointers(), &{&1, "derived"})
    Map.merge(raw, derived)
  end

  defp deep_prefixes(declared) do
    declared
    |> Map.keys()
    |> Enum.filter(&(pointer_depth(&1) >= 3))
    |> MapSet.new(&parent_prefix/1)
  end

  defp pointer_depth("/" <> rest), do: rest |> String.split("/") |> length()
  defp pointer_depth(_), do: 0

  defp parent_prefix("/" <> rest) do
    parts = rest |> String.split("/") |> Enum.drop(-1)
    "/" <> Enum.join(parts, "/")
  end

  defp enumerate_emitted_pointers(exchange, deep) do
    Enum.flat_map(@provenance_section_roots, fn root ->
      section = Map.get(exchange, root)

      if is_map(section) do
        Enum.flat_map(section, &emit_pointer(root, &1, deep))
      else
        []
      end
    end)
  end

  defp emit_pointer(root, {key, value}, deep) do
    prefix = "/#{root}/#{key}"

    cond do
      MapSet.member?(deep, prefix) and is_map(value) ->
        Enum.map(Map.keys(value), &"#{prefix}/#{&1}")

      MapSet.member?(deep, prefix) ->
        # Deep-prefixed section (e.g. /structure/handle_errors) with a
        # nil or non-map value. We emit nothing here; coverage for the
        # declared subkeys is decided by the orphan check, which treats
        # a nil parent as vacuously satisfied (Honesty Rule — see
        # `walk_pointer/2`). The test "nil parent is vacuously resolved"
        # exercises this interplay.
        []

      true ->
        [prefix]
    end
  end

  defp uncovered_findings(id, emitted, declared, provenance) do
    emitted
    |> Enum.reject(fn p ->
      Map.has_key?(declared, p) or Map.get(provenance, p) == "override"
    end)
    |> Enum.sort()
    |> Enum.map(fn p ->
      %Finding{
        exchange: id,
        invariant: "provenance_covers_schema",
        path: p,
        message: "section emitted at #{p} but not declared in Provenance raw/derived lists"
      }
    end)
  end

  # No override-tag escape hatch here (unlike uncovered/tag_mismatch): a
  # declared pointer must point at a real key. "override" can mask a
  # wrong *value* but can't synthesize a missing key path.
  defp orphan_findings(id, exchange, declared) do
    declared
    |> Map.keys()
    |> Enum.reject(&pointer_resolves?(exchange, &1))
    |> Enum.sort()
    |> Enum.map(fn p ->
      %Finding{
        exchange: id,
        invariant: "provenance_covers_schema",
        path: p,
        message: "Provenance declares #{p} but the key path does not resolve in the emitted exchange"
      }
    end)
  end

  defp tag_mismatch_findings(id, declared, provenance) do
    declared
    |> Enum.reject(fn {p, expected} ->
      actual = Map.get(provenance, p)
      actual in [expected, "override"]
    end)
    |> Enum.sort()
    |> Enum.map(fn {p, expected} ->
      actual = Map.get(provenance, p)

      %Finding{
        exchange: id,
        invariant: "provenance_covers_schema",
        path: p,
        message: "tag mismatch at #{p}: expected #{inspect(expected)} or \"override\", got #{inspect(actual)}"
      }
    end)
  end

  # A pointer resolves if the full key path walks through maps (value
  # may be nil at the end) OR if mid-walk we hit a nil parent — that's
  # vacuously satisfied per the Honesty Rule (nil-plus-reason is
  # legitimate, and a nil parent trivially can't track its subkeys).
  defp pointer_resolves?(exchange, "/" <> rest) do
    rest |> String.split("/") |> walk_pointer(exchange)
  end

  defp pointer_resolves?(_exchange, _), do: false

  defp walk_pointer([], _value), do: true
  defp walk_pointer(_remaining, nil), do: true

  defp walk_pointer([key | rest], map) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> walk_pointer(rest, v)
      :error -> false
    end
  end

  defp walk_pointer(_, _), do: false

  defp exchange_id(%{"exchange" => %{"id" => id}}) when is_binary(id), do: id
  defp exchange_id(%{"id" => id}) when is_binary(id), do: id
  defp exchange_id(_), do: "<unknown>"

  # Schema copies and metadata files live alongside per-exchange JSON but
  # are not exchanges. `exchange_v4.json` is the JSON Schema copy under
  # Schema files must be excluded so the wildcard loader does not try to
  # treat them as exchange JSON. Files starting with `_` are manifests/reports.
  @non_exchange_files [CcxtExtract.Schema.schema_filename()]

  defp load_exchanges(output_dir, scope) do
    output_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      base = Path.basename(path)
      String.starts_with?(base, "_") or base in @non_exchange_files
    end)
    |> maybe_scope_files(scope)
    |> Enum.sort()
    |> Enum.map(&JsonIO.read_json!/1)
  end

  defp maybe_scope_files(paths, nil), do: paths

  defp maybe_scope_files(paths, scope) do
    # Plain map keyed by ID avoids flowing MapSet through a keyword opt,
    # which dialyzer can't track opaquely from `any()` input.
    allowed = Map.new(scope, &{&1, true})
    Enum.filter(paths, fn path -> Map.has_key?(allowed, Path.basename(path, ".json")) end)
  end

  # Load `priv/discoveries/parse_methods.json` and project to
  # `%{exchange_id => [method_name, ...]}`. Returns `%{}` when the
  # discovery file is absent so v3-only test runs (which never need the
  # inventory) don't fail. Callers can override the path via
  # `:parse_methods_inventory_path` or pass an inline map via
  # `:parse_methods_inventory` (see `run_all/1`).
  defp load_parse_methods_inventory(opts) do
    path =
      opts[:parse_methods_inventory_path] ||
        CcxtExtract.Paths.priv("discoveries/parse_methods.json")

    case JsonIO.read_json(path) do
      {:ok, %{"exchanges" => entries}} when is_list(entries) ->
        Map.new(entries, fn entry ->
          methods = Map.get(entry, "parse_methods") || %{}
          {entry["id"], Map.keys(methods)}
        end)

      {:ok, malformed} ->
        raise """
        parse_methods.json at #{path} has an unexpected top-level shape.

        Expected: %{"exchanges" => [_ | _]}
        Got:      #{inspect(malformed, limit: 5)}

        Regenerate via `mix ccxt_extract.parse_methods` (or the full
        `mix ccxt_extract.update`). Silently falling back to %{} would
        disable parse_methods_digest_covers_inventory and let lossy
        digests through.
        """

      {:error, {:missing_input, _}} ->
        %{}

      {:error, {:invalid_json, detail}} ->
        raise """
        parse_methods.json at #{path} is not valid JSON: #{detail}

        Regenerate via `mix ccxt_extract.parse_methods` (or the full
        `mix ccxt_extract.update`). Silently falling back to %{} would
        disable parse_methods_digest_covers_inventory and let lossy
        digests through.
        """
    end
  end

  defp load_baseline_roots(opts) do
    path =
      opts[:baseline_path] ||
        CcxtExtract.Paths.priv("contract_test/error_code_fields_roots.json")

    case JsonIO.read_json(path) do
      {:ok, body} ->
        Enum.sort(body)

      {:error, {:missing_input, _}} ->
        raise """
        Contract test baseline missing at #{path}.

        Create it with the current corpus roots, e.g.:

            #{Jason.encode!(["response", "error"])}

        The baseline is the authority for \
        error_code_fields_root_in_observed_set. Deriving the safelist from \
        the same corpus being validated would make the invariant tautological.
        """
    end
  end

  defp load_request_defaults_reachable_baseline(opts) do
    path =
      opts[:request_defaults_baseline_path] ||
        CcxtExtract.Paths.priv("contract_test/request_defaults_reachable_baseline.json")

    case JsonIO.read_json(path) do
      {:ok, baseline} when is_map(baseline) ->
        baseline

      {:ok, other} ->
        raise """
        Contract test baseline at #{path} has unexpected shape.

        Expected a map of #{inspect(%{"binance" => ["fetchFundingHistory"]})}.
        Got: #{inspect(other, limit: 3)}

        The baseline is the authority for \
        request_defaults_resolvable_reachable_from_unified — it exempts methods \
        that legitimately carry resolvable literal bodies but never appear in \
        the filtered endpoints.unified map (transitive helpers + unified methods \
        the extractor didn't surface). Update it intentionally on CCXT bumps.
        """

      {:error, {:missing_input, _}} ->
        %{}
    end
  end

  defp load_hierarchy_baseline(opts) do
    path =
      opts[:hierarchy_baseline_path] ||
        CcxtExtract.Paths.priv("contract_test/error_class_hierarchy.json")

    case JsonIO.read_json(path) do
      {:ok, %{"tree" => _, "flat_parents" => _, "ancestors" => _} = rec} ->
        rec

      {:ok, other} ->
        raise """
        Contract test hierarchy baseline at #{path} has unexpected shape.

        Expected map with keys "tree", "flat_parents", "ancestors".
        Got: #{inspect(other, limit: 3)}

        The baseline is the authority for error_class_hierarchy_content_equals_baseline.
        Update the committed file intentionally on legitimate taxonomy changes.
        """

      {:error, {:missing_input, _}} ->
        raise """
        Contract test baseline missing at #{path}.

        The baseline pins the exact CCXT error class taxonomy (tree/flat_parents/ancestors)
        for content-equality checking. It is updated intentionally when
        errorHierarchy.ts legitimately changes.
        """
    end
  end

  defp run_invariants(exchange, observed) do
    Enum.flat_map(@invariants, fn {_name, fun} ->
      apply(__MODULE__, fun, [exchange, observed])
    end)
  end

  defp run_corpus_invariants(opts) do
    Enum.flat_map(@corpus_invariants, fn {_name, fun} ->
      apply(__MODULE__, fun, [opts])
    end)
  end

  @doc """
  Flag same-file flows from a `CcxtExtract.Paths` read helper (`priv`,
  `priv_dir`, `discoveries`, `ts_src`, `bundle`, `version_file`) into a
  `File` writer (`write*`, `mkdir_p*`, `cp*`, `rm*`, `rename`, `touch*`).

  Uses `Reach.Project.taint_analysis/2` over `lib/**/*.ex` and filters to
  same-file, unsanitized flows that reach a **write-position** argument of the
  sink (per the `{function, arity} => write_arg_indices` registry). The
  position filter distinguishes `File.cp!/2` arg 0 (a read source — a
  `Paths.priv(...)` path there is fine) from arg 1 (the write destination), and
  drops control-only reaches such as `if File.exists?(p), do: File.write!(other, …)`
  without relying on a path-inspection sanitizer. Content readers
  (`read`/`read!`/`stream!`/`open`/`open!`) remain sanitizers so a path that has
  become file content can flow into a writer freely. Cross-module flows are
  conservatively dropped — Reach's source frontend over-approximates through
  function boundaries (e.g. `FixtureParity.check(fixtures_dir)` taints an
  unrelated `File.write!` inside the callee), and dynamic-dispatch writers
  (`writer.(dest)`) are invisible to the source frontend. This is a best-effort
  guard against the common direct-call leak pattern.

  ## Options

    * `:glob` — override the source glob (default: `"lib/**/*.ex"`). Used
      by tests to target a narrower module set.

  Corpus-scoped: returns all findings tagged with `exchange: "_corpus"`.
  Gracefully returns `[]` when Reach is unavailable (e.g. prod compile
  where the dep is `only: [:dev, :test]`).
  """
  @spec check_paths_rw_split(keyword()) :: [finding()]
  def check_paths_rw_split(opts \\ []) do
    if Code.ensure_loaded?(Reach.Project) do
      glob = Keyword.get(opts, :glob, "lib/**/*.ex")
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      project = apply(Reach.Project, :from_glob, [glob])

      @paths_read_helpers
      |> Enum.flat_map(&paths_rw_findings(project, &1))
      |> Enum.filter(&paths_rw_reportable?/1)
      |> Enum.map(&paths_rw_to_finding/1)
      |> Enum.uniq()
    else
      []
    end
  end

  # `apply/3` is intentional: `:reach` is `only: [:dev, :test]` so
  # `Reach.Project` is absent when compiling in prod. Direct calls trigger
  # compile-time warnings ("module is not available"); `apply/3` defers
  # resolution to runtime (guarded by `Code.ensure_loaded?/1` above).
  defp paths_rw_findings(project, fn_name) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Reach.Project, :taint_analysis, [
      project,
      [
        sources: [type: :call, module: CcxtExtract.Paths, function: fn_name],
        sinks: &paths_rw_sink?/1,
        sanitizers: &paths_rw_sanitizer?/1
      ]
    ])
  end

  defp paths_rw_sink?(node) do
    node.type == :call and
      node.meta[:module] == File and
      Map.has_key?(@writer_sinks, {node.meta[:function], node.meta[:arity]})
  end

  # Once a path has been consumed by a content reader, the downstream value is
  # file CONTENT, not a path — so further flow into a writer is legitimate
  # (reading a committed artifact and writing its bytes into the output dir).
  # Prevents false positives on `Paths.priv → File.read! → ... → File.write!`.
  defp paths_rw_sanitizer?(node) do
    node.type == :call and
      node.meta[:module] == File and
      node.meta[:function] in @file_reader_fns
  end

  # Keep only unsanitized, same-file flows whose read-helper path reaches a
  # WRITE-position argument of the sink. See module doc on check_paths_rw_split/1.
  defp paths_rw_reportable?(%{sanitized: true}), do: false

  defp paths_rw_reportable?(%{source: %{source_span: s}, sink: %{source_span: k}} = flow)
       when not is_nil(s) and not is_nil(k) do
    s.file == k.file and reaches_write_position?(flow)
  end

  defp paths_rw_reportable?(_), do: false

  # True when the read-helper source flows into (or *is*) a write-position
  # argument of the sink — not a read-position arg (e.g. `File.cp!/2` arg 0)
  # and not a control-only reach (e.g. `if File.exists?(p), do: File.write!(other, …)`,
  # where `p` reaches the sink node through a control edge but never its
  # write-position argument subtree). For a remote `File.<fn>` call the receiver
  # contributes no child node, so `sink.children` is the positional argument
  # list and child index == argument index. The source node is excluded from the
  # chop `path`, so it is folded back in to catch `File.write!(Paths.priv(…), x)`
  # where the source IS the write-position argument.
  defp reaches_write_position?(%{source: source, sink: sink, path: path}) do
    indices = Map.get(@writer_sinks, {sink.meta[:function], sink.meta[:arity]}, [])
    reachable = MapSet.new([source.id | path])

    sink.children
    |> Enum.with_index()
    |> Enum.any?(fn {arg, index} ->
      index in indices and subtree_intersects?(arg, reachable)
    end)
  end

  defp subtree_intersects?(node, reachable) do
    node |> subtree_ids([]) |> Enum.any?(&MapSet.member?(reachable, &1))
  end

  defp subtree_ids(%{id: id, children: children}, acc) do
    Enum.reduce(children, [id | acc], &subtree_ids/2)
  end

  defp paths_rw_to_finding(%{source: source, sink: sink}) do
    src_fn = "#{inspect(source.meta.module)}.#{source.meta.function}/#{source.meta.arity}"
    sink_fn = "File.#{sink.meta.function}/#{sink.meta.arity}"

    %Finding{
      exchange: "_corpus",
      invariant: "paths_rw_split",
      path: "#{source.source_span.file}:#{source.source_span.start_line}",
      message:
        "#{src_fn} (read helper) flows into #{sink_fn} at #{sink.source_span.file}:#{sink.source_span.start_line} — use the matching `out_*` write helper"
    }
  end

  defp entry_root(%{"object_path" => [root | _]}) when is_binary(root), do: root
  defp entry_root(%{"object_path" => nil, "object" => object}) when is_binary(object), do: object
  defp entry_root(%{"object" => object}) when is_binary(object), do: object
  defp entry_root(_), do: nil

  defp error_code_fields_path(index, %{"object_path" => [root | _]}) when is_binary(root) do
    "errors.handle_errors.error_code_fields[#{index}].object_path"
  end

  defp error_code_fields_path(index, %{"object_path" => nil, "object" => object}) when is_binary(object) do
    "errors.handle_errors.error_code_fields[#{index}].object"
  end

  defp error_code_fields_path(index, %{"object" => object}) when is_binary(object) do
    "errors.handle_errors.error_code_fields[#{index}].object"
  end

  defp error_code_fields_path(index, _entry) do
    base = "errors.handle_errors.error_code_fields[#{index}]"
    "#{base}.object_path"
  end

  defp collect_map_keys(map) when is_map(map) do
    Enum.reduce(map, MapSet.new(), fn {k, v}, acc ->
      acc = MapSet.put(acc, k)
      if is_map(v), do: MapSet.union(acc, collect_map_keys(v)), else: acc
    end)
  end

  defp collect_map_keys(_), do: MapSet.new()

  defp build_report(exchanges, findings, baseline, tier_scope) do
    %{
      "tier_scope" => tier_scope,
      "summary" => %{
        "exchanges_checked" => length(exchanges),
        "invariants_run" => length(@invariants) + length(@corpus_invariants),
        "total_findings" => length(findings),
        "findings_by_invariant" => count_by_invariant(findings)
      },
      "baseline" => %{
        "error_code_fields_roots" => baseline.error_code_fields_roots
      },
      "findings" => Enum.map(findings, &finding_to_string_keyed_map/1)
    }
  end

  # `Map.from_struct/1` drops `__struct__` before stringifying keys, so the
  # emitted report carries plain `{"exchange","invariant","path","message"}`
  # objects identical to the pre-struct map shape (Task 109).
  defp finding_to_string_keyed_map(%Finding{} = finding) do
    finding
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp count_by_invariant(findings) do
    base = Map.new(@invariants ++ @corpus_invariants, fn {name, _} -> {name, 0} end)
    Enum.reduce(findings, base, fn f, acc -> Map.update!(acc, f.invariant, &(&1 + 1)) end)
  end
end
