defmodule CcxtExtract.MethodAST do
  @moduledoc """
  Shared builder for method AST data structures.

  Converts a MethodDefinition ESTree AST node into a normalized map with
  params, return_type, async flag, statement count, and the full body AST.

  Used by ParseMethods, WsMethods, SignMethod, HandleErrors, and Overrides
  to produce consistent method data without duplicating the extraction logic.

  ## Usage

      method_data = CcxtExtract.MethodAST.extract(method_node)
      # => %{"params" => [...], "return_type" => ..., "async" => true, "statements" => 5, "body" => %{...}}
  """

  @doc """
  Extract method data from a MethodDefinition AST node.

  Returns a map with params, return_type, async, statement count, and the
  full body AST. Returns nil if the input is nil.
  """
  @spec extract(map() | nil) :: map() | nil
  def extract(nil), do: nil

  def extract(method) do
    %{
      "params" => CcxtExtract.Methods.extract_params(method.value.params),
      "return_type" => CcxtExtract.Methods.extract_return_type(method.value),
      "async" => method.value.async,
      "statements" => length(method.value.body.body),
      "body" => method.value.body
    }
  end
end
