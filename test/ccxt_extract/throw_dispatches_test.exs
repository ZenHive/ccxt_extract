defmodule CcxtExtract.ThrowDispatchesTest do
  @moduledoc """
  Unit tests for ThrowDispatches.derive/1.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.ThrowDispatches

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

  defp binary_plus(left, right) do
    %{"type" => "BinaryExpression", "operator" => "+", "left" => left, "right" => right}
  end

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

  defp this_member(prop_name, computed \\ false) do
    prop = if computed, do: literal(prop_name), else: identifier(prop_name)

    %{
      "type" => "MemberExpression",
      "object" => this_expression(),
      "property" => prop,
      "computed" => computed
    }
  end

  defp exceptions_member(key, computed) do
    prop = if computed, do: literal(key), else: identifier(key)

    %{
      "type" => "MemberExpression",
      "computed" => computed,
      "object" => this_member("exceptions"),
      "property" => prop
    }
  end

  defp by_url_call(key) do
    %{
      "type" => "CallExpression",
      "callee" => this_member("getExceptionsByUrl"),
      "arguments" => [identifier("url"), literal(key)]
    }
  end

  defp json_call(arg) do
    %{
      "type" => "CallExpression",
      "callee" => this_member("json"),
      "arguments" => [arg]
    }
  end

  defp throw_call(helper, exceptions_arg, lookup_arg, message_arg \\ identifier("feedback")) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => this_expression(),
        "property" => identifier(helper)
      },
      "arguments" => [exceptions_arg, lookup_arg, message_arg]
    }
  end

  defp variable_declaration(name, init) do
    %{
      "type" => "VariableDeclaration",
      "declarations" => [
        %{"type" => "VariableDeclarator", "init" => init, "id" => identifier(name)}
      ]
    }
  end

  defp expression_statement(expr), do: %{"type" => "ExpressionStatement", "expression" => expr}

  defp feedback_expression(var_name) do
    binary_plus(binary_plus(this_member("id"), literal(" ")), identifier(var_name))
  end

  defp if_statement(consequent_body) do
    %{
      "type" => "IfStatement",
      "test" => literal(true),
      "consequent" => %{"type" => "BlockStatement", "body" => consequent_body},
      "alternate" => nil
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

  describe "derive/1" do
    test "returns nil for nil input" do
      assert ThrowDispatches.derive(nil) == nil
    end

    test "returns nil for non-AST input" do
      assert ThrowDispatches.derive("not a map") == nil
      assert ThrowDispatches.derive(%{"no" => "body"}) == nil
    end

    test "returns empty list when no throw calls present" do
      ast = method_ast([expression_statement(identifier("x"))])
      assert ThrowDispatches.derive(ast) == []
    end

    test "simple exact + broad dispatch" do
      code_decl = variable_declaration("code", safe_call("safeString", [identifier("response"), literal("code")]))
      msg_decl = variable_declaration("msg", safe_call("safeString", [identifier("response"), literal("msg")]))
      feedback_decl = variable_declaration("feedback", feedback_expression("msg"))

      exact = throw_call("throwExactlyMatchedException", exceptions_member("exact", true), identifier("code"))
      broad = throw_call("throwBroadlyMatchedException", exceptions_member("broad", true), identifier("msg"))

      ast =
        method_ast([
          code_decl,
          msg_decl,
          feedback_decl,
          expression_statement(exact),
          expression_statement(broad)
        ])

      assert [
               %{
                 "helper" => "throwExactlyMatchedException",
                 "exceptions_source" => "exceptions.exact",
                 "exceptions_source_raw" => "this.exceptions['exact']",
                 "lookup" => %{
                   "object" => "response",
                   "object_path" => nil,
                   "field" => "code",
                   "field2" => nil,
                   "method" => "safeString"
                 },
                 "message_lookup" => %{
                   "object" => "response",
                   "object_path" => nil,
                   "field" => "msg",
                   "field2" => nil,
                   "method" => "safeString"
                 }
               },
               %{
                 "helper" => "throwBroadlyMatchedException",
                 "exceptions_source" => "exceptions.broad",
                 "lookup" => %{"field" => "msg", "method" => "safeString"},
                 "message_lookup" => %{"field" => "msg", "method" => "safeString"}
               }
             ] = ThrowDispatches.derive(ast)
    end

    test "binance-style 4-call branch (by_url + direct, exact + broad)" do
      code_decl = variable_declaration("code", safe_call("safeString", [identifier("response"), literal("code")]))
      msg_decl = variable_declaration("msg", safe_call("safeString", [identifier("response"), literal("msg")]))
      feedback_decl = variable_declaration("feedback", feedback_expression("msg"))

      calls = [
        throw_call("throwExactlyMatchedException", by_url_call("exact"), identifier("code")),
        throw_call("throwExactlyMatchedException", exceptions_member("exact", true), identifier("code")),
        throw_call("throwBroadlyMatchedException", by_url_call("broad"), identifier("msg")),
        throw_call("throwBroadlyMatchedException", exceptions_member("broad", true), identifier("msg"))
      ]

      ast =
        method_ast([
          code_decl,
          msg_decl,
          feedback_decl,
          if_statement(Enum.map(calls, &expression_statement/1))
        ])

      result = ThrowDispatches.derive(ast)
      assert length(result) == 4
      sources = Enum.map(result, & &1["exceptions_source"])
      assert sources == ["by_url.exact", "exceptions.exact", "by_url.broad", "exceptions.broad"]
      assert Enum.all?(result, &is_map(&1["message_lookup"]))
    end

    test "dotted access (this.exceptions.exact) normalizes correctly" do
      decl = variable_declaration("code", safe_call("safeString", [identifier("response"), literal("code")]))
      call = throw_call("throwExactlyMatchedException", exceptions_member("exact", false), identifier("code"))
      ast = method_ast([decl, expression_statement(call)])

      [entry] = ThrowDispatches.derive(ast)
      assert entry["exceptions_source"] == "exceptions.exact"
      assert entry["exceptions_source_raw"] == "this.exceptions.exact"
    end

    test "bare this.exceptions normalizes correctly" do
      decl = variable_declaration("code", safe_call("safeString", [identifier("response"), literal("code")]))
      call = throw_call("throwExactlyMatchedException", this_member("exceptions"), identifier("code"))
      ast = method_ast([decl, expression_statement(call)])

      [entry] = ThrowDispatches.derive(ast)
      assert entry["exceptions_source"] == "exceptions"
      assert entry["exceptions_source_raw"] == "this.exceptions"
    end

    test "unbound Identifier arg[1] yields lookup: nil" do
      call = throw_call("throwExactlyMatchedException", exceptions_member("exact", true), identifier("unknown"))
      ast = method_ast([expression_statement(call)])

      [entry] = ThrowDispatches.derive(ast)
      assert entry["lookup"] == nil
      assert entry["message_lookup"] == nil
    end

    test "ignores non-throw this.* calls" do
      decl = variable_declaration("code", safe_call("safeString", [identifier("response"), literal("code")]))
      ast = method_ast([decl])
      assert ThrowDispatches.derive(ast) == []
    end

    test "unknown exceptions source becomes 'other', raw preserved" do
      decl = variable_declaration("code", safe_call("safeString", [identifier("response"), literal("code")]))

      weird = %{
        "type" => "MemberExpression",
        "computed" => false,
        "object" => identifier("localMap"),
        "property" => identifier("exact")
      }

      call = throw_call("throwExactlyMatchedException", weird, identifier("code"))
      ast = method_ast([decl, expression_statement(call)])

      [entry] = ThrowDispatches.derive(ast)
      assert entry["exceptions_source"] == "other"
      assert entry["exceptions_source_raw"] == "localMap.exact"
    end

    test "resolves alias chains for lookup and message_lookup" do
      message_decl =
        variable_declaration("message", safe_call("safeString", [identifier("response"), literal("message")]))

      alias_decl = variable_declaration("errorInfo", identifier("message"))
      feedback_decl = variable_declaration("feedback", feedback_expression("errorInfo"))

      call =
        throw_call(
          "throwExactlyMatchedException",
          exceptions_member("exact", true),
          identifier("errorInfo"),
          identifier("feedback")
        )

      ast = method_ast([message_decl, alias_decl, feedback_decl, expression_statement(call)])

      [entry] = ThrowDispatches.derive(ast)
      assert entry["lookup"]["field"] == "message"
      assert entry["message_lookup"]["field"] == "message"
    end

    test "resolves message_lookup through nested helper calls" do
      message_decl =
        variable_declaration("message", safe_call("safeString", [identifier("response"), literal("message")]))

      feedback_decl =
        variable_declaration(
          "feedback",
          binary_plus(binary_plus(this_member("id"), literal(" ")), json_call(identifier("message")))
        )

      call = throw_call("throwExactlyMatchedException", exceptions_member("exact", true), identifier("message"))
      ast = method_ast([message_decl, feedback_decl, expression_statement(call)])

      [entry] = ThrowDispatches.derive(ast)
      assert entry["lookup"]["field"] == "message"
      assert entry["message_lookup"]["field"] == "message"
    end

    test "throw deeply nested inside if statements is collected" do
      decl = variable_declaration("code", safe_call("safeString", [identifier("response"), literal("code")]))
      call = throw_call("throwExactlyMatchedException", exceptions_member("exact", true), identifier("code"))
      nested = if_statement([if_statement([expression_statement(call)])])
      ast = method_ast([decl, nested])

      assert [%{"helper" => "throwExactlyMatchedException"}] = ThrowDispatches.derive(ast)
    end
  end
end
