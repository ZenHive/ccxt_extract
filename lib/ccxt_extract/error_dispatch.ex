defmodule CcxtExtract.ErrorDispatch do
  @moduledoc """
  Derive a flat handler-routing table from `handleErrors()` AST literal throw
  sites.

  Walks the `handleErrors()` method body collecting every `throw new
  <ExceptionClass>(...)` statement plus the conditional context that gates it
  (the chain of enclosing `IfStatement.test` predicates). Each entry surfaces:

  * `exception_class` — the class name in the `NewExpression.callee.name`
  * `predicate_raw` — compact source rendering of the conjoined `if`-test chain
    that gates this throw, or `null` for unconditional throws (top-level body
    statements)
  * `predicate_kind` — coarse classifier of the **innermost** condition shape:
    * `"http_status_in"` — comparisons of the form `code <op> N` where
      `<op>` is one of `===`, `==`, `!==`, `!=`, `>=`, `>`, `<=`, `<`,
      or `||`-disjunctions thereof
    * `"body_contains"` — `body.indexOf(<literal>) >= 0`,
      `body.indexOf(<literal>) > -1`, or `||`-disjunctions thereof
      (also accepted on `message` / `url` / `reason`)
    * `"identifier_check"` — `<id>` truthy, `<id> === <literal>`, or
      `<literal> === <id>`
    * `"other"` — anything else / unconditional
  * `predicate_values` — array of literal values pulled out when
    `predicate_kind` is `"http_status_in"` or `"body_contains"`; `null`
    otherwise.

  The dispatch table complements existing `handle_errors` derivations:
  `error_code_fields` (which fields carry routing keys), `throw_dispatches`
  (which `throwExactly/BroadlyMatchedException` helper calls happen, and
  what `safe*` lookup feeds them), and the static `exceptions` /
  `http_exceptions` describe maps. `error_dispatch` is the missing
  AST-derived view of **literal** throws that the static maps do not name.

  Returns `nil` when the input is `nil` or has no `body`. Returns an empty
  list when the method body has zero literal throws.
  """

  @doc """
  Derive a list of `ErrorDispatchEntry` maps from a `handleErrors()` method AST.

  Returns `nil` when the input is nil or not a `%{"body" => _}` map. Returns
  an empty list when no literal throws are found.
  """
  @spec derive(map() | nil) :: [map()] | nil
  def derive(nil), do: nil

  def derive(%{"body" => body}) when is_map(body) do
    body
    |> collect_throws([])
    |> Enum.map(&build_entry/1)
  end

  def derive(_), do: nil

  # --- Walk: collect throws with enclosing predicate chain ---

  # Walk an AST node, threading the list of enclosing `IfStatement.test`
  # nodes that gate the current branch. `consequent` adds the test as-is;
  # `alternate` would need negation semantics that are too lossy to
  # represent as raw text here, so we DROP the test from the chain when
  # descending into the `else` branch. Throws nested in `else` (or `else if`)
  # branches will have a shorter `predicate_raw` than the source position
  # suggests — an acknowledged limitation. Negated branches are rare in
  # handleErrors() in practice; most throws live in the `consequent` of a
  # straight `if` / `else if` chain whose tests are recorded faithfully.
  defp collect_throws(node, predicates) when is_map(node) do
    case node do
      %{"type" => "ThrowStatement", "argument" => %{"type" => "NewExpression"} = arg} ->
        case extract_class_name(arg) do
          nil -> []
          name -> [%{class: name, predicates: Enum.reverse(predicates)}]
        end

      %{"type" => "IfStatement", "test" => test, "consequent" => consequent} = stmt ->
        cons = collect_throws(consequent, [test | predicates])
        alt = collect_throws(Map.get(stmt, "alternate"), predicates)
        cons ++ alt

      _ ->
        node
        |> Map.values()
        |> Enum.flat_map(&collect_throws(&1, predicates))
    end
  end

  defp collect_throws(nodes, predicates) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_throws(&1, predicates))
  end

  defp collect_throws(_, _predicates), do: []

  defp extract_class_name(%{"callee" => %{"type" => "Identifier", "name" => name}}), do: name
  defp extract_class_name(_), do: nil

  # --- Build entry ---

  defp build_entry(%{class: class, predicates: []}) do
    %{
      "exception_class" => class,
      "predicate_raw" => nil,
      "predicate_kind" => "other",
      "predicate_values" => nil
    }
  end

  defp build_entry(%{class: class, predicates: predicates}) do
    raw = Enum.map_join(predicates, " && ", &render_ast/1)
    innermost = List.last(predicates)
    {kind, values} = classify_predicate(innermost)

    %{
      "exception_class" => class,
      "predicate_raw" => raw,
      "predicate_kind" => kind,
      "predicate_values" => values
    }
  end

  # --- Predicate classification ---

  # `code === N` / `code !== N` / `code >= N` etc.
  defp classify_predicate(%{"type" => "BinaryExpression", "left" => left, "right" => right, "operator" => op})
       when op in ["===", "==", ">=", ">", "<=", "<", "!==", "!="] do
    case classify_status_compare(left, right) do
      {:status, value} ->
        {"http_status_in", [to_string(value)]}

      :body_contains ->
        {"body_contains",
         body_contains_values(%{"type" => "BinaryExpression", "left" => left, "right" => right, "operator" => op})}

      _ ->
        classify_identifier_check(left, right)
    end
  end

  # `code === 1 || code === 2`
  defp classify_predicate(%{"type" => "LogicalExpression", "operator" => "||"} = node) do
    case collect_status_disjuncts(node) do
      {:ok, values} -> {"http_status_in", Enum.uniq(values)}
      :no -> classify_body_disjuncts(node)
    end
  end

  defp classify_predicate(%{"type" => "ParenthesizedExpression", "expression" => inner}), do: classify_predicate(inner)

  # Bare-identifier truthy check: `if (code) { ... }`
  defp classify_predicate(%{"type" => "Identifier"}), do: {"identifier_check", nil}

  defp classify_predicate(_), do: {"other", nil}

  # `code === 418`
  defp classify_status_compare(%{"type" => "Identifier", "name" => "code"}, %{"type" => "Literal", "value" => value}),
    do: {:status, value}

  defp classify_status_compare(%{"type" => "Literal", "value" => value}, %{"type" => "Identifier", "name" => "code"}),
    do: {:status, value}

  # `body.indexOf('LOT_SIZE') >= 0`
  defp classify_status_compare(%{"type" => "CallExpression"} = call, %{"type" => "Literal", "value" => 0}) do
    if body_indexof_call?(call), do: :body_contains, else: :other
  end

  # `body.indexOf('LOT_SIZE') > -1` / `!== -1` — JS AST has no negative literals,
  # so `-1` is `UnaryExpression(-, Literal(1))`.
  defp classify_status_compare(%{"type" => "CallExpression"} = call, %{
         "type" => "UnaryExpression",
         "operator" => "-",
         "argument" => %{"type" => "Literal", "value" => 1}
       }) do
    if body_indexof_call?(call), do: :body_contains, else: :other
  end

  defp classify_status_compare(_, _), do: :other

  defp body_indexof_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "Identifier", "name" => obj},
           "property" => %{"type" => "Identifier", "name" => "indexOf"}
         }
       })
       when obj in ["body", "message", "url", "reason"],
       do: true

  defp body_indexof_call?(_), do: false

  defp body_contains_values(%{
         "left" => %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "Identifier", "name" => obj},
             "property" => %{"type" => "Identifier", "name" => "indexOf"}
           },
           "arguments" => [%{"type" => "Literal", "value" => v} | _]
         }
       })
       when obj in ["body", "message", "url", "reason"] and is_binary(v),
       do: [v]

  defp body_contains_values(_), do: nil

  defp classify_identifier_check(%{"type" => "Identifier", "name" => _}, %{"type" => "Literal"}),
    do: {"identifier_check", nil}

  defp classify_identifier_check(%{"type" => "Literal"}, %{"type" => "Identifier"}), do: {"identifier_check", nil}

  defp classify_identifier_check(_, _), do: {"other", nil}

  # Walk a chain of `||` looking for `code === N` on each disjunct
  defp collect_status_disjuncts(%{"type" => "LogicalExpression", "operator" => "||", "left" => l, "right" => r}) do
    with {:ok, ls} <- collect_status_disjuncts(l),
         {:ok, rs} <- collect_status_disjuncts(r) do
      {:ok, ls ++ rs}
    end
  end

  defp collect_status_disjuncts(%{"type" => "ParenthesizedExpression", "expression" => inner}),
    do: collect_status_disjuncts(inner)

  defp collect_status_disjuncts(%{"type" => "BinaryExpression"} = node) do
    case classify_status_compare(node["left"], node["right"]) do
      {:status, v} -> {:ok, [to_string(v)]}
      _ -> :no
    end
  end

  defp collect_status_disjuncts(_), do: :no

  defp classify_body_disjuncts(%{"type" => "LogicalExpression", "operator" => "||"} = node) do
    values = walk_body_disjuncts(node, [])
    if values == [], do: {"other", nil}, else: {"body_contains", Enum.uniq(values)}
  end

  defp walk_body_disjuncts(%{"type" => "LogicalExpression", "operator" => "||", "left" => l, "right" => r}, acc) do
    acc |> walk_body_disjuncts_node(l) |> walk_body_disjuncts_node(r)
  end

  defp walk_body_disjuncts(_, acc), do: acc

  defp walk_body_disjuncts_node(acc, %{"type" => "BinaryExpression"} = node) do
    case body_contains_values(node) do
      nil -> acc
      vs -> acc ++ vs
    end
  end

  defp walk_body_disjuncts_node(acc, %{"type" => "ParenthesizedExpression", "expression" => inner}),
    do: walk_body_disjuncts_node(acc, inner)

  defp walk_body_disjuncts_node(acc, %{"type" => "LogicalExpression", "operator" => "||"} = node),
    do: walk_body_disjuncts(node, acc)

  defp walk_body_disjuncts_node(acc, _), do: acc

  # --- AST string renderer (subset; mirrors throw_dispatches.ex shape) ---

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
