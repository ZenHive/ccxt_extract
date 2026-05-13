defmodule CcxtExtract.FetchMethods do
  @moduledoc """
  Extract all `fetch*()` method bodies as raw ESTree AST for every REST exchange.

  Fetch methods are the public-facing unified API methods (`fetchTrades`,
  `fetchTicker`, `fetchOHLCV`, etc.) that unwrap vendor REST responses before
  delegating to the matching `parse*()` method. This module extracts the
  complete method AST — parameters, return type, and full body — for every
  `fetch*` method found on each exchange.

  The resulting `priv/discoveries/fetch_methods.json` is consumed by Task 83b
  (`CcxtExtract.Normalization.ResponseEnvelopes`) which walks the bodies looking
  for `this.safeValue`/`this.safeList` response-unwrap calls.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.FetchMethods.extract()
      CcxtExtract.FetchMethods.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "fetch_methods.json"

  @impl true
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      class_body = class.body.body
      methods = find_fetch_methods(class_body)

      fetch_methods_map =
        Map.new(methods, fn method ->
          {method.key.name, CcxtExtract.MethodAST.extract(method)}
        end)

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "fetch_method_count" => map_size(fetch_methods_map),
        "fetch_methods" => fetch_methods_map
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{
      "with_fetch_methods" => Enum.count(exchanges, fn e -> e["fetch_method_count"] > 0 end),
      "total_methods" => Enum.sum(Enum.map(exchanges, & &1["fetch_method_count"]))
    }
  end

  @doc """
  Find all fetch*() MethodDefinitions in a class body.

  Returns a list of AST nodes whose method name starts with "fetch".
  """
  @spec find_fetch_methods([map()]) :: [map()]
  def find_fetch_methods(class_body) do
    Enum.filter(class_body, fn member ->
      member.type == :method_definition && String.starts_with?(member.key.name, "fetch")
    end)
  end
end
