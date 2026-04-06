defmodule CcxtExtract.ParseMethodsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ParseMethods
  alias Mix.Tasks.CcxtExtract.ParseMethods, as: ParseMethodsTask

  # Mock parse methods with different signatures and return types
  @parse_ticker %{
    type: "MethodDefinition",
    key: %{name: "parseTicker"},
    value: %{
      async: false,
      params: [
        %{
          type: "Identifier",
          name: "ticker",
          typeAnnotation: %{typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "Dict"}}}
        },
        %{
          type: "AssignmentPattern",
          left: %{
            name: "market",
            typeAnnotation: %{typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "Market"}}}
          },
          right: %{type: "Identifier", name: "undefined"}
        }
      ],
      returnType: %{typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "Ticker"}}},
      body: %{
        type: "FunctionBody",
        body: [
          %{type: "VariableDeclaration"},
          %{type: "VariableDeclaration"},
          %{type: "ReturnStatement", argument: %{type: "CallExpression"}}
        ],
        start: 5000,
        end: 6000
      }
    }
  }

  @parse_order %{
    type: "MethodDefinition",
    key: %{name: "parseOrder"},
    value: %{
      async: false,
      params: [
        %{
          type: "Identifier",
          name: "order",
          typeAnnotation: %{typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "Dict"}}}
        },
        %{
          type: "AssignmentPattern",
          left: %{
            name: "market",
            typeAnnotation: %{typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "Market"}}}
          },
          right: %{type: "Identifier", name: "undefined"}
        }
      ],
      returnType: %{typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "Order"}}},
      body: %{
        type: "FunctionBody",
        body: [
          %{type: "VariableDeclaration"},
          %{type: "ReturnStatement"}
        ],
        start: 7000,
        end: 8000
      }
    }
  }

  @parse_trade %{
    type: "MethodDefinition",
    key: %{name: "parseTrade"},
    value: %{
      async: false,
      params: [
        %{type: "Identifier", name: "trade", typeAnnotation: nil},
        %{
          type: "AssignmentPattern",
          left: %{name: "market", typeAnnotation: nil},
          right: %{type: "Identifier", name: "undefined"}
        }
      ],
      returnType: nil,
      body: %{
        type: "FunctionBody",
        body: [%{type: "ReturnStatement"}],
        start: 9000,
        end: 9500
      }
    }
  }

  # Non-parse methods
  @describe_method %{
    type: "MethodDefinition",
    key: %{name: "describe"},
    value: %{
      async: false,
      params: [],
      returnType: nil,
      body: %{body: [%{type: "ReturnStatement"}]}
    }
  }

  @sign_method %{
    type: "MethodDefinition",
    key: %{name: "sign"},
    value: %{
      async: false,
      params: [%{type: "Identifier", name: "path", typeAnnotation: nil}],
      returnType: nil,
      body: %{body: [%{type: "ReturnStatement"}]}
    }
  }

  @fetch_ticker_method %{
    type: "MethodDefinition",
    key: %{name: "fetchTicker"},
    value: %{
      async: true,
      params: [%{type: "Identifier", name: "symbol", typeAnnotation: nil}],
      returnType: nil,
      body: %{body: [%{type: "ReturnStatement"}]}
    }
  }

  # Builds a mock AST with a class containing the given methods
  defp mock_ast(methods, class_name \\ "binance") do
    %{
      body: [
        %{
          type: "ExportDefaultDeclaration",
          declaration: %{
            type: "ClassDeclaration",
            id: %{name: class_name},
            superClass: %{name: "Exchange"},
            body: %{body: methods}
          }
        }
      ]
    }
  end

  describe "extract_from_ast/2" do
    test "extracts multiple parse methods" do
      ast = mock_ast([@describe_method, @parse_ticker, @sign_method, @parse_order, @parse_trade])
      result = ParseMethods.extract_from_ast(ast, "binance.ts")

      assert result["id"] == "binance"
      assert result["class_name"] == "binance"
      assert result["file"] == "binance.ts"
      assert result["parse_method_count"] == 3
      assert Map.has_key?(result["parse_methods"], "parseTicker")
      assert Map.has_key?(result["parse_methods"], "parseOrder")
      assert Map.has_key?(result["parse_methods"], "parseTrade")
    end

    test "returns empty map when no parse methods present" do
      ast = mock_ast([@describe_method, @sign_method, @fetch_ticker_method], "ace")
      result = ParseMethods.extract_from_ast(ast, "ace.ts")

      assert result["id"] == "ace"
      assert result["parse_method_count"] == 0
      assert result["parse_methods"] == %{}
    end

    test "returns nil when no exported class" do
      ast = %{body: [%{type: "ImportDeclaration", source: %{value: "foo"}}]}
      assert ParseMethods.extract_from_ast(ast, "not_a_class.ts") == nil
    end

    test "falls back to filename for class name when id is nil" do
      ast = %{
        body: [
          %{
            type: "ExportDefaultDeclaration",
            declaration: %{
              type: "ClassDeclaration",
              id: nil,
              body: %{body: [@parse_ticker]}
            }
          }
        ]
      }

      result = ParseMethods.extract_from_ast(ast, "anonymous.ts")
      assert result["id"] == "anonymous"
      assert result["class_name"] == nil
      assert result["parse_method_count"] == 1
    end

    test "extracts params with types via Methods helpers" do
      ast = mock_ast([@parse_ticker])
      result = ParseMethods.extract_from_ast(ast, "binance.ts")

      ticker = result["parse_methods"]["parseTicker"]
      params = ticker["params"]
      assert length(params) == 2
      assert Enum.at(params, 0)["name"] == "ticker"
      assert Enum.at(params, 0)["type"] == "Dict"
      assert Enum.at(params, 1)["name"] == "market"
      assert Enum.at(params, 1)["type"] == "Market"
    end

    test "extracts return type" do
      ast = mock_ast([@parse_ticker, @parse_trade])
      result = ParseMethods.extract_from_ast(ast, "binance.ts")

      assert result["parse_methods"]["parseTicker"]["return_type"] == "Ticker"
      assert result["parse_methods"]["parseTrade"]["return_type"] == nil
    end
  end

  describe "find_parse_methods/1" do
    test "finds all parse* methods, ignores others" do
      all = [@describe_method, @parse_ticker, @sign_method, @parse_order, @fetch_ticker_method, @parse_trade]
      result = ParseMethods.find_parse_methods(all)

      names = Enum.map(result, & &1.key.name)
      assert length(names) == 3
      assert "parseTicker" in names
      assert "parseOrder" in names
      assert "parseTrade" in names
      refute "describe" in names
      refute "sign" in names
      refute "fetchTicker" in names
    end

    test "returns empty list when no parse methods" do
      assert ParseMethods.find_parse_methods([@describe_method, @sign_method]) == []
    end

    test "returns empty list for empty class body" do
      assert ParseMethods.find_parse_methods([]) == []
    end
  end

  describe "MethodAST.extract/1" do
    test "returns nil for nil input" do
      assert CcxtExtract.MethodAST.extract(nil) == nil
    end

    test "extracts all fields from parseTicker" do
      result = CcxtExtract.MethodAST.extract(@parse_ticker)

      assert is_list(result["params"])
      assert length(result["params"]) == 2
      assert result["return_type"] == "Ticker"
      assert result["async"] == false
      assert result["statements"] == 3
      assert is_map(result["body"])
    end

    test "extracts all fields from parseOrder" do
      result = CcxtExtract.MethodAST.extract(@parse_order)

      assert result["return_type"] == "Order"
      assert result["statements"] == 2
    end

    test "body AST is the raw value.body node" do
      result = CcxtExtract.MethodAST.extract(@parse_ticker)

      body = result["body"]
      assert body.type == "FunctionBody"
      assert body.start == 5000
      assert body.end == 6000
      assert length(body.body) == 3
    end
  end

  describe "JSON round-trip" do
    test "atom keys become string keys at all nesting depths" do
      ast = mock_ast([@parse_ticker, @parse_order])
      exchange = ParseMethods.extract_from_ast(ast, "binance.ts")

      json = Jason.encode!(exchange)
      decoded = Jason.decode!(json)

      # Top level
      assert is_binary(decoded |> Map.keys() |> hd())
      # Parse methods map
      assert Map.has_key?(decoded["parse_methods"], "parseTicker")
      # Method data level
      ticker = decoded["parse_methods"]["parseTicker"]
      assert is_binary(ticker |> Map.keys() |> hd())
      # Body level — atom keys converted to strings
      assert ticker["body"]["type"] == "FunctionBody"
      # Nested statement
      first_stmt = hd(decoded["parse_methods"]["parseTicker"]["body"]["body"])
      assert is_binary(first_stmt |> Map.keys() |> hd())
    end
  end

  describe "Mix.Tasks.CcxtExtract.ParseMethods.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        ParseMethodsTask.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        ParseMethodsTask.run(["rest"])
      end
    end
  end
end
