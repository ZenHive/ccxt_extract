defmodule CcxtExtract.SignDispatch do
  @moduledoc """
  Derive a per-section dispatch view from `sign()` AST top-level branches.

  CCXT's `sign()` is a single method whose body is a chain of
  `if (api === '...') { ... } else if (api === '...' || ...) { ... }`
  branches. There is no separate "private signing handler" method most of
  the time — the per-section logic is inline. This module surfaces the
  branch structure as a routing table:

  * `sections` — sorted, unique list of `api` literal values reached by
    every analyzed branch (e.g. `["private", "public", "sapi"]`)
  * `branches` — ordered list of branch entries. Each entry records:
    * `predicate_raw` — compact source rendering of the `IfStatement.test`
    * `matches` — map of normalized routing keys, currently:
      `%{"api" => [...], "path" => [...]}`. Values come from
      `<id> === '<literal>'` comparisons inside the predicate. Keys with no
      literals are omitted.
    * `is_else` — boolean. `true` for the trailing `else` of the chain
      (catches everything not matched above; carries no predicate of its
      own — `predicate_raw` is `null`)
    * `source_span` — `{start, end}` byte offsets of the branch body, the
      "handler identifier" in CCXT's inline shape

  Returns `nil` when the input is `nil` or has no `body`. Returns
  `%{"sections" => [], "branches" => []}` when the method exists but
  contains no recognizable `if` chain (e.g. an unconditional sign() that
  always builds the same request).

  Complements `authenticated_sections` (which sections require auth) and
  `sign_recipe` (per-section signing recipe) by surfacing the branch order
  and combined predicates that gate each handler.
  """

  @doc """
  Derive a `%{"sections" => [...], "branches" => [...]}` map from a
  `sign()` method AST.
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil

  def derive(%{"body" => %{"body" => stmts}}) when is_list(stmts) do
    branches =
      stmts
      |> Enum.flat_map(&flatten_if_chain/1)
      |> Enum.map(&build_branch/1)

    sections =
      branches
      |> Enum.flat_map(fn b -> get_in(b, ["matches", "api"]) || [] end)
      |> Enum.uniq()
      |> Enum.sort()

    %{"sections" => sections, "branches" => branches}
  end

  def derive(_), do: nil

  # Flatten a top-level `IfStatement` into ordered {test, body} tuples,
  # walking through the `alternate` chain. The terminating `else` branch
  # (no test) is emitted as `{:else, body}`.
  defp flatten_if_chain(%{"type" => "IfStatement", "test" => test, "consequent" => consequent} = stmt) do
    head = [%{kind: :if, test: test, body: consequent}]
    tail = flatten_alternate(Map.get(stmt, "alternate"))
    head ++ tail
  end

  defp flatten_if_chain(_), do: []

  defp flatten_alternate(nil), do: []

  defp flatten_alternate(%{"type" => "IfStatement", "test" => test, "consequent" => consequent} = stmt) do
    head = [%{kind: :else_if, test: test, body: consequent}]
    tail = flatten_alternate(Map.get(stmt, "alternate"))
    head ++ tail
  end

  defp flatten_alternate(other), do: [%{kind: :else, test: nil, body: other}]

  defp build_branch(%{kind: :else, body: body}) do
    %{
      "predicate_raw" => nil,
      "matches" => %{},
      "is_else" => true,
      "source_span" => span(body)
    }
  end

  defp build_branch(%{test: test, body: body}) do
    %{
      "predicate_raw" => render_ast(test),
      "matches" => collect_matches(test),
      "is_else" => false,
      "source_span" => span(body)
    }
  end

  defp span(%{"start" => s, "end" => e}) when is_integer(s) and is_integer(e), do: %{"start" => s, "end" => e}
  defp span(_), do: nil

  # Collect literal-equality matches keyed by identifier name. Walks the
  # predicate looking for `<id> === '<literal>'` (or symmetric form) where
  # `<id>` is a top-level Identifier (not a member access) and the literal
  # is a string. Walks `||`, `&&`, parens; ignores other shapes silently.
  defp collect_matches(test) do
    test
    |> walk_matches(%{})
    |> Map.new(fn {k, v} -> {k, v |> Enum.uniq() |> Enum.sort()} end)
  end

  defp walk_matches(%{"type" => "BinaryExpression", "operator" => op, "left" => l, "right" => r}, acc)
       when op in ["===", "=="] do
    case eq_literal(l, r) do
      {ident, value} -> Map.update(acc, ident, [value], &[value | &1])
      :no -> acc
    end
  end

  defp walk_matches(%{"type" => "LogicalExpression", "left" => l, "right" => r}, acc) do
    acc = walk_matches(l, acc)
    walk_matches(r, acc)
  end

  defp walk_matches(%{"type" => "ParenthesizedExpression", "expression" => inner}, acc), do: walk_matches(inner, acc)

  defp walk_matches(_, acc), do: acc

  defp eq_literal(%{"type" => "Identifier", "name" => name}, %{"type" => "Literal", "value" => v})
       when is_binary(v) and is_binary(name),
       do: {name, v}

  defp eq_literal(%{"type" => "Literal", "value" => v}, %{"type" => "Identifier", "name" => name})
       when is_binary(v) and is_binary(name),
       do: {name, v}

  defp eq_literal(_, _), do: :no

  # --- AST string renderer (mirrors throw_dispatches.ex / error_dispatch.ex shape) ---

  defp render_ast(%{"type" => "ThisExpression"}), do: "this"
  defp render_ast(%{"type" => "Identifier", "name" => name}), do: name
  defp render_ast(%{"type" => "Literal", "value" => v}) when is_binary(v), do: "'#{v}'"
  defp render_ast(%{"type" => "Literal", "value" => v}) when is_nil(v), do: "null"
  defp render_ast(%{"type" => "Literal", "value" => v}), do: to_string(v)

  defp render_ast(%{"type" => "MemberExpression", "object" => obj, "property" => prop, "computed" => computed}) do
    obj_str = render_ast(obj)

    if computed do
      "#{obj_str}[#{render_ast(prop)}]"
    else
      "#{obj_str}.#{render_ast(prop)}"
    end
  end

  defp render_ast(%{"type" => "CallExpression", "callee" => callee, "arguments" => args}) do
    args_str = Enum.map_join(args, ", ", &render_ast/1)
    "#{render_ast(callee)}(#{args_str})"
  end

  defp render_ast(%{"type" => "BinaryExpression", "left" => l, "right" => r, "operator" => op}),
    do: "#{render_ast(l)} #{op} #{render_ast(r)}"

  defp render_ast(%{"type" => "LogicalExpression", "left" => l, "right" => r, "operator" => op}),
    do: "#{render_ast(l)} #{op} #{render_ast(r)}"

  defp render_ast(%{"type" => "UnaryExpression", "operator" => op, "argument" => arg}), do: "#{op}#{render_ast(arg)}"

  defp render_ast(%{"type" => "ParenthesizedExpression", "expression" => inner}), do: "(#{render_ast(inner)})"

  defp render_ast(%{"type" => type}), do: "<#{type}>"
  defp render_ast(_), do: "<unknown>"
end
