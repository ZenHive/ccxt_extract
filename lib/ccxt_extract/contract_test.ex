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
      `structure.unified_endpoints` must appear in `runtime.describe.has` with
      value `true` or `"emulated"`.

    * `authenticated_sections_reachable_in_api` — every entry in
      `structure.authenticated_sections` must be reachable as a map key at
      some depth within `runtime.describe.api`.

    * `error_code_fields_root_in_observed_set` — every
      `error_code_fields` entry's root (first element of `object_path`, or
      `object` when `object_path` is null) must appear in the committed
      baseline at `priv/contract_test/error_code_fields_roots.json`. The
      baseline is the authority: deriving the safelist from the same corpus
      being validated would make the invariant tautological. When a new
      root legitimately appears, update the baseline file intentionally.

  New invariants append to `@invariants`; the runner is registry-driven.
  """

  alias CcxtExtract.JsonIO

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
    {"request_defaults_resolvable_reachable_from_unified", :check_request_defaults_resolvable_reachable_from_unified}
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
    baseline = %{error_code_fields_roots: baseline_roots}
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
  `runtime.describe.has`. Public for registry-based dispatch and direct
  test introspection.
  """
  # TODO(Task 57c): Baseline run surfaces ~341 legitimate drift findings —
  # unified_endpoints over-declares vs runtime.describe.has. Triage in 57c.
  @spec check_unified_endpoints_claimed_in_has(map(), map()) :: [finding()]
  def check_unified_endpoints_claimed_in_has(exchange, _observed) do
    id = exchange_id(exchange)
    has = get_in(exchange, ["runtime", "describe", "has"]) || %{}
    unified = get_in(exchange, ["structure", "unified_endpoints"]) || %{}

    unified
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&has_claims_support?(has, &1))
    |> Enum.map(fn name ->
      actual = Map.get(has, name, :missing)

      %{
        exchange: id,
        invariant: "unified_endpoints_claimed_in_has",
        path: "structure.unified_endpoints.#{name}",
        message: "unified_endpoints declares #{name} but runtime.describe.has.#{name} = #{inspect(actual)}"
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
  entry but aren't reachable from `structure.unified_endpoints` — where
  "reachable" means: the method name is either a key of `unified_endpoints`
  OR appears as a value in some `unified_endpoints[*]` list. Helper methods
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
    defaults = get_in(exchange, ["structure", "request_defaults"]) || %{}
    unified = get_in(exchange, ["structure", "unified_endpoints"]) || %{}
    reachable = unified_reachable_names(unified)

    defaults
    |> Enum.sort_by(fn {method, _} -> method end)
    |> Enum.filter(fn {_method, body} -> has_literal_entry?(body) end)
    |> Enum.reject(fn {method, _} -> MapSet.member?(reachable, method) end)
    |> Enum.map(fn {method, _} ->
      %{
        exchange: id,
        invariant: "request_defaults_resolvable_reachable_from_unified",
        path: "structure.request_defaults.#{method}",
        message:
          "request_defaults.#{method} has a resolvable literal entry but #{method} is not reachable from unified_endpoints (neither a key nor a value)"
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
  `runtime.describe.api` at any nesting depth.
  """
  # TODO(Task 57d): Tokocrypto findings show inherited sign() gates pointing
  # at parent-class api sections. Walk inheritance + intersect in 57d.
  @spec check_authenticated_sections_reachable_in_api(map(), map()) :: [finding()]
  def check_authenticated_sections_reachable_in_api(exchange, _observed) do
    id = exchange_id(exchange)
    sections = get_in(exchange, ["structure", "authenticated_sections"]) || []
    api = get_in(exchange, ["runtime", "describe", "api"]) || %{}
    reachable = collect_map_keys(api)

    sections
    |> Enum.with_index()
    |> Enum.reject(fn {name, _i} -> MapSet.member?(reachable, name) end)
    |> Enum.map(fn {name, i} ->
      %{
        exchange: id,
        invariant: "authenticated_sections_reachable_in_api",
        path: "structure.authenticated_sections[#{i}]",
        message: "authenticated section #{inspect(name)} not reachable in runtime.describe.api tree"
      }
    end)
  end

  @doc """
  Flag `error_code_fields` entries whose root (first of `object_path`, or
  `object`) is not in the committed baseline set.
  """
  @spec check_error_code_fields_root(map(), map()) :: [finding()]
  def check_error_code_fields_root(exchange, %{error_code_fields_roots: roots}) do
    id = exchange_id(exchange)
    entries = get_in(exchange, ["structure", "handle_errors", "error_code_fields"]) || []

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
    keys = CcxtExtract.OverrideRegistry.pointer_to_keys(entry["path"])
    actual = get_in(exchange, keys)

    if actual == entry["value"] do
      []
    else
      [
        %{
          exchange: id,
          invariant: "override_paths_present_in_output",
          path: entry["path"],
          message: "override value not present at path; got #{inspect(actual)}"
        }
      ]
    end
  end

  @doc """
  Flag drift between the `CcxtExtract.Provenance` declared pointer lists
  (`raw_pointers/0 ++ derived_pointers/0`) and the sections actually
  emitted under `/exchange`, `/runtime`, and `/structure` in each
  output exchange JSON. Catches three drift types:

    * `uncovered_section` — Pipeline emits a section but Provenance has
      no matching pointer (and `_provenance` doesn't tag it `"override"`).
    * `orphan_declaration` — Provenance declares a pointer whose key path
      doesn't exist in the emitted exchange map.
    * `tag_mismatch` — `exchange._provenance[pointer]` is present but its
      value doesn't match the predicted tag (and isn't `"override"`,
      which is always allowed).

  Granularity mirrors Provenance's own split: most sections compare at
  depth-2 (`/section/key`), but parents with deeper declared children
  (today only `/structure/handle_errors`) compare at depth-3. Derived
  from the declared set itself, not hardcoded — adding a deeper pointer
  to `Provenance` automatically shifts enumeration for that prefix.
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

  @provenance_section_roots ~w(exchange runtime structure)

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
  # are not exchanges. `exchange_v2.json` is the JSON Schema copy; files
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
        sinks: &paths_rw_sink?/1
      ]
    ])
  end

  defp paths_rw_sink?(node) do
    node.type == :call and
      node.meta[:module] == File and
      node.meta[:function] in @file_writer_fns
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
    "structure.handle_errors.error_code_fields[#{index}].object_path"
  end

  defp error_code_fields_path(index, %{"object_path" => nil, "object" => object}) when is_binary(object) do
    "structure.handle_errors.error_code_fields[#{index}].object"
  end

  defp error_code_fields_path(index, %{"object" => object}) when is_binary(object) do
    "structure.handle_errors.error_code_fields[#{index}].object"
  end

  defp error_code_fields_path(index, _entry) do
    base = "structure.handle_errors.error_code_fields[#{index}]"
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
    base = Map.new(@invariants, fn {name, _} -> {name, 0} end)
    Enum.reduce(findings, base, fn f, acc -> Map.update!(acc, f.invariant, &(&1 + 1)) end)
  end
end
