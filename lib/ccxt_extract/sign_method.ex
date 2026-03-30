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

  require Logger

  @output_file "sign_methods.json"

  @doc """
  Extract sign() method AST from all REST exchange TypeScript files.

  Parses each `.ts` file in `priv/ccxt/ts/src/` via OXC, finds the `sign()`
  method on the default-exported class, and extracts its full AST body.

  Exchanges without a `sign()` method get `"sign" => nil` in the output.

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
  Write extracted sign method data to `priv/discoveries/sign_methods.json`.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(exchanges, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    with_sign = Enum.count(exchanges, & &1["sign"])

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(exchanges),
      "with_sign" => with_sign,
      "exchanges" => exchanges
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Parse a single TypeScript file and extract sign() method data.

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
  Extract sign() method data from a parsed AST.

  Finds the default-exported class, searches for a `sign` MethodDefinition,
  and extracts its full AST body. Returns nil if no exported class is found.
  """
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      sign_data =
        class.body.body
        |> find_sign_method()
        |> extract_sign_data()

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "sign" => sign_data
      }
    end
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

  @doc """
  Extract sign method data from a MethodDefinition AST node.

  Returns a map with params, return_type, async, statement count, and the
  full body AST. Returns nil if the input is nil (no sign method found).
  """
  @spec extract_sign_data(map() | nil) :: map() | nil
  def extract_sign_data(nil), do: nil

  def extract_sign_data(method) do
    %{
      "params" => CcxtExtract.Methods.extract_params(method.value.params),
      "return_type" => CcxtExtract.Methods.extract_return_type(method.value),
      "async" => method.value.async,
      "statements" => length(method.value.body.body),
      "body" => method.value.body
    }
  end
end
