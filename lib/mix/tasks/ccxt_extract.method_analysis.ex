defmodule Mix.Tasks.CcxtExtract.MethodAnalysis do
  @shortdoc "Analyze method families, universality, and distribution"

  @moduledoc """
  Reads `priv/discoveries/methods_rest.json` and `methods_ws.json` (from Tasks 4a + 4b)
  and produces a family analysis of methods across all exchanges.

  Groups methods by prefix family (`fetch*`, `parse*`, `create*`, etc.),
  identifies universal vs rare methods, and computes method count distributions.

  Writes output to `priv/discoveries/method_analysis.json`.

      mix ccxt_extract.method_analysis
      mix ccxt_extract.method_analysis --tier1 --dex
      mix ccxt_extract.method_analysis --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict the analysis to the named
      priority tiers (combinable). Tier inheritance expands roots to their
      full family.
    * `--exchange ID` — restrict to explicit exchange IDs (repeatable or
      comma-separated). Typos fail loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  The active scope is stamped into the JSON envelope as `tier_scope`. Both
  `methods_rest.json` and `methods_ws.json` aggregates are loaded
  universe-wide; the in-scope subset of `exchanges` lists is used to compute
  families and cross-type analysis.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Analyzing method families and distributions...")

    case CcxtExtract.MethodAnalysis.extract(scope) do
      {:ok, analysis} ->
        CcxtExtract.MethodAnalysis.write!(analysis, tier_scope: tier_scope)

        rest = analysis["rest"]
        ws = analysis["ws"]
        cross = analysis["cross_type"]

        rest_families = format_family_summary(rest["families"])
        ws_families = format_family_summary(ws["families"])

        Mix.shell().info("""
        Done.

        REST: #{rest["exchange_count"]} exchanges, #{rest["total_methods"]} total methods, #{rest["unique_method_names"]} unique
        Top families:
        #{rest_families}

        WS: #{ws["exchange_count"]} exchanges, #{ws["total_methods"]} total methods, #{ws["unique_method_names"]} unique
        Top families:
        #{ws_families}

        Cross-type: #{cross["shared_count"]} shared, #{cross["rest_only_count"]} REST-only, #{cross["ws_only_count"]} WS-only

        Output: priv/discoveries/method_analysis.json
        """)

      {:error, {:missing_input, path}} ->
        Mix.raise("Missing input file: #{path}\nRun `mix ccxt_extract.methods` first.")
    end
  end

  # Format top families sorted by method count
  defp format_family_summary(families) do
    families
    |> Enum.sort_by(fn {_prefix, data} -> -data["count"] end)
    |> Enum.take(8)
    |> Enum.map_join("\n", fn {prefix, data} ->
      "  #{String.pad_trailing(prefix, 10)} #{data["count"]} methods"
    end)
  end
end
