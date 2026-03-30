defmodule Mix.Tasks.CcxtExtract.FamilyAnalysis do
  @shortdoc "Analyze exchange families: inheritance, own methods, and config diffs"

  @moduledoc """
  Reads existing discovery files (class hierarchy, exchange summary, per-exchange
  describe) and produces a family analysis showing what each variant defines
  relative to its root ancestor.

  Writes output to `priv/discoveries/family_analysis.json`.

      mix ccxt_extract.family_analysis
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Analyzing exchange families...")

    case CcxtExtract.FamilyAnalysis.extract() do
      {:ok, analysis} ->
        CcxtExtract.FamilyAnalysis.write!(analysis)

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
        Mix.shell().error(
          "Missing input file: #{path}\nRun `mix ccxt_extract.summary` and `mix ccxt_extract.describe` first."
        )
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
