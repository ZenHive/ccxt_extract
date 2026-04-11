defmodule CcxtExtract.ErrorCodeFieldsTest do
  @moduledoc """
  Unit tests for ErrorCodeFields.derive/1.
  Uses synthetic AST nodes matching real handleErrors() patterns.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.ErrorCodeFields

  # --- Helpers to build AST nodes ---

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

  defp safe_call(method, args) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => this_expression(),
        "property" => identifier(method)
      },
      "arguments" => args
    }
  end

  defp method_ast(statements) do
    %{
      "async" => false,
      "params" => [],
      "return_type" => nil,
      "statements" => length(statements),
      "body" => %{"type" => "BlockStatement", "body" => statements}
    }
  end

  defp expression_statement(expr) do
    %{"type" => "ExpressionStatement", "expression" => expr}
  end

  defp variable_declaration(init) do
    %{
      "type" => "VariableDeclaration",
      "declarations" => [
        %{"type" => "VariableDeclarator", "init" => init, "id" => identifier("x")}
      ]
    }
  end

  defp if_statement(consequent_body, alternate_body) do
    result = %{
      "type" => "IfStatement",
      "test" => %{"type" => "Literal", "value" => true},
      "consequent" => %{"type" => "BlockStatement", "body" => consequent_body}
    }

    if alternate_body do
      Map.put(result, "alternate", %{"type" => "BlockStatement", "body" => alternate_body})
    else
      Map.put(result, "alternate", nil)
    end
  end

  # --- Tests ---

  describe "derive/1" do
    test "returns nil for nil input" do
      assert ErrorCodeFields.derive(nil) == nil
    end

    test "returns nil for non-map input" do
      assert ErrorCodeFields.derive("not a map") == nil
    end

    test "returns nil for map without body key" do
      assert ErrorCodeFields.derive(%{"async" => false}) == nil
    end

    test "returns empty list when no safe* calls present" do
      ast = method_ast([expression_statement(identifier("x"))])
      assert ErrorCodeFields.derive(ast) == []
    end

    test "extracts simple safeString(response, 'code')" do
      call = safe_call("safeString", [identifier("response"), literal("code")])
      ast = method_ast([variable_declaration(call)])

      assert ErrorCodeFields.derive(ast) == [
               %{"object" => "response", "field" => "code", "method" => "safeString", "field2" => nil}
             ]
    end

    test "extracts safeString2 with two field args" do
      call = safe_call("safeString2", [identifier("response"), literal("ret_code"), literal("retCode")])
      ast = method_ast([variable_declaration(call)])

      assert ErrorCodeFields.derive(ast) == [
               %{"object" => "response", "field" => "ret_code", "method" => "safeString2", "field2" => "retCode"}
             ]
    end

    test "extracts safeValue call" do
      call = safe_call("safeValue", [identifier("response"), literal("message")])
      ast = method_ast([variable_declaration(call)])

      assert ErrorCodeFields.derive(ast) == [
               %{"object" => "response", "field" => "message", "method" => "safeValue", "field2" => nil}
             ]
    end

    test "extracts calls with non-response object" do
      call = safe_call("safeString", [identifier("error"), literal("sCode")])
      ast = method_ast([variable_declaration(call)])

      assert ErrorCodeFields.derive(ast) == [
               %{"object" => "error", "field" => "sCode", "method" => "safeString", "field2" => nil}
             ]
    end

    test "extracts calls nested inside IfStatement" do
      call1 = safe_call("safeString", [identifier("response"), literal("code")])
      call2 = safe_call("safeString", [identifier("response"), literal("msg")])

      ast = method_ast([if_statement([variable_declaration(call1)], [variable_declaration(call2)])])

      result = ErrorCodeFields.derive(ast)
      assert length(result) == 2

      fields = Enum.map(result, & &1["field"])
      assert "code" in fields
      assert "msg" in fields
    end

    test "extracts multiple calls from flat body" do
      call1 = safe_call("safeString", [identifier("response"), literal("code")])
      call2 = safe_call("safeValue", [identifier("response"), literal("message")])

      ast = method_ast([variable_declaration(call1), variable_declaration(call2)])

      result = ErrorCodeFields.derive(ast)
      assert length(result) == 2
      assert Enum.map(result, & &1["field"]) == ["code", "message"]
    end

    test "handles integer field values (array index access)" do
      call = safe_call("safeValue", [identifier("errors"), literal(0)])
      ast = method_ast([variable_declaration(call)])

      assert ErrorCodeFields.derive(ast) == [
               %{"object" => "errors", "field" => 0, "method" => "safeValue", "field2" => nil}
             ]
    end

    test "records nil object when first arg is not an Identifier" do
      # Some exchanges pass a complex expression as first arg
      call = safe_call("safeString", [literal("not_identifier"), literal("code")])
      ast = method_ast([variable_declaration(call)])

      assert ErrorCodeFields.derive(ast) == [
               %{"object" => nil, "field" => "code", "method" => "safeString", "field2" => nil}
             ]
    end

    test "records nil field when second arg is not a Literal" do
      # e.g., safeString(response, someVariable)
      call = safe_call("safeString", [identifier("response"), identifier("fieldVar")])
      ast = method_ast([variable_declaration(call)])

      assert ErrorCodeFields.derive(ast) == [
               %{"object" => "response", "field" => nil, "method" => "safeString", "field2" => nil}
             ]
    end

    test "ignores non-safe* this.method() calls" do
      call = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => this_expression(),
          "property" => identifier("throwExactlyMatchedException")
        },
        "arguments" => [identifier("response"), literal("code")]
      }

      ast = method_ast([expression_statement(call)])
      assert ErrorCodeFields.derive(ast) == []
    end

    test "ignores safe* calls not on this" do
      call = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => identifier("utils"),
          "property" => identifier("safeString")
        },
        "arguments" => [identifier("response"), literal("code")]
      }

      ast = method_ast([expression_statement(call)])
      assert ErrorCodeFields.derive(ast) == []
    end
  end
end
