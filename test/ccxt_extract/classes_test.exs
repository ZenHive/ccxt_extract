defmodule CcxtExtract.ClassesTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Classes

  describe "build_tree/1" do
    test "groups children under their parent by node_key/parent_key" do
      classes = [
        %{"node_key" => "rest:binance", "parent_key" => "Exchange"},
        %{"node_key" => "rest:bybit", "parent_key" => "Exchange"},
        %{"node_key" => "rest:binanceus", "parent_key" => "rest:binance"},
        %{"node_key" => "ws:binance", "parent_key" => "rest:binance"}
      ]

      tree = Classes.build_tree(classes)

      assert tree["Exchange"] == ["rest:binance", "rest:bybit"]
      assert tree["rest:binance"] == ["rest:binanceus", "ws:binance"]
    end

    test "returns empty map for empty list" do
      assert Classes.build_tree([]) == %{}
    end

    test "skips classes with nil parent_key" do
      classes = [
        %{"node_key" => "rest:Exchange", "parent_key" => nil},
        %{"node_key" => "rest:binance", "parent_key" => "Exchange"}
      ]

      tree = Classes.build_tree(classes)
      assert tree == %{"Exchange" => ["rest:binance"]}
    end

    test "sorts children alphabetically" do
      classes = [
        %{"node_key" => "rest:zonda", "parent_key" => "Exchange"},
        %{"node_key" => "rest:alpaca", "parent_key" => "Exchange"},
        %{"node_key" => "rest:mexc", "parent_key" => "Exchange"}
      ]

      assert Classes.build_tree(classes)["Exchange"] == ["rest:alpaca", "rest:mexc", "rest:zonda"]
    end

    test "deduplicates children" do
      classes = [
        %{"node_key" => "rest:binance", "parent_key" => "Exchange"},
        %{"node_key" => "rest:binance", "parent_key" => "Exchange"}
      ]

      assert Classes.build_tree(classes)["Exchange"] == ["rest:binance"]
    end
  end

  describe "find_ws_counterparts/1" do
    test "finds exchanges with both REST and WS implementations" do
      classes = [
        %{"id" => "binance", "type" => "rest"},
        %{"id" => "binance", "type" => "ws"},
        %{"id" => "bybit", "type" => "rest"},
        %{"id" => "bybit", "type" => "ws"},
        %{"id" => "luno", "type" => "rest"}
      ]

      assert Classes.find_ws_counterparts(classes) == ["binance", "bybit"]
    end

    test "returns empty list when no counterparts" do
      classes = [
        %{"id" => "binance", "type" => "rest"},
        %{"id" => "bybit", "type" => "ws"}
      ]

      assert Classes.find_ws_counterparts(classes) == []
    end

    test "returns empty list for empty input" do
      assert Classes.find_ws_counterparts([]) == []
    end
  end

  describe "build_import_aliases/2" do
    test "resolves ../ imports as REST parent" do
      ast = %{
        body: [
          %{
            type: "ImportDeclaration",
            source: %{value: "../binance.js"},
            specifiers: [
              %{type: "ImportDefaultSpecifier", local: %{name: "binanceRest"}}
            ]
          }
        ]
      }

      aliases = Classes.build_import_aliases(ast, "ws")
      assert aliases["binanceRest"] == {"binance", "rest"}
    end

    test "resolves ./ imports as same type (WS in WS context)" do
      ast = %{
        body: [
          %{
            type: "ImportDeclaration",
            source: %{value: "./binance.js"},
            specifiers: [
              %{type: "ImportDefaultSpecifier", local: %{name: "binance"}}
            ]
          }
        ]
      }

      aliases = Classes.build_import_aliases(ast, "ws")
      assert aliases["binance"] == {"binance", "ws"}
    end

    test "resolves ./ imports as same type (REST in REST context)" do
      ast = %{
        body: [
          %{
            type: "ImportDeclaration",
            source: %{value: "./binance.js"},
            specifiers: [
              %{type: "ImportDefaultSpecifier", local: %{name: "binance"}}
            ]
          }
        ]
      }

      aliases = Classes.build_import_aliases(ast, "rest")
      assert aliases["binance"] == {"binance", "rest"}
    end

    test "skips non-default import specifiers" do
      ast = %{
        body: [
          %{
            type: "ImportDeclaration",
            source: %{value: "../base/errors.js"},
            specifiers: [
              %{type: "ImportSpecifier", local: %{name: "BadRequest"}, imported: %{name: "BadRequest"}}
            ]
          }
        ]
      }

      aliases = Classes.build_import_aliases(ast, "ws")
      assert aliases == %{}
    end

    test "returns empty map for no imports" do
      ast = %{body: [%{type: "ClassDeclaration"}]}
      assert Classes.build_import_aliases(ast, "rest") == %{}
    end
  end

  describe "extract_class/4" do
    test "extracts class with resolved extends" do
      ast = %{
        body: [
          %{
            type: "ExportDefaultDeclaration",
            declaration: %{
              id: %{name: "binance"},
              superClass: %{name: "Exchange"},
              body: %{
                body: [
                  %{
                    type: "MethodDefinition",
                    key: %{name: "describe"},
                    value: %{async: false, params: [], body: %{body: [%{}, %{}]}}
                  },
                  %{
                    type: "MethodDefinition",
                    key: %{name: "fetchTicker"},
                    value: %{async: true, params: [%{name: "symbol"}], body: %{body: [%{}]}}
                  }
                ]
              }
            }
          }
        ]
      }

      result = Classes.extract_class(ast, "binance.ts", "rest", %{})

      assert result["id"] == "binance"
      assert result["node_key"] == "rest:binance"
      assert result["class_name"] == "binance"
      assert result["extends_raw"] == "Exchange"
      assert result["extends_resolved"] == "Exchange"
      assert result["parent_key"] == "Exchange"
      assert result["type"] == "rest"
      assert result["file"] == "binance.ts"
      assert result["methods"] == ["describe", "fetchTicker"]
      assert result["method_count"] == 2

      [describe, fetch_ticker] = result["method_details"]
      assert describe["name"] == "describe"
      assert describe["async"] == false
      assert describe["params"] == 0
      assert describe["statements"] == 2

      assert fetch_ticker["name"] == "fetchTicker"
      assert fetch_ticker["async"] == true
      assert fetch_ticker["params"] == 1
      assert fetch_ticker["statements"] == 1
    end

    test "resolves WS alias to REST parent" do
      ast = %{
        body: [
          %{
            type: "ExportDefaultDeclaration",
            declaration: %{
              id: %{name: "binance"},
              superClass: %{name: "binanceRest"},
              body: %{body: []}
            }
          }
        ]
      }

      aliases = %{"binanceRest" => {"binance", "rest"}}
      result = Classes.extract_class(ast, "binance.ts", "ws", aliases)

      assert result["node_key"] == "ws:binance"
      assert result["extends_raw"] == "binanceRest"
      assert result["extends_resolved"] == "binance"
      assert result["parent_key"] == "rest:binance"
    end

    test "returns nil when no export default" do
      ast = %{body: [%{type: "ImportDeclaration", source: %{value: "./foo.js"}, specifiers: []}]}
      assert Classes.extract_class(ast, "util.ts", "rest", %{}) == nil
    end

    test "returns nil when export has no class body" do
      ast = %{
        body: [
          %{
            type: "ExportDefaultDeclaration",
            declaration: %{type: "Identifier", name: "foo"}
          }
        ]
      }

      assert Classes.extract_class(ast, "foo.ts", "rest", %{}) == nil
    end

    test "handles class with no superclass" do
      ast = %{
        body: [
          %{
            type: "ExportDefaultDeclaration",
            declaration: %{
              id: %{name: "Base"},
              superClass: nil,
              body: %{body: []}
            }
          }
        ]
      }

      result = Classes.extract_class(ast, "base.ts", "rest", %{})
      assert result["extends_raw"] == nil
      assert result["extends_resolved"] == nil
      assert result["parent_key"] == nil
      assert result["class_name"] == "Base"
    end

    test "handles anonymous class using filename as id" do
      ast = %{
        body: [
          %{
            type: "ExportDefaultDeclaration",
            declaration: %{
              id: nil,
              superClass: %{name: "Exchange"},
              body: %{body: []}
            }
          }
        ]
      }

      result = Classes.extract_class(ast, "mystery.ts", "ws", %{})
      assert result["id"] == "mystery"
      assert result["node_key"] == "ws:mystery"
      assert result["class_name"] == nil
      assert result["type"] == "ws"
    end
  end

  describe "extract_methods/1" do
    test "filters only MethodDefinition nodes" do
      members = [
        %{type: "MethodDefinition", key: %{name: "foo"}, value: %{async: false, params: [], body: %{body: []}}},
        %{type: "PropertyDefinition", key: %{name: "bar"}},
        %{type: "MethodDefinition", key: %{name: "baz"}, value: %{async: true, params: [%{}], body: %{body: [%{}]}}}
      ]

      methods = Classes.extract_methods(members)
      assert length(methods) == 2
      assert Enum.map(methods, & &1["name"]) == ["foo", "baz"]
    end

    test "returns empty list for no methods" do
      assert Classes.extract_methods([]) == []
    end
  end
end
