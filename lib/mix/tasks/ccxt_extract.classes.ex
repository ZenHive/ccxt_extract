defmodule Mix.Tasks.CcxtExtract.Classes do
  @shortdoc "Extract class hierarchy from CCXT TypeScript source"

  @moduledoc """
  Parses all CCXT TypeScript exchange files with OXC and extracts the class
  hierarchy: class names, inheritance chains, and method lists.

  Writes output to `priv/discoveries/class_hierarchy.json`.

      mix ccxt_extract.classes
      mix ccxt_extract.classes --tier1
      mix ccxt_extract.classes --exchange binance

  ## Options

    * `--tier1 --tier2 --tier3 --dex --all --exchange` — scope flags.
      Accepted for consistency with other extractors and stamped into the
      envelope as `tier_scope`, but the class list, inheritance `tree`,
      and `ws_counterparts` are always derived from the full CCXT source.

  ## Design note

  Unlike other extractors, this task ignores the scope for the data itself.
  `class_hierarchy.json` is load-bearing infrastructure — `CcxtExtract.Tiers`
  reads it to expand tier flags with family inheritance. A partial class
  tree would silently degrade tier expansion everywhere, so the hierarchy
  always reflects the full CCXT source regardless of the caller's scope.

  The scope flag still travels into `tier_scope` for traceability, and
  `--exchange typo` still fails loudly with fuzzy suggestions so operators
  see their input is acknowledged.
  """

  use Mix.Task

  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {_scope, tier_scope, _opts} = TaskScope.parse_and_resolve!(args)

    Mix.shell().info("Extracting class hierarchy from CCXT TypeScript source...")

    {:ok, classes, stats} = CcxtExtract.Classes.extract()

    rest_count = Enum.count(classes, &(&1["type"] == "rest"))
    ws_count = Enum.count(classes, &(&1["type"] == "ws"))
    tree = CcxtExtract.Classes.build_tree(classes)
    ws_counterparts = CcxtExtract.Classes.find_ws_counterparts(classes)

    # Find largest families (most direct children)
    top_families =
      tree
      |> Enum.sort_by(fn {_parent, children} -> -length(children) end)
      |> Enum.take(5)
      |> Enum.map_join("\n    ", fn {parent, children} ->
        "#{parent}: #{length(children)} children"
      end)

    CcxtExtract.Classes.write!(classes, tier_scope: tier_scope)

    error_msg =
      if stats.errors == [] do
        ""
      else
        "\n  Parse errors: #{length(stats.errors)} (check logs for details)"
      end

    Mix.shell().info("""
    Done. #{length(classes)} classes extracted.
      REST: #{rest_count}
      WS: #{ws_count}
      Skipped (no class): #{length(stats.skipped)}#{error_msg}
      WS counterparts: #{length(ws_counterparts)}
      Inheritance families: #{map_size(tree)}
      Largest families:
        #{top_families}
    Output: priv/discoveries/class_hierarchy.json
    """)
  end
end
