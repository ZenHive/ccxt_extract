defmodule CcxtExtract.Integration.Cached.ClassesCachedTest do
  @moduledoc """
  Structure tests for class_hierarchy.json — reads cached discovery output.
  Same assertions as ClassesIntegrationTest but without OXC parsing.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir CcxtExtract.Paths.discoveries()
  @discovery_path Path.join(@fixtures_dir, "class_hierarchy.json")

  # Reference exchange sets from CLAUDE.md
  @all_reference ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid aster lighter)

  # Sanity floor for method counts on reference exchanges. The precise count drifts
  # with every upstream CCXT release; policing exact numbers is the job of
  # `mix ccxt_extract.contract_test`, not cached fixture tests. Here we just assert
  # the class is non-trivial.
  @min_methods_floor 30

  # {variant_id, parent_id}
  @variant_inheritance [
    {"binanceus", "binance"},
    {"binancecoinm", "binance"},
    {"binanceusdm", "binance"},
    {"okxus", "okx"},
    {"kucoinfutures", "kucoin"}
  ]

  # {alias_id, parent_id}
  @alias_inheritance [{"huobi", "htx"}, {"gateio", "gate"}]

  setup_all do
    data = @discovery_path |> File.read!() |> Jason.decode!()
    %{classes: data["classes"], tree: data["tree"], ws_counterparts: data["ws_counterparts"]}
  end

  describe "structure" do
    test "extracts expected class counts from REST and WS sources", %{classes: classes} do
      assert length(classes) >= 170,
             "Expected 170+ classes, got #{length(classes)}"

      rest_count = Enum.count(classes, &(&1["type"] == "rest"))
      ws_count = Enum.count(classes, &(&1["type"] == "ws"))

      assert rest_count >= 100, "Expected 100+ REST classes, got #{rest_count}"
      assert ws_count >= 70, "Expected 70+ WS classes, got #{ws_count}"
    end

    test "each class has correct field types", %{classes: classes} do
      for c <- classes do
        assert is_binary(c["id"]), "id should be string, got: #{inspect(c["id"])}"
        assert is_binary(c["node_key"]), "node_key should be string for #{c["id"]}"

        assert String.starts_with?(c["node_key"], c["type"] <> ":"),
               "node_key should start with type: for #{c["id"]}"

        assert c["type"] in ["rest", "ws"], "type should be rest or ws for #{c["id"]}"
        assert is_binary(c["file"]), "file should be string for #{c["id"]}"
        assert is_list(c["methods"]), "methods should be list for #{c["id"]}"
        assert is_integer(c["method_count"]), "method_count should be integer for #{c["id"]}"
        assert c["method_count"] == length(c["methods"]), "method_count mismatch for #{c["id"]}"
        assert is_list(c["method_details"]), "method_details should be list for #{c["id"]}"

        for m <- c["method_details"] do
          assert is_binary(m["name"]), "method name should be string in #{c["id"]}"
          assert is_boolean(m["async"]), "method async should be boolean in #{c["id"]}"
          assert is_integer(m["params"]), "method params should be integer in #{c["id"]}"
          assert is_integer(m["statements"]), "method statements should be integer in #{c["id"]}"
        end
      end
    end

    test "classes are sorted by id within each type", %{classes: classes} do
      by_type = Enum.group_by(classes, & &1["type"], & &1["id"])

      for {type, ids} <- by_type do
        assert ids == Enum.sort(ids), "#{type} classes not sorted by id"
      end

      types_in_order = classes |> Enum.map(& &1["type"]) |> Enum.dedup()
      assert types_in_order == ["rest", "ws"], "expected rest classes before ws classes"
    end

    test "binance REST class has expected structure", %{classes: classes} do
      binance = Enum.find(classes, &(&1["id"] == "binance" and &1["type"] == "rest"))

      assert binance, "binance REST class should be in the list"
      assert binance["class_name"] == "binance"
      assert binance["node_key"] == "rest:binance"
      assert binance["extends_raw"] == "Exchange"
      assert binance["extends_resolved"] == "Exchange"
      assert binance["parent_key"] == "Exchange"
      assert binance["method_count"] > 50, "binance should have 50+ methods"
      assert "describe" in binance["methods"]
      assert "fetchTicker" in binance["methods"]
      assert "sign" in binance["methods"]
    end

    test "WS binance resolves alias to REST parent", %{classes: classes} do
      ws_binance = Enum.find(classes, &(&1["id"] == "binance" and &1["type"] == "ws"))

      assert ws_binance, "WS binance should be in the list"
      assert ws_binance["node_key"] == "ws:binance"
      assert ws_binance["extends_raw"] == "binanceRest"
      assert ws_binance["extends_resolved"] == "binance"
      assert ws_binance["parent_key"] == "rest:binance"
    end

    test "no unresolved parent references in hierarchy", %{classes: classes} do
      node_keys = MapSet.new(classes, & &1["node_key"])

      unresolved =
        Enum.reject(classes, fn c ->
          is_nil(c["parent_key"]) or
            c["parent_key"] == "Exchange" or
            MapSet.member?(node_keys, c["parent_key"])
        end)

      assert unresolved == [],
             "Found #{length(unresolved)} unresolved parent references: #{inspect(Enum.map(unresolved, &{&1["node_key"], &1["parent_key"]}))}"
    end

    test "inheritance tree has Exchange as a root parent with no duplicates", %{tree: tree} do
      assert Map.has_key?(tree, "Exchange"), "Exchange should be a parent in the tree"
      assert length(tree["Exchange"]) >= 40, "Exchange should have 40+ direct children"

      for {parent, children} <- tree do
        assert children == Enum.uniq(children),
               "Duplicate children found under #{parent}: #{inspect(children)}"
      end
    end

    test "WS counterparts include major exchanges", %{ws_counterparts: counterparts} do
      assert length(counterparts) >= 60, "Expected 60+ WS counterparts"
      assert "binance" in counterparts
      assert "bybit" in counterparts
    end
  end

  describe "REST class structure for reference exchanges" do
    for id <- @all_reference do
      test "#{id} REST class extends Exchange with core methods", %{classes: classes} do
        c = find_rest(classes, unquote(id))
        assert c, "#{unquote(id)} REST class should exist"
        assert c["extends_resolved"] == "Exchange"
        assert c["parent_key"] == "Exchange"

        assert c["method_count"] > @min_methods_floor,
               "#{unquote(id)} should have > #{@min_methods_floor} methods, got #{c["method_count"]}"

        assert "describe" in c["methods"], "#{unquote(id)} should have describe method"
        assert "sign" in c["methods"], "#{unquote(id)} should have sign method"
      end
    end
  end

  describe "WS class resolution for reference exchanges" do
    for id <- @all_reference do
      test "#{id} WS class resolves to REST parent", %{classes: classes} do
        ws = find_ws(classes, unquote(id))
        assert ws, "#{unquote(id)} WS class should exist"

        assert ws["parent_key"] == "rest:#{unquote(id)}",
               "#{unquote(id)} WS parent_key should be rest:#{unquote(id)}, got #{ws["parent_key"]}"
      end
    end
  end

  describe "variant class inheritance" do
    for {variant, parent} <- @variant_inheritance do
      test "#{variant} REST class extends #{parent}", %{classes: classes} do
        c = find_rest(classes, unquote(variant))
        assert c, "#{unquote(variant)} REST class should exist"
        assert c["extends_resolved"] == unquote(parent)
        assert c["parent_key"] == "rest:#{unquote(parent)}"
      end
    end
  end

  describe "alias class inheritance" do
    for {alias_id, parent} <- @alias_inheritance do
      test "#{alias_id} REST class extends #{parent}", %{classes: classes} do
        c = find_rest(classes, unquote(alias_id))
        assert c, "#{unquote(alias_id)} REST class should exist"
        assert c["extends_resolved"] == unquote(parent)
        assert c["parent_key"] == "rest:#{unquote(parent)}"
      end
    end
  end

  describe "WS counterparts include reference exchanges" do
    for id <- @all_reference do
      test "#{id} has WS counterpart", %{ws_counterparts: counterparts} do
        assert unquote(id) in counterparts,
               "#{unquote(id)} should have a WS counterpart"
      end
    end
  end

  defp find_class(classes, id, type), do: Enum.find(classes, &(&1["id"] == id and &1["type"] == type))
  defp find_rest(classes, id), do: find_class(classes, id, "rest")
  defp find_ws(classes, id), do: find_class(classes, id, "ws")
end
