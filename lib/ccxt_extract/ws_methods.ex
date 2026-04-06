defmodule CcxtExtract.WsMethods do
  @moduledoc """
  Extract all `watch*()` and `handle*()` method bodies as raw ESTree AST for every WS exchange.

  WebSocket exchanges define two categories of methods:
  - **watch* methods** — async, subscribe to WS channels (watchTicker, watchBalance, etc.)
  - **handle* methods** — sync, process incoming WS messages (handleTrade, handleBalanceWs, etc.)

  This module extracts the complete method AST for every watch/handle method found
  on each exchange — parameters, return type, and full body. Combined into a single
  `ws_methods` map keyed by method name; consumers can filter by async flag or name prefix.

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.WsMethods.extract()
      CcxtExtract.WsMethods.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "ws_methods.json"

  @impl true
  def source_dir, do: Path.join(CcxtExtract.Paths.ts_src(), "pro")

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      methods = find_ws_methods(class.body.body)

      ws_methods_map =
        Map.new(methods, fn method ->
          {method.key.name, CcxtExtract.MethodAST.extract(method)}
        end)

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "ws_method_count" => map_size(ws_methods_map),
        "ws_methods" => ws_methods_map
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{
      "with_ws_methods" => Enum.count(exchanges, fn e -> e["ws_method_count"] > 0 end),
      "total_methods" => Enum.sum(Enum.map(exchanges, & &1["ws_method_count"]))
    }
  end

  @doc """
  Find all watch*/handle* MethodDefinitions in a class body.

  Returns a list of AST nodes whose method name starts with "watch" or "handle".
  """
  @spec find_ws_methods([map()]) :: [map()]
  def find_ws_methods(class_body) do
    Enum.filter(class_body, fn member ->
      member.type == "MethodDefinition" &&
        (String.starts_with?(member.key.name, "watch") ||
           String.starts_with?(member.key.name, "handle"))
    end)
  end
end
