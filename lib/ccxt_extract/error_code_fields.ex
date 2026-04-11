defmodule CcxtExtract.ErrorCodeFields do
  @moduledoc """
  Derive error code field names from the handleErrors() method AST.

  Walks the already-extracted handleErrors() AST recursively, collecting all
  `this.safeString()`, `this.safeString2()`, and `this.safeValue()` calls.
  These calls reveal which response body fields each exchange checks for
  error codes and messages.

  Each call is recorded with full context:
  - `object` — the identifier passed as first argument (`"response"`, `"error"`, etc.)
  - `field` — the literal field name being accessed (second argument)
  - `method` — which safe* method was used
  - `field2` — for safeString2, the alternate field name (third argument)

  All safe* calls are preserved, not just those with `response` as first arg.
  Some exchanges destructure the response first (e.g., `const error = response['error']`)
  then call `safeString(error, 'code')`. Consumers decide which object context matters.

  ## Usage

      CcxtExtract.ErrorCodeFields.derive(method_ast)
      #=> [%{"object" => "response", "field" => "code", "method" => "safeString", "field2" => nil}, ...]
  """

  @safe_methods ~w(safeString safeString2 safeValue)

  @doc """
  Derive error code field references from a handleErrors() method AST.

  Returns a list of safe* call records, or nil if the method AST is nil.
  Returns an empty list if no safe* calls are found.
  """
  @spec derive(map() | nil) :: [map()] | nil
  def derive(nil), do: nil

  def derive(%{"body" => body}) when is_map(body) do
    collect_safe_calls(body)
  end

  def derive(_), do: nil

  # Recursively walk any AST node/list, collecting safe* CallExpression matches
  defp collect_safe_calls(node) when is_map(node) do
    own = extract_if_safe_call(node)
    children = node |> Map.values() |> collect_safe_calls()

    case own do
      nil -> children
      record -> [record | children]
    end
  end

  defp collect_safe_calls(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_safe_calls/1)
  end

  defp collect_safe_calls(_), do: []

  # Check if a node is a this.safe*(obj, field, ...) CallExpression
  defp extract_if_safe_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method_name}
         },
         "arguments" => [first_arg | rest_args]
       })
       when method_name in @safe_methods do
    object = extract_identifier_name(first_arg)
    field = extract_literal_value(Enum.at(rest_args, 0))
    field2 = extract_literal_value(Enum.at(rest_args, 1))

    %{
      "object" => object,
      "field" => field,
      "method" => method_name,
      "field2" => field2
    }
  end

  defp extract_if_safe_call(_), do: nil

  # Extract identifier name from an Identifier node
  defp extract_identifier_name(%{"type" => "Identifier", "name" => name}), do: name
  defp extract_identifier_name(_), do: nil

  # Extract literal value from a Literal node
  defp extract_literal_value(%{"type" => "Literal", "value" => value}), do: value
  defp extract_literal_value(_), do: nil
end
