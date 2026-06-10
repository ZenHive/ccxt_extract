defmodule CcxtExtract.ErrorDispatchTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ErrorDispatch

  describe "derive/1 input handling" do
    test "returns nil on nil input" do
      assert ErrorDispatch.derive(nil) == nil
    end

    test "returns nil on a map without body" do
      assert ErrorDispatch.derive(%{"params" => []}) == nil
    end

    test "returns empty list on body with no throws" do
      method = %{"body" => %{"type" => "BlockStatement", "body" => []}}
      assert ErrorDispatch.derive(method) == []
    end

    test "returns nil on non-map non-nil input" do
      assert ErrorDispatch.derive("string") == nil
    end
  end

  describe "literal throw extraction" do
    test "captures unconditional throw at top of body" do
      # throw new ExchangeError ('boom')
      method = %{
        "body" => %{
          "type" => "BlockStatement",
          "body" => [throw_new("ExchangeError")]
        }
      }

      assert [
               %{
                 "exception_class" => "ExchangeError",
                 "predicate_raw" => nil,
                 "predicate_kind" => "other",
                 "predicate_values" => nil
               }
             ] = ErrorDispatch.derive(method)
    end

    test "captures throw nested in if with code === literal" do
      # if (code === 418) { throw new DDoSProtection ('limited') }
      method = %{
        "body" => %{
          "type" => "BlockStatement",
          "body" => [
            if_throw(binop("code", "===", lit(418)), "DDoSProtection")
          ]
        }
      }

      assert [
               %{
                 "exception_class" => "DDoSProtection",
                 "predicate_kind" => "http_status_eq",
                 "predicate_values" => ["418"]
               }
             ] = ErrorDispatch.derive(method)
    end

    test "captures || disjunction of code comparisons" do
      # if ((code === 418) || (code === 429)) { throw ... }
      pred =
        logop(
          "||",
          paren(binop("code", "===", lit(418))),
          paren(binop("code", "===", lit(429)))
        )

      method = %{
        "body" => %{
          "type" => "BlockStatement",
          "body" => [if_throw(pred, "DDoSProtection")]
        }
      }

      assert [%{"predicate_kind" => "http_status_eq", "predicate_values" => ["418", "429"]}] =
               ErrorDispatch.derive(method)
    end

    test "captures parenthesized reversed code comparisons" do
      method = method_with_throw(paren(binop(lit(429), "===", ident("code"))), "RateLimitExceeded")

      assert [
               %{
                 "predicate_raw" => "(429 === code)",
                 "predicate_kind" => "http_status_eq",
                 "predicate_values" => ["429"]
               }
             ] = ErrorDispatch.derive(method)
    end

    test "captures code range comparisons separately from exact status checks" do
      method = method_with_throw(binop("code", ">=", lit(500)), "ExchangeNotAvailable")

      assert [
               %{
                 "predicate_raw" => "code >= 500",
                 "predicate_kind" => "http_status_range",
                 "predicate_values" => ["500"]
               }
             ] = ErrorDispatch.derive(method)
    end

    test "captures body.indexOf literal as body_contains" do
      pred =
        binop(
          %{
            "type" => "CallExpression",
            "callee" => %{
              "type" => "MemberExpression",
              "object" => ident("body"),
              "property" => ident("indexOf"),
              "computed" => false
            },
            "arguments" => [lit("LOT_SIZE")]
          },
          ">=",
          lit(0)
        )

      method = %{
        "body" => %{
          "type" => "BlockStatement",
          "body" => [if_throw(pred, "InvalidOrder")]
        }
      }

      assert [%{"predicate_kind" => "body_contains", "predicate_values" => ["LOT_SIZE"]}] =
               ErrorDispatch.derive(method)
    end

    test "captures body.indexOf greater than minus one as body_contains" do
      method =
        method_with_throw(
          binop(index_of("message", "busy"), ">", unary("-", lit(1))),
          "ExchangeNotAvailable"
        )

      assert [
               %{
                 "predicate_raw" => "message.indexOf('busy') > -1",
                 "predicate_kind" => "body_contains",
                 "predicate_values" => ["busy"]
               }
             ] = ErrorDispatch.derive(method)
    end

    test "captures || disjunction of body.indexOf predicates" do
      pred =
        logop(
          "||",
          binop(index_of("body", "A"), ">=", lit(0)),
          paren(binop(index_of("reason", "B"), ">", unary("-", lit(1))))
        )

      method = method_with_throw(pred, "BadResponse")

      assert [
               %{
                 "predicate_kind" => "body_contains",
                 "predicate_values" => ["A", "B"]
               }
             ] = ErrorDispatch.derive(method)
    end

    test "captures bare identifier truthy checks" do
      method = method_with_throw(ident("code"), "ExchangeError")

      assert [%{"predicate_kind" => "identifier_check", "predicate_values" => nil}] =
               ErrorDispatch.derive(method)
    end

    test "captures identifier literal equality checks" do
      method = method_with_throw(binop(ident("status"), "===", lit("error")), "ExchangeError")

      assert [%{"predicate_kind" => "identifier_check", "predicate_values" => nil}] =
               ErrorDispatch.derive(method)
    end

    test "captures literal identifier equality checks" do
      method = method_with_throw(binop(lit("error"), "===", ident("status")), "ExchangeError")

      assert [%{"predicate_kind" => "identifier_check", "predicate_values" => nil}] =
               ErrorDispatch.derive(method)
    end

    test "falls back to other for unclassified predicates" do
      pred =
        binop(
          %{"type" => "MemberExpression", "object" => ident("response"), "property" => lit("status"), "computed" => true},
          "===",
          lit(nil)
        )

      method = method_with_throw(pred, "ExchangeError")

      assert [
               %{
                 "predicate_raw" => "response['status'] === null",
                 "predicate_kind" => "other",
                 "predicate_values" => nil
               }
             ] = ErrorDispatch.derive(method)
    end

    test "renders unknown AST shapes in raw predicates" do
      method = method_with_throw(binop(%{"type" => "Mystery"}, "===", %{}), "ExchangeError")

      assert [
               %{
                 "predicate_raw" => "<Mystery> === <unknown>",
                 "predicate_kind" => "other"
               }
             ] = ErrorDispatch.derive(method)
    end

    test "skips throw of non-NewExpression argument" do
      # `throw e` (rethrow) — not a NewExpression callee, so skip
      method = %{
        "body" => %{
          "type" => "BlockStatement",
          "body" => [
            %{"type" => "ThrowStatement", "argument" => ident("e")}
          ]
        }
      }

      assert ErrorDispatch.derive(method) == []
    end

    test "skips throw when NewExpression callee is not an identifier" do
      method = %{
        "body" => %{
          "type" => "BlockStatement",
          "body" => [
            %{
              "type" => "ThrowStatement",
              "argument" => %{
                "type" => "NewExpression",
                "callee" => %{
                  "type" => "MemberExpression",
                  "object" => ident("errors"),
                  "property" => ident("ExchangeError"),
                  "computed" => false
                },
                "arguments" => []
              }
            }
          ]
        }
      }

      assert ErrorDispatch.derive(method) == []
    end

    test "renders nested if-test chain joined with &&" do
      # if (code >= 400) { if (body.indexOf('LOT_SIZE') >= 0) { throw } }
      inner_pred =
        binop(
          %{
            "type" => "CallExpression",
            "callee" => %{
              "type" => "MemberExpression",
              "object" => ident("body"),
              "property" => ident("indexOf"),
              "computed" => false
            },
            "arguments" => [lit("LOT_SIZE")]
          },
          ">=",
          lit(0)
        )

      outer_pred = binop("code", ">=", lit(400))
      throw_stmt = if_throw(inner_pred, "InvalidOrder")

      method = %{
        "body" => %{
          "type" => "BlockStatement",
          "body" => [
            %{
              "type" => "IfStatement",
              "test" => outer_pred,
              "consequent" => %{
                "type" => "BlockStatement",
                "body" => [throw_stmt]
              }
            }
          ]
        }
      }

      assert [
               %{
                 "exception_class" => "InvalidOrder",
                 "predicate_raw" => raw,
                 "predicate_kind" => "body_contains"
               }
             ] = ErrorDispatch.derive(method)

      assert raw =~ "code >= 400"
      assert raw =~ "LOT_SIZE"
      assert raw =~ "&&"
    end
  end

  # --- AST builders ---

  defp ident(name), do: %{"type" => "Identifier", "name" => name}
  defp lit(v), do: %{"type" => "Literal", "value" => v}
  defp unary(op, arg), do: %{"type" => "UnaryExpression", "operator" => op, "argument" => arg}

  defp binop(left, op, right) when is_binary(left), do: binop(ident(left), op, right)

  defp binop(left, op, right), do: %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right}

  defp logop(op, left, right), do: %{"type" => "LogicalExpression", "operator" => op, "left" => left, "right" => right}

  defp paren(expr), do: %{"type" => "ParenthesizedExpression", "expression" => expr}

  defp index_of(object, value) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => ident(object),
        "property" => ident("indexOf"),
        "computed" => false
      },
      "arguments" => [lit(value)]
    }
  end

  defp throw_new(class) do
    %{
      "type" => "ThrowStatement",
      "argument" => %{
        "type" => "NewExpression",
        "callee" => ident(class),
        "arguments" => []
      }
    }
  end

  defp method_with_throw(pred, class) do
    %{
      "body" => %{
        "type" => "BlockStatement",
        "body" => [if_throw(pred, class)]
      }
    }
  end

  defp if_throw(pred, class) do
    %{
      "type" => "IfStatement",
      "test" => pred,
      "consequent" => %{
        "type" => "BlockStatement",
        "body" => [throw_new(class)]
      }
    }
  end
end
