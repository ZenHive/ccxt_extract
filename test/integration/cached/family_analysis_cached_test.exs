defmodule CcxtExtract.Integration.Cached.FamilyAnalysisCachedTest do
  @moduledoc """
  Validates FamilyAnalysis against cached discovery data.
  Reads from priv/discoveries/ — no QuickBEAM or OXC needed.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.FamilyAnalysis

  @moduletag :integration
  @moduletag timeout: 30_000

  @discoveries_dir CcxtExtract.Paths.discoveries()

  # Multi-member families from the roadmap investigation
  @multi_member_families [
    {"binance", ~w(binancecoinm binanceus binanceusdm), []},
    {"hitbtc", ~w(bequant fmfwio), []},
    {"okx", ~w(myokx okxus), []},
    {"kucoin", ~w(kucoinfutures), []},
    {"coinbase", [], ~w(coinbaseadvanced)},
    # CCXT 4.5.57 retired the `gateio` alias, so `gate` is now a standalone family.
    {"htx", [], ~w(huobi)}
  ]

  setup_all do
    classes_data =
      @discoveries_dir
      |> Path.join("class_hierarchy.json")
      |> File.read!()
      |> Jason.decode!()

    summary_data =
      @discoveries_dir
      |> Path.join("exchange_summary.json")
      |> File.read!()
      |> Jason.decode!()

    describe_dir = Path.join(@discoveries_dir, "describe")

    {:ok, analysis} = FamilyAnalysis.analyze(classes_data, summary_data, describe_dir)

    present_roots = MapSet.new(analysis["families"], & &1["root"])

    expected_families =
      Enum.filter(@multi_member_families, fn {root, _variants, _aliases} ->
        MapSet.member?(present_roots, root)
      end)

    %{analysis: analysis, expected_families: expected_families}
  end

  describe "analysis structure" do
    test "has required top-level keys", %{analysis: analysis} do
      assert is_binary(analysis["extracted_at"])
      assert is_map(analysis["source_files"])
      assert is_map(analysis["summary"])
      assert is_list(analysis["families"])
    end

    test "families cover all summary families", %{analysis: analysis} do
      summary_data =
        @discoveries_dir
        |> Path.join("exchange_summary.json")
        |> File.read!()
        |> Jason.decode!()

      assert length(analysis["families"]) == length(summary_data["families"])
    end
  end

  describe "summary" do
    test "counts match family list", %{analysis: analysis} do
      summary = analysis["summary"]
      families = analysis["families"]

      multi = Enum.count(families, &(&1["type"] == "multi_member"))
      standalone = Enum.count(families, &(&1["type"] == "standalone"))

      assert summary["total_families"] == length(families)
      assert summary["multi_member"] == multi
      assert summary["standalone"] == standalone
      assert summary["multi_member"] + summary["standalone"] == summary["total_families"]
    end

    test "most overridden methods is sorted by count descending", %{analysis: analysis} do
      overrides = analysis["summary"]["most_common_own_methods"]

      counts = Enum.map(overrides, & &1["count"])
      assert counts == Enum.sort(counts, :desc)
    end

    test "most changed describe keys is sorted by count descending", %{analysis: analysis} do
      keys = analysis["summary"]["most_changed_describe_keys"]

      counts = Enum.map(keys, & &1["count"])
      assert counts == Enum.sort(counts, :desc)
    end

    test "describe is the most overridden method", %{analysis: analysis} do
      overrides = analysis["summary"]["most_common_own_methods"]
      first = List.first(overrides)

      assert first["method"] == "describe"
    end
  end

  describe "standalone families" do
    test "have lightweight structure", %{analysis: analysis} do
      standalones = Enum.filter(analysis["families"], &(&1["type"] == "standalone"))
      refute standalones == [], "expected standalone families"

      for family <- standalones do
        assert is_binary(family["root"])
        assert is_integer(family["method_count"])
        assert is_boolean(family["has_ws"])
        refute Map.has_key?(family, "members"), "standalone should not have members key"
      end
    end
  end

  describe "multi-member families" do
    test "expected families have correct structure", %{analysis: analysis, expected_families: expected_families} do
      assert expected_families != [],
             "No multi-member families present in scoped data — test would be vacuous"

      for {root, expected_variants, expected_aliases} <- expected_families do
        family = Enum.find(analysis["families"], &(&1["root"] == root))

        assert family, "#{root} family should exist"
        assert family["type"] == "multi_member"
        assert is_integer(family["root_method_count"])
        assert family["root_method_count"] > 0
        assert is_integer(family["shared_method_count"])
        assert is_boolean(family["has_ws"])
        assert is_list(family["members"])

        member_ids = Enum.map(family["members"], & &1["id"])

        for variant <- expected_variants do
          assert variant in member_ids,
                 "#{variant} should be a member of #{root}"

          member = Enum.find(family["members"], &(&1["id"] == variant))
          assert member["relationship"] == "variant"
        end

        for alias_id <- expected_aliases do
          assert alias_id in member_ids,
                 "#{alias_id} should be a member of #{root}"

          member = Enum.find(family["members"], &(&1["id"] == alias_id))
          assert member["relationship"] == "alias"
        end
      end
    end

    test "all members have own method data", %{analysis: analysis} do
      multi = Enum.filter(analysis["families"], &(&1["type"] == "multi_member"))

      for family <- multi, member <- family["members"] do
        assert is_list(member["own_methods"]),
               "#{member["id"]}: own_methods should be a list"

        assert is_integer(member["own_method_count"]),
               "#{member["id"]}: own_method_count should be an integer"

        assert member["own_method_count"] == length(member["own_methods"]),
               "#{member["id"]}: override count mismatch"
      end
    end

    test "all members have describe diff data", %{analysis: analysis} do
      multi = Enum.filter(analysis["families"], &(&1["type"] == "multi_member"))

      for family <- multi, member <- family["members"] do
        assert is_list(member["describe_changed_keys"]),
               "#{member["id"]}: describe_changed_keys should be a list"

        # Variants have their own describe file, so diffs should be non-empty.
        # Aliases may lack a describe file (aliases were skipped in Task 6), so empty is ok.
        if member["relationship"] == "variant" do
          assert member["describe_changed_keys"] != [],
                 "#{member["id"]}: expected describe key diffs vs #{family["root"]}"
        end
      end
    end

    test "every member defines describe()", %{analysis: analysis} do
      multi = Enum.filter(analysis["families"], &(&1["type"] == "multi_member"))

      for family <- multi, member <- family["members"] do
        assert "describe" in member["own_methods"],
               "#{member["id"]}: expected describe in own_methods"
      end
    end
  end

  describe "families are sorted" do
    test "alphabetically by root", %{analysis: analysis} do
      roots = Enum.map(analysis["families"], & &1["root"])
      assert roots == Enum.sort(roots)
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON that round-trips", %{analysis: analysis, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "family_analysis.json")

      assert :ok = FamilyAnalysis.write!(analysis, output_path: output_path)
      assert File.exists?(output_path)

      reloaded = output_path |> File.read!() |> Jason.decode!()
      assert reloaded["summary"]["total_families"] == analysis["summary"]["total_families"]
      assert length(reloaded["families"]) == length(analysis["families"])
    end
  end
end
