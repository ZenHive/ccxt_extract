defmodule CcxtExtract.SummaryTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Summary

  # Shared fixtures — minimal data matching the real JSON structures

  defp sample_exchanges do
    [
      %{"id" => "binance", "name" => "Binance", "alias" => false},
      %{"id" => "binanceus", "name" => "Binance US", "alias" => false},
      %{"id" => "binancecoinm", "name" => "Binance COIN-M", "alias" => false},
      %{"id" => "huobi", "name" => "Huobi", "alias" => true},
      %{"id" => "okx", "name" => "OKX", "alias" => false},
      %{"id" => "luno", "name" => "Luno", "alias" => false}
    ]
  end

  defp sample_classes do
    [
      %{"id" => "binance", "node_key" => "rest:binance", "parent_key" => "Exchange", "type" => "rest"},
      %{"id" => "binanceus", "node_key" => "rest:binanceus", "parent_key" => "rest:binance", "type" => "rest"},
      %{"id" => "binancecoinm", "node_key" => "rest:binancecoinm", "parent_key" => "rest:binance", "type" => "rest"},
      %{"id" => "binance", "node_key" => "ws:binance", "parent_key" => "rest:binance", "type" => "ws"},
      %{"id" => "okx", "node_key" => "rest:okx", "parent_key" => "Exchange", "type" => "rest"},
      %{"id" => "okx", "node_key" => "ws:okx", "parent_key" => "rest:okx", "type" => "ws"},
      %{"id" => "luno", "node_key" => "rest:luno", "parent_key" => "Exchange", "type" => "rest"}
    ]
  end

  defp sample_tree do
    %{
      "Exchange" => ["rest:binance", "rest:luno", "rest:okx"],
      "rest:binance" => ["rest:binancecoinm", "rest:binanceus", "ws:binance"],
      "rest:okx" => ["ws:okx"]
    }
  end

  defp sample_ws_counterparts, do: ["binance", "okx"]

  defp sample_exchanges_with_class_alias do
    sample_exchanges() ++
      [
        %{"id" => "coinbase", "name" => "Coinbase", "alias" => false},
        %{"id" => "coinbaseadvanced", "name" => "Coinbase Advanced", "alias" => true}
      ]
  end

  defp sample_classes_with_class_alias do
    sample_classes() ++
      [
        %{"id" => "coinbase", "node_key" => "rest:coinbase", "parent_key" => "Exchange", "type" => "rest"},
        %{
          "id" => "coinbaseadvanced",
          "node_key" => "rest:coinbaseadvanced",
          "parent_key" => "rest:coinbase",
          "type" => "rest"
        }
      ]
  end

  defp sample_tree_with_class_alias do
    %{
      "Exchange" => ["rest:binance", "rest:coinbase", "rest:luno", "rest:okx"],
      "rest:binance" => ["rest:binancecoinm", "rest:binanceus", "ws:binance"],
      "rest:coinbase" => ["rest:coinbaseadvanced"],
      "rest:okx" => ["ws:okx"]
    }
  end

  describe "invert_tree/1" do
    test "inverts parent->children to child->parent" do
      tree = %{
        "Exchange" => ["rest:binance", "rest:okx"],
        "rest:binance" => ["rest:binanceus"]
      }

      inverted = Summary.invert_tree(tree)

      assert inverted["rest:binance"] == "Exchange"
      assert inverted["rest:okx"] == "Exchange"
      assert inverted["rest:binanceus"] == "rest:binance"
    end

    test "returns empty map for empty tree" do
      assert Summary.invert_tree(%{}) == %{}
    end

    test "handles single parent with multiple children" do
      tree = %{"Exchange" => ["rest:a", "rest:b", "rest:c"]}
      inverted = Summary.invert_tree(tree)

      assert inverted["rest:a"] == "Exchange"
      assert inverted["rest:b"] == "Exchange"
      assert inverted["rest:c"] == "Exchange"
    end
  end

  describe "find_root_ancestor/2" do
    test "returns self when parent is Exchange" do
      inverted = %{"rest:binance" => "Exchange"}
      assert Summary.find_root_ancestor("rest:binance", inverted) == "rest:binance"
    end

    test "returns self when not in tree" do
      assert Summary.find_root_ancestor("rest:unknown", %{}) == "rest:unknown"
    end

    test "walks up to root ancestor" do
      inverted = %{
        "rest:binanceus" => "rest:binance",
        "rest:binance" => "Exchange"
      }

      assert Summary.find_root_ancestor("rest:binanceus", inverted) == "rest:binance"
    end

    test "walks up deep chains" do
      inverted = %{
        "rest:deep" => "rest:mid",
        "rest:mid" => "rest:root",
        "rest:root" => "Exchange"
      }

      assert Summary.find_root_ancestor("rest:deep", inverted) == "rest:root"
    end
  end

  describe "build_families/4" do
    test "groups exchanges into families by root ancestor" do
      ws_set = MapSet.new(sample_ws_counterparts())
      families = Summary.build_families(sample_exchanges(), sample_classes(), sample_tree(), ws_set)

      binance_family = Enum.find(families, &(&1["root"] == "binance"))
      assert binance_family["variants"] == ["binancecoinm", "binanceus"]
      assert binance_family["variant_count"] == 2
      assert binance_family["has_ws"] == true
    end

    test "keeps orphan aliases out of family alias lists" do
      ws_set = MapSet.new(sample_ws_counterparts())
      families = Summary.build_families(sample_exchanges(), sample_classes(), sample_tree(), ws_set)

      binance_family = Enum.find(families, &(&1["root"] == "binance"))
      refute "huobi" in binance_family["aliases"]
    end

    test "attaches aliases with their own class to the parent family" do
      ws_set = MapSet.new(sample_ws_counterparts())

      families =
        Summary.build_families(
          sample_exchanges_with_class_alias(),
          sample_classes_with_class_alias(),
          sample_tree_with_class_alias(),
          ws_set
        )

      coinbase_family = Enum.find(families, &(&1["root"] == "coinbase"))
      assert coinbase_family["variants"] == []
      assert coinbase_family["aliases"] == ["coinbaseadvanced"]
      assert coinbase_family["alias_count"] == 1
      assert coinbase_family["total_members"] == 2
    end

    test "marks families with WS counterparts" do
      ws_set = MapSet.new(sample_ws_counterparts())
      families = Summary.build_families(sample_exchanges(), sample_classes(), sample_tree(), ws_set)

      okx_family = Enum.find(families, &(&1["root"] == "okx"))
      luno_family = Enum.find(families, &(&1["root"] == "luno"))

      assert okx_family["has_ws"] == true
      assert luno_family["has_ws"] == false
    end

    test "single-exchange families have no variants or aliases" do
      ws_set = MapSet.new(sample_ws_counterparts())
      families = Summary.build_families(sample_exchanges(), sample_classes(), sample_tree(), ws_set)

      luno_family = Enum.find(families, &(&1["root"] == "luno"))
      assert luno_family["variants"] == []
      assert luno_family["aliases"] == []
      assert luno_family["total_members"] == 1
    end

    test "families are sorted alphabetically by root" do
      ws_set = MapSet.new(sample_ws_counterparts())
      families = Summary.build_families(sample_exchanges(), sample_classes(), sample_tree(), ws_set)

      roots = Enum.map(families, & &1["root"])
      assert roots == Enum.sort(roots)
    end

    test "returns empty list for empty inputs" do
      families = Summary.build_families([], [], %{}, MapSet.new())
      assert families == []
    end
  end

  describe "find_orphan_aliases/2" do
    test "returns aliases without a matching class entry" do
      assert Summary.find_orphan_aliases(
               sample_exchanges_with_class_alias(),
               sample_classes_with_class_alias()
             ) == ["huobi"]
    end

    test "excludes aliases that have a class entry" do
      # coinbaseadvanced is alias=true but HAS a class entry — not an orphan
      orphans =
        Summary.find_orphan_aliases(
          sample_exchanges_with_class_alias(),
          sample_classes_with_class_alias()
        )

      refute "coinbaseadvanced" in orphans
    end

    test "never returns non-alias exchanges" do
      orphans = Summary.find_orphan_aliases(sample_exchanges(), sample_classes())
      # binance, okx, luno are not aliases — should never appear
      refute "binance" in orphans
      refute "okx" in orphans
      refute "luno" in orphans
    end

    test "returns empty list when no orphan aliases exist" do
      # All exchanges have matching class entries, none are aliases
      exchanges = [%{"id" => "binance", "alias" => false}]
      classes = [%{"id" => "binance"}]
      assert Summary.find_orphan_aliases(exchanges, classes) == []
    end

    test "returns sorted results" do
      exchanges = [
        %{"id" => "zebra", "alias" => true},
        %{"id" => "alpha", "alias" => true}
      ]

      orphans = Summary.find_orphan_aliases(exchanges, [])
      assert orphans == ["alpha", "zebra"]
    end
  end

  describe "build_summary/4" do
    test "computes correct aggregate counts" do
      summary =
        Summary.build_summary(
          sample_exchanges(),
          sample_classes(),
          sample_tree(),
          sample_ws_counterparts()
        )

      counts = summary["counts"]

      assert counts["exchanges"]["total"] == 6
      assert counts["exchanges"]["aliases"] == 1
      assert counts["exchanges"]["real"] == 5

      assert counts["classes"]["rest"] == 5
      assert counts["classes"]["ws"] == 2
      assert counts["classes"]["total"] == 7

      assert counts["exchanges_with_ws"] == 2
    end

    test "includes metadata fields" do
      summary =
        Summary.build_summary(
          sample_exchanges(),
          sample_classes(),
          sample_tree(),
          sample_ws_counterparts()
        )

      assert is_binary(summary["extracted_at"])
      assert summary["source_files"]["exchanges"] == "exchanges.json"
      assert summary["source_files"]["class_hierarchy"] == "class_hierarchy.json"
    end

    test "families list is present" do
      summary =
        Summary.build_summary(
          sample_exchanges(),
          sample_classes(),
          sample_tree(),
          sample_ws_counterparts()
        )

      assert is_list(summary["families"])
      assert summary["counts"]["families"] == length(summary["families"])
    end
  end
end
