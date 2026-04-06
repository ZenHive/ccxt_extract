defmodule CcxtExtract.SignMethod do
  @moduledoc """
  Extract the `sign()` method body as raw ESTree AST for every REST exchange.

  The `sign()` method defines how each exchange authenticates API requests.
  This module extracts the complete method AST — parameters, return type,
  and the full body — preserving all structural detail for downstream consumers.

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.SignMethod.extract()
      CcxtExtract.SignMethod.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "sign_methods.json"

  @impl true
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      sign_data =
        class.body.body
        |> find_sign_method()
        |> CcxtExtract.MethodAST.extract()

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "sign" => sign_data
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{"with_sign" => Enum.count(exchanges, & &1["sign"])}
  end

  @doc """
  Find the sign() MethodDefinition in a class body.

  Returns the AST node or nil if not found.
  """
  @spec find_sign_method([map()]) :: map() | nil
  def find_sign_method(class_body) do
    Enum.find(class_body, fn member ->
      member.type == "MethodDefinition" && member.key.name == "sign"
    end)
  end
end
