defmodule CcxtExtract.SignMethodTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.SignMethod
  alias Mix.Tasks.CcxtExtract.SignMethods

  # Mock AST for a class with a sign() method
  @sign_method %{
    type: :method_definition,
    key: %{name: "sign"},
    value: %{
      async: false,
      params: [
        %{type: :identifier, name: "path", typeAnnotation: nil},
        %{
          type: :assignment_pattern,
          left: %{name: "api", typeAnnotation: nil},
          right: %{type: :literal, value: "public"}
        },
        %{
          type: :assignment_pattern,
          left: %{name: "method", typeAnnotation: nil},
          right: %{type: :literal, value: "GET"}
        },
        %{
          type: :assignment_pattern,
          left: %{name: "params", typeAnnotation: nil},
          right: %{type: :object_expression, properties: []}
        },
        %{
          type: :assignment_pattern,
          left: %{name: "headers", typeAnnotation: %{typeAnnotation: %{type: :ts_any_keyword}}},
          right: %{type: :identifier, name: "undefined"}
        },
        %{
          type: :assignment_pattern,
          left: %{name: "body", typeAnnotation: %{typeAnnotation: %{type: :ts_any_keyword}}},
          right: %{type: :identifier, name: "undefined"}
        }
      ],
      returnType: nil,
      body: %{
        type: :function_body,
        body: [
          %{type: :variable_declaration, declarations: [%{type: :variable_declarator}]},
          %{type: :if_statement, test: %{type: :binary_expression}},
          %{type: :return_statement, argument: %{type: :object_expression}}
        ],
        start: 1000,
        end: 2000
      }
    }
  }

  @describe_method %{
    type: :method_definition,
    key: %{name: "describe"},
    value: %{
      async: false,
      params: [],
      returnType: nil,
      body: %{body: [%{type: :return_statement}]}
    }
  }

  @fetch_ticker_method %{
    type: :method_definition,
    key: %{name: "fetchTicker"},
    value: %{
      async: true,
      params: [%{type: :identifier, name: "symbol", typeAnnotation: nil}],
      returnType: nil,
      body: %{body: [%{}, %{}, %{}]}
    }
  }

  # Builds a mock AST with a class containing the given methods
  defp mock_ast(methods, class_name \\ "binance") do
    %{
      body: [
        %{
          type: :export_default_declaration,
          declaration: %{
            type: :class_declaration,
            id: %{name: class_name},
            superClass: %{name: "Exchange"},
            body: %{body: methods}
          }
        }
      ]
    }
  end

  describe "extract_from_ast/2" do
    test "extracts sign method when present" do
      ast = mock_ast([@describe_method, @sign_method, @fetch_ticker_method])
      result = SignMethod.extract_from_ast(ast, "binance.ts")

      assert result["id"] == "binance"
      assert result["class_name"] == "binance"
      assert result["file"] == "binance.ts"
      assert result["sign"]
      assert result["sign"]["statements"] == 3
      assert result["sign"]["async"] == false
    end

    test "returns sign as nil when sign method absent" do
      ast = mock_ast([@describe_method, @fetch_ticker_method], "ace")
      result = SignMethod.extract_from_ast(ast, "ace.ts")

      assert result["id"] == "ace"
      assert result["sign"] == nil
    end

    test "returns nil when no exported class" do
      ast = %{body: [%{type: :import_declaration, source: %{value: "foo"}}]}
      assert SignMethod.extract_from_ast(ast, "not_a_class.ts") == nil
    end

    test "falls back to filename for class name when id is nil" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{
              type: :class_declaration,
              id: nil,
              body: %{body: [@describe_method]}
            }
          }
        ]
      }

      result = SignMethod.extract_from_ast(ast, "anonymous.ts")
      assert result["id"] == "anonymous"
      assert result["class_name"] == nil
    end

    test "extracts sign params with types via Methods helpers" do
      ast = mock_ast([@sign_method])
      result = SignMethod.extract_from_ast(ast, "binance.ts")

      params = result["sign"]["params"]
      assert length(params) == 6

      # First param is a plain Identifier
      assert Enum.at(params, 0)["name"] == "path"
      # Remaining are AssignmentPattern with defaults
      assert Enum.at(params, 1)["name"] == "api"
      assert Enum.at(params, 4)["name"] == "headers"
      assert Enum.at(params, 4)["type"] == "any"
    end
  end

  describe "find_sign_method/1" do
    test "finds sign among multiple methods" do
      result = SignMethod.find_sign_method([@describe_method, @sign_method, @fetch_ticker_method])
      assert result.key.name == "sign"
    end

    test "returns nil when sign is absent" do
      assert SignMethod.find_sign_method([@describe_method, @fetch_ticker_method]) == nil
    end

    test "returns nil for empty class body" do
      assert SignMethod.find_sign_method([]) == nil
    end
  end

  describe "MethodAST.extract/1" do
    test "returns nil for nil input" do
      assert CcxtExtract.MethodAST.extract(nil) == nil
    end

    test "extracts params, return_type, async, statements, and body" do
      result = CcxtExtract.MethodAST.extract(@sign_method)

      assert is_list(result["params"])
      assert length(result["params"]) == 6
      assert result["return_type"] == nil
      assert result["async"] == false
      assert result["statements"] == 3
      assert is_map(result["body"])
    end

    test "body AST is the raw value.body node" do
      result = CcxtExtract.MethodAST.extract(@sign_method)

      # The body is the raw atom-keyed AST node from OXC
      body = result["body"]
      assert body.type == "FunctionBody"
      assert body.start == 1000
      assert body.end == 2000
      assert length(body.body) == 3
    end
  end

  describe "JSON round-trip" do
    test "atom keys become string keys at all nesting depths" do
      ast = mock_ast([@sign_method])
      exchange = SignMethod.extract_from_ast(ast, "binance.ts")

      json = Jason.encode!(exchange)
      decoded = Jason.decode!(json)

      # Top level
      assert is_binary(decoded |> Map.keys() |> hd())
      # Sign level
      assert is_binary(decoded["sign"] |> Map.keys() |> hd())
      # Body level — atom keys converted to strings
      assert decoded["sign"]["body"]["type"] == "FunctionBody"
      # Nested statement
      first_stmt = hd(decoded["sign"]["body"]["body"])
      assert is_binary(first_stmt |> Map.keys() |> hd())
    end
  end

  describe "Mix.Tasks.CcxtExtract.SignMethods.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        SignMethods.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        SignMethods.run(["rest"])
      end
    end
  end
end
