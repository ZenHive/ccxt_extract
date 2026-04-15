defmodule CcxtExtract.MethodsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Methods

  describe "extract_method_details/1" do
    test "extracts basic method metadata" do
      method = %{
        type: :method_definition,
        key: %{name: "fetchTicker"},
        value: %{
          async: true,
          params: [
            %{type: :identifier, name: "symbol", typeAnnotation: nil}
          ],
          returnType: nil,
          body: %{body: [%{}, %{}, %{}]}
        }
      }

      result = Methods.extract_method_details(method)

      assert result["name"] == "fetchTicker"
      assert result["async"] == true
      assert result["statements"] == 3
      assert result["return_type"] == nil
      assert [%{"name" => "symbol", "type" => nil}] = result["params"]
    end

    test "extracts sync method with no params" do
      method = %{
        type: :method_definition,
        key: %{name: "describe"},
        value: %{
          async: false,
          params: [],
          returnType: nil,
          body: %{body: [%{}]}
        }
      }

      result = Methods.extract_method_details(method)

      assert result["name"] == "describe"
      assert result["async"] == false
      assert result["params"] == []
      assert result["statements"] == 1
    end
  end

  describe "extract_params/1" do
    test "extracts simple Identifier param" do
      params = [%{type: :identifier, name: "symbol", typeAnnotation: nil}]

      assert [%{"name" => "symbol", "type" => nil}] = Methods.extract_params(params)
    end

    test "extracts Identifier param with type annotation" do
      params = [
        %{
          type: :identifier,
          name: "symbol",
          typeAnnotation: %{
            typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "string"}}
          }
        }
      ]

      assert [%{"name" => "symbol", "type" => "string"}] = Methods.extract_params(params)
    end

    test "extracts AssignmentPattern param (default value)" do
      params = [
        %{
          type: :assignment_pattern,
          left: %{name: "params", typeAnnotation: nil},
          right: %{type: :object_expression, properties: []}
        }
      ]

      assert [%{"name" => "params", "type" => nil}] = Methods.extract_params(params)
    end

    test "extracts AssignmentPattern with type annotation on left" do
      params = [
        %{
          type: :assignment_pattern,
          left: %{
            name: "limit",
            typeAnnotation: %{
              typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "Int"}}
            }
          },
          right: %{type: :literal, value: nil}
        }
      ]

      assert [%{"name" => "limit", "type" => "Int"}] = Methods.extract_params(params)
    end

    test "extracts RestElement param" do
      params = [
        %{
          type: :rest_element,
          argument: %{name: "args", typeAnnotation: nil}
        }
      ]

      assert [%{"name" => "...args", "type" => nil}] = Methods.extract_params(params)
    end

    test "extracts ObjectPattern as destructured" do
      params = [
        %{
          type: :object_pattern,
          properties: [
            %{key: %{name: "a"}, value: %{name: "a"}},
            %{key: %{name: "b"}, value: %{name: "b"}}
          ]
        }
      ]

      assert [%{"name" => "{destructured}", "type" => nil}] = Methods.extract_params(params)
    end

    test "handles multiple params with mixed shapes" do
      params = [
        %{type: :identifier, name: "symbol", typeAnnotation: nil},
        %{
          type: :assignment_pattern,
          left: %{name: "since", typeAnnotation: nil},
          right: %{type: :literal, value: nil}
        },
        %{
          type: :assignment_pattern,
          left: %{name: "limit", typeAnnotation: nil},
          right: %{type: :literal, value: nil}
        },
        %{
          type: :assignment_pattern,
          left: %{name: "params", typeAnnotation: nil},
          right: %{type: :object_expression, properties: []}
        }
      ]

      result = Methods.extract_params(params)
      names = Enum.map(result, & &1["name"])
      assert names == ["symbol", "since", "limit", "params"]
    end

    test "returns empty list for no params" do
      assert Methods.extract_params([]) == []
    end

    test "handles unknown param type gracefully" do
      params = [%{type: :some_new_node_type}]

      assert [%{"name" => "?:SomeNewNodeType", "type" => nil}] = Methods.extract_params(params)
    end
  end

  describe "extract_return_type/1" do
    test "returns nil when no return type annotation" do
      function_node = %{returnType: nil, async: true, params: [], body: %{body: []}}
      assert Methods.extract_return_type(function_node) == nil
    end

    test "returns nil when returnType key is missing" do
      function_node = %{async: true, params: [], body: %{body: []}}
      assert Methods.extract_return_type(function_node) == nil
    end

    test "extracts TSTypeReference return type with generic params" do
      function_node = %{
        returnType: %{
          typeAnnotation: %{
            type: :ts_type_reference,
            typeName: %{name: "Promise"},
            typeArguments: %{
              type: :ts_type_parameter_instantiation,
              params: [
                %{type: :ts_type_reference, typeName: %{name: "Ticker"}, typeArguments: nil}
              ]
            }
          }
        }
      }

      assert Methods.extract_return_type(function_node) == "Promise<Ticker>"
    end

    test "extracts keyword return type (void)" do
      function_node = %{
        returnType: %{
          typeAnnotation: %{type: :ts_void_keyword}
        }
      }

      assert Methods.extract_return_type(function_node) == "void"
    end
  end

  describe "extract_type_name/1" do
    test "returns nil for nil" do
      assert Methods.extract_type_name(nil) == nil
    end

    test "extracts TSTypeReference name without generics" do
      node = %{type: :ts_type_reference, typeName: %{name: "Order"}, typeArguments: nil}
      assert Methods.extract_type_name(node) == "Order"
    end

    test "extracts TSTypeReference with single generic param" do
      node = %{
        type: :ts_type_reference,
        typeName: %{name: "Promise"},
        typeArguments: %{
          type: :ts_type_parameter_instantiation,
          params: [
            %{type: :ts_type_reference, typeName: %{name: "Ticker"}, typeArguments: nil}
          ]
        }
      }

      assert Methods.extract_type_name(node) == "Promise<Ticker>"
    end

    test "extracts TSTypeReference with multiple generic params" do
      node = %{
        type: :ts_type_reference,
        typeName: %{name: "Map"},
        typeArguments: %{
          type: :ts_type_parameter_instantiation,
          params: [
            %{type: :ts_string_keyword},
            %{type: :ts_type_reference, typeName: %{name: "Order"}, typeArguments: nil}
          ]
        }
      }

      assert Methods.extract_type_name(node) == "Map<string, Order>"
    end

    test "extracts nested generic types" do
      node = %{
        type: :ts_type_reference,
        typeName: %{name: "Promise"},
        typeArguments: %{
          type: :ts_type_parameter_instantiation,
          params: [
            %{
              type: :ts_type_reference,
              typeName: %{name: "Dictionary"},
              typeArguments: %{
                type: :ts_type_parameter_instantiation,
                params: [%{type: :ts_string_keyword}]
              }
            }
          ]
        }
      }

      assert Methods.extract_type_name(node) == "Promise<Dictionary<string>>"
    end

    test "extracts TSArrayType" do
      node = %{
        type: :ts_array_type,
        elementType: %{type: :ts_type_reference, typeName: %{name: "Trade"}}
      }

      assert Methods.extract_type_name(node) == "Trade[]"
    end

    test "extracts TSUnionType" do
      node = %{
        type: :ts_union_type,
        types: [
          %{type: :ts_string_keyword},
          %{type: :ts_undefined_keyword}
        ]
      }

      assert Methods.extract_type_name(node) == "string | undefined"
    end

    test "extracts keyword types" do
      assert Methods.extract_type_name(%{type: :ts_string_keyword}) == "string"
      assert Methods.extract_type_name(%{type: :ts_number_keyword}) == "number"
      assert Methods.extract_type_name(%{type: :ts_boolean_keyword}) == "boolean"
      assert Methods.extract_type_name(%{type: :ts_any_keyword}) == "any"
      assert Methods.extract_type_name(%{type: :ts_void_keyword}) == "void"
      assert Methods.extract_type_name(%{type: :ts_undefined_keyword}) == "undefined"
    end

    test "handles TSTypeReference without typeName.name" do
      node = %{type: :ts_type_reference, typeName: %{type: :ts_qualified_name}}
      assert Methods.extract_type_name(node) == "unknown"
    end
  end

  describe "extract_from_ast/2" do
    test "extracts exchange with methods" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{
              id: %{name: "testex"},
              superClass: %{name: "Exchange"},
              body: %{
                body: [
                  %{
                    type: :method_definition,
                    key: %{name: "describe"},
                    value: %{async: false, params: [], returnType: nil, body: %{body: [%{}]}}
                  },
                  %{
                    type: :method_definition,
                    key: %{name: "fetchTicker"},
                    value: %{
                      async: true,
                      params: [%{type: :identifier, name: "symbol", typeAnnotation: nil}],
                      returnType: nil,
                      body: %{body: [%{}, %{}]}
                    }
                  }
                ]
              }
            }
          }
        ]
      }

      result = Methods.extract_from_ast(ast, "testex.ts")

      assert result["id"] == "testex"
      assert result["class_name"] == "testex"
      assert result["file"] == "testex.ts"
      assert result["method_count"] == 2
      assert length(result["methods"]) == 2

      [describe, fetch_ticker] = result["methods"]
      assert describe["name"] == "describe"
      assert fetch_ticker["name"] == "fetchTicker"
      assert fetch_ticker["async"] == true
      assert [%{"name" => "symbol"}] = fetch_ticker["params"]
    end

    test "returns nil when no export default" do
      ast = %{body: [%{type: :import_declaration, source: %{value: "./foo.js"}, specifiers: []}]}
      assert Methods.extract_from_ast(ast, "util.ts") == nil
    end

    test "returns nil when export has no class body" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{type: :identifier, name: "foo"}
          }
        ]
      }

      assert Methods.extract_from_ast(ast, "foo.ts") == nil
    end

    test "uses filename as id when class is anonymous" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{
              id: nil,
              superClass: %{name: "Exchange"},
              body: %{body: []}
            }
          }
        ]
      }

      result = Methods.extract_from_ast(ast, "mystery.ts")
      assert result["id"] == "mystery"
      assert result["class_name"] == nil
    end

    test "skips non-MethodDefinition members" do
      ast = %{
        body: [
          %{
            type: :export_default_declaration,
            declaration: %{
              id: %{name: "testex"},
              superClass: %{name: "Exchange"},
              body: %{
                body: [
                  %{type: :property_definition, key: %{name: "prop"}},
                  %{
                    type: :method_definition,
                    key: %{name: "describe"},
                    value: %{async: false, params: [], returnType: nil, body: %{body: [%{}]}}
                  }
                ]
              }
            }
          }
        ]
      }

      result = Methods.extract_from_ast(ast, "testex.ts")
      assert result["method_count"] == 1
    end
  end

  describe "parse_file/1" do
    @tag :tmp_dir
    test "returns {:skip, filename} when file has no exported class", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "utils.ts")
      File.write!(path, "export function helper() { return 42; }")

      assert {:skip, "utils.ts"} = Methods.parse_file(path)
    end

    @tag :tmp_dir
    test "returns {:ok, exchange} for valid exchange file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "testex.ts")

      File.write!(path, """
      export default class testex extends Exchange {
        describe() { return {}; }
        async fetchTicker(symbol: string) { return {}; }
      }
      """)

      assert {:ok, exchange} = Methods.parse_file(path)
      assert exchange["id"] == "testex"
      assert exchange["method_count"] == 2

      ticker = Enum.find(exchange["methods"], &(&1["name"] == "fetchTicker"))
      assert ticker["async"] == true
      assert [%{"name" => "symbol", "type" => "string"}] = ticker["params"]
    end

    @tag :tmp_dir
    test "returns {:error, filename, reason} on parse failure", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "broken.ts")
      File.write!(path, <<0, 0, 0, 0>>)

      result = Methods.parse_file(path)

      case result do
        {:error, "broken.ts", _reason} -> :ok
        {:skip, "broken.ts"} -> :ok
        {:ok, _} -> flunk("Expected error or skip for null-byte file, got {:ok, ...}")
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "Mix.Tasks.CcxtExtract.Methods.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option\(s\): --typo/, fn ->
        Mix.Tasks.CcxtExtract.Methods.run(["--typo", "rest"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument\(s\): rest/, fn ->
        Mix.Tasks.CcxtExtract.Methods.run(["rest"])
      end
    end

    test "rejects invalid --type value" do
      assert_raise Mix.Error, ~r/Invalid --type/, fn ->
        Mix.Tasks.CcxtExtract.Methods.run(["--type", "invalid"])
      end
    end
  end
end
