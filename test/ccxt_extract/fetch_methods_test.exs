defmodule CcxtExtract.FetchMethodsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.FetchMethods
  alias Mix.Tasks.CcxtExtract.FetchMethods, as: FetchMethodsTask

  # Mock fetch methods with different signatures and return types
  @fetch_trades %{
    type: :method_definition,
    key: %{name: "fetchTrades"},
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
            name: "since",
            typeAnnotation: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "Int"}}}
          },
          right: %{type: :identifier, name: "undefined"}
        }
      ],
      returnType: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "Promise"}}},
      body: %{
        type: :function_body,
        body: [
          %{type: :variable_declaration},
          %{type: :variable_declaration},
          %{type: :expression_statement},
          %{type: :return_statement, argument: %{type: :call_expression}}
        ],
        start: 5000,
        end: 6000
      }
    }
  }

  @fetch_ticker %{
    type: :method_definition,
    key: %{name: "fetchTicker"},
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
          right: %{type: :identifier, name: "undefined"}
        }
      ],
      returnType: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "Ticker"}}},
      body: %{
        type: :function_body,
        body: [
          %{type: :variable_declaration},
          %{type: :return_statement}
        ],
        start: 7000,
        end: 8000
      }
    }
  }

  @fetch_ohlcv %{
    type: :method_definition,
    key: %{name: "fetchOHLCV"},
    value: %{
      async: true,
      params: [
        %{type: :identifier, name: "symbol", typeAnnotation: nil},
        %{
          type: :assignment_pattern,
          left: %{name: "timeframe", typeAnnotation: nil},
          right: %{type: :literal, value: "1m"}
        }
      ],
      returnType: nil,
      body: %{
        type: :function_body,
        body: [%{type: :return_statement}],
        start: 9000,
        end: 9500
      }
    }
  }

  # Non-fetch methods
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

  @sign_method %{
    type: :method_definition,
    key: %{name: "sign"},
    value: %{
      async: false,
      params: [%{type: :identifier, name: "path", typeAnnotation: nil}],
      returnType: nil,
      body: %{body: [%{type: :return_statement}]}
    }
  }

  @parse_ticker_method %{
    type: :method_definition,
    key: %{name: "parseTicker"},
    value: %{
      async: false,
      params: [%{type: :identifier, name: "ticker", typeAnnotation: nil}],
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
            superClass: %{name: "Exchange"},
            body: %{body: methods}
          }
        }
      ]
    }
  end

  describe "extract_from_ast/2" do
    test "extracts multiple fetch methods" do
      ast = mock_ast([@describe_method, @fetch_trades, @sign_method, @fetch_ticker, @fetch_ohlcv])
      result = FetchMethods.extract_from_ast(ast, "binance.ts")

      assert result["id"] == "binance"
      assert result["class_name"] == "binance"
      assert result["file"] == "binance.ts"
      assert result["fetch_method_count"] == 3
      assert Map.has_key?(result["fetch_methods"], "fetchTrades")
      assert Map.has_key?(result["fetch_methods"], "fetchTicker")
      assert Map.has_key?(result["fetch_methods"], "fetchOHLCV")
    end

    test "returns empty map when no fetch methods present" do
      ast = mock_ast([@describe_method, @sign_method, @parse_ticker_method], "ace")
      result = FetchMethods.extract_from_ast(ast, "ace.ts")

      assert result["id"] == "ace"
      assert result["fetch_method_count"] == 0
      assert result["fetch_methods"] == %{}
    end

    test "returns nil when no exported class" do
      ast = %{body: [%{type: :import_declaration, source: %{value: "foo"}}]}
      assert FetchMethods.extract_from_ast(ast, "not_a_class.ts") == nil
    end

    test "falls back to filename for class name when id is nil" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{
              type: :class_declaration,
              id: nil,
              body: %{body: [@fetch_trades]}
            }
          }
        ]
      }

      result = FetchMethods.extract_from_ast(ast, "anonymous.ts")
      assert result["id"] == "anonymous"
      assert result["class_name"] == nil
      assert result["fetch_method_count"] == 1
    end

    test "extracts params with types via Methods helpers" do
      ast = mock_ast([@fetch_trades])
      result = FetchMethods.extract_from_ast(ast, "binance.ts")

      trades = result["fetch_methods"]["fetchTrades"]
      params = trades["params"]
      assert length(params) == 2
      assert Enum.at(params, 0)["name"] == "symbol"
      assert Enum.at(params, 0)["type"] == "string"
      assert Enum.at(params, 1)["name"] == "since"
      assert Enum.at(params, 1)["type"] == "Int"
    end

    test "extracts return type" do
      ast = mock_ast([@fetch_trades, @fetch_ohlcv])
      result = FetchMethods.extract_from_ast(ast, "binance.ts")

      assert result["fetch_methods"]["fetchTrades"]["return_type"] == "Promise"
      assert result["fetch_methods"]["fetchOHLCV"]["return_type"] == nil
    end

    test "extracts async flag" do
      ast = mock_ast([@fetch_trades])
      result = FetchMethods.extract_from_ast(ast, "binance.ts")

      assert result["fetch_methods"]["fetchTrades"]["async"] == true
    end
  end

  describe "find_fetch_methods/1" do
    test "finds all fetch* methods, ignores others" do
      all = [@describe_method, @fetch_trades, @sign_method, @fetch_ticker, @parse_ticker_method, @fetch_ohlcv]
      result = FetchMethods.find_fetch_methods(all)

      names = Enum.map(result, & &1.key.name)
      assert length(names) == 3
      assert "fetchTrades" in names
      assert "fetchTicker" in names
      assert "fetchOHLCV" in names
      refute "describe" in names
      refute "sign" in names
      refute "parseTicker" in names
    end

    test "returns empty list when no fetch methods" do
      assert FetchMethods.find_fetch_methods([@describe_method, @sign_method]) == []
    end

    test "returns empty list for empty class body" do
      assert FetchMethods.find_fetch_methods([]) == []
    end
  end

  describe "MethodAST.extract/1 via fetch methods" do
    test "extracts all fields from fetchTrades" do
      result = CcxtExtract.MethodAST.extract(@fetch_trades)

      assert is_list(result["params"])
      assert length(result["params"]) == 2
      assert result["return_type"] == "Promise"
      assert result["async"] == true
      assert result["statements"] == 4
      assert is_map(result["body"])
    end

    test "extracts all fields from fetchTicker" do
      result = CcxtExtract.MethodAST.extract(@fetch_ticker)

      assert result["return_type"] == "Ticker"
      assert result["statements"] == 2
    end

    test "body AST is the raw value.body node" do
      result = CcxtExtract.MethodAST.extract(@fetch_trades)

      body = result["body"]
      assert body.type == "FunctionBody"
      assert body.start == 5000
      assert body.end == 6000
      assert length(body.body) == 4
    end
  end

  describe "JSON round-trip" do
    test "atom keys become string keys at all nesting depths" do
      ast = mock_ast([@fetch_trades, @fetch_ticker])
      exchange = FetchMethods.extract_from_ast(ast, "binance.ts")

      json = Jason.encode!(exchange)
      decoded = Jason.decode!(json)

      # Top level
      assert is_binary(decoded |> Map.keys() |> hd())
      # Fetch methods map
      assert Map.has_key?(decoded["fetch_methods"], "fetchTrades")
      # Method data level
      trades = decoded["fetch_methods"]["fetchTrades"]
      assert is_binary(trades |> Map.keys() |> hd())
      # Body level — atom keys converted to strings
      assert trades["body"]["type"] == "FunctionBody"
      # Nested statement
      first_stmt = hd(decoded["fetch_methods"]["fetchTrades"]["body"]["body"])
      assert is_binary(first_stmt |> Map.keys() |> hd())
    end
  end

  describe "write_stats/1" do
    test "counts exchanges with fetch methods" do
      exchanges = [
        %{"fetch_method_count" => 5},
        %{"fetch_method_count" => 0},
        %{"fetch_method_count" => 12}
      ]

      stats = FetchMethods.write_stats(exchanges)
      assert stats["with_fetch_methods"] == 2
      assert stats["total_methods"] == 17
    end

    test "returns zero counts for empty list" do
      stats = FetchMethods.write_stats([])
      assert stats["with_fetch_methods"] == 0
      assert stats["total_methods"] == 0
    end

    test "returns zero counts when all exchanges have no fetch methods" do
      exchanges = [%{"fetch_method_count" => 0}, %{"fetch_method_count" => 0}]
      stats = FetchMethods.write_stats(exchanges)
      assert stats["with_fetch_methods"] == 0
      assert stats["total_methods"] == 0
    end
  end

  describe "Mix.Tasks.CcxtExtract.FetchMethods.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        FetchMethodsTask.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        FetchMethodsTask.run(["rest"])
      end
    end
  end
end
