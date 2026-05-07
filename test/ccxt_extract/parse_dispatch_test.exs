defmodule CcxtExtract.ParseDispatchTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ParseDispatch

  describe "derive/1 input handling" do
    test "returns nil on nil" do
      assert ParseDispatch.derive(nil) == nil
    end

    test "returns nil on non-list, non-nil" do
      assert ParseDispatch.derive(%{}) == nil
    end

    test "returns empty map on empty class body" do
      assert ParseDispatch.derive([]) == %{}
    end

    test "ignores non-MethodDefinition class members" do
      assert ParseDispatch.derive([%{"type" => "PropertyDefinition", "key" => %{"name" => "x"}}]) == %{}
    end
  end

  describe "string-keyed shape (post-normalize)" do
    test "captures a single this.parseTicker call" do
      class_body = [
        method_def("fetchTicker", [
          this_call("parseTicker", [])
        ])
      ]

      assert ParseDispatch.derive(class_body) == %{"fetchTicker" => ["parseTicker"]}
    end

    test "method without parse calls is omitted" do
      class_body = [
        method_def("fetchTicker", [this_call("parseTicker", [])]),
        method_def("setSandboxMode", [this_call("checkRequiredCredentials", [])])
      ]

      result = ParseDispatch.derive(class_body)
      assert Map.has_key?(result, "fetchTicker")
      refute Map.has_key?(result, "setSandboxMode")
    end

    test "ignores non-parse calls (e.g. parseTimeframe excluded? — included since it starts with parseT)" do
      # parseTimeframe DOES match the pattern (parse + uppercase); parseFloat
      # would too. The dispatch table records what's there — consumers can
      # filter further if they only want domain parsers.
      class_body = [
        method_def("fetchOHLCV", [
          this_call("parseTimeframe", []),
          this_call("parseOHLCVs", [])
        ])
      ]

      assert ParseDispatch.derive(class_body) == %{
               "fetchOHLCV" => ["parseOHLCVs", "parseTimeframe"]
             }
    end

    test "parse* with lowercase next char is NOT a parse helper (no dispatch)" do
      class_body = [
        method_def("foo", [this_call("parsefoo", [])])
      ]

      assert ParseDispatch.derive(class_body) == %{}
    end

    test "deduplicates and sorts parse calls" do
      class_body = [
        method_def("fetchOrders", [
          this_call("parseOrders", []),
          this_call("parseOrder", []),
          this_call("parseOrders", [])
        ])
      ]

      assert ParseDispatch.derive(class_body) == %{
               "fetchOrders" => ["parseOrder", "parseOrders"]
             }
    end

    test "calls without ThisExpression object are not dispatch entries" do
      # `parseTicker(x)` (bare call) and `obj.parseTicker(x)` (member but
      # not `this`) are both excluded — only `this.parse*()` counts.
      class_body = [
        method_def("foo", [
          %{
            "type" => "CallExpression",
            "callee" => %{"type" => "Identifier", "name" => "parseTicker"},
            "arguments" => []
          },
          %{
            "type" => "CallExpression",
            "callee" => %{
              "type" => "MemberExpression",
              "object" => %{"type" => "Identifier", "name" => "obj"},
              "property" => %{"type" => "Identifier", "name" => "parseTicker"}
            },
            "arguments" => []
          }
        ])
      ]

      assert ParseDispatch.derive(class_body) == %{}
    end
  end

  describe "atom-keyed shape (raw OXC)" do
    test "captures parse calls in raw atom-keyed AST" do
      class_body = [
        %{
          type: :method_definition,
          key: %{name: "fetchTicker"},
          value: %{
            body: %{
              body: [
                %{
                  type: :call_expression,
                  callee: %{
                    type: :member_expression,
                    object: %{type: :this_expression},
                    property: %{type: :identifier, name: "parseTicker"}
                  },
                  arguments: []
                }
              ]
            }
          }
        }
      ]

      assert ParseDispatch.derive(class_body) == %{"fetchTicker" => ["parseTicker"]}
    end
  end

  # --- Builders for string-keyed shape ---

  defp method_def(name, body_stmts) do
    %{
      "type" => "MethodDefinition",
      "key" => %{"name" => name},
      "value" => %{
        "body" => %{"type" => "BlockStatement", "body" => body_stmts}
      }
    }
  end

  defp this_call(name, args) do
    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => %{"type" => "ThisExpression"},
        "property" => %{"type" => "Identifier", "name" => name}
      },
      "arguments" => args
    }
  end
end
