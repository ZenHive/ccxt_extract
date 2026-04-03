defmodule CcxtExtract.BaseMethodsTest do
  @moduledoc """
  Tests for BaseMethods extraction from the base Exchange.ts class.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.BaseMethods

  describe "extract_from_ast/1" do
    test "extracts parse and safe methods and field assignments, filters others" do
      ast =
        wrap_class([
          method_node("parseOrder", false, [param("order", "Dict")], "Order"),
          method_node("safeString", false, [param("obj", nil), param("key", "IndexType")], "Str"),
          property_node("safeValue"),
          property_node("parseDate"),
          property_node("uuid"),
          method_node("fetchTicker", true, [param("symbol", "string")], "Ticker"),
          method_node("describe", false, [], nil)
        ])

      result = BaseMethods.extract_from_ast(ast)

      # 2 MethodDefinitions + 2 PropertyDefinitions matching parse*/safe*
      assert map_size(result) == 4
      assert Map.has_key?(result, "parseOrder")
      assert Map.has_key?(result, "safeString")
      assert Map.has_key?(result, "safeValue")
      assert Map.has_key?(result, "parseDate")
      refute Map.has_key?(result, "uuid")
      refute Map.has_key?(result, "fetchTicker")
      refute Map.has_key?(result, "describe")

      # Verify source field distinguishes the two types
      assert result["parseOrder"]["source"] == "method_definition"
      assert result["safeValue"]["source"] == "field_assignment"
    end

    test "field assignments have empty params and nil return_type" do
      ast = wrap_class([property_node("safeValue")])

      result = BaseMethods.extract_from_ast(ast)

      assert result["safeValue"] == %{
               "name" => "safeValue",
               "category" => "safe",
               "params" => [],
               "return_type" => nil,
               "async" => false,
               "source" => "field_assignment"
             }
    end

    test "returns empty map when no class found" do
      ast = %{body: [%{type: "ImportDeclaration", source: %{value: "foo"}}]}
      assert BaseMethods.extract_from_ast(ast) == %{}
    end
  end

  describe "method data extraction via extract_from_ast/1" do
    test "extracts parse method with params and return type" do
      ast =
        wrap_class([
          method_node("parseTrade", false, [param("trade", "Dict"), param("market", "Market")], "Trade")
        ])

      result = BaseMethods.extract_from_ast(ast)

      assert result["parseTrade"] == %{
               "name" => "parseTrade",
               "category" => "parse",
               "params" => [%{"name" => "trade", "type" => "Dict"}, %{"name" => "market", "type" => "Market"}],
               "return_type" => "Trade",
               "async" => false,
               "source" => "method_definition"
             }
    end

    test "extracts safe method" do
      ast =
        wrap_class([
          method_node("safeNumber", false, [param("obj", nil), param("key", "IndexType")], "Num")
        ])

      result = BaseMethods.extract_from_ast(ast)

      assert result["safeNumber"]["name"] == "safeNumber"
      assert result["safeNumber"]["category"] == "safe"
      assert result["safeNumber"]["async"] == false
    end

    test "captures async flag" do
      ast = wrap_class([method_node("parseAsync", true, [], nil)])

      result = BaseMethods.extract_from_ast(ast)
      assert result["parseAsync"]["async"] == true
    end

    test "method with no params has empty param list" do
      ast = wrap_class([method_node("safeTimestamp", false, [], nil)])

      result = BaseMethods.extract_from_ast(ast)
      assert result["safeTimestamp"]["params"] == []
      assert result["safeTimestamp"]["return_type"] == nil
    end

    test "method with complex return type (array)" do
      ast =
        wrap_class([
          method_node("parseOHLCVs", false, [param("ohlcvs", "object[]")], "OHLCV[]")
        ])

      result = BaseMethods.extract_from_ast(ast)
      assert result["parseOHLCVs"]["return_type"] == "OHLCV[]"

      param = Enum.find(result["parseOHLCVs"]["params"], &(&1["name"] == "ohlcvs"))
      assert param["type"] == "object[]"
    end

    test "by_category counts sum to total method count" do
      ast =
        wrap_class([
          method_node("parseTrade", false, [], nil),
          method_node("parseOrder", false, [], nil),
          method_node("safeString", false, [], nil),
          property_node("safeValue")
        ])

      result = BaseMethods.extract_from_ast(ast)
      by_category = count_by_category(result)

      assert by_category["parse"] == 2
      assert by_category["safe"] == 2
      assert by_category["parse"] + by_category["safe"] == map_size(result)
    end
  end

  describe "extract/0" do
    @tag :extraction
    test "extracts methods from real Exchange.ts" do
      {:ok, result} = BaseMethods.extract()

      assert result["source_file"] == "base/Exchange.ts"
      assert result["method_count"] > 80
      assert is_map(result["by_category"])
      assert result["by_category"]["parse"] > 50
      assert result["by_category"]["safe"] > 20

      methods = result["methods"]
      assert is_map(methods)

      # Spot-check known MethodDefinition methods
      assert Map.has_key?(methods, "parseOrder")
      assert methods["parseOrder"]["category"] == "parse"
      assert methods["parseOrder"]["return_type"] == "Order"
      assert methods["parseOrder"]["source"] == "method_definition"

      assert Map.has_key?(methods, "safeNumber")
      assert methods["safeNumber"]["category"] == "safe"

      # Spot-check known PropertyDefinition field assignments
      assert Map.has_key?(methods, "safeValue")
      assert methods["safeValue"]["source"] == "field_assignment"
      assert methods["safeValue"]["params"] == []

      assert Map.has_key?(methods, "parseDate")
      assert methods["parseDate"]["source"] == "field_assignment"

      # All methods have required keys
      for {_name, method} <- methods do
        assert is_binary(method["name"])
        assert method["category"] in ["parse", "safe"]
        assert is_list(method["params"])
        assert is_boolean(method["async"])
        assert Map.has_key?(method, "return_type")
        assert method["source"] in ["method_definition", "field_assignment"]
      end
    end
  end

  # --- AST Node Builders ---

  # Wrap class members in an ExportDefaultDeclaration AST envelope
  defp wrap_class(members) do
    %{
      body: [
        %{
          type: "ExportDefaultDeclaration",
          declaration: %{
            type: "ClassDeclaration",
            id: %{name: "Exchange"},
            superClass: nil,
            body: %{body: members}
          }
        }
      ]
    }
  end

  # Build a PropertyDefinition node (class field assignment like `safeValue = safeValue;`)
  defp property_node(name) do
    %{
      type: "PropertyDefinition",
      key: %{name: name, type: "Identifier"},
      value: %{name: name, type: "Identifier"},
      static: false,
      computed: false,
      typeAnnotation: nil
    }
  end

  defp method_node(name, async, params, return_type) do
    %{
      type: "MethodDefinition",
      key: %{name: name},
      value: %{
        type: "FunctionExpression",
        async: async,
        params: params,
        body: %{body: []},
        returnType: build_return_type(return_type)
      }
    }
  end

  defp param(name, nil) do
    %{type: "Identifier", name: name, optional: false, typeAnnotation: nil, decorators: []}
  end

  defp param(name, type_name) do
    %{
      type: "Identifier",
      name: name,
      optional: false,
      typeAnnotation: %{
        type: "TSTypeAnnotation",
        typeAnnotation: %{
          type: "TSTypeReference",
          typeName: %{name: type_name, type: "Identifier", optional: false, typeAnnotation: nil, decorators: []},
          typeArguments: nil
        }
      },
      decorators: []
    }
  end

  defp build_return_type(nil), do: nil

  defp build_return_type(type_name) do
    %{
      type: "TSTypeAnnotation",
      typeAnnotation: %{
        type: "TSTypeReference",
        typeName: %{name: type_name, type: "Identifier", optional: false, typeAnnotation: nil, decorators: []},
        typeArguments: nil
      }
    }
  end

  # Count methods per category (helper for tests)
  defp count_by_category(methods) do
    methods
    |> Map.values()
    |> Enum.group_by(& &1["category"])
    |> Map.new(fn {cat, list} -> {cat, length(list)} end)
  end
end
