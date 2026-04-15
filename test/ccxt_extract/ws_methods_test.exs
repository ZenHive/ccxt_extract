defmodule CcxtExtract.WsMethodsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.WsMethods
  alias Mix.Tasks.CcxtExtract.WsMethods, as: WsMethodsTask

  # Mock watch methods (async, subscribe to WS channels)
  @watch_ticker %{
    type: :method_definition,
    key: %{name: "watchTicker"},
    value: %{
      async: true,
      params: [
        %{
          type: :identifier,
          name: "symbol",
          typeAnnotation: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "string"}}}
        },
        %{
          type: :assignment_pattern,
          left: %{
            name: "params",
            typeAnnotation: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "object"}}}
          },
          right: %{type: :object_expression, properties: []}
        }
      ],
      returnType: %{
        typeAnnotation: %{
          type: :ts_type_reference,
          typeName: %{name: "Promise"},
          typeArguments: %{params: [%{type: :ts_type_reference, typeName: %{name: "Ticker"}}]}
        }
      },
      body: %{
        type: :function_body,
        body: [
          %{type: :variable_declaration},
          %{type: :expression_statement},
          %{type: :return_statement, argument: %{type: :call_expression}}
        ],
        start: 1000,
        end: 2000
      }
    }
  }

  @watch_balance %{
    type: :method_definition,
    key: %{name: "watchBalance"},
    value: %{
      async: true,
      params: [
        %{
          type: :assignment_pattern,
          left: %{
            name: "params",
            typeAnnotation: nil
          },
          right: %{type: :object_expression, properties: []}
        }
      ],
      returnType: %{
        typeAnnotation: %{
          type: :ts_type_reference,
          typeName: %{name: "Promise"},
          typeArguments: %{params: [%{type: :ts_type_reference, typeName: %{name: "Balances"}}]}
        }
      },
      body: %{
        type: :function_body,
        body: [
          %{type: :expression_statement},
          %{type: :return_statement}
        ],
        start: 3000,
        end: 4000
      }
    }
  }

  # Mock handle methods (sync, process incoming WS messages)
  @handle_ticker %{
    type: :method_definition,
    key: %{name: "handleTicker"},
    value: %{
      async: false,
      params: [
        %{
          type: :identifier,
          name: "client",
          typeAnnotation: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "Client"}}}
        },
        %{type: :identifier, name: "message", typeAnnotation: nil}
      ],
      returnType: nil,
      body: %{
        type: :function_body,
        body: [
          %{type: :variable_declaration},
          %{type: :expression_statement},
          %{type: :expression_statement},
          %{type: :expression_statement}
        ],
        start: 5000,
        end: 6000
      }
    }
  }

  @handle_balance_ws %{
    type: :method_definition,
    key: %{name: "handleBalanceWs"},
    value: %{
      async: false,
      params: [
        %{
          type: :identifier,
          name: "client",
          typeAnnotation: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "Client"}}}
        },
        %{type: :identifier, name: "message", typeAnnotation: nil}
      ],
      returnType: nil,
      body: %{
        type: :function_body,
        body: [%{type: :expression_statement}],
        start: 7000,
        end: 7500
      }
    }
  }

  # Non-WS methods (should be filtered out)
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
      body: %{body: [%{type: :return_statement}]}
    }
  }

  @parse_ticker_method %{
    type: :method_definition,
    key: %{name: "parseTicker"},
    value: %{
      async: false,
      params: [%{type: :identifier, name: "data", typeAnnotation: nil}],
      returnType: nil,
      body: %{body: [%{type: :return_statement}]}
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
            superClass: %{name: "binanceRest"},
            body: %{body: methods}
          }
        }
      ]
    }
  end

  describe "extract_from_ast/2" do
    test "extracts both watch and handle methods" do
      ast = mock_ast([@describe_method, @watch_ticker, @handle_ticker, @watch_balance, @handle_balance_ws])
      result = WsMethods.extract_from_ast(ast, "binance.ts")

      assert result["id"] == "binance"
      assert result["class_name"] == "binance"
      assert result["file"] == "binance.ts"
      assert result["ws_method_count"] == 4
      assert Map.has_key?(result["ws_methods"], "watchTicker")
      assert Map.has_key?(result["ws_methods"], "watchBalance")
      assert Map.has_key?(result["ws_methods"], "handleTicker")
      assert Map.has_key?(result["ws_methods"], "handleBalanceWs")
    end

    test "excludes non-WS methods (fetch*, parse*, describe, etc.)" do
      ast = mock_ast([@describe_method, @fetch_ticker_method, @parse_ticker_method, @watch_ticker])
      result = WsMethods.extract_from_ast(ast, "binance.ts")

      assert result["ws_method_count"] == 1
      assert Map.keys(result["ws_methods"]) == ["watchTicker"]
    end

    test "returns empty map when no WS methods present" do
      ast = mock_ast([@describe_method, @fetch_ticker_method], "ace")
      result = WsMethods.extract_from_ast(ast, "ace.ts")

      assert result["id"] == "ace"
      assert result["ws_method_count"] == 0
      assert result["ws_methods"] == %{}
    end

    test "returns nil when no exported class" do
      ast = %{body: [%{type: :import_declaration, source: %{value: "foo"}}]}
      assert WsMethods.extract_from_ast(ast, "not_a_class.ts") == nil
    end

    test "falls back to filename for class name when id is nil" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{
              type: :class_declaration,
              id: nil,
              body: %{body: [@watch_ticker]}
            }
          }
        ]
      }

      result = WsMethods.extract_from_ast(ast, "anonymous.ts")
      assert result["id"] == "anonymous"
      assert result["class_name"] == nil
      assert result["ws_method_count"] == 1
    end

    test "watch methods have async: true" do
      ast = mock_ast([@watch_ticker])
      result = WsMethods.extract_from_ast(ast, "binance.ts")

      assert result["ws_methods"]["watchTicker"]["async"] == true
    end

    test "handle methods have async: false" do
      ast = mock_ast([@handle_ticker])
      result = WsMethods.extract_from_ast(ast, "binance.ts")

      assert result["ws_methods"]["handleTicker"]["async"] == false
    end

    test "extracts params with types via Methods helpers" do
      ast = mock_ast([@watch_ticker])
      result = WsMethods.extract_from_ast(ast, "binance.ts")

      params = result["ws_methods"]["watchTicker"]["params"]
      assert length(params) == 2
      assert Enum.at(params, 0)["name"] == "symbol"
      assert Enum.at(params, 0)["type"] == "string"
      assert Enum.at(params, 1)["name"] == "params"
    end

    test "extracts return type from watch method" do
      ast = mock_ast([@watch_ticker, @handle_ticker])
      result = WsMethods.extract_from_ast(ast, "binance.ts")

      assert result["ws_methods"]["watchTicker"]["return_type"] == "Promise<Ticker>"
      assert result["ws_methods"]["handleTicker"]["return_type"] == nil
    end
  end

  describe "find_ws_methods/1" do
    test "finds watch and handle methods, ignores others" do
      all = [
        @describe_method,
        @watch_ticker,
        @fetch_ticker_method,
        @handle_ticker,
        @parse_ticker_method,
        @watch_balance,
        @handle_balance_ws
      ]

      result = WsMethods.find_ws_methods(all)
      names = Enum.map(result, & &1.key.name)

      assert length(names) == 4
      assert "watchTicker" in names
      assert "watchBalance" in names
      assert "handleTicker" in names
      assert "handleBalanceWs" in names
      refute "describe" in names
      refute "fetchTicker" in names
      refute "parseTicker" in names
    end

    test "finds only watch methods when no handle methods" do
      result = WsMethods.find_ws_methods([@watch_ticker, @watch_balance, @describe_method])
      names = Enum.map(result, & &1.key.name)

      assert length(names) == 2
      assert "watchTicker" in names
      assert "watchBalance" in names
    end

    test "finds only handle methods when no watch methods" do
      result = WsMethods.find_ws_methods([@handle_ticker, @handle_balance_ws, @describe_method])
      names = Enum.map(result, & &1.key.name)

      assert length(names) == 2
      assert "handleTicker" in names
      assert "handleBalanceWs" in names
    end

    test "returns empty list when no WS methods" do
      assert WsMethods.find_ws_methods([@describe_method, @fetch_ticker_method]) == []
    end

    test "returns empty list for empty class body" do
      assert WsMethods.find_ws_methods([]) == []
    end
  end

  describe "MethodAST.extract/1" do
    test "returns nil for nil input" do
      assert CcxtExtract.MethodAST.extract(nil) == nil
    end

    test "extracts all fields from watchTicker" do
      result = CcxtExtract.MethodAST.extract(@watch_ticker)

      assert is_list(result["params"])
      assert length(result["params"]) == 2
      assert result["return_type"] == "Promise<Ticker>"
      assert result["async"] == true
      assert result["statements"] == 3
      assert is_map(result["body"])
    end

    test "extracts all fields from handleTicker" do
      result = CcxtExtract.MethodAST.extract(@handle_ticker)

      assert is_list(result["params"])
      assert length(result["params"]) == 2
      assert result["return_type"] == nil
      assert result["async"] == false
      assert result["statements"] == 4
      assert is_map(result["body"])
    end

    test "body AST is the raw value.body node" do
      result = CcxtExtract.MethodAST.extract(@watch_ticker)

      body = result["body"]
      assert body.type == "FunctionBody"
      assert body.start == 1000
      assert body.end == 2000
      assert length(body.body) == 3
    end
  end

  describe "JSON round-trip" do
    test "atom keys become string keys at all nesting depths" do
      ast = mock_ast([@watch_ticker, @handle_ticker])
      exchange = WsMethods.extract_from_ast(ast, "binance.ts")

      json = Jason.encode!(exchange)
      decoded = Jason.decode!(json)

      # Top level
      assert is_binary(decoded |> Map.keys() |> hd())
      # WS methods map
      assert Map.has_key?(decoded["ws_methods"], "watchTicker")
      assert Map.has_key?(decoded["ws_methods"], "handleTicker")
      # Method data level
      ticker = decoded["ws_methods"]["watchTicker"]
      assert is_binary(ticker |> Map.keys() |> hd())
      # Body level — atom keys converted to strings
      assert ticker["body"]["type"] == "FunctionBody"
      # Nested statement
      first_stmt = hd(decoded["ws_methods"]["watchTicker"]["body"]["body"])
      assert is_binary(first_stmt |> Map.keys() |> hd())
    end
  end

  describe "Mix.Tasks.CcxtExtract.WsMethods.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        WsMethodsTask.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        WsMethodsTask.run(["rest"])
      end
    end
  end
end
