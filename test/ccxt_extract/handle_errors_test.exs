defmodule CcxtExtract.HandleErrorsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ErrorDispatch
  alias CcxtExtract.HandleErrors
  alias Mix.Tasks.CcxtExtract.HandleErrors, as: HandleErrorsTask

  # Mock AST for a class with a handleErrors() method
  @handle_errors_method %{
    type: :method_definition,
    key: %{name: "handleErrors"},
    value: %{
      async: false,
      params: [
        %{type: :identifier, name: "code", typeAnnotation: nil},
        %{type: :identifier, name: "reason", typeAnnotation: nil},
        %{type: :identifier, name: "url", typeAnnotation: nil},
        %{type: :identifier, name: "method", typeAnnotation: nil},
        %{type: :identifier, name: "headers", typeAnnotation: nil},
        %{type: :identifier, name: "body", typeAnnotation: nil},
        %{type: :identifier, name: "response", typeAnnotation: nil},
        %{type: :identifier, name: "requestHeaders", typeAnnotation: nil},
        %{type: :identifier, name: "requestBody", typeAnnotation: nil}
      ],
      returnType: nil,
      body: %{
        type: :function_body,
        body: [
          %{type: :if_statement, test: %{type: :binary_expression}},
          %{type: :variable_declaration, declarations: [%{type: :variable_declarator}]},
          %{type: :if_statement, test: %{type: :call_expression}},
          %{type: :return_statement, argument: nil}
        ],
        start: 5000,
        end: 6000
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
    test "extracts handleErrors method when present" do
      ast = mock_ast([@describe_method, @handle_errors_method, @sign_method])
      result = HandleErrors.extract_from_ast(ast, "binance.ts")

      assert result["id"] == "binance"
      assert result["class_name"] == "binance"
      assert result["file"] == "binance.ts"
      assert result["handle_errors"]
      assert result["handle_errors"]["statements"] == 4
      assert result["handle_errors"]["async"] == false
    end

    test "returns handle_errors as nil when method absent" do
      ast = mock_ast([@describe_method, @sign_method], "ace")
      result = HandleErrors.extract_from_ast(ast, "ace.ts")

      assert result["id"] == "ace"
      assert result["handle_errors"] == nil
    end

    test "returns nil when no exported class" do
      ast = %{body: [%{type: :import_declaration, source: %{value: "foo"}}]}
      assert HandleErrors.extract_from_ast(ast, "not_a_class.ts") == nil
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

      result = HandleErrors.extract_from_ast(ast, "anonymous.ts")
      assert result["id"] == "anonymous"
      assert result["class_name"] == nil
    end

    test "extracts handleErrors params via Methods helpers" do
      ast = mock_ast([@handle_errors_method])
      result = HandleErrors.extract_from_ast(ast, "binance.ts")

      params = result["handle_errors"]["params"]
      assert length(params) == 9
      assert Enum.at(params, 0)["name"] == "code"
      assert Enum.at(params, 6)["name"] == "response"
    end

    test "includes exceptions fields (nil when no describe file)" do
      ast = mock_ast([@handle_errors_method])
      result = HandleErrors.extract_from_ast(ast, "binance.ts")

      # extract_from_ast calls load_describe_exceptions which may or may not find files
      assert Map.has_key?(result, "exceptions")
      assert Map.has_key?(result, "http_exceptions")
    end
  end

  describe "find_handle_errors_method/1" do
    test "finds handleErrors among multiple methods" do
      result =
        HandleErrors.find_handle_errors_method([
          @describe_method,
          @handle_errors_method,
          @sign_method
        ])

      assert result.key.name == "handleErrors"
    end

    test "returns nil when handleErrors is absent" do
      assert HandleErrors.find_handle_errors_method([@describe_method, @sign_method]) == nil
    end

    test "returns nil for empty class body" do
      assert HandleErrors.find_handle_errors_method([]) == nil
    end
  end

  describe "MethodAST.extract/1" do
    test "returns nil for nil input" do
      assert CcxtExtract.MethodAST.extract(nil) == nil
    end

    test "extracts params, return_type, async, statements, and body" do
      result = CcxtExtract.MethodAST.extract(@handle_errors_method)

      assert is_list(result["params"])
      assert length(result["params"]) == 9
      assert result["return_type"] == nil
      assert result["async"] == false
      assert result["statements"] == 4
      assert is_map(result["body"])
    end

    test "body AST is the raw value.body node" do
      result = CcxtExtract.MethodAST.extract(@handle_errors_method)

      body = result["body"]
      assert body.type == "FunctionBody"
      assert body.start == 5000
      assert body.end == 6000
      assert length(body.body) == 4
    end
  end

  describe "load_describe_exceptions/1" do
    @tag :tmp_dir
    test "returns {nil, nil} when describe file missing", %{tmp_dir: _tmp_dir} do
      # Uses a non-existent exchange id — no describe file will exist
      assert HandleErrors.load_describe_exceptions("nonexistent_exchange_zzz") == {nil, nil}
    end
  end

  describe "JSON round-trip" do
    test "atom keys become string keys at all nesting depths" do
      ast = mock_ast([@handle_errors_method])
      exchange = HandleErrors.extract_from_ast(ast, "binance.ts")

      json = Jason.encode!(exchange)
      decoded = Jason.decode!(json)

      # Top level
      assert is_binary(decoded |> Map.keys() |> hd())
      # handle_errors level
      assert is_binary(decoded["handle_errors"] |> Map.keys() |> hd())
      # Body level — atom keys converted to strings
      assert decoded["handle_errors"]["body"]["type"] == "FunctionBody"
      # Nested statement
      first_stmt = hd(decoded["handle_errors"]["body"]["body"])
      assert is_binary(first_stmt |> Map.keys() |> hd())
    end
  end

  describe "http_status_map/1" do
    test "returns nil for nil input" do
      assert HandleErrors.http_status_map(nil) == nil
    end

    test "returns nil when both channels empty AND http_exceptions is nil" do
      handle_errors = %{"method" => nil, "http_exceptions" => nil, "exceptions" => nil}
      assert HandleErrors.http_status_map(handle_errors) == nil
    end

    test "projects describe.httpExceptions with normalized class names" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => %{"429" => "__function:RateLimitExceeded", "404" => "BadRequest"},
        "exceptions" => nil
      }

      result = HandleErrors.http_status_map(handle_errors)

      assert result == %{
               "429" => [%{"class" => "RateLimitExceeded", "source" => "http_exceptions"}],
               "404" => [%{"class" => "BadRequest", "source" => "http_exceptions"}]
             }
    end

    test "honest empty map when http_exceptions is an empty map and method has no throws" do
      handle_errors = %{"method" => %{"body" => %{"body" => []}}, "http_exceptions" => %{}, "exceptions" => nil}
      assert HandleErrors.http_status_map(handle_errors) == %{}
    end

    test "merges throw_dispatch_predicate entries from error_dispatch http_status_eq" do
      # ESTree fragment: if (code === 418) throw new DDoSProtection('msg')
      method = %{
        "body" => %{
          "body" => [
            %{
              "type" => "IfStatement",
              "test" => %{
                "type" => "BinaryExpression",
                "operator" => "===",
                "left" => %{"type" => "Identifier", "name" => "code"},
                "right" => %{"type" => "Literal", "value" => 418}
              },
              "consequent" => %{
                "type" => "BlockStatement",
                "body" => [
                  %{
                    "type" => "ThrowStatement",
                    "argument" => %{
                      "type" => "NewExpression",
                      "callee" => %{"type" => "Identifier", "name" => "DDoSProtection"},
                      "arguments" => []
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      handle_errors = %{"method" => method, "http_exceptions" => %{"418" => "DDoSProtection"}, "exceptions" => nil}
      # Thread precomputed dispatch (the optimized path exercised by Pipeline)
      dispatch = ErrorDispatch.derive(method)
      result = HandleErrors.http_status_map(handle_errors, dispatch)

      entries = result["418"]
      assert is_list(entries)
      assert %{"class" => "DDoSProtection", "source" => "http_exceptions"} in entries
      assert %{"class" => "DDoSProtection", "source" => "throw_dispatch_predicate"} in entries
      assert length(entries) == 2
    end

    test "deduplicates identical {class, source} entries within a status" do
      method = %{
        "body" => %{
          "body" => [
            %{
              "type" => "IfStatement",
              "test" => %{
                "type" => "LogicalExpression",
                "operator" => "||",
                "left" => %{
                  "type" => "BinaryExpression",
                  "operator" => "===",
                  "left" => %{"type" => "Identifier", "name" => "code"},
                  "right" => %{"type" => "Literal", "value" => 429}
                },
                "right" => %{
                  "type" => "BinaryExpression",
                  "operator" => "===",
                  "left" => %{"type" => "Identifier", "name" => "code"},
                  "right" => %{"type" => "Literal", "value" => 429}
                }
              },
              "consequent" => %{
                "type" => "BlockStatement",
                "body" => [
                  %{
                    "type" => "ThrowStatement",
                    "argument" => %{
                      "type" => "NewExpression",
                      "callee" => %{"type" => "Identifier", "name" => "RateLimitExceeded"},
                      "arguments" => []
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      handle_errors = %{"method" => method, "http_exceptions" => nil, "exceptions" => nil}

      # Both 1-arity (derive inside) and 2-arity (precomputed) produce identical output
      dispatch = ErrorDispatch.derive(method)
      assert HandleErrors.http_status_map(handle_errors) == %{
               "429" => [%{"class" => "RateLimitExceeded", "source" => "throw_dispatch_predicate"}]
             }

      assert HandleErrors.http_status_map(handle_errors, dispatch) == %{
               "429" => [%{"class" => "RateLimitExceeded", "source" => "throw_dispatch_predicate"}]
             }
    end

    test "does not project range predicates as exact status-map keys" do
      method = %{
        "body" => %{
          "body" => [
            %{
              "type" => "IfStatement",
              "test" => %{
                "type" => "BinaryExpression",
                "operator" => ">=",
                "left" => %{"type" => "Identifier", "name" => "code"},
                "right" => %{"type" => "Literal", "value" => 500}
              },
              "consequent" => %{
                "type" => "BlockStatement",
                "body" => [
                  %{
                    "type" => "ThrowStatement",
                    "argument" => %{
                      "type" => "NewExpression",
                      "callee" => %{"type" => "Identifier", "name" => "ExchangeNotAvailable"},
                      "arguments" => []
                    }
                  }
                ]
              }
            }
          ]
        }
      }

      handle_errors = %{"method" => method, "http_exceptions" => nil, "exceptions" => nil}

      assert HandleErrors.http_status_map(handle_errors) == %{}
    end
  end

  describe "retryable_buckets/1" do
    test "returns nil for nil input" do
      assert HandleErrors.retryable_buckets(nil) == nil
    end

    test "constant five-bucket shape even when no classes are referenced" do
      handle_errors = %{"method" => nil, "http_exceptions" => nil, "exceptions" => nil}

      result = HandleErrors.retryable_buckets(handle_errors)

      assert result == %{
               "rate_limit" => [],
               "auth" => [],
               "server_busy" => [],
               "network" => [],
               "non_retryable" => []
             }
    end

    test "buckets classes from http_exceptions" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => %{
          "429" => "RateLimitExceeded",
          "401" => "AuthenticationError",
          "503" => "ExchangeNotAvailable"
        },
        "exceptions" => nil
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert result["rate_limit"] == ["RateLimitExceeded"]
      assert result["auth"] == ["AuthenticationError"]
      assert result["server_busy"] == ["ExchangeNotAvailable"]
      assert result["non_retryable"] == []
    end

    test "buckets classes from exceptions broad/exact tables" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => nil,
        "exceptions" => %{
          "exact" => %{"INVALID_ORDER" => "InvalidOrder", "BAD_KEY" => "AuthenticationError"},
          "broad" => %{"DDoS" => "DDoSProtection"}
        }
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert "InvalidOrder" in result["non_retryable"]
      assert "AuthenticationError" in result["auth"]
      assert "DDoSProtection" in result["rate_limit"]
    end

    test "strips QuickBEAM `__function:` sentinel prefix" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => %{"429" => "__function:RateLimitExceeded"},
        "exceptions" => %{"exact" => %{"X" => "__function:InvalidOrder"}}
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert "RateLimitExceeded" in result["rate_limit"]
      assert "InvalidOrder" in result["non_retryable"]
      refute Enum.any?(result["non_retryable"], &String.starts_with?(&1, "__function:"))
    end

    test "unknown classes fall into non_retryable" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => %{"418" => "BinanceCustomError"},
        "exceptions" => nil
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert "BinanceCustomError" in result["non_retryable"]
    end

    test "lists are sorted and unique within each bucket" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => %{
          "429" => "RateLimitExceeded",
          "418" => "DDoSProtection",
          "529" => "RateLimitExceeded"
        },
        "exceptions" => %{"exact" => %{"X" => "DDoSProtection"}}
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert result["rate_limit"] == ["DDoSProtection", "RateLimitExceeded"]
    end

    test "buckets classes from precomputed error_dispatch (threaded path)" do
      # Minimal method AST that yields two throws for different buckets
      method = %{
        "body" => %{
          "body" => [
            %{
              "type" => "IfStatement",
              "test" => %{"type" => "Identifier", "name" => "foo"},
              "consequent" => %{
                "type" => "BlockStatement",
                "body" => [
                  %{
                    "type" => "ThrowStatement",
                    "argument" => %{
                      "type" => "NewExpression",
                      "callee" => %{"type" => "Identifier", "name" => "DDoSProtection"}
                    }
                  }
                ]
              }
            },
            %{
              "type" => "ThrowStatement",
              "argument" => %{
                "type" => "NewExpression",
                "callee" => %{"type" => "Identifier", "name" => "AuthenticationError"}
              }
            }
          ]
        }
      }

      handle_errors = %{"method" => method, "http_exceptions" => nil, "exceptions" => nil}
      dispatch = ErrorDispatch.derive(method)
      # Sanity: derive produced the two classes
      assert length(dispatch) == 2

      # Threaded path (dispatch precomputed) and 1-arity path agree
      result_threaded = HandleErrors.retryable_buckets(handle_errors, dispatch)
      result_derive = HandleErrors.retryable_buckets(handle_errors)

      assert result_threaded == result_derive
      assert "DDoSProtection" in result_threaded["rate_limit"]
      assert "AuthenticationError" in result_threaded["auth"]
    end

    test "recurses into market-type-nested exceptions (binance / bybit / okx variants)" do
      # Three-level shape used by binance USDM, bybit linear/inverse, and okx variants:
      # %{"<market-type>" => %{"exact" | "broad" => %{<code> => <class>}}}
      # The flat 2-level walk would miss every class here.
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => nil,
        "exceptions" => %{
          "linear" => %{
            "exact" => %{"110001" => "InvalidOrder"},
            "broad" => %{"timeout" => "RequestTimeout"}
          },
          "spot" => %{
            "exact" => %{"AUTH-1001" => "AuthenticationError"}
          }
        }
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert "InvalidOrder" in result["non_retryable"]
      assert "RequestTimeout" in result["network"]
      assert "AuthenticationError" in result["auth"]
    end

    test "recurses through arbitrarily-deep nested maps" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => nil,
        "exceptions" => %{
          "a" => %{"b" => %{"c" => %{"d" => "DDoSProtection"}}}
        }
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert "DDoSProtection" in result["rate_limit"]
    end

    test "non-string leaves are skipped (numbers, booleans, nil)" do
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => nil,
        "exceptions" => %{
          "exact" => %{
            "code1" => "InvalidOrder",
            "code2" => 42,
            "code3" => true,
            "code4" => nil
          }
        }
      }

      result = HandleErrors.retryable_buckets(handle_errors)

      assert "InvalidOrder" in result["non_retryable"]
      # No surprise classes from non-string leaves
      total_classes = result |> Map.values() |> List.flatten() |> length()
      assert total_classes == 1
    end
  end

  describe "http_status_map/1 — non-numeric httpExceptions keys" do
    test "filters out non-numeric httpExceptions keys (schema constraint ^[0-9]+$)" do
      # If describe().httpExceptions ships a non-numeric key, it must NOT
      # leak into error_status_map (would violate the v3/v4 schema's
      # ^[0-9]+$ propertyNames constraint).
      handle_errors = %{
        "method" => nil,
        "http_exceptions" => %{
          "429" => "RateLimitExceeded",
          "API0005" => "ExchangeError",
          "non-numeric" => "BadRequest"
        }
      }

      result = HandleErrors.http_status_map(handle_errors)

      assert Map.has_key?(result, "429")
      refute Map.has_key?(result, "API0005")
      refute Map.has_key?(result, "non-numeric")
    end
  end

  describe "Mix.Tasks.CcxtExtract.HandleErrors.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        HandleErrorsTask.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        HandleErrorsTask.run(["rest"])
      end
    end
  end
end
