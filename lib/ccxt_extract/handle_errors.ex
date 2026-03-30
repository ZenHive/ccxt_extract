defmodule CcxtExtract.HandleErrors do
  @moduledoc """
  Extract the `handleErrors()` method body as raw ESTree AST for every REST exchange.

  The `handleErrors()` method defines how each exchange maps HTTP responses and
  error codes to CCXT exception types. This module extracts the complete method AST
  alongside the `exceptions` and `httpExceptions` from each exchange's `describe()`.

  Together, the AST (conditional logic, fallthrough, edge cases) and the describe
  exceptions (static lookup tables) give consumers the full error-handling picture.

  Reuses parameter and type extraction from `CcxtExtract.Methods`.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.HandleErrors.extract()
      CcxtExtract.HandleErrors.write!(exchanges)
  """

  require Logger

  @output_file "handle_errors.json"

  @doc """
  Extract handleErrors() method AST from all REST exchange TypeScript files.

  Parses each `.ts` file in `priv/ccxt/ts/src/` via OXC, finds the `handleErrors()`
  method on the default-exported class, and extracts its full AST body. Also loads
  the `exceptions` and `httpExceptions` from each exchange's describe() JSON.

  Exchanges without a `handleErrors()` method get `"handle_errors" => nil`.
  Exchanges without a describe file get `nil` for both exception fields.

  Returns `{:ok, exchanges, stats}` where stats has `:skipped` and `:errors` lists.
  """
  # TODO(Task 11): extract/0, write!/2, parse_file/1 share ~80% with SignMethod —
  # extract shared MethodExtractor when implementing parse*() extraction
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
  Write extracted handleErrors data to `priv/discoveries/handle_errors.json`.
  """
  @spec write!([map()], String.t()) :: :ok
  def write!(exchanges, output_path \\ CcxtExtract.Paths.priv(Path.join("discoveries", @output_file))) do
    File.mkdir_p!(Path.dirname(output_path))

    with_handle_errors = Enum.count(exchanges, & &1["handle_errors"])

    output = %{
      "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "count" => length(exchanges),
      "with_handle_errors" => with_handle_errors,
      "exchanges" => exchanges
    }

    json = Jason.encode!(output, pretty: true)
    File.write!(output_path, json)
    :ok
  end

  @doc """
  Parse a single TypeScript file and extract handleErrors() method data.

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
  Extract handleErrors() method data from a parsed AST.

  Finds the default-exported class, searches for a `handleErrors` MethodDefinition,
  and extracts its full AST body. Also loads describe() exceptions for the exchange.
  Returns nil if no exported class is found.
  """
  @spec extract_from_ast(map(), String.t()) :: map() | nil
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == "ExportDefaultDeclaration"))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      handle_errors_data =
        class.body.body
        |> find_handle_errors_method()
        |> extract_handle_errors_data()

      {exceptions, http_exceptions} = load_describe_exceptions(id)

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "handle_errors" => handle_errors_data,
        "exceptions" => exceptions,
        "http_exceptions" => http_exceptions
      }
    end
  end

  @doc """
  Find the handleErrors() MethodDefinition in a class body.

  Returns the AST node or nil if not found.
  """
  @spec find_handle_errors_method([map()]) :: map() | nil
  def find_handle_errors_method(class_body) do
    Enum.find(class_body, fn member ->
      member.type == "MethodDefinition" && member.key.name == "handleErrors"
    end)
  end

  @doc """
  Extract handleErrors method data from a MethodDefinition AST node.

  Returns a map with params, return_type, async, statement count, and the
  full body AST. Returns nil if the input is nil (no handleErrors method found).
  """
  @spec extract_handle_errors_data(map() | nil) :: map() | nil
  def extract_handle_errors_data(nil), do: nil

  def extract_handle_errors_data(method) do
    %{
      "params" => CcxtExtract.Methods.extract_params(method.value.params),
      "return_type" => CcxtExtract.Methods.extract_return_type(method.value),
      "async" => method.value.async,
      "statements" => length(method.value.body.body),
      "body" => method.value.body
    }
  end

  @doc """
  Load exceptions and httpExceptions from an exchange's describe() JSON.

  Returns `{exceptions, http_exceptions}` where each is a map or nil.
  Returns `{nil, nil}` if the describe file doesn't exist.
  """
  @spec load_describe_exceptions(String.t()) :: {map() | nil, map() | nil}
  def load_describe_exceptions(exchange_id) do
    describe_path =
      CcxtExtract.Paths.priv(Path.join(["discoveries", "describe", "#{exchange_id}.json"]))

    if File.exists?(describe_path) do
      data = describe_path |> File.read!() |> Jason.decode!()
      describe = data["describe"] || %{}
      {normalize_map(describe["exceptions"]), normalize_map(describe["httpExceptions"])}
    else
      {nil, nil}
    end
  end

  # Normalize non-map values (e.g. "__undefined" sentinel from QuickBEAM) to nil
  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: nil
end
