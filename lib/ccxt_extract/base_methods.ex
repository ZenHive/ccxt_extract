defmodule CcxtExtract.BaseMethods do
  @moduledoc """
  Extract base class method signatures from CCXT's `Exchange.ts`.

  The base `Exchange` class (~9k lines) defines shared utility methods that
  every exchange inherits: `parse*()` normalizers (~84 methods) and `safe*()`
  helpers (~29 methods). Unlike per-exchange extractors, this produces a
  single global artifact — `_base_methods.json` — stored once, not per-exchange.

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, result} = CcxtExtract.BaseMethods.extract()
      CcxtExtract.BaseMethods.write!(result)
  """

  @output_file "_base_methods.json"
  @source_file "base/Exchange.ts"

  @doc """
  Extract all `parse*()` and `safe*()` method signatures from Exchange.ts.

  Returns `{:ok, result}` where result contains the methods map and metadata.

  Raises if CCXT source is not set up (`mix ccxt_extract.setup`) or if
  Exchange.ts cannot be parsed.
  """
  @spec extract() :: {:ok, map()} | no_return()
  def extract do
    base_path = Path.join(CcxtExtract.Paths.ts_src(), @source_file)

    if !File.exists?(base_path) do
      raise "CCXT base Exchange.ts not found at #{base_path}. Run `mix ccxt_extract.setup` first."
    end

    source = File.read!(base_path)

    case OXC.parse(source, "Exchange.ts") do
      {:ok, ast} ->
        methods = extract_from_ast(ast)

        if map_size(methods) < 50 do
          raise "Expected 50+ base methods, got #{map_size(methods)}"
        end

        by_category = count_by_category(methods)

        result = %{
          "source_file" => @source_file,
          "method_count" => map_size(methods),
          "by_category" => by_category,
          "methods" => methods
        }

        {:ok, result}

      {:error, reason} ->
        raise "Failed to parse Exchange.ts: #{inspect(reason)}"
    end
  end

  @doc """
  Write base methods to `priv/discoveries/_base_methods.json`.
  """
  @spec write!(map(), String.t()) :: :ok
  def write!(result, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    output = Map.put(result, "extracted_at", DateTime.to_iso8601(DateTime.utc_now()))

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Extract base method signatures from a parsed AST.

  Finds the `export default class Exchange` and extracts all `MethodDefinition`
  and `PropertyDefinition` nodes whose name starts with `parse` or `safe`.

  Returns a map of `%{method_name => method_data}`.
  """
  @spec extract_from_ast(map()) :: map()
  def extract_from_ast(ast) do
    class_body = find_class_body(ast.body)

    case class_body do
      nil ->
        %{}

      members ->
        members
        |> Enum.filter(&base_method?/1)
        |> Map.new(&{&1.key.name, extract_member(&1)})
    end
  end

  # Extract signature data from a MethodDefinition AST node (full signature)
  defp extract_member(%{type: "MethodDefinition"} = method) do
    name = method.key.name

    %{
      "name" => name,
      "category" => categorize(name),
      "params" => CcxtExtract.Methods.extract_params(method.value.params),
      "return_type" => CcxtExtract.Methods.extract_return_type(method.value),
      "async" => method.value.async || false,
      "source" => "method_definition"
    }
  end

  # Extract minimal data from a PropertyDefinition (class field alias to imported function)
  defp extract_member(%{type: "PropertyDefinition"} = prop) do
    name = prop.key.name

    %{
      "name" => name,
      "category" => categorize(name),
      "params" => [],
      "return_type" => nil,
      "async" => false,
      "source" => "field_assignment"
    }
  end

  # Find the class body members from the AST.
  # Exchange.ts uses `export default class Exchange { ... }`
  defp find_class_body(body) do
    export = Enum.find(body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && export.declaration.body do
      export.declaration.body.body
    else
      # Fallback: plain ClassDeclaration (no export default)
      class = Enum.find(body, &(&1.type == "ClassDeclaration"))
      class && class.body && class.body.body
    end
  end

  # Categorize a method name by its prefix
  defp categorize(name) do
    cond do
      String.starts_with?(name, "parse") -> "parse"
      String.starts_with?(name, "safe") -> "safe"
      true -> nil
    end
  end

  # Match MethodDefinition or PropertyDefinition nodes with parse* or safe* names
  defp base_method?(%{type: type, key: %{name: name}}) when type in ["MethodDefinition", "PropertyDefinition"] do
    categorize(name) != nil
  end

  defp base_method?(_), do: false

  # Count methods per category
  defp count_by_category(methods) do
    methods
    |> Map.values()
    |> Enum.group_by(& &1["category"])
    |> Map.new(fn {cat, list} -> {cat, length(list)} end)
  end
end
