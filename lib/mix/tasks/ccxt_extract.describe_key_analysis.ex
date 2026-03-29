defmodule Mix.Tasks.CcxtExtract.DescribeKeyAnalysis do
  @shortdoc "Analyze describe() key frequency and nesting depth"

  @moduledoc """
  Reads `priv/discoveries/describe_keys.json` (from Task 3a) and produces a
  frequency analysis of describe() keys across all exchanges.

  Categorizes keys into tiers (universal, common, frequent, uncommon, rare),
  reports type consistency, and measures max nesting depth per key via QuickBEAM.

  Writes output to `priv/discoveries/describe_key_analysis.json`.

      mix ccxt_extract.describe_key_analysis
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info("Analyzing describe() key frequency and nesting depth...")

    case CcxtExtract.DescribeKeyAnalysis.extract() do
      {:ok, analysis} ->
        CcxtExtract.DescribeKeyAnalysis.write!(analysis)

        tier_summary =
          analysis["tiers"]
          |> Enum.sort_by(fn {tier, _} -> tier_order(tier) end)
          |> Enum.map_join("\n", fn {tier, keys} -> "  #{tier}: #{length(keys)} keys" end)

        Mix.shell().info("""
        Done. #{analysis["key_count"]} keys analyzed across #{analysis["exchange_count"]} exchanges.
        Tier breakdown:
        #{tier_summary}
        Output: priv/discoveries/describe_key_analysis.json
        """)

      {:error, {:missing_input, path}} ->
        Mix.shell().error("Missing input file: #{path}\nRun `mix ccxt_extract.describe_keys` first.")
    end
  end

  # Sort tiers from most to least common
  defp tier_order("universal"), do: 0
  defp tier_order("common"), do: 1
  defp tier_order("frequent"), do: 2
  defp tier_order("uncommon"), do: 3
  defp tier_order("rare"), do: 4
  defp tier_order(_), do: 5
end
