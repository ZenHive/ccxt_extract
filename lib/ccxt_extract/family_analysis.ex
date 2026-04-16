defmodule CcxtExtract.FamilyAnalysis do
  @moduledoc """
  Analyze exchange families: inheritance, own methods, and configuration diffs.

  Reads existing discovery files (class hierarchy, exchange summary, per-exchange
  describe) and produces a family analysis showing what each variant defines
  relative to its root ancestor.

  For multi-member families: own methods (defined in child's .ts file) from OXC
  class data, top-level describe() key diffs from QuickBEAM data, shared method inventory.

  For standalone families: lightweight entry with root, method count, WS status.

  ## Usage

      {:ok, analysis} = CcxtExtract.FamilyAnalysis.extract()
      CcxtExtract.FamilyAnalysis.write!(analysis)
  """

  require Logger

  @classes_file "class_hierarchy.json"
  @summary_file "exchange_summary.json"
  @describe_dir "describe"
  @output_file "family_analysis.json"

  @doc """
  Run the full family analysis from existing discovery files.

  Reads class_hierarchy.json, exchange_summary.json, and per-exchange describe
  files. Accepts an optional `scope` from `CcxtExtract.TaskScope.parse_and_resolve!/3`.
  When narrowed, families are kept iff the scope intersects the family's root,
  variants, or aliases — within a kept family, ALL members are still analyzed
  to preserve family context (the inheritance tree is universe-wide by design,
  same precedent as `classes.ex`).

  Returns `{:ok, analysis}`, `{:error, {:missing_input, path}}`, or
  `{:error, {:invalid_json, detail}}`.
  """
  @spec extract(:all | MapSet.t(String.t())) ::
          {:ok, map()} | {:error, CcxtExtract.JsonIO.read_error()}
  def extract(scope \\ :all) do
    discoveries = CcxtExtract.Paths.discoveries()
    classes_path = Path.join(discoveries, @classes_file)
    summary_path = Path.join(discoveries, @summary_file)
    describe_dir = Path.join(discoveries, @describe_dir)

    with {:ok, classes_data} <- CcxtExtract.JsonIO.read_json(classes_path),
         {:ok, summary_data} <- CcxtExtract.JsonIO.read_json(summary_path),
         :ok <- validate_describe_dir(describe_dir) do
      analyze(classes_data, summary_data, describe_dir, scope)
    end
  end

  @doc """
  Build the full analysis from classes data, summary data, and describe directory.

  Filters families by `scope` overlap; class lookup stays universe-wide so root
  ancestry resolves correctly within kept families.
  """
  @spec analyze(map(), map(), String.t(), :all | MapSet.t(String.t())) :: {:ok, map()}
  def analyze(classes_data, summary_data, describe_dir, scope \\ :all) do
    classes = classes_data["classes"]
    families = filter_families(summary_data["families"], scope)

    # Build lookup: exchange id -> class entry (REST only)
    class_lookup =
      classes
      |> Enum.filter(&(&1["type"] == "rest"))
      |> Map.new(&{&1["id"], &1})

    # Analyze each family
    family_analyses =
      families
      |> Enum.map(&analyze_family(&1, class_lookup, describe_dir))
      |> Enum.sort_by(& &1["root"])

    summary = build_summary(family_analyses)

    {:ok,
     %{
       "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
       "source_files" => %{
         "class_hierarchy" => @classes_file,
         "exchange_summary" => @summary_file,
         "describe" => @describe_dir
       },
       "summary" => summary,
       "families" => family_analyses
     }}
  end

  defp filter_families(families, :all), do: families

  defp filter_families(families, %MapSet{} = scope) do
    Enum.filter(families, fn family ->
      members = [family["root"] | (family["variants"] || []) ++ (family["aliases"] || [])]
      Enum.any?(members, &MapSet.member?(scope, &1))
    end)
  end

  @doc """
  Analyze a single family from summary data, class lookup, and describe directory.

  Multi-member families get full analysis (own methods, describe diffs).
  Standalone families get a lightweight entry.
  """
  @spec analyze_family(map(), map(), String.t()) :: map()
  def analyze_family(%{"total_members" => 1} = family, class_lookup, _describe_dir) do
    root_id = family["root"]
    root_class = Map.get(class_lookup, root_id, %{})

    %{
      "root" => root_id,
      "type" => "standalone",
      "method_count" => root_class["method_count"] || 0,
      "has_ws" => family["has_ws"]
    }
  end

  def analyze_family(family, class_lookup, describe_dir) do
    root_id = family["root"]
    root_class = Map.get(class_lookup, root_id, %{})
    root_methods = root_class["methods"] || []

    member_ids = family["variants"] ++ family["aliases"]

    # Per-member analysis: own methods + describe diffs
    members =
      Enum.map(member_ids, fn member_id ->
        member_class = Map.get(class_lookup, member_id, %{})
        member_methods = member_class["methods"] || []
        relationship = if member_id in family["aliases"], do: "alias", else: "variant"

        describe_diff = diff_describe_for_pair(root_id, member_id, describe_dir)

        %{
          "id" => member_id,
          "relationship" => relationship,
          "own_methods" => member_methods,
          "own_method_count" => length(member_methods),
          "describe_changed_keys" => describe_diff
        }
      end)

    # Shared methods: root methods minus any that a member defines
    all_overridden =
      members
      |> Enum.flat_map(& &1["own_methods"])
      |> MapSet.new()

    shared_methods = Enum.reject(root_methods, &MapSet.member?(all_overridden, &1))

    %{
      "root" => root_id,
      "type" => "multi_member",
      "root_method_count" => length(root_methods),
      "shared_method_count" => length(shared_methods),
      "has_ws" => family["has_ws"],
      "members" => members
    }
  end

  @doc """
  Compare two describe() maps and return a sorted list of top-level keys that differ.

  Keys present in one but not the other are included. Keys with identical values
  are excluded. Comparison is shallow (top-level only).

      diff_describe_keys(
        %{"id" => "okx", "name" => "OKX", "has" => %{}},
        %{"id" => "okxus", "name" => "OKX (US)", "has" => %{}}
      )
      #=> ["id", "name"]
  """
  @spec diff_describe_keys(map(), map()) :: [String.t()]
  def diff_describe_keys(root_describe, member_describe) do
    all_keys =
      MapSet.union(
        MapSet.new(Map.keys(root_describe)),
        MapSet.new(Map.keys(member_describe))
      )

    all_keys
    |> Enum.filter(fn key ->
      Map.get(root_describe, key) != Map.get(member_describe, key)
    end)
    |> Enum.sort()
  end

  @doc """
  Build summary statistics from analyzed families.
  """
  @spec build_summary([map()]) :: map()
  def build_summary(family_analyses) do
    multi = Enum.filter(family_analyses, &(&1["type"] == "multi_member"))
    standalone = Enum.filter(family_analyses, &(&1["type"] == "standalone"))

    # Most common own methods across all families
    override_freq =
      multi
      |> Enum.flat_map(fn f -> Enum.flat_map(f["members"], & &1["own_methods"]) end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_method, count} -> -count end)
      |> Enum.map(fn {method, count} -> %{"method" => method, "count" => count} end)

    # Most-changed describe keys across all families
    describe_key_freq =
      multi
      |> Enum.flat_map(fn f -> Enum.flat_map(f["members"], & &1["describe_changed_keys"]) end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_key, count} -> -count end)
      |> Enum.map(fn {key, count} -> %{"key" => key, "count" => count} end)

    # Family size distribution
    sizes =
      Enum.map(family_analyses, fn
        %{"type" => "standalone"} -> 1
        %{"members" => members} -> 1 + length(members)
      end)

    %{
      "total_families" => length(family_analyses),
      "multi_member" => length(multi),
      "standalone" => length(standalone),
      "size_distribution" => %{
        "min" => Enum.min(sizes, fn -> 0 end),
        "max" => Enum.max(sizes, fn -> 0 end),
        "sizes" => sizes |> Enum.frequencies() |> Map.new(fn {k, v} -> {to_string(k), v} end)
      },
      "most_common_own_methods" => override_freq,
      "most_changed_describe_keys" => describe_key_freq
    }
  end

  @doc """
  Write analysis to `priv/discoveries/family_analysis.json`.

  Accepts `:tier_scope` option — the JSON-serialisable value from
  `CcxtExtract.TaskScope.parse_and_resolve!/3`, stamped into the analysis
  envelope as `tier_scope`.
  """
  @spec write!(map(), keyword()) :: :ok
  def write!(analysis, opts \\ []) do
    output_path =
      Keyword.get(opts, :output_path, CcxtExtract.Paths.priv(Path.join("discoveries", @output_file)))

    tier_scope = Keyword.get(opts, :tier_scope, "all")
    stamped = Map.put(analysis, "tier_scope", tier_scope)

    File.mkdir_p!(Path.dirname(output_path))

    json = Jason.encode!(stamped, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  # Validate that the describe directory exists and contains JSON files.
  defp validate_describe_dir(dir) do
    cond do
      not File.dir?(dir) ->
        {:error, {:missing_input, dir}}

      dir |> File.ls!() |> Enum.any?(&String.ends_with?(&1, ".json")) ->
        :ok

      true ->
        {:error, {:missing_input, dir}}
    end
  end

  # Load describe() for a root/member pair and diff their top-level keys.
  # Returns empty list if either describe file is missing (expected for aliases).
  # Logs a warning for missing root files, which indicates corrupted upstream data.
  defp diff_describe_for_pair(root_id, member_id, describe_dir) do
    root_path = Path.join(describe_dir, "#{root_id}.json")
    member_path = Path.join(describe_dir, "#{member_id}.json")

    with {:ok, root_data} <- CcxtExtract.JsonIO.read_json(root_path),
         {:ok, member_data} <- CcxtExtract.JsonIO.read_json(member_path) do
      diff_describe_keys(root_data["describe"], member_data["describe"])
    else
      {:error, {:missing_input, ^root_path}} ->
        Logger.warning("Missing describe file for root exchange #{root_id}: #{root_path}")
        []

      {:error, {:missing_input, _member_path}} ->
        []

      {:error, {:invalid_json, detail}} ->
        Logger.warning("Corrupt describe file while diffing #{root_id}/#{member_id}: #{detail}")
        []
    end
  end
end
