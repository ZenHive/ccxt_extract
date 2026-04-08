defmodule CcxtExtract.OverridesTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Overrides
  alias Mix.Tasks.CcxtExtract.Overrides, as: OverridesTask

  # --- Mock method definitions ---

  @describe_method %{
    type: "MethodDefinition",
    key: %{name: "describe"},
    value: %{
      async: false,
      params: [],
      returnType: %{
        typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "any"}}
      },
      body: %{
        type: "FunctionBody",
        body: [%{type: "ReturnStatement"}],
        start: 100,
        end: 200
      }
    }
  }

  @sign_method %{
    type: "MethodDefinition",
    key: %{name: "sign"},
    value: %{
      async: false,
      params: [
        %{type: "Identifier", name: "path", typeAnnotation: nil},
        %{type: "Identifier", name: "api", typeAnnotation: nil}
      ],
      returnType: nil,
      body: %{
        type: "FunctionBody",
        body: [%{type: "VariableDeclaration"}, %{type: "ReturnStatement"}],
        start: 300,
        end: 500
      }
    }
  }

  @fetch_ticker_method %{
    type: "MethodDefinition",
    key: %{name: "fetchTicker"},
    value: %{
      async: true,
      params: [
        %{
          type: "Identifier",
          name: "symbol",
          typeAnnotation: %{typeAnnotation: %{type: "TSTypeReference", typeName: %{name: "string"}}}
        }
      ],
      returnType: %{
        typeAnnotation: %{
          type: "TSTypeReference",
          typeName: %{name: "Promise"},
          typeArguments: %{params: [%{type: "TSTypeReference", typeName: %{name: "Ticker"}}]}
        }
      },
      body: %{
        type: "FunctionBody",
        body: [%{type: "ExpressionStatement"}, %{type: "ReturnStatement"}],
        start: 600,
        end: 800
      }
    }
  }

  # --- Helper to build mock class maps (as in class_hierarchy.json) ---

  defp mock_class(id, type, parent_key, methods) do
    %{
      "id" => id,
      "node_key" => "#{type}:#{id}",
      "class_name" => id,
      "extends_resolved" => parent_key_to_id(parent_key),
      "parent_key" => parent_key,
      "type" => type,
      "file" => "#{id}.ts",
      "methods" => methods,
      "method_count" => length(methods)
    }
  end

  defp parent_key_to_id("Exchange"), do: "Exchange"
  defp parent_key_to_id(pk), do: pk |> String.split(":") |> List.last()

  describe "build_ancestor_methods/2" do
    test "base class extending Exchange has only own methods" do
      classes = [
        mock_class("binance", "rest", "Exchange", ["describe", "sign", "fetchTicker"])
      ]

      by_node_key = Map.new(classes, &{&1["node_key"], &1})
      result = Overrides.build_ancestor_methods(classes, by_node_key)

      assert MapSet.equal?(
               result["rest:binance"],
               MapSet.new(["describe", "sign", "fetchTicker"])
             )
    end

    test "child accumulates parent methods" do
      classes = [
        mock_class("binance", "rest", "Exchange", ["describe", "sign", "fetchTicker"]),
        mock_class("binanceus", "rest", "rest:binance", ["describe"])
      ]

      by_node_key = Map.new(classes, &{&1["node_key"], &1})
      result = Overrides.build_ancestor_methods(classes, by_node_key)

      # binanceus accumulated = own (describe) + parent (describe, sign, fetchTicker)
      assert MapSet.equal?(
               result["rest:binanceus"],
               MapSet.new(["describe", "sign", "fetchTicker"])
             )
    end

    test "multi-level chain accumulates through all ancestors" do
      classes = [
        mock_class("binance", "rest", "Exchange", ["describe", "sign", "fetchTicker"]),
        mock_class("binance", "ws", "rest:binance", ["describe", "watchTicker"]),
        mock_class("binancecoinm", "ws", "ws:binance", ["describe"])
      ]

      by_node_key = Map.new(classes, &{&1["node_key"], &1})
      result = Overrides.build_ancestor_methods(classes, by_node_key)

      # ws:binancecoinm accumulated = own + ws:binance + rest:binance
      assert MapSet.equal?(
               result["ws:binancecoinm"],
               MapSet.new(["describe", "sign", "fetchTicker", "watchTicker"])
             )
    end

    test "missing parent is handled gracefully" do
      classes = [
        mock_class("orphan", "rest", "rest:nonexistent", ["describe"])
      ]

      by_node_key = Map.new(classes, &{&1["node_key"], &1})
      result = Overrides.build_ancestor_methods(classes, by_node_key)

      # Missing parent treated as empty, so accumulated = just own
      assert MapSet.equal?(result["rest:orphan"], MapSet.new(["describe"]))
    end

    test "circular reference does not infinite loop" do
      # Artificial circular case — should not happen in CCXT but must be safe
      classes = [
        mock_class("a", "rest", "rest:b", ["methodA"]),
        mock_class("b", "rest", "rest:a", ["methodB"])
      ]

      by_node_key = Map.new(classes, &{&1["node_key"], &1})

      # Should complete without hanging
      result = Overrides.build_ancestor_methods(classes, by_node_key)
      assert is_map(result)
    end
  end

  describe "MethodAST.extract/1" do
    test "returns nil for nil input" do
      assert CcxtExtract.MethodAST.extract(nil) == nil
    end

    test "extracts all fields from a method" do
      result = CcxtExtract.MethodAST.extract(@describe_method)

      assert result["async"] == false
      assert result["params"] == []
      assert result["return_type"] == "any"
      assert result["statements"] == 1
      assert is_map(result["body"])
    end

    test "extracts params with types via Methods helpers" do
      result = CcxtExtract.MethodAST.extract(@fetch_ticker_method)

      assert length(result["params"]) == 1
      assert Enum.at(result["params"], 0)["name"] == "symbol"
      assert Enum.at(result["params"], 0)["type"] == "string"
      assert result["return_type"] == "Promise<Ticker>"
      assert result["async"] == true
    end

    test "body AST preserves raw node" do
      result = CcxtExtract.MethodAST.extract(@sign_method)

      assert result["body"].type == "FunctionBody"
      assert result["body"].start == 300
      assert result["body"].end == 500
    end
  end

  describe "extract_method_bodies/3" do
    setup do
      # Two-class hierarchy: child overrides parent's fetchTicker
      dir = System.tmp_dir!()
      path = Path.join(dir, "test_exchange.ts")

      source = """
      export default class testExchange extends Exchange {
        describe(): any {
          return {};
        }
        sign(path: string, api: string): any {
          return path + api;
        }
        fetchTicker(symbol: string): Promise<any> {
          return this.request(symbol);
        }
      }
      """

      File.write!(path, source)
      on_exit(fn -> File.rm(path) end)

      {:ok, path: path}
    end

    test "extracts only requested methods", %{path: path} do
      wanted = MapSet.new(["describe", "sign"])
      {:ok, methods} = Overrides.extract_method_bodies(path, "test_exchange.ts", wanted)

      assert Map.has_key?(methods, "describe")
      assert Map.has_key?(methods, "sign")
      refute Map.has_key?(methods, "fetchTicker")
    end

    test "returns empty map when no methods match", %{path: path} do
      wanted = MapSet.new(["nonExistent"])
      {:ok, methods} = Overrides.extract_method_bodies(path, "test_exchange.ts", wanted)

      assert methods == %{}
    end

    test "method data includes body AST", %{path: path} do
      wanted = MapSet.new(["describe"])
      {:ok, methods} = Overrides.extract_method_bodies(path, "test_exchange.ts", wanted)

      describe = methods["describe"]
      assert describe["async"] == false
      assert is_map(describe["body"])
      assert is_integer(describe["statements"])
    end
  end

  describe "JSON round-trip" do
    test "atom keys become string keys at all nesting depths" do
      result = CcxtExtract.MethodAST.extract(@fetch_ticker_method)

      json = Jason.encode!(result)
      decoded = Jason.decode!(json)

      assert is_binary(decoded |> Map.keys() |> hd())
      assert decoded["body"]["type"] == "FunctionBody"
      assert is_list(decoded["params"])
      first_param = hd(decoded["params"])
      assert is_binary(first_param |> Map.keys() |> hd())
    end

    test "full exchange map round-trips correctly" do
      exchange = %{
        "id" => "binanceus",
        "type" => "rest",
        "file" => "binanceus.ts",
        "node_key" => "rest:binanceus",
        "parent_key" => "rest:binance",
        "extends" => "binance",
        "own_method_count" => 1,
        "override_count" => 1,
        "new_method_count" => 0,
        "inherited_count" => 2,
        "overrides" => %{
          "describe" => CcxtExtract.MethodAST.extract(@describe_method)
        },
        "new_methods" => %{},
        "inherited_methods" => ["fetchTicker", "sign"]
      }

      json = Jason.encode!(exchange)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "binanceus"
      assert decoded["override_count"] == 1
      assert Map.has_key?(decoded["overrides"], "describe")
      assert decoded["inherited_methods"] == ["fetchTicker", "sign"]
    end
  end

  describe "Mix.Tasks.CcxtExtract.Overrides.run/1 CLI validation" do
    test "rejects unknown switches" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        OverridesTask.run(["--typo"])
      end
    end

    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        OverridesTask.run(["rest"])
      end
    end
  end
end
