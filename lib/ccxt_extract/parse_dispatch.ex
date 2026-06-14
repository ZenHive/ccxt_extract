defmodule CcxtExtract.ParseDispatch do
  @moduledoc """
  Derive a per-method routing table that names which `parse*()` helpers are
  invoked from each method body.

  CCXT's REST exchanges don't have a centralized parse-handler dispatch
  table (those live on the WS side via `handleMessage` — Task 94, Phase 15).
  The REST dispatch is implicit: each unified fetcher (`fetchTicker`,
  `fetchOrder`, ...) calls `this.parse<Domain>(response, ...)` directly by
  name to convert exchange-native shapes to CCXT unified shapes.

  This derivation makes that implicit dispatch explicit. For every method
  defined on the class, scan the method body for `this.parse<X>(...)` call
  sites and record the set of parse helpers reached. Callers can use the
  resulting map to:

  * Trace which parse helper is responsible for a given fetcher's response
    shape (a port-contract concern that complements `unified_endpoints`).
  * Detect leaf parse methods (parsers that are called from a single
    fetcher) versus shared parsers (parsers reused across many fetchers).
  * Cross-validate that every public fetcher routes to at least one parse
    helper, surfacing oddly-shaped methods that bypass parse helpers
    entirely.

  ## Output shape

  `%{caller_method_name => [parse_helper_name, ...]}`

  * Keys are method names defined on the class (any kind — fetchers,
    parsers, helpers, hooks). Methods that don't call any parse helper are
    omitted.
  * Values are sorted, unique parse helper names. Self-recursive entries
    (where a parser calls itself or calls a sibling parse method) are
    preserved — the chain is real and consumers may want to walk it.

  Returns `nil` when the class body is `nil`. Returns an empty map when
  the class has no method that calls a parse helper.
  """

  @doc """
  Derive a `%{method_name => [parse_helper, ...]}` map from a class body
  list (a list of ESTree class members — typically `MethodDefinition`
  nodes plus `PropertyDefinition` etc.).

  Accepts either string-keyed AST nodes (post-`AstNormalize.normalize/1`,
  the on-disk shape used by every other derivation) or atom-keyed ones
  (the raw OXC parse output) so it can run both as a derivation pass over
  cached discoveries and inline at extractor time.
  """
  @spec derive(list() | nil) :: %{String.t() => [String.t()]} | nil
  def derive(nil), do: nil

  def derive(class_body) when is_list(class_body) do
    class_body
    |> Enum.flat_map(&extract_method_dispatch/1)
    |> Map.new()
  end

  def derive(_), do: nil

  defp extract_method_dispatch(node) do
    case method_def(node) do
      {:ok, name, body} ->
        calls =
          body
          |> collect_parse_calls([])
          |> Enum.uniq()
          |> Enum.sort()

        case calls do
          [] -> []
          list -> [{name, list}]
        end

      :no ->
        []
    end
  end

  # String-keyed (post-normalize) shape
  defp method_def(%{"type" => "MethodDefinition", "key" => %{"name" => name}, "value" => %{"body" => body}})
       when is_binary(name) and is_map(body), do: {:ok, name, body}

  # Atom-keyed (raw OXC) shape
  defp method_def(%{type: :method_definition, key: %{name: name}, value: %{body: body}})
       when is_binary(name) and is_map(body), do: {:ok, name, body}

  defp method_def(_), do: :no

  # Walk `body` (BlockStatement etc.) collecting names from
  # `this.parse<X>(...)` call sites.
  defp collect_parse_calls(node, acc) when is_map(node) do
    acc =
      case parse_call_name(node) do
        nil -> acc
        name -> [name | acc]
      end

    node
    |> Map.values()
    |> Enum.reduce(acc, &collect_parse_calls/2)
  end

  defp collect_parse_calls(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_parse_calls/2)
  end

  defp collect_parse_calls(_, acc), do: acc

  # String-keyed shape
  defp parse_call_name(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => name}
         }
       })
       when is_binary(name) do
    if parse_method?(name), do: name
  end

  # Atom-keyed shape
  defp parse_call_name(%{
         type: :call_expression,
         callee: %{
           type: :member_expression,
           object: %{type: :this_expression},
           property: %{type: :identifier, name: name}
         }
       })
       when is_binary(name) do
    if parse_method?(name), do: name
  end

  defp parse_call_name(_), do: nil

  defp parse_method?("parse" <> rest), do: starts_uppercase?(rest)
  defp parse_method?(_), do: false

  defp starts_uppercase?(<<c, _::binary>>) when c in ?A..?Z, do: true
  defp starts_uppercase?(_), do: false
end
