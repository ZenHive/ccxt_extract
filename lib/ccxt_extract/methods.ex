defmodule CcxtExtract.Methods do
  @moduledoc """
  Extract method inventory from CCXT TypeScript source via OXC.

  Parses `.ts` files and extracts per-method metadata including parameter
  names with TypeScript type annotations, return types, async status, and
  statement count.

  Supports both REST (`priv/ccxt/ts/src/*.ts`) and WS (`priv/ccxt/ts/src/pro/*.ts`)
  extraction via a `:rest` or `:ws` type parameter.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.Methods.extract(:rest)
      CcxtExtract.Methods.write!(:rest, exchanges)

      {:ok, exchanges, stats} = CcxtExtract.Methods.extract(:ws)
      CcxtExtract.Methods.write!(:ws, exchanges)
  """

  require Logger

  @rest_output_file "methods_rest.json"
  @ws_output_file "methods_ws.json"

  @doc """
  Extract method inventory from CCXT TypeScript source files.

  Type must be `:rest` or `:ws`:
  - `:rest` scans `priv/ccxt/ts/src/*.ts` (excluding `pro/`, `abstract/`, `base/`)
  - `:ws` scans `priv/ccxt/ts/src/pro/*.ts`

  Returns `{:ok, exchanges, stats}` where stats contains `:skipped` and `:errors` lists.
  """
  @spec extract(:rest | :ws) :: {:ok, [map()], map()}
  def extract(type) when type in [:rest, :ws] do
    ts_src = CcxtExtract.Paths.ts_src()

    if !File.dir?(ts_src) do
      raise "CCXT TypeScript source not found at #{ts_src}. Run `mix ccxt_extract.setup` first."
    end

    files = glob_files(ts_src, type)

    if files == [] do
      raise "No .ts files found for #{type} in #{ts_src}. CCXT source may be incomplete."
    end

    {exchanges, skipped, errors} =
      files
      |> Enum.map(&parse_file/1)
      |> CcxtExtract.OXCBatch.reduce_results()

    for {file, reason} <- errors do
      Logger.warning("Failed to parse #{file}: #{inspect(reason)}")
    end

    sorted = Enum.sort_by(exchanges, & &1["id"])

    {:ok, sorted, %{skipped: Enum.reverse(skipped), errors: Enum.reverse(errors)}}
  end

  @doc """
  Write extracted methods to the appropriate discovery file.

  `:rest` writes to `priv/discoveries/methods_rest.json`,
  `:ws` writes to `priv/discoveries/methods_ws.json`.

  Supported options:

    * `:scope` — `:all` or `MapSet.t(String.t())` for merge-safe scoped writes
    * `:tier_scope` — `CcxtExtract.Scope.to_manifest_value/1` output, stamped
      into the envelope. Defaults to `"all"`.
    * `:output_path` — override the default discovery path
    * `:extracted_at` — override the ISO8601 timestamp

  Routes through `CcxtExtract.AggregateWriter.write!/3` so scoped runs merge
  with the existing aggregate and `count` is always recomputed from the
  final merged entries list.
  """
  @spec write!(:rest | :ws, [map()], keyword()) :: :ok
  def write!(type, exchanges, opts \\ []) when type in [:rest, :ws] do
    filename = if type == :rest, do: @rest_output_file, else: @ws_output_file
    default_path = CcxtExtract.Paths.out(Path.join("discoveries", filename))
    output_path = Keyword.get(opts, :output_path, default_path)

    writer_opts = [
      entry_key: "exchanges",
      id_key: "id",
      scope: Keyword.get(opts, :scope, :all),
      stats_fn: fn _ -> %{} end,
      tier_scope: Keyword.get(opts, :tier_scope, "all"),
      extra: %{"type" => to_string(type)},
      normalize: false
    ]

    writer_opts =
      case Keyword.fetch(opts, :extracted_at) do
        {:ok, ts} -> Keyword.put(writer_opts, :extracted_at, ts)
        :error -> writer_opts
      end

    CcxtExtract.AggregateWriter.write!(output_path, exchanges, writer_opts)
  end

  @doc """
  Parse a single TypeScript file and extract exchange method inventory.

  Returns `{:ok, exchange_map}`, `{:skip, filename}` if no exported class,
  or `{:error, filename, reason}` on parse failure.
  """
  @spec parse_file(String.t()) :: {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}
  def parse_file(path), do: CcxtExtract.OXCBatch.parse_file(path, &extract_from_ast/2)

  @doc """
  Extract exchange method data from a parsed AST.

  Finds the default-exported class, extracts its methods with full
  parameter details and return types.
  """
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      methods =
        class.body.body
        |> Enum.filter(&(&1.type == :method_definition))
        |> Enum.map(&extract_method_details/1)

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "method_count" => length(methods),
        "methods" => methods
      }
    end
  end

  @doc """
  Extract detailed metadata from a MethodDefinition AST node.

  Returns a map with name, async status, parameter list (with names and types),
  return type, and statement count.
  """
  @spec extract_method_details(map()) :: map()
  def extract_method_details(method) do
    %{
      "name" => method.key.name,
      "async" => method.value.async,
      "params" => extract_params(method.value.params),
      "return_type" => extract_return_type(method.value),
      "statements" => length(method.value.body.body)
    }
  end

  @doc """
  Extract parameter names and TypeScript type annotations from a parameter list.

  Handles these AST node shapes:
  - `Identifier` — simple param: `symbol`
  - `AssignmentPattern` — default value: `params = {}`
  - `RestElement` — variadic: `...args`
  - `ObjectPattern` — destructured: `{a, b}`
  """
  @spec extract_params([map()]) :: [map()]
  def extract_params(params) do
    Enum.map(params, fn param ->
      {name, type_node} = extract_param_name_and_type(param)

      %{
        "name" => name,
        "type" => extract_type_name(type_node)
      }
    end)
  end

  @doc """
  Extract the return type annotation from a FunctionExpression AST node.

  Looks at `.returnType.typeAnnotation` and extracts the type name string.
  Returns `nil` if no return type annotation is present.
  """
  @spec extract_return_type(map()) :: String.t() | nil
  def extract_return_type(function_node) do
    case Map.get(function_node, :returnType) do
      nil -> nil
      return_type -> extract_type_name(return_type.typeAnnotation)
    end
  end

  @doc """
  Extract a human-readable type name from a TypeScript type annotation AST node.

  Handles common type node shapes:
  - `TSTypeReference` — named types like `string`, `Promise<Order>`
  - `TSArrayType` — `string[]`
  - `TSUnionType` — `string | number`
  - `TSAnyKeyword`, `TSStringKeyword`, etc. — built-in type keywords
  - Other types fall back to the node's `.type` field with "TS"/"Keyword" stripped
  """
  @spec extract_type_name(map() | nil) :: String.t() | nil
  def extract_type_name(nil), do: nil

  def extract_type_name(%{type: :ts_type_reference} = node) do
    base = get_in(node, [:typeName, :name]) || "unknown"

    case get_in(node, [:typeArguments, :params]) do
      [_ | _] = params ->
        args = Enum.map_join(params, ", ", &extract_type_name/1)
        "#{base}<#{args}>"

      _ ->
        base
    end
  end

  def extract_type_name(%{type: :ts_array_type} = node) do
    inner = extract_type_name(node.elementType)
    "#{inner}[]"
  end

  def extract_type_name(%{type: :ts_union_type} = node) do
    Enum.map_join(node.types, " | ", &extract_type_name/1)
  end

  # Fallback: derive the pre-0.7 string mapping from the snake_case atom.
  # `:ts_string_keyword` -> "string", `:ts_number_keyword` -> "number",
  # `:ts_qualified_name` -> "qualifiedname" (matches the old lowercase form).
  def extract_type_name(%{type: type}) when is_atom(type) and type not in [nil, true, false] do
    type
    |> Atom.to_string()
    |> String.replace_leading("ts_", "")
    |> String.replace_trailing("_keyword", "")
    |> String.replace("_", "")
  end

  # Glob the right directory based on type
  defp glob_files(ts_src, :rest) do
    Path.wildcard(Path.join(ts_src, "*.ts"))
  end

  defp glob_files(ts_src, :ws) do
    Path.wildcard(Path.join(ts_src, "pro/*.ts"))
  end

  # Extract parameter name and its type annotation node.
  # Different AST shapes store the name and type in different locations.
  defp extract_param_name_and_type(%{type: :identifier} = param) do
    {param.name, get_in(param, [:typeAnnotation, :typeAnnotation])}
  end

  defp extract_param_name_and_type(%{type: :assignment_pattern} = param) do
    name = get_in(param, [:left, :name]) || "{destructured}"
    type_node = get_in(param, [:left, :typeAnnotation, :typeAnnotation])
    {name, type_node}
  end

  defp extract_param_name_and_type(%{type: :rest_element} = param) do
    name = "...#{get_in(param, [:argument, :name]) || "args"}"
    type_node = get_in(param, [:argument, :typeAnnotation, :typeAnnotation])
    {name, type_node}
  end

  defp extract_param_name_and_type(%{type: :object_pattern}) do
    {"{destructured}", nil}
  end

  defp extract_param_name_and_type(%{type: type}) do
    {"?:#{CcxtExtract.AstNormalize.atom_to_pascal(type)}", nil}
  end
end
