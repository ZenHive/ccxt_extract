defmodule CcxtExtract.SignRecipe.ASTHelpers do
  @moduledoc """
  Shared AST tree-walking helpers for the sign-recipe derivation pipeline.

  Consumers: `Derive` (Task 65 crypto_op + placement), `CanonicalString`
  (Tasks 66a/66b), `AuthHeaders` (Task 67), and `Nonce` (Task 67). Before
  Task 67, `Derive` and `CanonicalString` each kept private copies of
  `collect_bindings/1` + `flatten_plus_chain/1` — that was fine for two
  consumers but drifted toward duplication rot at four. The helpers stay
  intentionally generic; anything specific to a derivation module
  (signature fingerprinting, reassignment tracking, verb-branching)
  lives next to its consumer.
  """

  @doc """
  Collect every `VariableDeclarator{id: Identifier(name), init: expr}` pair
  reachable from `node`, skipping declarators whose `init` is nil
  (`let x;`). Order is innermost-first (depth-first pre-order over the AST
  map's values), matching the pre-existing private implementations. Names
  appearing in multiple declarators surface once per binding site — callers
  that want the canonical binding use `Enum.find_value/2` themselves.
  """
  @spec collect_bindings(term()) :: [{String.t(), map()}]
  def collect_bindings(node) when is_map(node) do
    own =
      case node do
        %{"type" => "VariableDeclaration", "declarations" => decls} when is_list(decls) ->
          Enum.flat_map(decls, fn
            %{
              "type" => "VariableDeclarator",
              "id" => %{"type" => "Identifier", "name" => name},
              "init" => init
            }
            when not is_nil(init) ->
              [{name, init}]

            _ ->
              []
          end)

        _ ->
          []
      end

    children = node |> Map.values() |> Enum.flat_map(&collect_bindings/1)
    own ++ children
  end

  def collect_bindings(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_bindings/1)
  def collect_bindings(_), do: []

  @doc """
  Flatten a left-associative `+` chain `a + b + c + d` into `[a, b, c, d]`
  without evaluating. Non-`+` nodes return `[node]`.
  """
  @spec flatten_plus_chain(term()) :: [term()]
  def flatten_plus_chain(%{"type" => "BinaryExpression", "operator" => "+", "left" => l, "right" => r}) do
    flatten_plus_chain(l) ++ flatten_plus_chain(r)
  end

  def flatten_plus_chain(node), do: [node]

  @doc """
  Extract the string key from an `ObjectExpression.Property` node.
  Accepts both Literal (`{ 'X': v }`) and Identifier (`{ X: v }` shorthand)
  forms; returns `{:ok, key}` or `:error`.
  """
  @spec object_prop_key(map()) :: {:ok, String.t()} | :error
  def object_prop_key(%{"type" => "Property", "key" => %{"type" => "Literal", "value" => v}}) when is_binary(v),
    do: {:ok, v}

  def object_prop_key(%{"type" => "Property", "key" => %{"type" => "Identifier", "name" => v}}), do: {:ok, v}

  def object_prop_key(_), do: :error
end
