defmodule CcxtExtract.FamilyAnalysisIntegrationTest do
  use ExUnit.Case

  alias CcxtExtract.FamilyAnalysis

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 120_000

  # Generate discovery files once for the module.
  # Runs exchanges (QuickBEAM), classes (OXC), summary, and describe extractions.
  setup_all do
    {:ok, exchanges} = CcxtExtract.Exchanges.extract()
    CcxtExtract.Exchanges.write!(exchanges)

    {:ok, classes, _stats} = CcxtExtract.Classes.extract()
    CcxtExtract.Classes.write!(classes)

    {:ok, summary} = CcxtExtract.Summary.extract()
    CcxtExtract.Summary.write!(summary)

    {:ok, results} = CcxtExtract.Describe.extract()
    CcxtExtract.Describe.write!(results)

    {:ok, analysis} = FamilyAnalysis.extract()
    %{analysis: analysis}
  end

  describe "extract/0" do
    test "returns error when class_hierarchy.json is missing" do
      path = CcxtExtract.Paths.priv("discoveries/class_hierarchy.json")
      backup = path <> ".bak"
      File.rename!(path, backup)

      try do
        assert {:error, {:missing_input, ^path}} = FamilyAnalysis.extract()
      after
        File.rename!(backup, path)
      end
    end

    test "returns error when exchange_summary.json is missing" do
      path = CcxtExtract.Paths.priv("discoveries/exchange_summary.json")
      backup = path <> ".bak"
      File.rename!(path, backup)

      try do
        assert {:error, {:missing_input, ^path}} = FamilyAnalysis.extract()
      after
        File.rename!(backup, path)
      end
    end

    test "produces analysis with reasonable family counts", %{analysis: analysis} do
      summary = analysis["summary"]

      assert summary["total_families"] >= 90,
             "Expected 90+ families, got #{summary["total_families"]}"

      assert summary["multi_member"] >= 5,
             "Expected 5+ multi-member families, got #{summary["multi_member"]}"

      assert summary["standalone"] >= 80,
             "Expected 80+ standalone families, got #{summary["standalone"]}"
    end

    test "binance family has expected structure", %{analysis: analysis} do
      binance = Enum.find(analysis["families"], &(&1["root"] == "binance"))

      assert binance, "binance family should exist"
      assert binance["type"] == "multi_member"
      assert binance["root_method_count"] >= 100
      assert binance["has_ws"] == true

      member_ids = Enum.map(binance["members"], & &1["id"])
      assert "binanceus" in member_ids
      assert "binancecoinm" in member_ids
      assert "binanceusdm" in member_ids
    end

    test "describe diffs capture real differences", %{analysis: analysis} do
      binance = Enum.find(analysis["families"], &(&1["root"] == "binance"))
      binanceus = Enum.find(binance["members"], &(&1["id"] == "binanceus"))

      # binanceus adds "hostname" and changes identity keys
      assert "hostname" in binanceus["describe_changed_keys"]
    end

    test "describe is the most common own method", %{analysis: analysis} do
      overrides = analysis["summary"]["most_common_own_methods"]
      first = List.first(overrides)

      assert first["method"] == "describe"
    end
  end

  describe "write!/1" do
    @tag :tmp_dir
    test "writes valid JSON", %{analysis: analysis, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "family_analysis.json")

      assert :ok = FamilyAnalysis.write!(analysis, path)

      reloaded = path |> File.read!() |> Jason.decode!()
      assert reloaded["summary"]["total_families"] == analysis["summary"]["total_families"]
    end
  end
end
