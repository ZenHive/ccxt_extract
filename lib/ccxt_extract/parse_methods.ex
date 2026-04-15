defmodule CcxtExtract.ParseMethods do
  @moduledoc """
  Extract all `parse*()` method bodies as raw ESTree AST for every REST exchange.

  Parse methods contain field-by-field mappings from exchange-specific format to
  CCXT's unified format (parseTicker, parseOrder, parseTrade, parseBalance, etc.).
  This module extracts the complete method AST for every parse method found on
  each exchange — parameters, return type, and full body.

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.ParseMethods.extract()
      CcxtExtract.ParseMethods.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "parse_methods.json"

  @impl true
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      methods = find_parse_methods(class.body.body)

      parse_methods_map =
        Map.new(methods, fn method ->
          {method.key.name, CcxtExtract.MethodAST.extract(method)}
        end)

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "parse_method_count" => map_size(parse_methods_map),
        "parse_methods" => parse_methods_map
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{
      "with_parse_methods" => Enum.count(exchanges, fn e -> e["parse_method_count"] > 0 end),
      "total_methods" => Enum.sum(Enum.map(exchanges, & &1["parse_method_count"]))
    }
  end

  @doc """
  Find all parse*() MethodDefinitions in a class body.

  Returns a list of AST nodes whose method name starts with "parse".
  """
  @spec find_parse_methods([map()]) :: [map()]
  def find_parse_methods(class_body) do
    Enum.filter(class_body, fn member ->
      member.type == :method_definition && String.starts_with?(member.key.name, "parse")
    end)
  end
end
