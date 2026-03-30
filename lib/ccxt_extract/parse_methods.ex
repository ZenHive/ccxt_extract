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

  require Logger

  @output_file "parse_methods.json"

  @doc """
  Extract all parse*() method ASTs from all REST exchange TypeScript files.

  Parses each `.ts` file in `priv/ccxt/ts/src/` via OXC, finds all methods
  whose name starts with "parse", and extracts their full AST bodies.

  Exchanges without any parse methods get `"parse_methods" => %{}` in the output.

  Returns `{:ok, exchanges, stats}` where stats has `:skipped` and `:errors` lists.
  """
  @spec extract() :: {:ok, [map()], map()}
  def extract do
    ts_src = CcxtExtract.Paths.ts_src()

    if !File.dir?(ts_src) do
      raise "CCXT TypeScript source not found at #{ts_src}. Run `mix ccxt_extract.setup` first."
    end

    files = Path.wildcard(Path.join(ts_src, "*.ts"))

    if files == [] do
      raise "No .ts files found in #{ts_src}. CCXT source may be incomplete."
    end

    {exchanges, skipped, errors} =
      files
      |> Enum.map(&parse_file/1)
      |> Enum.reduce({[], [], []}, fn
        {:ok, exchange}, {ok, skip, err} -> {[exchange | ok], skip, err}
        {:skip, file}, {ok, skip, err} -> {ok, [file | skip], err}
        {:error, file, reason}, {ok, skip, err} -> {ok, skip, [{file, reason} | err]}
      end)

    for {file, reason} <- errors do
      Logger.warning("Failed to parse #{file}: #{inspect(reason)}")
    end

    sorted = Enum.sort_by(exchanges, & &1["id"])

    {:ok, sorted, %{skipped: Enum.reverse(skipped), errors: Enum.reverse(errors)}}
  end

  @doc """
  Write extracted parse method data to `priv/discoveries/parse_methods.json`.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(exchanges, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    with_parse = Enum.count(exchanges, fn e -> e["parse_method_count"] > 0 end)
    total_methods = Enum.sum(Enum.map(exchanges, & &1["parse_method_count"]))

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(exchanges),
      "with_parse_methods" => with_parse,
      "total_methods" => total_methods,
      "exchanges" => exchanges
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Parse a single TypeScript file and extract all parse*() method data.

  Returns `{:ok, exchange_map}`, `{:skip, filename}` if no exported class,
  or `{:error, filename, reason}` on parse failure.
  """
  @spec parse_file(String.t()) :: {:ok, map()} | {:skip, String.t()} | {:error, String.t(), term()}
  def parse_file(path) do
    source = File.read!(path)
    filename = Path.basename(path)

    case OXC.parse(source, filename) do
      {:ok, ast} ->
        case extract_from_ast(ast, filename) do
          nil -> {:skip, filename}
          exchange -> {:ok, exchange}
        end

      {:error, reason} ->
        {:error, filename, reason}
    end
  end

  @doc """
  Extract all parse*() method data from a parsed AST.

  Finds the default-exported class, searches for all MethodDefinitions whose
  name starts with "parse", and extracts their full AST bodies. Returns nil
  if no exported class is found.
  """
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      methods = find_parse_methods(class.body.body)

      parse_methods_map =
        Map.new(methods, fn method ->
          {method.key.name, extract_method_data(method)}
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

  @doc """
  Find all parse*() MethodDefinitions in a class body.

  Returns a list of AST nodes whose method name starts with "parse".
  """
  @spec find_parse_methods([map()]) :: [map()]
  def find_parse_methods(class_body) do
    Enum.filter(class_body, fn member ->
      member.type == "MethodDefinition" && String.starts_with?(member.key.name, "parse")
    end)
  end

  @doc """
  Extract method data from a MethodDefinition AST node.

  Returns a map with params, return_type, async, statement count, and the
  full body AST. Returns nil if the input is nil.
  """
  @spec extract_method_data(map() | nil) :: map() | nil
  def extract_method_data(nil), do: nil

  def extract_method_data(method) do
    %{
      "params" => CcxtExtract.Methods.extract_params(method.value.params),
      "return_type" => CcxtExtract.Methods.extract_return_type(method.value),
      "async" => method.value.async,
      "statements" => length(method.value.body.body),
      "body" => method.value.body
    }
  end
end
