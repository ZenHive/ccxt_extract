defmodule Mix.Tasks.CcxtExtract.Classes do
  @shortdoc "Extract class hierarchy from CCXT TypeScript source"

  @moduledoc """
  Parses all CCXT TypeScript exchange files with OXC and extracts the class
  hierarchy: class names, inheritance chains, and method lists.

  Writes output to `priv/discoveries/class_hierarchy.json`.

      mix ccxt_extract.classes
  """

  use Mix.Task

  @impl true
  def run(_args) do
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

    CcxtExtract.Classes.write!(classes, tree, ws_counterparts)

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
