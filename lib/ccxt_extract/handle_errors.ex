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

  use CcxtExtract.OXCExtractor, output_file: "handle_errors.json"

  @impl true
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name
      id = class_name || Path.rootname(filename)

      handle_errors_data =
        class.body.body
        |> find_handle_errors_method()
        |> CcxtExtract.MethodAST.extract()

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

  @impl true
  def write_stats(exchanges) do
    %{"with_handle_errors" => Enum.count(exchanges, & &1["handle_errors"])}
  end

  @doc """
  Find the handleErrors() MethodDefinition in a class body.

  Returns the AST node or nil if not found.
  """
  @spec find_handle_errors_method([map()]) :: map() | nil
  def find_handle_errors_method(class_body) do
    Enum.find(class_body, fn member ->
      member.type == :method_definition && member.key.name == "handleErrors"
    end)
  end

  @doc """
  Load exceptions and httpExceptions from an exchange's describe() JSON.

  Returns `{exceptions, http_exceptions}` where each is a map or nil.
  Returns `{nil, nil}` if the describe file doesn't exist.
  """
  @spec load_describe_exceptions(String.t()) :: {map() | nil, map() | nil}
  # sobelow_skip ["Traversal.FileModule"]
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
