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

    * `rate_limits_endpoint_cost_binding_coherent` — v4 emit only;
      `rate_limits.endpoint_cost_binding` equals
      `RateLimitCostBinding.derive(rate_limits.buckets)` (null when the wrapper
      is unresolved or has no buckets).

  New invariants append to `@invariants`; the runner is registry-driven.
  """

  alias CcxtExtract.ErrorHierarchy
  alias CcxtExtract.JsonIO
  alias CcxtExtract.Normalization
  alias CcxtExtract.RateLimitCostBinding
  alias CcxtExtract.RequestShape
  alias CcxtExtract.SignRecipe
  alias CcxtExtract.TestnetUrls

  @type finding :: %{
          exchange: String.t(),
          invariant: String.t(),
          path: String.t(),
          message: String.t()
        }

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
    {"testnet_urls_shape_valid", :check_testnet_urls_shape_valid},
    {"error_class_hierarchy_shape_valid", :check_error_class_hierarchy_shape_valid},
    {"error_classes_covered_by_hierarchy", :check_error_classes_covered_by_hierarchy},
    {"normalization_shape_valid", :check_normalization_shape_valid},
    {"parse_methods_digest_covers_inventory", :check_parse_methods_digest_covers_inventory},
    {"handle_errors_retryable_shape_valid", :check_handle_errors_retryable_shape_valid},
    {"handler_dispatch_v4_shape_valid", :check_handler_dispatch_v4_shape_valid},
    {"rate_limits_endpoint_cost_binding_coherent", :check_rate_limits_endpoint_cost_binding_coherent}
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

  # Functions that consume a filesystem path as input and return a non-path
  # value (content, boolean, stat map, file handle). Once a path flows through
  # one of these, downstream data is no longer a path, so further use in a
  # writer is legitimate — e.g. reading a committed JSON schema and writing
  # its contents into the output dir, or branching on `File.exists?/1` before
  # writing unrelated data via the `out_*` helpers.
  #
  # TODO(Task 127): Reach marks a flow sanitized if any sanitizer node
  # appears anywhere on the source→sink chop. That means a path-inspection
  # (`exists?`/`stat`/`ls`) in the same function as a LATER `File.write!` to
  # an unrelated `out_*` path currently sanitizes a false positive (e.g.
  # `ccxt_extract.setup.ex:254-287`), but would ALSO sanitize a genuine leak
  # of the form `if File.exists?(p), do: File.write!(p, data)` where the
  # sink's target IS the inspected path. A tighter fix would be
  # position-aware sinks (`File.cp!` arg 0 is read-only) plus variable-level
  # (not chop-level) sanitization. Narrowing to only content-readers
  # (`read`/`read!`/`stream!`/`open`/`open!`) re-exposes the setup.ex false
  # positive and trips the baseline-green contract test — verified
  # 2026-04-24. See CHANGELOG entry under the paths_rw_split fix.
  @file_reader_fns [
    :read,
    :read!,
    :stream!,
    :exists?,
    :regular?,
    :dir?,
    :stat,
    :stat!,
    :lstat,
    :lstat!,
    :ls,
    :ls!,
    :open,
    :open!
  ]

  @file_writer_fns [
    :write,
    :write!,
    :mkdir_p,
    :mkdir_p!,
    :cp,
    :cp!,
    :cp_r,
    :cp_r!,
    :rm,
    :rm!,
    :rm_rf,
    :rm_rf!,
    :rename,
    :touch,
    :touch!
  ]

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

    baseline = %{
      error_code_fields_roots: baseline_roots,
      parse_methods_inventory: parse_methods_inventory
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

      %{
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
  """
  # TODO(Task 110): Baseline corpus surfaces ~32 legitimate "helper method"
  # findings — e.g. bybit.fetchSpotMarkets, coinbase.fetchAccountsV2. These
  # helpers are called by a unified method but unified_endpoints values store
  # interface names (publicGetX), not helper names, so the reachability check
  # has no way to see the transitive call. Either add a transitive-call
  # analysis or maintain a baseline allowlist for known helpers.
  @spec check_request_defaults_resolvable_reachable_from_unified(map(), map()) :: [finding()]
  def check_request_defaults_resolvable_reachable_from_unified(exchange, _observed) do
    id = exchange_id(exchange)
    defaults = get_in(exchange, ["endpoints", "request", "defaults"]) || %{}
    unified = get_in(exchange, ["endpoints", "unified"]) || %{}
    reachable = unified_reachable_names(unified)

    defaults
    |> Enum.sort_by(fn {method, _} -> method end)
    |> Enum.filter(fn {_method, body} -> has_literal_entry?(body) end)
    |> Enum.reject(fn {method, _} -> MapSet.member?(reachable, method) end)
    |> Enum.map(fn {method, _} ->
      %{
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
      %{
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
        %{
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
        %{
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
    %{
      exchange: id,
      invariant: "sign_recipe_shape_valid",
      path: "auth.sign_recipe.#{section}",
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
    %{
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
        %{
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
        %{
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
    %{
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
    %{
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
    %{
      exchange: id,
      invariant: "testnet_urls_shape_valid",
      path: "testnet",
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
    %{
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
    %{
      exchange: id,
      invariant: "error_classes_covered_by_hierarchy",
      path: path,
      message: message
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

  Skipped on v3-shaped output (no `normalization` top-level key) — the
  invariant only fires under `--schema-target=4`.
  """
  @spec check_normalization_shape_valid(map(), map()) :: [finding()]
  def check_normalization_shape_valid(exchange, _observed) do
    case Map.fetch(exchange, "normalization") do
      :error -> []
      # Honesty Rule: nil means the extractor produced nothing; matches the
      # nil-parent branch in `check_provenance_covers_schema/2` and
      # `check_parse_methods_digest_covers_inventory/2`.
      {:ok, nil} -> []
      {:ok, record} -> normalization_record_findings(exchange_id(exchange), record)
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
    %{
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
      %{
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
    %{
      exchange: id,
      invariant: "handle_errors_retryable_shape_valid",
      path: "errors.#{section}",
      message: message
    }
  end

  @doc """
  Validate the v4 `endpoints.handlers` reshape (Tasks 88a/88b/88c).

  At v3 emission, the dispatch tables live at
  `structure.error_dispatch` / `sign_dispatch` / `parse_dispatch`. At
  v4 emission, the same tables route into
  `endpoints.handlers.{error,signing,parse}`. This invariant fires only
  when an exchange is v4-shaped (top-level `endpoints` group present
  and no `structure` section); on v3-shaped emission it short-circuits
  to no findings. Within a v4 exchange it asserts:

    * `endpoints.handlers` exists and is a map.
    * The three keys (`error`, `signing`, `parse`) are present.
    * No extra keys.
    * Each value content matches its v3 counterpart's nullable-shape
      (the JSON Schema enforces deeper structural shape — this
      invariant catches presence drift, not entry shape).

  Mirrors `testnet_urls_shape_valid`'s structure: per-key audit with a
  finding per drift type. JSON Schema catches the array-of-records and
  object-of-arrays leaf shapes; this invariant catches the
  reorganization integrity.
  """
  @spec check_handler_dispatch_v4_shape_valid(map(), map()) :: [finding()]
  def check_handler_dispatch_v4_shape_valid(exchange, _observed) do
    id = exchange_id(exchange)

    if v4_shape?(exchange) do
      handlers = get_in(exchange, ["endpoints", "handlers"])
      handler_dispatch_findings(id, handlers)
    else
      []
    end
  end

  defp v4_shape?(exchange) when is_map(exchange) do
    Map.has_key?(exchange, "endpoints") and not Map.has_key?(exchange, "structure")
  end

  defp v4_shape?(_), do: false

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
    %{
      exchange: id,
      invariant: "handler_dispatch_v4_shape_valid",
      path: path,
      message: message
    }
  end

  @doc """
  v4-only: `rate_limits.endpoint_cost_binding` must match
  `CcxtExtract.RateLimitCostBinding.derive/1` applied to the bucket wrapper at
  `rate_limits.buckets` — non-null only when the wrapper has a resolved,
  non-empty `buckets` list; otherwise null. Short-circuits on v3-shaped output.
  """
  @spec check_rate_limits_endpoint_cost_binding_coherent(map(), map()) :: [finding()]
  def check_rate_limits_endpoint_cost_binding_coherent(exchange, _observed) do
    if v4_shape?(exchange) do
      endpoint_cost_binding_findings(exchange)
    else
      []
    end
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
        %{
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
    %{
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
          %{
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
        %{
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
        %{
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
    target = if v4_shape?(exchange), do: 4, else: 3
    translated = CcxtExtract.OverrideRegistry.translate_pointer(pointer, target)
    keys = CcxtExtract.OverrideRegistry.pointer_to_keys(translated)
    actual = get_in(exchange, keys)

    if actual == entry["value"] do
      []
    else
      [
        %{
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
  (`raw_pointers_v4/0 ++ derived_pointers_v4/0`) and the sections actually
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
    raw = Map.new(CcxtExtract.Provenance.raw_pointers_v4(), &{&1, "raw"})
    derived = Map.new(CcxtExtract.Provenance.derived_pointers_v4(), &{&1, "derived"})
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
      %{
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
      %{
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

      %{
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
  # are not exchanges. `exchange_v4.json` is the JSON Schema copy; files
  # starting with `_` are manifests/reports. Mirrors validation.ex:207.
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
  same-file, unsanitized flows. Cross-module flows are conservatively
  dropped — Reach's source frontend over-approximates through function
  boundaries (e.g. `FixtureParity.check(fixtures_dir)` taints an unrelated
  `File.write!` inside the callee), and dynamic-dispatch writers
  (`writer.(dest)`) are invisible to the source frontend. This is a
  best-effort guard against the common direct-call leak pattern.

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
      node.meta[:function] in @file_writer_fns
  end

  # Once a path has been consumed by a File reader, the downstream value is
  # file CONTENT, not a path — so further flow into a writer is legitimate
  # (reading a committed artifact and writing its bytes into the output dir).
  # Prevents false positives on `Paths.priv → File.read! → ... → File.write!`.
  defp paths_rw_sanitizer?(node) do
    node.type == :call and
      node.meta[:module] == File and
      node.meta[:function] in @file_reader_fns
  end

  # Keep only unsanitized, same-file flows. See module doc on check_paths_rw_split/1.
  defp paths_rw_reportable?(%{sanitized: true}), do: false

  defp paths_rw_reportable?(%{source: %{source_span: s}, sink: %{source_span: k}}) when not is_nil(s) and not is_nil(k) do
    s.file == k.file
  end

  defp paths_rw_reportable?(_), do: false

  defp paths_rw_to_finding(%{source: source, sink: sink}) do
    src_fn = "#{inspect(source.meta.module)}.#{source.meta.function}/#{source.meta.arity}"
    sink_fn = "File.#{sink.meta.function}/#{sink.meta.arity}"

    %{
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
      "findings" => Enum.map(findings, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
    }
  end

  defp count_by_invariant(findings) do
    base = Map.new(@invariants ++ @corpus_invariants, fn {name, _} -> {name, 0} end)
    Enum.reduce(findings, base, fn f, acc -> Map.update!(acc, f.invariant, &(&1 + 1)) end)
  end
end
