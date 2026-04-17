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
    {"override_paths_present_in_output", :check_override_paths_present_in_output}
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

    findings =
      exchanges
      |> Enum.flat_map(&run_invariants(&1, baseline))
      |> Enum.sort_by(&{&1.exchange, &1.invariant, &1.path})

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

  @doc "Registry of `{name, function_atom}` tuples. Public for test introspection."
  @spec invariants() :: [{String.t(), atom()}]
  def invariants, do: @invariants

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

  ## Internals

  defp exchange_id(%{"exchange" => %{"id" => id}}) when is_binary(id), do: id
  defp exchange_id(%{"id" => id}) when is_binary(id), do: id
  defp exchange_id(_), do: "<unknown>"

  # Schema copies and metadata files live alongside per-exchange JSON but
  # are not exchanges. `exchange_v2.json` is the JSON Schema copy; files
  # starting with `_` are manifests/reports. Mirrors validation.ex:207.
  @non_exchange_files ~w(exchange_v2.json)

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
        "invariants_run" => length(@invariants),
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
