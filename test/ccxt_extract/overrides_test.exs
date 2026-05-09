defmodule CcxtExtract.OverridesTest do
  # async: false — scope-aware write tests share tmp/overrides.json (race under parallel pool).
  use ExUnit.Case, async: false

  alias CcxtExtract.Overrides
  alias Mix.Tasks.CcxtExtract.Overrides, as: OverridesTask

  # --- Mock method definitions ---

  @describe_method %{
    type: :method_definition,
    key: %{name: "describe"},
    value: %{
      async: false,
      params: [],
      returnType: %{
        typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "any"}}
      },
      body: %{
        type: :function_body,
        body: [%{type: :return_statement}],
        start: 100,
        end: 200
      }
    }
  }

  @sign_method %{
    type: :method_definition,
    key: %{name: "sign"},
    value: %{
      async: false,
      params: [
        %{type: :identifier, name: "path", typeAnnotation: nil},
        %{type: :identifier, name: "api", typeAnnotation: nil}
      ],
      returnType: nil,
      body: %{
        type: :function_body,
        body: [%{type: :variable_declaration}, %{type: :return_statement}],
        start: 300,
        end: 500
      }
    }
  }

  @fetch_ticker_method %{
    type: :method_definition,
    key: %{name: "fetchTicker"},
    value: %{
      async: true,
      params: [
        %{
          type: :identifier,
          name: "symbol",
          typeAnnotation: %{typeAnnotation: %{type: :ts_type_reference, typeName: %{name: "string"}}}
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
        body: [%{type: :expression_statement}, %{type: :return_statement}],
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

  describe "write!/2 scope-aware aggregate" do
    @tmp_dir Path.join(System.tmp_dir!(), "ccxt_extract_overrides_write_test")

    setup do
      File.rm_rf!(@tmp_dir)
      File.mkdir_p!(@tmp_dir)
      on_exit(fn -> File.rm_rf!(@tmp_dir) end)
      :ok
    end

    defp override_entry(id, override_count, new_method_count \\ 0, type \\ "rest") do
      %{
        "id" => id,
        "type" => type,
        "file" => "#{id}.ts",
        "node_key" => "#{type}:#{id}",
        "parent_key" => "#{type}:binance",
        "extends" => "binance",
        "own_method_count" => override_count + new_method_count,
        "override_count" => override_count,
        "new_method_count" => new_method_count,
        "inherited_count" => 0,
        "overrides" => %{},
        "new_methods" => %{},
        "inherited_methods" => []
      }
    end

    test "scope=:all overwrites the file wholesale" do
      path = Path.join(@tmp_dir, "overrides.json")

      :ok = Overrides.write!([override_entry("bybit", 3)], output_path: path, scope: :all)

      :ok =
        Overrides.write!(
          [override_entry("binance", 5), override_entry("okx", 2)],
          output_path: path,
          scope: :all,
          tier_scope: "all"
        )

      data = Jason.decode!(File.read!(path))

      assert data["count"] == 2
      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(binance okx)
      assert data["tier_scope"] == "all"
    end

    test "scope=MapSet merges in-scope entries and preserves out-of-scope" do
      path = Path.join(@tmp_dir, "overrides.json")

      :ok =
        Overrides.write!(
          [override_entry("binance", 5), override_entry("bybit", 3), override_entry("okx", 2)],
          output_path: path,
          scope: :all
        )

      scope = MapSet.new(~w(binance bybit))

      :ok =
        Overrides.write!(
          [override_entry("binance", 7), override_entry("bybit", 4)],
          output_path: path,
          scope: scope,
          tier_scope: "TIER 1 (2)"
        )

      data = Jason.decode!(File.read!(path))

      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(binance bybit okx)

      binance = Enum.find(data["exchanges"], &(&1["id"] == "binance"))
      assert binance["override_count"] == 7

      okx = Enum.find(data["exchanges"], &(&1["id"] == "okx"))
      assert okx["override_count"] == 2

      assert data["tier_scope"] == "TIER 1 (2)"
    end

    test "legacy positional-string path call returns atom-keyed summary" do
      # Integration tests still call `Overrides.write!(exchanges, path)` with a
      # binary path and destructure the returned summary.
      path = Path.join(@tmp_dir, "overrides.json")

      exchanges = [
        override_entry("binance", 5, 10),
        override_entry("bybit", 3, 4)
      ]

      summary = Overrides.write!(exchanges, path)

      assert summary.with_overrides == 2
      assert summary.total_overrides == 8
      assert summary.total_new == 14

      # File is still written via AggregateWriter.
      data = Jason.decode!(File.read!(path))
      assert data["count"] == 2
      assert data["tier_scope"] == "all"
    end

    test "same-id siblings (rest + ws) are distinct merge entries" do
      # overrides.json can contain both rest:binance and ws:binance with the
      # same `id`. Merge identity must be `node_key`, not `id`.
      path = Path.join(@tmp_dir, "overrides.json")

      seed = [
        override_entry("binance", 3, 0, "rest"),
        override_entry("binance", 2, 0, "ws"),
        override_entry("bybit", 4, 0, "rest")
      ]

      :ok = Overrides.write!(seed, output_path: path, scope: :all)

      # Scoped re-run: both rest and ws variants of binance are re-extracted.
      scope = MapSet.new(~w(binance))

      update = [
        override_entry("binance", 5, 0, "rest"),
        override_entry("binance", 6, 0, "ws")
      ]

      :ok = Overrides.write!(update, output_path: path, scope: scope)

      data = Jason.decode!(File.read!(path))
      by_node_key = Map.new(data["exchanges"], &{&1["node_key"], &1})

      assert by_node_key["rest:binance"]["override_count"] == 5
      assert by_node_key["ws:binance"]["override_count"] == 6
      assert by_node_key["rest:bybit"]["override_count"] == 4
      assert map_size(by_node_key) == 3
    end

    test "partial extract preserves stale sibling (e.g., WS failed, REST succeeded)" do
      # Scoped scenario where one variant fails to extract: the surviving
      # variant replaces its prior entry, but the failed sibling's prior
      # entry is preserved rather than silently vanishing. Guards against
      # the merge-by-bare-id regression Codex surfaced in review.
      path = Path.join(@tmp_dir, "overrides.json")

      seed = [
        override_entry("binance", 3, 0, "rest"),
        override_entry("binance", 2, 0, "ws")
      ]

      :ok = Overrides.write!(seed, output_path: path, scope: :all)

      scope = MapSet.new(~w(binance))
      # Simulates `Overrides.extract/0` producing only the REST variant because
      # the WS class failed to parse (logged as `stats.errors`, not in `exchanges`).
      partial = [override_entry("binance", 7, 0, "rest")]

      :ok = Overrides.write!(partial, output_path: path, scope: scope)

      data = Jason.decode!(File.read!(path))
      by_node_key = Map.new(data["exchanges"], &{&1["node_key"], &1})

      # REST replaced with fresh value.
      assert by_node_key["rest:binance"]["override_count"] == 7
      # WS kept at prior (stale) value rather than silently dropped.
      assert by_node_key["ws:binance"]["override_count"] == 2
      assert map_size(by_node_key) == 2
    end

    test "envelope totals are recomputed from merged entries (drift guard)" do
      path = Path.join(@tmp_dir, "overrides.json")

      # Seed with three entries — totals should reflect all three.
      seed = [
        override_entry("binance", 5, 10),
        override_entry("bybit", 3, 4),
        override_entry("okx", 2, 6)
      ]

      :ok = Overrides.write!(seed, output_path: path, scope: :all)

      # Scoped merge: replace binance + bybit with new counts.
      scope = MapSet.new(~w(binance bybit))
      update = [override_entry("binance", 7, 12), override_entry("bybit", 4, 5)]
      :ok = Overrides.write!(update, output_path: path, scope: scope)

      data = Jason.decode!(File.read!(path))

      # Drift guard: every envelope total equals the sum derived from entries.
      exchanges = data["exchanges"]

      assert data["count"] == length(exchanges)

      assert data["with_overrides"] ==
               Enum.count(exchanges, fn e -> e["override_count"] > 0 end)

      assert data["total_overrides"] ==
               Enum.sum(Enum.map(exchanges, & &1["override_count"]))

      assert data["total_new_methods"] ==
               Enum.sum(Enum.map(exchanges, & &1["new_method_count"]))
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
