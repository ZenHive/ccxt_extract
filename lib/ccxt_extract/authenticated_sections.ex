defmodule CcxtExtract.AuthenticatedSections do
  @moduledoc """
  Derive API section names proven to require authentication via
  `checkRequiredCredentials()` gates in the sign() method AST.

  Walks the already-extracted sign() AST to find IfStatement branches that
  call `this.checkRequiredCredentials()` and collects the api section name
  comparisons gating those branches.

  Handles three patterns:

  1. **Direct** — `api === 'X'` comparisons directly in the IfStatement test:
     ```typescript
     if (api === 'private' || api === 'sapi') {
       this.checkRequiredCredentials();
     }
     ```

  2. **Array-indexed** — `api[N] === 'X'` for exchanges that treat api as a
     tuple-like array (e.g., coinbase, bitget, gate):
     ```typescript
     const signed = api[1] === 'private';
     if (signed) { this.checkRequiredCredentials(); }
     ```

  3. **Indirect (variable binding)** — variable declarations that bind
     `api === 'X'` or `api[N] === 'X'`, then referenced in the IfStatement test:
     ```typescript
     const isPrivate = api === 'private';
     if (isPrivate || isFuturePrivate) {
       this.checkRequiredCredentials();
     }
     ```

  Note: some exchanges (e.g., lighter, p2b) perform authentication without
  calling `checkRequiredCredentials()`. Those sections are not captured here —
  the raw sign() AST is available for consumers needing broader auth detection.

  Returns `nil` when the sign() method AST is absent.

  ## Usage

      CcxtExtract.AuthenticatedSections.derive(sign_method_ast)
      #=> ["dapiPrivate", "fapiPrivate", "private", "sapi", ...]
  """

  @doc """
  Derive authenticated section names from a sign() method AST.

  Returns a sorted, deduplicated list of section name strings, or nil if the
  method AST is nil. Returns an empty list if no authenticated sections found.
  """
  @spec derive(map() | nil) :: [String.t()] | nil
  def derive(nil), do: nil

  def derive(%{"body" => %{"body" => body_stmts}}) when is_list(body_stmts) do
    bindings = resolve_variable_bindings(body_stmts)

    body_stmts
    |> collect_from_if_statements(bindings)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def derive(_), do: nil

  # Scan top-level VariableDeclarations for `api === 'sectionName'` bindings.
  # Returns a map of variable_name => section_name.
  defp resolve_variable_bindings(body_stmts) do
    Enum.reduce(body_stmts, %{}, fn stmt, acc ->
      case stmt do
        %{"type" => "VariableDeclaration", "declarations" => declarations} ->
          Enum.reduce(declarations, acc, &extract_api_binding/2)

        _ ->
          acc
      end
    end)
  end

  # Extract `const varName = api === 'sectionName'` pattern
  defp extract_api_binding(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => var_name}, "init" => init},
         acc
       ) do
    case extract_api_equals(init) do
      {:ok, section} -> Map.put(acc, var_name, section)
      :skip -> acc
    end
  end

  defp extract_api_binding(_, acc), do: acc

  # Check if a node is `api === 'literal'` or `api[N] === 'literal'` (direct or parenthesized)
  defp extract_api_equals(%{
         "type" => "BinaryExpression",
         "operator" => "===",
         "left" => %{"type" => "Identifier", "name" => "api"},
         "right" => %{"type" => "Literal", "value" => value}
       })
       when is_binary(value) do
    {:ok, value}
  end

  # Array-indexed: api[0] === 'X' or api[1] === 'X'
  defp extract_api_equals(%{
         "type" => "BinaryExpression",
         "operator" => "===",
         "left" => %{
           "type" => "MemberExpression",
           "computed" => true,
           "object" => %{"type" => "Identifier", "name" => "api"}
         },
         "right" => %{"type" => "Literal", "value" => value}
       })
       when is_binary(value) do
    {:ok, value}
  end

  defp extract_api_equals(%{"type" => "ParenthesizedExpression", "expression" => inner}) do
    extract_api_equals(inner)
  end

  defp extract_api_equals(_), do: :skip

  # Walk all nodes recursively, collecting sections from IfStatements
  # whose consequent contains checkRequiredCredentials()
  defp collect_from_if_statements(nodes, bindings) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_from_if_statements(&1, bindings))
  end

  defp collect_from_if_statements(%{"type" => "IfStatement"} = node, bindings) do
    test = Map.get(node, "test", %{})
    consequent = Map.get(node, "consequent", %{})
    alternate = Map.get(node, "alternate")

    own =
      if has_check_required_credentials?(consequent) do
        collect_api_values(test, bindings)
      else
        []
      end

    # Continue walking the alternate (else-if chain)
    alt_sections =
      if alternate do
        collect_from_if_statements(alternate, bindings)
      else
        []
      end

    # Also recurse into consequent for nested IfStatements
    nested = collect_nested_ifs(consequent, bindings)

    own ++ alt_sections ++ nested
  end

  defp collect_from_if_statements(%{} = node, bindings) do
    node
    |> Map.values()
    |> Enum.flat_map(fn
      v when is_map(v) -> collect_from_if_statements(v, bindings)
      v when is_list(v) -> collect_from_if_statements(v, bindings)
      _ -> []
    end)
  end

  defp collect_from_if_statements(_, _bindings), do: []

  # Recurse into a consequent block to find nested IfStatements
  # (but don't re-check the same IfStatement)
  defp collect_nested_ifs(%{"type" => "BlockStatement", "body" => stmts}, bindings) when is_list(stmts) do
    collect_from_if_statements(stmts, bindings)
  end

  defp collect_nested_ifs(_, _), do: []

  # Check if a node tree contains a this.checkRequiredCredentials() call
  defp has_check_required_credentials?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "checkRequiredCredentials"}
         }
       }), do: true

  defp has_check_required_credentials?(node) when is_map(node) do
    Enum.any?(Map.values(node), &has_check_required_credentials?/1)
  end

  defp has_check_required_credentials?(nodes) when is_list(nodes) do
    Enum.any?(nodes, &has_check_required_credentials?/1)
  end

  defp has_check_required_credentials?(_), do: false

  # Collect api section values from an IfStatement test condition.
  # Handles direct `api === 'X'` and resolved variable references.
  defp collect_api_values(
         %{
           "type" => "BinaryExpression",
           "operator" => "===",
           "left" => %{"type" => "Identifier", "name" => "api"},
           "right" => %{"type" => "Literal", "value" => value}
         },
         _bindings
       )
       when is_binary(value) do
    [value]
  end

  # Array-indexed: api[0] === 'X' or api[1] === 'X'
  defp collect_api_values(
         %{
           "type" => "BinaryExpression",
           "operator" => "===",
           "left" => %{
             "type" => "MemberExpression",
             "computed" => true,
             "object" => %{"type" => "Identifier", "name" => "api"}
           },
           "right" => %{"type" => "Literal", "value" => value}
         },
         _bindings
       )
       when is_binary(value) do
    [value]
  end

  # Resolve variable references from bindings
  defp collect_api_values(%{"type" => "Identifier", "name" => name}, bindings) do
    case Map.get(bindings, name) do
      nil -> []
      section -> [section]
    end
  end

  # Walk LogicalExpression trees (||, &&)
  defp collect_api_values(%{"type" => "LogicalExpression", "left" => left, "right" => right}, bindings) do
    collect_api_values(left, bindings) ++ collect_api_values(right, bindings)
  end

  # Unwrap parenthesized expressions
  defp collect_api_values(%{"type" => "ParenthesizedExpression", "expression" => inner}, bindings) do
    collect_api_values(inner, bindings)
  end

  # Fallback — no api values extractable from this node
  defp collect_api_values(_, _bindings), do: []
end
