defmodule Mix.Tasks.CcxtExtract.FamilyAnalysis do
  @shortdoc "Analyze exchange families: inheritance, own methods, and config diffs"

  @moduledoc """
  Reads existing discovery files (class hierarchy, exchange summary, per-exchange
  describe) and produces a family analysis showing what each variant defines
  relative to its root ancestor.

  Writes output to `priv/discoveries/family_analysis.json`.

      mix ccxt_extract.family_analysis
      mix ccxt_extract.family_analysis --tier1 --dex
      mix ccxt_extract.family_analysis --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict the analysis to families that
      intersect the named priority tiers (combinable). Tier inheritance
      expands roots to their full family.
    * `--exchange ID` — keep families whose root, variants, or aliases include
      the given exchange ID (repeatable or comma-separated). Within a kept
      family, ALL members are still analyzed for full family context.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`. The
  inheritance tree (`class_hierarchy.json`) and the per-family member set are
  always read universe-wide — scope filters which families are reported on,
  not the underlying tree (same precedent as `classes.ex`).
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Analyzing exchange families...")

    case CcxtExtract.FamilyAnalysis.extract(scope) do
      {:ok, analysis} ->
        CcxtExtract.FamilyAnalysis.write!(analysis, tier_scope: tier_scope)

        summary = analysis["summary"]
        multi = Enum.filter(analysis["families"], &(&1["type"] == "multi_member"))

        family_details = Enum.map_join(multi, "\n", &format_family/1)

        Mix.shell().info("""
        Done.

        Families: #{summary["total_families"]} total (#{summary["multi_member"]} multi-member, #{summary["standalone"]} standalone)
        Size range: #{summary["size_distribution"]["min"]}-#{summary["size_distribution"]["max"]} members

        Multi-member families:
        #{family_details}

        Output: priv/discoveries/family_analysis.json
        """)

      {:error, {:missing_input, path}} ->
        Mix.raise("Missing input file: #{path}\nRun `mix ccxt_extract.summary` and `mix ccxt_extract.describe` first.")
    end
  end

  defp format_family(family) do
    members =
      Enum.map_join(family["members"], ", ", fn m ->
        "#{m["id"]}(#{m["relationship"]}, #{m["own_method_count"]} own methods, #{length(m["describe_changed_keys"])} key diffs)"
      end)

    "  #{family["root"]}: #{members}"
  end
end
