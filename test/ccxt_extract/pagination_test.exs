defmodule CcxtExtract.PaginationTest do
  @moduledoc """
  Tests for Pagination extraction from exchange TypeScript files.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Pagination

  # --- AST Helpers ---

  # Build a minimal class AST wrapped in ExportDefaultDeclaration
  defp build_class_ast(class_name, methods) do
    %{
      body: [
        %{
          type: "ExportDefaultDeclaration",
          declaration: %{
            type: "ClassDeclaration",
            id: %{name: class_name},
            superClass: nil,
            body: %{body: methods}
          }
        }
      ]
    }
  end

  # Build a MethodDefinition whose body contains the given statements
  defp method_with_body(method_name, statements) do
    %{
      type: "MethodDefinition",
      key: %{name: method_name},
      value: %{
        type: "FunctionExpression",
        async: true,
        params: [],
        body: %{body: statements}
      }
    }
  end

  # Build a this.fetchPaginatedCall* CallExpression
  defp pagination_call(strategy_method, args) do
    %{
      type: "CallExpression",
      callee: %{
        type: "MemberExpression",
        object: %{type: "ThisExpression"},
        property: %{type: "Identifier", name: strategy_method}
      },
      arguments: args
    }
  end

  defp literal(value), do: %{type: "Literal", value: value}
  defp identifier(name), do: %{type: "Identifier", name: name}

  # Wrap a pagination call inside a return statement (typical pattern)
  defp return_pagination_call(strategy_method, args) do
    %{
      type: "ReturnStatement",
      argument: %{
        type: "AwaitExpression",
        argument: pagination_call(strategy_method, args)
      }
    }
  end

  # Extract the single entry from a pagination list (asserts exactly one entry)
  defp single_entry(result, method_name) do
    entries = result["pagination"][method_name]
    assert length(entries) == 1, "Expected 1 entry for #{method_name}, got #{length(entries)}"
    hd(entries)
  end

  describe "extract_from_ast/2" do
    test "extracts dynamic pagination" do
      stmt =
        return_pagination_call("fetchPaginatedCallDynamic", [
          literal("fetchTrades"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("params"),
          literal(1000)
        ])

      ast = build_class_ast("binance", [method_with_body("fetchTrades", [stmt])])
      result = Pagination.extract_from_ast(ast, "binance.ts")

      assert result["id"] == "binance"
      assert result["pagination_count"] == 1

      entry = single_entry(result, "fetchTrades")
      assert entry["strategy"] == "dynamic"
      assert entry["max_entries_per_request"] == 1000
      assert entry["target_method"] == "fetchTrades"
      assert entry["containing_method"] == "fetchTrades"
    end

    test "extracts deterministic pagination" do
      stmt =
        return_pagination_call("fetchPaginatedCallDeterministic", [
          literal("fetchOHLCV"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("timeframe"),
          identifier("params"),
          literal(1000)
        ])

      ast = build_class_ast("binance", [method_with_body("fetchOHLCV", [stmt])])
      result = Pagination.extract_from_ast(ast, "binance.ts")

      entry = single_entry(result, "fetchOHLCV")
      assert entry["strategy"] == "deterministic"
      assert entry["max_entries_per_request"] == 1000
    end

    test "extracts cursor pagination with all fields" do
      stmt =
        return_pagination_call("fetchPaginatedCallCursor", [
          literal("fetchTrades"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("params"),
          literal("tradeId"),
          literal("after"),
          identifier("undefined"),
          literal(100)
        ])

      ast = build_class_ast("okx", [method_with_body("fetchTrades", [stmt])])
      result = Pagination.extract_from_ast(ast, "okx.ts")

      entry = single_entry(result, "fetchTrades")
      assert entry["strategy"] == "cursor"
      assert entry["cursor_received"] == "tradeId"
      assert entry["cursor_sent"] == "after"
      assert entry["cursor_increment"] == nil
      assert entry["max_entries_per_request"] == 100
    end

    test "extracts incremental pagination" do
      stmt =
        return_pagination_call("fetchPaginatedCallIncremental", [
          literal("fetchMyLiquidations"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("params"),
          literal("current"),
          literal(100)
        ])

      ast = build_class_ast("binance", [method_with_body("fetchMyLiquidations", [stmt])])
      result = Pagination.extract_from_ast(ast, "binance.ts")

      entry = single_entry(result, "fetchMyLiquidations")
      assert entry["strategy"] == "incremental"
      assert entry["page_key"] == "current"
      assert entry["max_entries_per_request"] == 100
    end

    test "non-literal strategy arguments produce nil values" do
      stmt =
        return_pagination_call("fetchPaginatedCallDynamic", [
          literal("fetchTrades"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("params"),
          identifier("maxLimit")
        ])

      ast = build_class_ast("test", [method_with_body("fetchTrades", [stmt])])
      result = Pagination.extract_from_ast(ast, "test.ts")

      entry = single_entry(result, "fetchTrades")
      assert entry["strategy"] == "dynamic"
      assert entry["max_entries_per_request"] == nil
    end

    test "no pagination calls returns empty map" do
      stmt = %{type: "ReturnStatement", argument: identifier("result")}
      ast = build_class_ast("nopag", [method_with_body("fetchTrades", [stmt])])

      result = Pagination.extract_from_ast(ast, "nopag.ts")

      assert result["id"] == "nopag"
      assert result["pagination_count"] == 0
      assert result["pagination"] == %{}
    end

    test "no exported class returns nil" do
      ast = %{body: [%{type: "ImportDeclaration", source: %{value: "foo"}}]}
      assert Pagination.extract_from_ast(ast, "foo.ts") == nil
    end

    test "multiple methods with different strategies" do
      dynamic_stmt =
        return_pagination_call("fetchPaginatedCallDynamic", [
          literal("fetchTrades"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("params"),
          literal(500)
        ])

      deterministic_stmt =
        return_pagination_call("fetchPaginatedCallDeterministic", [
          literal("fetchOHLCV"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("timeframe"),
          identifier("params"),
          literal(1000)
        ])

      ast =
        build_class_ast("multi", [
          method_with_body("fetchTrades", [dynamic_stmt]),
          method_with_body("fetchOHLCV", [deterministic_stmt])
        ])

      result = Pagination.extract_from_ast(ast, "multi.ts")

      assert result["pagination_count"] == 2
      assert hd(result["pagination"]["fetchTrades"])["strategy"] == "dynamic"
      assert hd(result["pagination"]["fetchOHLCV"])["strategy"] == "deterministic"
    end

    test "duplicate method name preserves all variants" do
      call1 =
        return_pagination_call("fetchPaginatedCallCursor", [
          literal("fetchAccounts"),
          identifier("undefined"),
          identifier("undefined"),
          identifier("undefined"),
          identifier("params"),
          literal("next_starting_after"),
          literal("starting_after"),
          identifier("undefined"),
          literal(100)
        ])

      call2 =
        return_pagination_call("fetchPaginatedCallCursor", [
          literal("fetchAccounts"),
          identifier("undefined"),
          identifier("undefined"),
          identifier("undefined"),
          identifier("params"),
          literal("cursor"),
          literal("cursor"),
          identifier("undefined"),
          literal(250)
        ])

      ast =
        build_class_ast("coinbase", [
          method_with_body("fetchAccountsV2", [call1]),
          method_with_body("fetchAccountsV3", [call2])
        ])

      result = Pagination.extract_from_ast(ast, "coinbase.ts")

      # Both variants preserved
      assert result["pagination_count"] == 2
      entries = result["pagination"]["fetchAccounts"]
      assert length(entries) == 2

      # Each entry has its containing method
      containing = entries |> Enum.map(& &1["containing_method"]) |> Enum.sort()
      assert containing == ["fetchAccountsV2", "fetchAccountsV3"]

      # Different params preserved
      limits = entries |> Enum.map(& &1["max_entries_per_request"]) |> Enum.sort()
      assert limits == [100, 250]
    end

    test "finds pagination call nested inside if block" do
      nested_call =
        pagination_call("fetchPaginatedCallDynamic", [
          literal("fetchOrders"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("params")
        ])

      if_stmt = %{
        type: "IfStatement",
        test: identifier("paginate"),
        consequent: %{
          type: "BlockStatement",
          body: [
            %{type: "ReturnStatement", argument: %{type: "AwaitExpression", argument: nested_call}}
          ]
        },
        alternate: nil
      }

      ast = build_class_ast("nested", [method_with_body("fetchOrders", [if_stmt])])
      result = Pagination.extract_from_ast(ast, "nested.ts")

      assert result["pagination_count"] == 1
      assert hd(result["pagination"]["fetchOrders"])["strategy"] == "dynamic"
    end

    test "variable method name emitted as unresolved" do
      # Simulates bydfi pattern: methodName variable passed to fetchPaginatedCallDynamic
      stmt =
        return_pagination_call("fetchPaginatedCallDynamic", [
          identifier("methodName"),
          identifier("symbol"),
          identifier("since"),
          identifier("limit"),
          identifier("params"),
          literal(1000)
        ])

      ast = build_class_ast("bydfi", [method_with_body("fetchTransactionsHelper", [stmt])])
      result = Pagination.extract_from_ast(ast, "bydfi.ts")

      # No resolved entries, but unresolved counts toward total
      assert result["pagination"] == %{}
      assert result["pagination_count"] == 1

      # Unresolved entry captured
      assert [unresolved] = result["pagination_unresolved"]
      assert unresolved["target_method"] == nil
      assert unresolved["containing_method"] == "fetchTransactionsHelper"
      assert unresolved["strategy"] == "dynamic"
      assert unresolved["max_entries_per_request"] == 1000
    end
  end

  describe "extract_pagination_entry/1" do
    test "returns entry with nil target_method when method name is a variable" do
      call =
        pagination_call("fetchPaginatedCallDynamic", [
          identifier("methodName"),
          identifier("symbol")
        ])

      entry = Pagination.extract_pagination_entry({"fetchHelper", call})
      assert entry["target_method"] == nil
      assert entry["containing_method"] == "fetchHelper"
      assert entry["strategy"] == "dynamic"
    end
  end

  describe "parse_file/1" do
    @tag :extraction
    test "parses binance and finds expected pagination entries" do
      path = Path.join(CcxtExtract.Paths.ts_src(), "binance.ts")

      if File.exists?(path) do
        assert {:ok, result} = Pagination.parse_file(path)
        assert result["id"] == "binance"
        assert result["pagination_count"] > 0

        # Binance should have fetchTrades (dynamic), fetchOHLCV (deterministic),
        # and fetchMyLiquidations (incremental) — all as arrays
        assert [%{"strategy" => "dynamic"} | _] = result["pagination"]["fetchTrades"]
        assert [%{"strategy" => "deterministic"} | _] = result["pagination"]["fetchOHLCV"]
        assert [%{"strategy" => "incremental"} | _] = result["pagination"]["fetchMyLiquidations"]
      else
        flunk("CCXT source not found at #{path}. Run `mix ccxt_extract.setup` first.")
      end
    end
  end

  describe "extract/0" do
    @tag :extraction
    test "extracts pagination from all exchange files" do
      {:ok, exchanges, stats} = Pagination.extract()

      assert exchanges != []
      assert stats.errors == []

      # All entries have required keys
      for exchange <- exchanges do
        assert is_binary(exchange["id"])
        assert is_binary(exchange["file"])
        assert is_integer(exchange["pagination_count"])
        assert is_map(exchange["pagination"])
      end

      # At least 40 exchanges should have pagination
      with_pagination = Enum.count(exchanges, &(&1["pagination_count"] > 0))
      assert with_pagination >= 40

      # Spot-check: binance must have pagination
      binance = Enum.find(exchanges, &(&1["id"] == "binance"))
      assert binance, "binance should exist in extracted exchanges"
      assert binance["pagination_count"] > 5

      # Check entries are arrays with expected structure
      {_name, entries} = Enum.at(binance["pagination"], 0)
      assert is_list(entries)
      entry = hd(entries)
      assert is_binary(entry["strategy"])
      assert entry["strategy"] in ~w(dynamic deterministic cursor incremental)
      assert is_binary(entry["containing_method"])
      assert is_binary(entry["target_method"])
    end

    @tag :extraction
    test "coinbase has multiple fetchAccounts variants" do
      {:ok, exchanges, _stats} = Pagination.extract()

      coinbase = Enum.find(exchanges, &(&1["id"] == "coinbase"))
      assert coinbase, "coinbase should exist"

      entries = coinbase["pagination"]["fetchAccounts"]
      assert length(entries) >= 2, "coinbase fetchAccounts should have multiple variants"

      # Different containing methods
      containing = entries |> Enum.map(& &1["containing_method"]) |> Enum.sort()
      assert "fetchAccountsV2" in containing
      assert "fetchAccountsV3" in containing
    end

    @tag :extraction
    test "bydfi has unresolved pagination entries" do
      {:ok, exchanges, _stats} = Pagination.extract()

      bydfi = Enum.find(exchanges, &(&1["id"] == "bydfi"))
      assert bydfi, "bydfi should exist"

      unresolved = Map.get(bydfi, "pagination_unresolved", [])
      assert unresolved != [], "bydfi should have unresolved pagination entries"

      entry = hd(unresolved)
      assert entry["target_method"] == nil
      assert entry["containing_method"] == "fetchTransactionsHelper"
    end
  end
end
