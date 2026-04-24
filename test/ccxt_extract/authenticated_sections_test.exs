defmodule CcxtExtract.AuthenticatedSectionsTest do
  @moduledoc """
  Unit tests for AuthenticatedSections.derive/1.
  Uses synthetic AST nodes matching real sign() patterns.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.AuthenticatedSections

  # --- AST builder helpers ---

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

  defp check_required_credentials_call do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => this_expression(),
          "property" => identifier("checkRequiredCredentials")
        },
        "arguments" => []
      }
    }
  end

  defp api_equals(section) do
    %{
      "type" => "BinaryExpression",
      "operator" => "===",
      "left" => identifier("api"),
      "right" => literal(section)
    }
  end

  # api[index] === section (array-indexed pattern, e.g. coinbase)
  defp api_index_equals(index, section) do
    %{
      "type" => "BinaryExpression",
      "operator" => "===",
      "left" => %{
        "type" => "MemberExpression",
        "computed" => true,
        "object" => identifier("api"),
        "property" => literal(index)
      },
      "right" => literal(section)
    }
  end

  defp logical_or(left, right) do
    %{"type" => "LogicalExpression", "operator" => "||", "left" => left, "right" => right}
  end

  defp if_statement(test, consequent_stmts, alternate \\ nil) do
    node = %{
      "type" => "IfStatement",
      "test" => test,
      "consequent" => %{"type" => "BlockStatement", "body" => consequent_stmts},
      "alternate" => alternate
    }

    node
  end

  defp var_declaration(name, init) do
    %{
      "type" => "VariableDeclaration",
      "declarations" => [
        %{"type" => "VariableDeclarator", "id" => identifier(name), "init" => init}
      ]
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

  # --- Tests ---

  describe "derive/1" do
    test "returns nil for nil input" do
      assert AuthenticatedSections.derive(nil) == nil
    end

    test "returns nil for non-map input" do
      assert AuthenticatedSections.derive("not a map") == nil
    end

    test "returns nil for map without body" do
      assert AuthenticatedSections.derive(%{"async" => false}) == nil
    end

    test "returns empty list when no checkRequiredCredentials present" do
      ast =
        method_ast([
          if_statement(api_equals("public"), [
            %{"type" => "ExpressionStatement", "expression" => identifier("x")}
          ])
        ])

      assert AuthenticatedSections.derive(ast) == []
    end

    test "extracts single section from direct pattern" do
      # if (api === 'private') { this.checkRequiredCredentials() }
      ast =
        method_ast([
          if_statement(api_equals("private"), [check_required_credentials_call()])
        ])

      assert AuthenticatedSections.derive(ast) == ["private"]
    end

    test "extracts multiple sections from OR chain" do
      # if (api === 'private' || api === 'sapi' || api === 'dapiPrivate') { checkRequiredCredentials() }
      test_expr =
        logical_or(
          api_equals("private"),
          logical_or(api_equals("sapi"), api_equals("dapiPrivate"))
        )

      ast = method_ast([if_statement(test_expr, [check_required_credentials_call()])])

      assert AuthenticatedSections.derive(ast) == ["dapiPrivate", "private", "sapi"]
    end

    test "extracts from else-if chain" do
      # if (api === 'public') { ... } else if (api === 'private') { checkRequiredCredentials() }
      else_if =
        if_statement(api_equals("private"), [check_required_credentials_call()])

      ast =
        method_ast([
          if_statement(
            api_equals("public"),
            [%{"type" => "ExpressionStatement", "expression" => identifier("noop")}],
            else_if
          )
        ])

      assert AuthenticatedSections.derive(ast) == ["private"]
    end

    test "does not include sections from branches without checkRequiredCredentials" do
      # if (api === 'public') { noop } else if (api === 'private') { checkRequiredCredentials() }
      else_if =
        if_statement(api_equals("private"), [check_required_credentials_call()])

      ast =
        method_ast([
          if_statement(
            api_equals("public"),
            [%{"type" => "ExpressionStatement", "expression" => identifier("noop")}],
            else_if
          )
        ])

      result = AuthenticatedSections.derive(ast)
      refute "public" in result
      assert "private" in result
    end

    test "deduplicates section names" do
      # api === 'private' appears in two different branches
      test1 = logical_or(api_equals("private"), api_equals("sapi"))
      test2 = logical_or(api_equals("private"), api_equals("dapiPrivate"))

      ast =
        method_ast([
          if_statement(test1, [check_required_credentials_call()]),
          if_statement(test2, [check_required_credentials_call()])
        ])

      result = AuthenticatedSections.derive(ast)
      assert result == ["dapiPrivate", "private", "sapi"]
    end

    test "resolves indirect variable bindings" do
      # const isPrivate = api === 'private';
      # const isFutures = api === 'futuresPrivate';
      # if (isPrivate || isFutures) { checkRequiredCredentials() }
      ast =
        method_ast([
          var_declaration("isPrivate", api_equals("private")),
          var_declaration("isFutures", api_equals("futuresPrivate")),
          if_statement(
            logical_or(identifier("isPrivate"), identifier("isFutures")),
            [check_required_credentials_call()]
          )
        ])

      assert AuthenticatedSections.derive(ast) == ["futuresPrivate", "private"]
    end

    test "resolves mix of direct and indirect patterns" do
      # const isBroker = api === 'broker';
      # if (api === 'private' || isBroker) { checkRequiredCredentials() }
      ast =
        method_ast([
          var_declaration("isBroker", api_equals("broker")),
          if_statement(
            logical_or(api_equals("private"), identifier("isBroker")),
            [check_required_credentials_call()]
          )
        ])

      assert AuthenticatedSections.derive(ast) == ["broker", "private"]
    end

    test "ignores unresolvable variable references" do
      # const signed = someComplexExpression;
      # if (signed) { checkRequiredCredentials() }
      ast =
        method_ast([
          var_declaration("signed", %{
            "type" => "MemberExpression",
            "object" => identifier("this"),
            "property" => identifier("apiKey")
          }),
          if_statement(
            identifier("signed"),
            [check_required_credentials_call()]
          )
        ])

      assert AuthenticatedSections.derive(ast) == []
    end

    test "handles nested IfStatement with checkRequiredCredentials" do
      # if (api === 'private') {
      #   if (someCondition) { checkRequiredCredentials() }
      # }
      inner_if =
        if_statement(
          identifier("someCondition"),
          [check_required_credentials_call()]
        )

      ast =
        method_ast([
          if_statement(
            api_equals("private"),
            [inner_if]
          )
        ])

      # The outer if has checkRequiredCredentials in its consequent (nested)
      assert AuthenticatedSections.derive(ast) == ["private"]
    end

    test "handles parenthesized api comparison in variable binding" do
      # const isPrivate = (api === 'private');
      ast =
        method_ast([
          var_declaration("isPrivate", %{
            "type" => "ParenthesizedExpression",
            "expression" => api_equals("private")
          }),
          if_statement(
            identifier("isPrivate"),
            [check_required_credentials_call()]
          )
        ])

      assert AuthenticatedSections.derive(ast) == ["private"]
    end

    test "extracts section from array-indexed api pattern" do
      # if (api[1] === 'private') { this.checkRequiredCredentials() }
      ast =
        method_ast([
          if_statement(api_index_equals(1, "private"), [check_required_credentials_call()])
        ])

      assert AuthenticatedSections.derive(ast) == ["private"]
    end

    test "extracts from mixed plain and array-indexed patterns" do
      # if (api === 'trade' || api[1] === 'private') { checkRequiredCredentials() }
      test_expr = logical_or(api_equals("trade"), api_index_equals(1, "private"))
      ast = method_ast([if_statement(test_expr, [check_required_credentials_call()])])

      assert AuthenticatedSections.derive(ast) == ["private", "trade"]
    end

    test "resolves array-indexed variable binding" do
      # const signed = api[1] === 'private';
      # if (signed) { checkRequiredCredentials() }
      ast =
        method_ast([
          var_declaration("signed", api_index_equals(1, "private")),
          if_statement(
            identifier("signed"),
            [check_required_credentials_call()]
          )
        ])

      assert AuthenticatedSections.derive(ast) == ["private"]
    end

    test "inverts else-branch: auth set is api_keys minus non-auth test values" do
      # if (api === 'public') { ... } else { this.checkRequiredCredentials(); ... }
      # api_keys = ["public", "private"] -> authenticated = ["private"]
      else_block = %{
        "type" => "BlockStatement",
        "body" => [check_required_credentials_call()]
      }

      ast =
        method_ast([
          if_statement(
            api_equals("public"),
            [%{"type" => "ExpressionStatement", "expression" => identifier("noop")}],
            else_block
          )
        ])

      assert AuthenticatedSections.derive(ast, %{"public" => nil, "private" => nil}) == ["private"]
    end

    test "inverts else-branch: flattens else-if chain, accumulates non-auth across branches" do
      # if (api === 'public') { ... }
      # else if (api === 'webExchange') { ... }
      # else { this.checkRequiredCredentials(); ... }
      # api_keys = ["public", "webExchange", "private", "v2Private"] -> ["private", "v2Private"]
      noop = [%{"type" => "ExpressionStatement", "expression" => identifier("noop")}]

      else_block = %{
        "type" => "BlockStatement",
        "body" => [check_required_credentials_call()]
      }

      else_if =
        if_statement(api_equals("webExchange"), noop, else_block)

      ast =
        method_ast([
          if_statement(api_equals("public"), noop, else_if)
        ])

      api = %{"public" => nil, "webExchange" => nil, "private" => nil, "v2Private" => nil}

      assert AuthenticatedSections.derive(ast, api) == ["private", "v2Private"]
    end

    test "inversion is skipped when api_keys is nil (derive/1 fallback)" do
      else_block = %{
        "type" => "BlockStatement",
        "body" => [check_required_credentials_call()]
      }

      ast =
        method_ast([
          if_statement(
            api_equals("public"),
            [%{"type" => "ExpressionStatement", "expression" => identifier("noop")}],
            else_block
          )
        ])

      # Without api_keys the inversion can't compute the complement; result is [].
      assert AuthenticatedSections.derive(ast) == []
    end

    test "returns sorted output" do
      test_expr =
        logical_or(
          api_equals("zapi"),
          logical_or(api_equals("aapi"), api_equals("mapi"))
        )

      ast = method_ast([if_statement(test_expr, [check_required_credentials_call()])])

      assert AuthenticatedSections.derive(ast) == ["aapi", "mapi", "zapi"]
    end
  end

  describe "integration with real exchange patterns" do
    @tag :extraction
    test "extracts sections from sign_methods.json for reference exchanges" do
      path = "priv/discoveries/sign_methods.json"

      if File.exists?(path) do
        data = path |> File.read!() |> Jason.decode!()
        exchanges = Map.get(data, "exchanges", [])

        expected = %{
          "binance" => {:min, 10},
          "bybit" => {:exact, ["private"]},
          "okx" => {:exact, ["private"]},
          "kraken" => {:exact, ["private"]},
          "aftermath" => {:exact, ["private"]},
          "deribit" => {:exact, ["private"]},
          "kucoin" => {:min, 3},
          # Array-indexed: api[1] === 'private' (regression for Codex finding #1)
          "coinbase" => {:min, 1}
        }

        for {id, expectation} <- expected do
          exchange = Enum.find(exchanges, &(&1["id"] == id))
          assert exchange, "Exchange #{id} not found in sign_methods.json"

          sign_ast = exchange["sign"]
          result = AuthenticatedSections.derive(sign_ast)
          assert is_list(result), "#{id}: expected list, got #{inspect(result)}"

          case expectation do
            {:exact, sections} ->
              assert result == sections,
                     "#{id}: expected #{inspect(sections)}, got #{inspect(result)}"

            {:min, count} ->
              assert length(result) >= count,
                     "#{id}: expected at least #{count} sections, got #{length(result)}: #{inspect(result)}"
          end
        end
      end
    end
  end

  describe "nested sub-section expansion" do
    test "emits dotted paths for children matching the derived name-class" do
      # sign AST derives ["private"]; htx-style describe.api nests authenticated
      # endpoints under container keys (contract.private, spot.private)
      ast =
        method_ast([
          if_statement(api_equals("private"), [check_required_credentials_call()])
        ])

      api = %{
        "contract" => %{"private" => %{}, "public" => %{}},
        "private" => %{},
        "spot" => %{"private" => %{}, "public" => %{}}
      }

      assert AuthenticatedSections.derive(ast, api) ==
               ["contract.private", "private", "spot.private"]
    end

    test "does not emit dotted paths for children outside the derived name-class" do
      # derived set is ["private"] — a "public" child must NOT be added
      ast =
        method_ast([
          if_statement(api_equals("private"), [check_required_credentials_call()])
        ])

      api = %{"contract" => %{"private" => %{}, "public" => %{}}}

      result = AuthenticatedSections.derive(ast, api)
      assert "contract.private" in result
      refute "contract.public" in result
    end

    test "single-arg derive(ast) still returns flat names only (backward compat)" do
      ast =
        method_ast([
          if_statement(api_equals("private"), [check_required_credentials_call()])
        ])

      assert AuthenticatedSections.derive(ast) == ["private"]
      assert AuthenticatedSections.derive(ast, nil) == ["private"]
    end

    test "scalar sub-tree is skipped defensively (no raise)" do
      # describe.api with a non-map value under a top-level key — shouldn't happen
      # in practice, but the expansion must not explode on malformed input
      ast =
        method_ast([
          if_statement(api_equals("private"), [check_required_credentials_call()])
        ])

      api = %{"private" => %{}, "weird" => "not a map"}

      assert AuthenticatedSections.derive(ast, api) == ["private"]
    end

    test "v2Private twin: name-class filter prevents spurious parent expansion" do
      # sign derives ["private", "v2Private"]; api has a "v2" container whose
      # child is "v2Private". Assert dotted form is "v2.v2Private" (child matches),
      # NOT "v2.private" (no such child) and NOT any expansion from the "v2"
      # parent just because it happens to be a key.
      test_expr = logical_or(api_equals("private"), api_equals("v2Private"))

      ast = method_ast([if_statement(test_expr, [check_required_credentials_call()])])

      api = %{
        "contract" => %{"private" => %{}},
        "v2" => %{"v2Private" => %{}}
      }

      assert AuthenticatedSections.derive(ast, api) ==
               ["contract.private", "private", "v2.v2Private", "v2Private"]
    end
  end
end
