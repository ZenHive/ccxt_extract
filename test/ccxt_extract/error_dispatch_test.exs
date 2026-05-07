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
                 "predicate_kind" => "http_status_in",
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

      assert [%{"predicate_kind" => "http_status_in", "predicate_values" => ["418", "429"]}] =
               ErrorDispatch.derive(method)
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

  defp binop(left, op, right) when is_binary(left), do: binop(ident(left), op, right)

  defp binop(left, op, right), do: %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right}

  defp logop(op, left, right), do: %{"type" => "LogicalExpression", "operator" => op, "left" => left, "right" => right}

  defp paren(expr), do: %{"type" => "ParenthesizedExpression", "expression" => expr}

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
