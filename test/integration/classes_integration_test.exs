defmodule CcxtExtract.ClassesIntegrationTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Classes

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 60_000

  # Reference exchange sets from CLAUDE.md
  @all_reference ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex hyperliquid aster lighter)

  # {id, min_method_count} — exact observed values (CCXT 4.x)
  # Breaking on CCXT update is intentional: forces review of what changed
  @rest_expectations [
    {"binance", 166},
    {"bybit", 139},
    {"okx", 131},
    {"deribit", 68},
    {"coinbaseexchange", 42},
    {"kraken", 67},
    {"kucoin", 138},
    {"gate", 125},
    {"htx", 109},
    {"bitmex", 66},
    {"hyperliquid", 109},
    {"aster", 71},
    {"lighter", 58}
  ]

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

  # Run extraction once for the module — OXC parsing ~189 files takes a few seconds
  setup_all do
    {:ok, classes, stats} = Classes.extract()
    %{classes: classes, stats: stats}
  end

  describe "extract/0" do
    test "parses the vast majority of available files", %{classes: classes, stats: stats} do
      total_files =
        Path.wildcard(Path.join(CcxtExtract.Paths.ts_src(), "*.ts")) ++
          Path.wildcard(Path.join(CcxtExtract.Paths.ts_src(), "pro/*.ts"))

      total_available = length(total_files)
      total_parsed = length(classes) + length(stats.skipped)

      # At least 95% of files should parse successfully (no errors)
      assert stats.errors == [],
             "Expected zero parse errors, got #{length(stats.errors)}: #{inspect(stats.errors)}"

      # Parsed + skipped should account for all files
      assert total_parsed == total_available,
             "Expected #{total_available} results, got #{total_parsed} (#{length(classes)} classes + #{length(stats.skipped)} skipped)"
    end

    test "extracts expected class counts from REST and WS sources", %{classes: classes} do
      # Thresholds at ~90% of observed output (110 REST, 79 WS as of CCXT 4.x)
      # Catches major regressions without breaking on minor CCXT version changes
      assert length(classes) >= 170,
             "Expected 170+ classes, got #{length(classes)}"

      rest_count = Enum.count(classes, &(&1["type"] == "rest"))
      ws_count = Enum.count(classes, &(&1["type"] == "ws"))

      assert rest_count >= 100, "Expected 100+ REST classes, got #{rest_count}"
      assert ws_count >= 70, "Expected 70+ WS classes, got #{ws_count}"
    end

    test "skipped files are a small minority", %{classes: classes, stats: stats} do
      total = length(classes) + length(stats.skipped)
      skip_ratio = length(stats.skipped) / max(total, 1)

      # Skipped files should be < 10% of total — most files contain exchange classes
      assert skip_ratio < 0.10,
             "#{length(stats.skipped)} of #{total} files skipped (#{Float.round(skip_ratio * 100, 1)}%) — expected < 10%"
    end

    test "each class has correct field types", %{classes: classes} do
      for c <- classes do
        assert is_binary(c["id"]), "id should be string, got: #{inspect(c["id"])}"
        assert is_binary(c["node_key"]), "node_key should be string for #{c["id"]}"
        assert String.starts_with?(c["node_key"], c["type"] <> ":"), "node_key should start with type: for #{c["id"]}"
        assert is_binary(c["type"]), "type should be string for #{c["id"]}"
        assert c["type"] in ["rest", "ws"], "type should be rest or ws for #{c["id"]}"
        assert is_binary(c["file"]), "file should be string for #{c["id"]}"
        assert is_list(c["methods"]), "methods should be list for #{c["id"]}"
        assert is_integer(c["method_count"]), "method_count should be integer for #{c["id"]}"
        assert c["method_count"] == length(c["methods"]), "method_count mismatch for #{c["id"]}"
        assert is_list(c["method_details"]), "method_details should be list for #{c["id"]}"

        assert is_nil(c["class_name"]) or is_binary(c["class_name"]),
               "class_name should be nil or string for #{c["id"]}"

        assert is_nil(c["extends_raw"]) or is_binary(c["extends_raw"]),
               "extends_raw should be nil or string for #{c["id"]}"

        assert is_nil(c["extends_resolved"]) or is_binary(c["extends_resolved"]),
               "extends_resolved should be nil or string for #{c["id"]}"

        assert is_nil(c["parent_key"]) or is_binary(c["parent_key"]),
               "parent_key should be nil or string for #{c["id"]}"

        for m <- c["method_details"] do
          assert is_binary(m["name"]), "method name should be string in #{c["id"]}"
          assert is_boolean(m["async"]), "method async should be boolean in #{c["id"]}"
          assert is_integer(m["params"]), "method params should be integer in #{c["id"]}"
          assert is_integer(m["statements"]), "method statements should be integer in #{c["id"]}"
        end
      end
    end

    test "classes are sorted by id", %{classes: classes} do
      ids = Enum.map(classes, & &1["id"])
      assert ids == Enum.sort(ids)
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

      # Every non-root parent_key should either be "Exchange" or a valid node_key
      unresolved =
        Enum.reject(classes, fn c ->
          is_nil(c["parent_key"]) or
            c["parent_key"] == "Exchange" or
            MapSet.member?(node_keys, c["parent_key"])
        end)

      assert unresolved == [],
             "Found #{length(unresolved)} unresolved parent references: #{inspect(Enum.map(unresolved, &{&1["node_key"], &1["parent_key"]}))}"
    end

    test "inheritance tree has Exchange as a root parent with no duplicates", %{classes: classes} do
      tree = Classes.build_tree(classes)
      assert Map.has_key?(tree, "Exchange"), "Exchange should be a parent in the tree"
      assert length(tree["Exchange"]) >= 40, "Exchange should have 40+ direct children"

      # No duplicate children in any tree entry
      for {parent, children} <- tree do
        assert children == Enum.uniq(children),
               "Duplicate children found under #{parent}: #{inspect(children)}"
      end
    end

    test "WS counterparts include major exchanges", %{classes: classes} do
      counterparts = Classes.find_ws_counterparts(classes)
      assert length(counterparts) >= 60, "Expected 60+ WS counterparts"
      assert "binance" in counterparts
      assert "bybit" in counterparts
    end
  end

  describe "REST class structure for reference exchanges" do
    for {id, min_methods} <- @rest_expectations do
      test "#{id} REST class extends Exchange with #{min_methods}+ methods", %{classes: classes} do
        c = find_rest(classes, unquote(id))
        assert c, "#{unquote(id)} REST class should exist"
        assert c["extends_resolved"] == "Exchange"
        assert c["parent_key"] == "Exchange"

        assert c["method_count"] >= unquote(min_methods),
               "#{unquote(id)} should have #{unquote(min_methods)}+ methods, got #{c["method_count"]}"

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
      test "#{id} has WS counterpart", %{classes: classes} do
        counterparts = Classes.find_ws_counterparts(classes)

        assert unquote(id) in counterparts,
               "#{unquote(id)} should have a WS counterpart"
      end
    end
  end

  defp find_class(classes, id, type), do: Enum.find(classes, &(&1["id"] == id and &1["type"] == type))

  defp find_rest(classes, id), do: find_class(classes, id, "rest")
  defp find_ws(classes, id), do: find_class(classes, id, "ws")
end
