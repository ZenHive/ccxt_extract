defmodule CcxtExtract.SummaryIntegrationTest do
  use ExUnit.Case

  alias CcxtExtract.Summary

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 120_000

  # {family_root, expected_variant, min_variant_count}
  @families_with_variants [
    {"binance", "binanceus", 3},
    {"okx", "okxus", 1},
    {"kucoin", "kucoinfutures", 1}
  ]

  # {family_root, expected_alias}
  @families_with_aliases [{"htx", "huobi"}, {"gate", "gateio"}]

  @standalone_exchanges ~w(bybit deribit coinbaseexchange kraken bitmex)
  @dex_exchanges ~w(hyperliquid aster lighter)
  @non_orphan_aliases ~w(huobi gateio)

  # Generate discovery files once for the module.
  # Runs both exchanges (QuickBEAM ~13s) and classes (OXC ~2s) extractions.
  setup_all do
    {:ok, exchanges} = CcxtExtract.Exchanges.extract()
    CcxtExtract.Exchanges.write!(exchanges)

    {:ok, classes, _stats} = CcxtExtract.Classes.extract()
    CcxtExtract.Classes.write!(classes)

    {:ok, summary} = Summary.extract()
    %{summary: summary, exchanges: exchanges, classes: classes}
  end

  describe "extract/0" do
    test "returns error when exchanges.json is missing" do
      exchanges_path = CcxtExtract.Paths.priv("discoveries/exchanges.json")
      backup = exchanges_path <> ".bak"
      File.rename!(exchanges_path, backup)

      try do
        assert {:error, {:missing_input, ^exchanges_path}} = Summary.extract()
      after
        File.rename!(backup, exchanges_path)
      end
    end

    test "returns error when class_hierarchy.json is missing" do
      classes_path = CcxtExtract.Paths.priv("discoveries/class_hierarchy.json")
      backup = classes_path <> ".bak"
      File.rename!(classes_path, backup)

      try do
        assert {:error, {:missing_input, ^classes_path}} = Summary.extract()
      after
        File.rename!(backup, classes_path)
      end
    end

    test "extracts summary with reasonable counts", %{summary: summary} do
      counts = summary["counts"]

      assert counts["exchanges"]["total"] >= 100,
             "Expected 100+ exchanges, got #{counts["exchanges"]["total"]}"

      assert counts["exchanges"]["real"] >= 90,
             "Expected 90+ real exchanges, got #{counts["exchanges"]["real"]}"

      assert counts["exchanges"]["aliases"] >= 1,
             "Expected at least 1 alias exchange"

      assert counts["classes"]["rest"] >= 100,
             "Expected 100+ REST classes, got #{counts["classes"]["rest"]}"

      assert counts["classes"]["ws"] >= 60,
             "Expected 60+ WS classes, got #{counts["classes"]["ws"]}"

      assert counts["families"] >= 30,
             "Expected 30+ families, got #{counts["families"]}"

      assert counts["exchanges_with_ws"] >= 60,
             "Expected 60+ exchanges with WS"
    end

    test "known families have expected structure", %{summary: summary} do
      families = summary["families"]

      binance = Enum.find(families, &(&1["root"] == "binance"))
      assert binance, "binance family should exist"
      assert binance["variant_count"] >= 1, "binance should have at least 1 variant"
      assert binance["has_ws"] == true, "binance should have WS support"
      assert binance["total_members"] >= 2, "binance family should have 2+ members"

      for f <- families do
        assert is_binary(f["root"]), "root should be string"
        assert is_list(f["variants"]), "variants should be list for #{f["root"]}"
        assert is_list(f["aliases"]), "aliases should be list for #{f["root"]}"
        assert is_integer(f["variant_count"]), "variant_count should be integer for #{f["root"]}"
        assert is_integer(f["alias_count"]), "alias_count should be integer for #{f["root"]}"
        assert is_integer(f["total_members"]), "total_members should be integer for #{f["root"]}"
        assert is_boolean(f["has_ws"]), "has_ws should be boolean for #{f["root"]}"

        assert f["variant_count"] == length(f["variants"]),
               "variant_count mismatch for #{f["root"]}"

        assert f["alias_count"] == length(f["aliases"]),
               "alias_count mismatch for #{f["root"]}"

        assert f["total_members"] == 1 + f["variant_count"] + f["alias_count"],
               "total_members mismatch for #{f["root"]}"
      end
    end

    test "families are sorted alphabetically", %{summary: summary} do
      roots = Enum.map(summary["families"], & &1["root"])
      assert roots == Enum.sort(roots), "families should be sorted by root"
    end

    test "orphan aliases are identified", %{summary: summary} do
      orphans = summary["orphan_aliases"]
      assert is_list(orphans), "orphan_aliases should be a list"
      assert orphans == Enum.sort(orphans), "orphan_aliases should be sorted"
    end

    test "aliases with class entries are attached to families", %{
      summary: summary,
      exchanges: exchanges,
      classes: classes
    } do
      rest_class_ids =
        classes
        |> Enum.filter(&(&1["type"] == "rest"))
        |> MapSet.new(& &1["id"])

      aliases_with_classes =
        exchanges
        |> Enum.filter(&(&1["alias"] && MapSet.member?(rest_class_ids, &1["id"])))
        |> Enum.map(& &1["id"])

      refute aliases_with_classes == [], "expected at least one alias with a class entry"

      for alias_id <- aliases_with_classes do
        family = Enum.find(summary["families"], fn f -> alias_id in f["aliases"] end)

        assert family, "expected #{alias_id} to be attached to a family"

        refute alias_id in summary["orphan_aliases"],
               "expected #{alias_id} to be classified as a family alias, not an orphan"
      end
    end
  end

  describe "families with variants" do
    for {root, expected_variant, min_count} <- @families_with_variants do
      test "#{root} family has #{expected_variant} variant", %{summary: summary} do
        family = find_family(summary, unquote(root))
        assert family, "#{unquote(root)} family should exist"

        assert family["variant_count"] >= unquote(min_count),
               "#{unquote(root)} should have #{unquote(min_count)}+ variants, got #{family["variant_count"]}"

        assert unquote(expected_variant) in family["variants"],
               "#{unquote(expected_variant)} should be a variant of #{unquote(root)}"

        assert family["has_ws"] == true, "#{unquote(root)} should have WS support"
      end
    end
  end

  describe "families with aliases" do
    for {root, expected_alias} <- @families_with_aliases do
      test "#{root} family includes #{expected_alias} alias", %{summary: summary} do
        family = find_family(summary, unquote(root))
        assert family, "#{unquote(root)} family should exist"

        assert unquote(expected_alias) in family["aliases"],
               "#{unquote(expected_alias)} should be an alias of #{unquote(root)}"

        assert family["alias_count"] >= 1
      end
    end
  end

  describe "standalone exchange families" do
    for id <- @standalone_exchanges do
      test "#{id} is a standalone single-member family", %{summary: summary} do
        family = find_family(summary, unquote(id))
        assert family, "#{unquote(id)} family should exist"
        assert family["variant_count"] == 0
        assert family["alias_count"] == 0
        assert family["total_members"] == 1
        assert family["has_ws"] == true, "#{unquote(id)} should have WS support"
      end
    end
  end

  describe "DEX exchange families" do
    for id <- @dex_exchanges do
      test "#{id} DEX family exists with WS", %{summary: summary} do
        family = find_family(summary, unquote(id))
        assert family, "#{unquote(id)} family should exist"
        assert family["total_members"] >= 1
        assert family["has_ws"] == true, "#{unquote(id)} should have WS support"
      end
    end
  end

  describe "non-orphan aliases" do
    for id <- @non_orphan_aliases do
      test "#{id} is attached to a family, not orphaned", %{summary: summary} do
        refute unquote(id) in summary["orphan_aliases"],
               "#{unquote(id)} has a class file and should be in a family, not orphaned"
      end
    end
  end

  describe "write!/1" do
    @tag :tmp_dir
    test "writes valid JSON that round-trips", %{summary: summary, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "exchange_summary.json")

      assert :ok = Summary.write!(summary, output_path)
      assert File.exists?(output_path)

      reloaded = output_path |> File.read!() |> Jason.decode!()
      assert reloaded["counts"] == summary["counts"]
      assert length(reloaded["families"]) == length(summary["families"])
      assert reloaded["orphan_aliases"] == summary["orphan_aliases"]
    end
  end

  defp find_family(summary, root), do: Enum.find(summary["families"], &(&1["root"] == root))
end
