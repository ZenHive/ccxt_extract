defmodule CcxtExtract.SignDispatchTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.SignDispatch

  describe "derive/1 input handling" do
    test "returns nil on nil" do
      assert SignDispatch.derive(nil) == nil
    end

    test "returns nil on a map without body.body" do
      assert SignDispatch.derive(%{"params" => []}) == nil
    end

    test "returns empty branches for body without if statements" do
      method = %{"body" => %{"type" => "BlockStatement", "body" => [return_stmt()]}}
      assert SignDispatch.derive(method) == %{"sections" => [], "branches" => []}
    end
  end

  describe "branch enumeration" do
    test "single if with api === literal" do
      method = method_with_if(api_eq("private"), nil)

      assert %{
               "sections" => ["private"],
               "branches" => [
                 %{
                   "is_else" => false,
                   "matches" => %{"api" => ["private"]},
                   "predicate_raw" => "api === 'private'"
                 }
               ]
             } = SignDispatch.derive(method)
    end

    test "if/else if chain with || disjuncts" do
      first = api_eq("public")

      second =
        logop(
          "||",
          paren(api_eq("private")),
          paren(api_eq("sapi"))
        )

      method = method_with_if_chain([{first, body_span(100, 200)}, {second, body_span(200, 400)}])

      result = SignDispatch.derive(method)

      assert result["sections"] == ["private", "public", "sapi"]
      assert length(result["branches"]) == 2

      [b1, b2] = result["branches"]
      assert b1["matches"] == %{"api" => ["public"]}
      assert b1["source_span"] == %{"start" => 100, "end" => 200}
      assert b2["matches"] == %{"api" => ["private", "sapi"]}
    end

    test "trailing else carries no predicate" do
      method = method_with_if_else(api_eq("private"), body_span(50, 100), body_span(100, 200))

      assert %{"branches" => [_first, %{"is_else" => true, "predicate_raw" => nil}]} =
               SignDispatch.derive(method)
    end

    test "non-string-equality predicates produce empty matches" do
      # `path !== 'foo'` — operator not in equality set
      method = method_with_if(neq("path", "foo"), nil)

      assert [%{"matches" => %{}, "is_else" => false}] = SignDispatch.derive(method)["branches"]
    end

    test "uniqueItems and sorted within each match key" do
      pred =
        logop(
          "||",
          paren(api_eq("sapi")),
          paren(logop("||", paren(api_eq("sapi")), paren(api_eq("private"))))
        )

      method = method_with_if(pred, nil)

      assert [%{"matches" => %{"api" => ["private", "sapi"]}}] =
               SignDispatch.derive(method)["branches"]
    end
  end

  # --- Builders ---

  defp ident(name), do: %{"type" => "Identifier", "name" => name}
  defp lit(v), do: %{"type" => "Literal", "value" => v}

  defp binop(l, op, r), do: %{"type" => "BinaryExpression", "operator" => op, "left" => l, "right" => r}

  defp logop(op, l, r), do: %{"type" => "LogicalExpression", "operator" => op, "left" => l, "right" => r}

  defp paren(expr), do: %{"type" => "ParenthesizedExpression", "expression" => expr}

  defp api_eq(value), do: binop(ident("api"), "===", lit(value))
  defp neq(name, value), do: binop(ident(name), "!==", lit(value))

  defp body_span(s, e), do: %{"type" => "BlockStatement", "body" => [], "start" => s, "end" => e}

  defp return_stmt do
    %{"type" => "ReturnStatement", "argument" => nil}
  end

  defp method_with_if(test, alternate) do
    if_stmt = %{
      "type" => "IfStatement",
      "test" => test,
      "consequent" => body_span(0, 10),
      "alternate" => alternate
    }

    %{"body" => %{"type" => "BlockStatement", "body" => [if_stmt]}}
  end

  defp method_with_if_chain(tests_with_spans) do
    [{first_test, first_body} | rest] = tests_with_spans

    chain =
      Enum.reduce(Enum.reverse(rest), nil, fn {test, body}, alternate ->
        %{
          "type" => "IfStatement",
          "test" => test,
          "consequent" => body,
          "alternate" => alternate
        }
      end)

    if_stmt = %{
      "type" => "IfStatement",
      "test" => first_test,
      "consequent" => first_body,
      "alternate" => chain
    }

    %{"body" => %{"type" => "BlockStatement", "body" => [if_stmt]}}
  end

  defp method_with_if_else(test, consequent_body, else_body) do
    if_stmt = %{
      "type" => "IfStatement",
      "test" => test,
      "consequent" => consequent_body,
      "alternate" => else_body
    }

    %{"body" => %{"type" => "BlockStatement", "body" => [if_stmt]}}
  end
end
