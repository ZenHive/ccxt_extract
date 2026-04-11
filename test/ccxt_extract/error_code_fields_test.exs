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

  defp variable_declaration(name, init) do
    %{
      "type" => "VariableDeclaration",
      "declarations" => [
        %{"type" => "VariableDeclarator", "init" => init, "id" => identifier(name)}
      ]
    }
  end

  defp if_statement(test_expr \\ %{"type" => "Literal", "value" => true}, consequent_body, alternate_body) do
    result = %{
      "type" => "IfStatement",
      "test" => test_expr,
      "consequent" => %{"type" => "BlockStatement", "body" => consequent_body}
    }

    if alternate_body do
      Map.put(result, "alternate", %{"type" => "BlockStatement", "body" => alternate_body})
    else
      Map.put(result, "alternate", nil)
    end
  end

  # Build this.throwExactlyMatchedException(exceptions, variable, feedback)
  defp throw_exactly_call(var_name) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => this_expression(),
        "property" => identifier("throwExactlyMatchedException")
      },
      "arguments" => [identifier("exceptions"), identifier(var_name), identifier("feedback")]
    }
  end

  # Build this.throwBroadlyMatchedException(exceptions, variable, feedback)
  defp throw_broadly_call(var_name) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => this_expression(),
        "property" => identifier("throwBroadlyMatchedException")
      },
      "arguments" => [identifier("exceptions"), identifier(var_name), identifier("feedback")]
    }
  end

  # Build: left === right
  defp binary_equals(left, right) do
    %{"type" => "BinaryExpression", "operator" => "===", "left" => left, "right" => right}
  end

  # Build: left !== right
  defp binary_not_equals(left, right) do
    %{"type" => "BinaryExpression", "operator" => "!==", "left" => left, "right" => right}
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
      ast = method_ast([variable_declaration("code", call)])

      assert ErrorCodeFields.derive(ast) == [
               %{
                 "object" => "response",
                 "field" => "code",
                 "method" => "safeString",
                 "field2" => nil,
                 "roles" => [],
                 "sentinel_values" => nil
               }
             ]
    end

    test "extracts safeString2 with two field args" do
      call = safe_call("safeString2", [identifier("response"), literal("ret_code"), literal("retCode")])
      ast = method_ast([variable_declaration("errorCode", call)])

      assert ErrorCodeFields.derive(ast) == [
               %{
                 "object" => "response",
                 "field" => "ret_code",
                 "method" => "safeString2",
                 "field2" => "retCode",
                 "roles" => [],
                 "sentinel_values" => nil
               }
             ]
    end

    test "extracts safeValue call" do
      call = safe_call("safeValue", [identifier("response"), literal("message")])
      ast = method_ast([variable_declaration("msg", call)])

      assert ErrorCodeFields.derive(ast) == [
               %{
                 "object" => "response",
                 "field" => "message",
                 "method" => "safeValue",
                 "field2" => nil,
                 "roles" => [],
                 "sentinel_values" => nil
               }
             ]
    end

    test "extracts calls with non-response object" do
      call = safe_call("safeString", [identifier("error"), literal("sCode")])
      ast = method_ast([variable_declaration("sCode", call)])

      assert ErrorCodeFields.derive(ast) == [
               %{
                 "object" => "error",
                 "field" => "sCode",
                 "method" => "safeString",
                 "field2" => nil,
                 "roles" => [],
                 "sentinel_values" => nil
               }
             ]
    end

    test "extracts calls nested inside IfStatement" do
      call1 = safe_call("safeString", [identifier("response"), literal("code")])
      call2 = safe_call("safeString", [identifier("response"), literal("msg")])

      ast =
        method_ast([
          if_statement(
            [variable_declaration("code", call1)],
            [variable_declaration("msg", call2)]
          )
        ])

      result = ErrorCodeFields.derive(ast)
      assert length(result) == 2

      fields = Enum.map(result, & &1["field"])
      assert "code" in fields
      assert "msg" in fields
      assert Enum.all?(result, &(&1["roles"] == []))
    end

    test "extracts multiple calls from flat body" do
      call1 = safe_call("safeString", [identifier("response"), literal("code")])
      call2 = safe_call("safeValue", [identifier("response"), literal("message")])

      ast = method_ast([variable_declaration("code", call1), variable_declaration("msg", call2)])

      result = ErrorCodeFields.derive(ast)
      assert length(result) == 2
      assert Enum.map(result, & &1["field"]) == ["code", "message"]
    end

    test "handles integer field values (array index access)" do
      call = safe_call("safeValue", [identifier("errors"), literal(0)])
      ast = method_ast([variable_declaration("err", call)])

      assert ErrorCodeFields.derive(ast) == [
               %{
                 "object" => "errors",
                 "field" => 0,
                 "method" => "safeValue",
                 "field2" => nil,
                 "roles" => [],
                 "sentinel_values" => nil
               }
             ]
    end

    test "records nil object when first arg is not an Identifier" do
      call = safe_call("safeString", [literal("not_identifier"), literal("code")])
      ast = method_ast([variable_declaration("code", call)])

      assert ErrorCodeFields.derive(ast) == [
               %{
                 "object" => nil,
                 "field" => "code",
                 "method" => "safeString",
                 "field2" => nil,
                 "roles" => [],
                 "sentinel_values" => nil
               }
             ]
    end

    test "records nil field when second arg is not a Literal" do
      call = safe_call("safeString", [identifier("response"), identifier("fieldVar")])
      ast = method_ast([variable_declaration("val", call)])

      assert ErrorCodeFields.derive(ast) == [
               %{
                 "object" => "response",
                 "field" => nil,
                 "method" => "safeString",
                 "field2" => nil,
                 "roles" => [],
                 "sentinel_values" => nil
               }
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

  describe "role classification" do
    test "error_code role from throwExactlyMatchedException" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          expression_statement(throw_exactly_call("code"))
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["error_code"]
      assert entry["sentinel_values"] == nil
    end

    test "error_message role from throwBroadlyMatchedException" do
      call = safe_call("safeString", [identifier("response"), literal("msg")])

      ast =
        method_ast([
          variable_declaration("message", call),
          expression_statement(throw_broadly_call("message"))
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["error_message"]
      assert entry["sentinel_values"] == nil
    end

    test "status_sentinel role from === comparison" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          if_statement(
            binary_equals(identifier("code"), literal("200")),
            [expression_statement(identifier("x"))],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["status_sentinel"]
      assert entry["sentinel_values"] == ["200"]
    end

    test "status_sentinel from !== comparison" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          if_statement(
            binary_not_equals(identifier("code"), literal("0")),
            [expression_statement(identifier("x"))],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["status_sentinel"]
      assert entry["sentinel_values"] == ["0"]
    end

    test "reversed comparison (literal === variable)" do
      call = safe_call("safeString", [identifier("response"), literal("status")])

      ast =
        method_ast([
          variable_declaration("status", call),
          if_statement(
            binary_equals(literal("error"), identifier("status")),
            [expression_statement(identifier("x"))],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["status_sentinel"]
      assert entry["sentinel_values"] == ["error"]
    end

    test "multiple sentinel values sorted" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          if_statement(
            binary_equals(identifier("code"), literal("200")),
            [expression_statement(identifier("x"))],
            nil
          ),
          if_statement(
            binary_not_equals(identifier("code"), literal("0")),
            [expression_statement(identifier("x"))],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["status_sentinel"]
      assert entry["sentinel_values"] == ["0", "200"]
    end

    test "dual role: error_code + status_sentinel (Binance pattern)" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("error", call),
          # Sentinel check: if (error === '200') return undefined
          if_statement(
            binary_equals(identifier("error"), literal("200")),
            [expression_statement(identifier("x"))],
            nil
          ),
          # Exception lookup
          expression_statement(throw_exactly_call("error"))
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["error_code", "status_sentinel"]
      assert entry["sentinel_values"] == ["200"]
    end

    test "triple role: error_code + error_message + status_sentinel" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          expression_statement(throw_exactly_call("code")),
          expression_statement(throw_broadly_call("code")),
          if_statement(
            binary_equals(identifier("code"), literal("0")),
            [expression_statement(identifier("x"))],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["error_code", "error_message", "status_sentinel"]
      assert entry["sentinel_values"] == ["0"]
    end

    test "no roles when safe* call is bare expression (no variable binding)" do
      call = safe_call("safeString", [identifier("response"), literal("code")])
      ast = method_ast([expression_statement(call)])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == []
      assert entry["sentinel_values"] == nil
    end

    test "no roles when variable is not used in throw or comparison" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          expression_statement(identifier("other"))
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == []
      assert entry["sentinel_values"] == nil
    end

    test "integer sentinel values are stringified" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          if_statement(
            binary_not_equals(identifier("code"), literal(0)),
            [expression_statement(identifier("x"))],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["status_sentinel"]
      assert entry["sentinel_values"] == ["0"]
    end

    test "multiple fields with independent roles" do
      code_call = safe_call("safeString", [identifier("response"), literal("code")])
      msg_call = safe_call("safeString", [identifier("response"), literal("msg")])

      ast =
        method_ast([
          variable_declaration("code", code_call),
          variable_declaration("message", msg_call),
          expression_statement(throw_exactly_call("code")),
          expression_statement(throw_broadly_call("message"))
        ])

      result = ErrorCodeFields.derive(ast)
      assert length(result) == 2

      code_entry = Enum.find(result, &(&1["field"] == "code"))
      msg_entry = Enum.find(result, &(&1["field"] == "msg"))

      assert code_entry["roles"] == ["error_code"]
      assert code_entry["sentinel_values"] == nil

      assert msg_entry["roles"] == ["error_message"]
      assert msg_entry["sentinel_values"] == nil
    end

    test "throw call with non-bound variable is ignored" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          # "other" is not a bound variable — should not affect code's roles
          expression_statement(throw_exactly_call("other"))
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == []
    end

    test "comparison with non-bound variable is ignored" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          if_statement(
            binary_equals(identifier("other"), literal("200")),
            [expression_statement(identifier("x"))],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == []
      assert entry["sentinel_values"] == nil
    end

    test "roles from deeply nested throw calls" do
      call = safe_call("safeString", [identifier("response"), literal("code")])

      ast =
        method_ast([
          variable_declaration("code", call),
          if_statement(
            [
              if_statement(
                [expression_statement(throw_exactly_call("code"))],
                nil
              )
            ],
            nil
          )
        ])

      [entry] = ErrorCodeFields.derive(ast)
      assert entry["roles"] == ["error_code"]
    end
  end
end
