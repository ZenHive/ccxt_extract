defmodule CcxtExtract.ValidateOverrides do
  @moduledoc """
  Cross-check curated override entries against extraction probes where available.

  Audits every `priv/overrides/<id>.json` entry and emits a per-exchange report
  classifying each entry as `verified`, `unverified`, `warning`, `mismatch`, or
  `error`. Used by `mix ccxt_extract.validate_overrides`.

  Probes (by v4 JSON Pointer after `OverrideRegistry.translate_pointer/1`):

    * `/auth/authenticated_sections` — AST derivation vs override + API reachability
    * `/raw/url_templates` — equality against `url_templates.json` discovery
    * `/auth/sign_recipe`, `/auth/sign_method` — stub (no live sign replay in v1)
    * other paths — `unverified` with `no_probe_for_path`

  Default exit is report-only (findings do not fail the task). Pass `--strict` on
  the mix task to fail on `mismatch`, `error`, `warning`, or entries explicitly
  marked `unverified: true`.
  """

  alias CcxtExtract.AuthenticatedSections
  alias CcxtExtract.JsonIO
  alias CcxtExtract.OverrideRegistry
  alias CcxtExtract.Paths

  @default_report "discoveries/override_validation_report.json"

  @doc """
  Validate all override files (or a subset) and return a report map.

  Options:

    * `:discoveries_dir` — discovery corpus dir; default `Paths.priv("discoveries")`
    * `:overrides_dir` — override files dir; default `Paths.priv("overrides")`
    * `:exchange_ids` — list of ids to check; default all `.json` files in `:overrides_dir`

  Strictness is the caller's concern — `run/1` always returns `{:ok, report}`.
  Pass the report to `strict_failure?/1` to decide a non-zero exit.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    discoveries_dir = Keyword.get(opts, :discoveries_dir, Paths.priv("discoveries"))
    overrides_dir = Keyword.get(opts, :overrides_dir, Paths.priv("overrides"))
    exchange_ids = Keyword.get(opts, :exchange_ids, list_override_ids(overrides_dir))
    ctx = load_context(discoveries_dir, overrides_dir)

    exchanges =
      exchange_ids
      |> Enum.sort()
      |> Enum.map(&validate_exchange(&1, ctx))

    report = build_report(exchanges)

    {:ok, report}
  end

  @doc """
  Return `true` when `report` contains findings that should fail `--strict`.
  """
  @spec strict_failure?(map()) :: boolean()
  def strict_failure?(report) do
    Enum.any?(report["exchanges"], fn %{"entries" => entries} ->
      Enum.any?(entries, &strict_entry?/1)
    end)
  end

  defp strict_entry?(%{"status" => status}) when status in ["mismatch", "error", "warning"], do: true

  defp strict_entry?(%{"status" => "unverified", "explicit_unverified" => true}), do: true
  defp strict_entry?(_), do: false

  @doc """
  Write the report to `path` as pretty JSON.
  """
  @spec write!(map(), String.t()) :: :ok
  def write!(report, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    JsonIO.write_json!(path, report, pretty: true)
    :ok
  end

  @doc false
  @spec default_report_path() :: String.t()
  def default_report_path, do: Paths.out(@default_report)

  # --- context loading ---

  defp load_context(discoveries_dir, overrides_dir) do
    %{
      discoveries_dir: discoveries_dir,
      overrides_dir: overrides_dir,
      sign_methods: load_sign_methods_lookup(discoveries_dir),
      url_templates: load_url_templates_lookup(discoveries_dir)
    }
  end

  defp list_override_ids(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.trim_trailing(&1, ".json"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp load_sign_methods_lookup(dir) do
    path = Path.join(dir, "sign_methods.json")

    case JsonIO.read_json(path) do
      {:ok, %{"exchanges" => exchanges}} when is_list(exchanges) ->
        Map.new(exchanges, fn
          %{"id" => id, "sign" => sign} -> {id, sign}
          %{"id" => id} -> {id, nil}
        end)

      _ ->
        %{}
    end
  end

  defp load_url_templates_lookup(dir) do
    path = Path.join(dir, "url_templates.json")

    case JsonIO.read_json(path) do
      {:ok, %{"exchanges" => exchanges}} when is_list(exchanges) ->
        Map.new(exchanges, fn
          %{"id" => id, "url_templates" => templates} -> {id, templates}
          %{"id" => id} -> {id, nil}
        end)

      _ ->
        %{}
    end
  end

  defp load_describe(discoveries_dir, id) do
    path = Path.join(discoveries_dir, "describe/#{id}.json")

    case JsonIO.read_json(path) do
      {:ok, %{"describe" => describe}} when is_map(describe) -> {:ok, describe}
      {:ok, _} -> {:error, :invalid_describe_shape}
      {:error, {:missing_input, _}} -> {:error, :missing_describe}
      {:error, {:invalid_json, detail}} -> {:error, {:invalid_json, detail}}
    end
  end

  # --- per-exchange ---

  defp validate_exchange(id, ctx) do
    case safe_load_overrides(id, ctx) do
      {:error, message} ->
        %{
          "exchange" => id,
          "load_error" => message,
          "entries" => [
            %{
              "path" => nil,
              "translated_path" => nil,
              "status" => "error",
              "probe" => "registry_load",
              "reason" => message,
              "explicit_unverified" => false,
              "details" => %{}
            }
          ]
        }

      {:ok, overrides} ->
        entries = Enum.map(overrides, &validate_entry(id, &1, ctx))
        %{"exchange" => id, "load_error" => nil, "entries" => entries}
    end
  end

  defp safe_load_overrides(id, ctx) do
    path = Path.join(ctx.overrides_dir, "#{id}.json")

    case OverrideRegistry.load_path(path) do
      :none -> {:error, "no override file for #{id}"}
      overrides when is_list(overrides) -> {:ok, overrides}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp validate_entry(id, entry, ctx) do
    path = entry["path"]
    translated = OverrideRegistry.translate_pointer(path)
    explicit_unverified = Map.get(entry, "unverified") == true
    base = entry_result_base(path, translated, explicit_unverified)

    case dry_run_pointer(translated) do
      {:ok, _} ->
        result = probe_entry(id, entry, translated, ctx)
        Map.merge(base, result)

      {:error, reason} ->
        Map.merge(base, %{
          "status" => "error",
          "probe" => "pointer",
          "reason" => reason,
          "details" => %{}
        })
    end
  end

  defp entry_result_base(path, translated, explicit_unverified) do
    %{
      "path" => path,
      "translated_path" => translated,
      "explicit_unverified" => explicit_unverified
    }
  end

  defp dry_run_pointer(translated) do
    _keys = OverrideRegistry.pointer_to_keys(translated)
    {:ok, :ok}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp probe_entry(id, entry, translated, ctx) do
    cond do
      Map.get(entry, "unverified") == true ->
        %{
          "status" => "unverified",
          "probe" => "explicit_flag",
          "reason" => "entry marked unverified: true",
          "details" => %{}
        }

      translated == "/auth/authenticated_sections" ->
        probe_authenticated_sections(id, entry, ctx)

      translated == "/raw/url_templates" ->
        probe_url_templates(id, entry, ctx)

      translated in ["/auth/sign_recipe", "/auth/sign_method"] ->
        %{
          "status" => "unverified",
          "probe" => "signing",
          "reason" => "signing_probe_not_implemented",
          "details" => %{}
        }

      true ->
        %{
          "status" => "unverified",
          "probe" => "none",
          "reason" => "no_probe_for_path",
          "details" => %{"translated_path" => translated}
        }
    end
  end

  # --- authenticated_sections probe ---

  defp probe_authenticated_sections(id, entry, ctx) do
    override = entry["value"]
    sign = Map.get(ctx.sign_methods, id)
    describe_result = load_describe(ctx.discoveries_dir, id)

    cond do
      not is_list(override) ->
        mismatch_result("override value must be a list", %{"override" => override})

      match?({:error, :missing_describe}, describe_result) ->
        unverified_result("no_describe_discovery", %{})

      match?({:error, _}, describe_result) ->
        unverified_result("describe_discovery_unavailable", %{"describe_error" => elem(describe_result, 1)})

      true ->
        {:ok, describe} = describe_result
        probe_auth_resolved(id, entry, override, sign, describe)
    end
  end

  # Override is a list and a describe discovery exists: derive sections from the
  # sign() AST, then classify the override against that derivation.
  defp probe_auth_resolved(id, entry, override, sign, describe) do
    api = Map.get(describe, "api")
    derived = AuthenticatedSections.derive(sign, api) || []
    derived_sorted = Enum.sort(derived)
    override_sorted = override |> Enum.sort() |> Enum.uniq()

    details = %{
      "derived" => if(derived == [], do: nil, else: derived),
      "override" => override,
      "unreachable" => unreachable_sections(id, override, api)
    }

    citation = citation_check(entry["verified_against"])
    classify_auth_sections(derived_sorted, override_sorted, details, citation)
  end

  # No AST derivation to compare against: reachability in describe.api is the
  # only remaining gate.
  defp classify_auth_sections([], _override_sorted, details, citation) do
    if details["unreachable"] == [] do
      finalize_auth_verified(details, citation)
    else
      mismatch_result("authenticated_sections_not_reachable_in_describe_api", details)
    end
  end

  defp classify_auth_sections(derived_sorted, override_sorted, details, citation) do
    override_set = MapSet.new(override_sorted)
    derived_set = MapSet.new(derived_sorted)

    cond do
      derived_sorted == override_sorted ->
        warning_result("override_redundant_ast_now_derives_same", details)

      MapSet.subset?(override_set, derived_set) ->
        # Curated subset — removes AST false positives (e.g. coinone v2Public).
        finalize_auth_verified(details, citation)

      MapSet.subset?(derived_set, override_set) and details["unreachable"] == [] ->
        # Override adds sections the walker missed; reachability is the gate.
        finalize_auth_verified(details, citation)

      MapSet.subset?(derived_set, override_set) ->
        mismatch_result("authenticated_sections_not_reachable_in_describe_api", details)

      true ->
        mismatch_result("override_conflicts_with_ast_derivation", details)
    end
  end

  defp unreachable_sections(_id, sections, api) when is_list(sections) do
    api = api || %{}
    reachable = collect_map_keys(api)

    Enum.reject(sections, &reachable_in_api?(&1, api, reachable))
  end

  defp unreachable_sections(_id, _sections, _api), do: []

  defp reachable_in_api?(name, api, reachable) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [flat] -> MapSet.member?(reachable, flat)
      [parent, child] -> is_map(get_in(api, [parent, child]))
    end
  end

  defp reachable_in_api?(_name, _api, _reachable), do: false

  defp collect_map_keys(map) when is_map(map) do
    Enum.reduce(map, MapSet.new(), fn {k, v}, acc ->
      acc = MapSet.put(acc, k)
      if is_map(v), do: MapSet.union(acc, collect_map_keys(v)), else: acc
    end)
  end

  defp collect_map_keys(_), do: MapSet.new()

  defp finalize_auth_verified(details, citation) do
    case citation do
      :missing -> unverified_result("verified_against_citation_path_missing", details)
      :ok -> verified_result("authenticated_sections", Map.put(details, "citation_ok", true))
    end
  end

  defp citation_check(nil), do: :ok
  defp citation_check(""), do: :ok

  defp citation_check(citation) when is_binary(citation) do
    path =
      citation
      |> String.split(~r/[\s(]/, parts: 2)
      |> List.first()
      |> strip_citation_line_suffix()

    if path != "" and File.exists?(path) do
      :ok
    else
      :missing
    end
  end

  defp citation_check(_), do: :missing

  defp strip_citation_line_suffix(path) when is_binary(path) do
    case String.split(path, ":", parts: 2) do
      [file, _line] -> file
      [file] -> file
    end
  end

  # --- url_templates probe ---

  defp probe_url_templates(id, entry, ctx) do
    override = entry["value"]
    runtime = Map.get(ctx.url_templates, id)

    cond do
      is_nil(runtime) ->
        unverified_result("no_url_templates_discovery", %{})

      override == runtime ->
        verified_result("url_templates", %{"runtime_keys" => Map.keys(runtime || %{})})

      true ->
        mismatch_result(
          "override_value_differs_from_url_templates_discovery",
          %{
            "override_keys" => if(is_map(override), do: Map.keys(override), else: override),
            "runtime_keys" => if(is_map(runtime), do: Map.keys(runtime), else: runtime)
          },
          "url_templates"
        )
    end
  end

  # --- result helpers ---

  defp verified_result(probe, details) do
    %{
      "status" => "verified",
      "probe" => probe,
      "reason" => nil,
      "details" => details
    }
  end

  defp unverified_result(reason, details) do
    %{
      "status" => "unverified",
      "probe" => probe_name_for_reason(reason),
      "reason" => reason,
      "details" => details
    }
  end

  defp warning_result(reason, details) do
    %{
      "status" => "warning",
      "probe" => "authenticated_sections",
      "reason" => reason,
      "details" => details
    }
  end

  defp mismatch_result(reason, details, probe \\ "authenticated_sections") do
    %{
      "status" => "mismatch",
      "probe" => probe,
      "reason" => reason,
      "details" => details
    }
  end

  defp probe_name_for_reason("no_probe_for_path"), do: "none"
  defp probe_name_for_reason("signing_probe_not_implemented"), do: "signing"
  defp probe_name_for_reason(_), do: "authenticated_sections"

  # --- report ---

  defp build_report(exchanges) do
    entries = Enum.flat_map(exchanges, & &1["entries"])

    summary = %{
      "exchanges" => length(exchanges),
      "entries" => length(entries),
      "verified" => count_status(entries, "verified"),
      "unverified" => count_status(entries, "unverified"),
      "warnings" => count_status(entries, "warning"),
      "mismatches" => count_status(entries, "mismatch"),
      "errors" => count_status(entries, "error")
    }

    %{
      "validated_at" => CcxtExtract.Clock.timestamp(:validated_at),
      "summary" => summary,
      "exchanges" => exchanges
    }
  end

  defp count_status(entries, status) do
    Enum.count(entries, &(&1["status"] == status))
  end
end
