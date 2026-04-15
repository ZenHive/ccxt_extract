defmodule CcxtExtract.FamilyAnalysisTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CcxtExtract.FamilyAnalysis

  # --- Fixtures ---

  defp sample_families do
    [
      %{
        "root" => "binance",
        "variants" => ["binanceus", "binancecoinm"],
        "aliases" => [],
        "variant_count" => 2,
        "alias_count" => 0,
        "total_members" => 3,
        "has_ws" => true
      },
      %{
        "root" => "htx",
        "variants" => [],
        "aliases" => ["huobi"],
        "variant_count" => 0,
        "alias_count" => 1,
        "total_members" => 2,
        "has_ws" => true
      },
      %{
        "root" => "kraken",
        "variants" => [],
        "aliases" => [],
        "variant_count" => 0,
        "alias_count" => 0,
        "total_members" => 1,
        "has_ws" => true
      },
      %{
        "root" => "luno",
        "variants" => [],
        "aliases" => [],
        "variant_count" => 0,
        "alias_count" => 0,
        "total_members" => 1,
        "has_ws" => false
      }
    ]
  end

  defp sample_class_lookup do
    %{
      "binance" => %{
        "id" => "binance",
        "type" => "rest",
        "method_count" => 166,
        "methods" => ["describe", "fetchMarkets", "sign", "handleErrors"]
      },
      "binanceus" => %{
        "id" => "binanceus",
        "type" => "rest",
        "method_count" => 1,
        "methods" => ["describe"]
      },
      "binancecoinm" => %{
        "id" => "binancecoinm",
        "type" => "rest",
        "method_count" => 3,
        "methods" => ["describe", "transferIn", "transferOut"]
      },
      "htx" => %{
        "id" => "htx",
        "type" => "rest",
        "method_count" => 120,
        "methods" => ["describe", "fetchMarkets", "sign"]
      },
      "huobi" => %{
        "id" => "huobi",
        "type" => "rest",
        "method_count" => 1,
        "methods" => ["describe"]
      },
      "kraken" => %{
        "id" => "kraken",
        "type" => "rest",
        "method_count" => 95,
        "methods" => ["describe", "fetchMarkets", "sign"]
      },
      "luno" => %{
        "id" => "luno",
        "type" => "rest",
        "method_count" => 40,
        "methods" => ["describe", "fetchMarkets"]
      }
    }
  end

  describe "diff_describe_keys/2" do
    test "returns empty list for identical maps" do
      m = %{"id" => "okx", "name" => "OKX", "has" => %{"fetchTicker" => true}}
      assert FamilyAnalysis.diff_describe_keys(m, m) == []
    end

    test "detects changed scalar values" do
      root = %{"id" => "okx", "name" => "OKX", "hostname" => "www.okx.com"}
      member = %{"id" => "okxus", "name" => "OKX (US)", "hostname" => "us.okx.com"}

      assert FamilyAnalysis.diff_describe_keys(root, member) == ["hostname", "id", "name"]
    end

    test "detects keys only in one map" do
      root = %{"id" => "binance", "name" => "Binance"}
      member = %{"id" => "binanceus", "name" => "Binance US", "hostname" => "binance.us"}

      diff = FamilyAnalysis.diff_describe_keys(root, member)
      assert "hostname" in diff
      assert "id" in diff
      assert "name" in diff
    end

    test "ignores unchanged nested objects" do
      shared = %{"fetchTicker" => true, "fetchBalance" => true}
      root = %{"id" => "a", "has" => shared}
      member = %{"id" => "b", "has" => shared}

      assert FamilyAnalysis.diff_describe_keys(root, member) == ["id"]
    end

    test "detects changed nested objects" do
      root = %{"id" => "a", "has" => %{"fetchTicker" => true}}
      member = %{"id" => "a", "has" => %{"fetchTicker" => false}}

      assert FamilyAnalysis.diff_describe_keys(root, member) == ["has"]
    end

    test "returns sorted keys" do
      root = %{"z" => 1, "a" => 2, "m" => 3}
      member = %{"z" => 9, "a" => 8, "m" => 7}

      assert FamilyAnalysis.diff_describe_keys(root, member) == ["a", "m", "z"]
    end

    test "handles empty maps" do
      assert FamilyAnalysis.diff_describe_keys(%{}, %{}) == []
      assert FamilyAnalysis.diff_describe_keys(%{"a" => 1}, %{}) == ["a"]
      assert FamilyAnalysis.diff_describe_keys(%{}, %{"a" => 1}) == ["a"]
    end
  end

  describe "analyze_family/3 standalone" do
    test "returns lightweight entry for standalone family" do
      family = Enum.find(sample_families(), &(&1["root"] == "kraken"))
      result = FamilyAnalysis.analyze_family(family, sample_class_lookup(), "/nonexistent")

      assert result["root"] == "kraken"
      assert result["type"] == "standalone"
      assert result["method_count"] == 95
      assert result["has_ws"] == true
    end

    test "handles missing class lookup gracefully" do
      family = %{
        "root" => "unknown",
        "variants" => [],
        "aliases" => [],
        "total_members" => 1,
        "has_ws" => false
      }

      result = FamilyAnalysis.analyze_family(family, %{}, "/nonexistent")

      assert result["type"] == "standalone"
      assert result["method_count"] == 0
    end
  end

  describe "analyze_family/3 multi-member" do
    test "returns own methods defined by child for variants" do
      family = Enum.find(sample_families(), &(&1["root"] == "binance"))
      result = FamilyAnalysis.analyze_family(family, sample_class_lookup(), "/nonexistent")

      assert result["root"] == "binance"
      assert result["type"] == "multi_member"
      assert result["root_method_count"] == 4
      assert result["has_ws"] == true

      binanceus = Enum.find(result["members"], &(&1["id"] == "binanceus"))
      assert binanceus["relationship"] == "variant"
      assert binanceus["own_methods"] == ["describe"]
      assert binanceus["own_method_count"] == 1

      coinm = Enum.find(result["members"], &(&1["id"] == "binancecoinm"))
      assert coinm["own_methods"] == ["describe", "transferIn", "transferOut"]
      assert coinm["own_method_count"] == 3
    end

    test "classifies aliases correctly" do
      family = Enum.find(sample_families(), &(&1["root"] == "htx"))
      result = FamilyAnalysis.analyze_family(family, sample_class_lookup(), "/nonexistent")

      huobi = Enum.find(result["members"], &(&1["id"] == "huobi"))
      assert huobi["relationship"] == "alias"
    end

    test "computes shared method count" do
      family = Enum.find(sample_families(), &(&1["root"] == "binance"))
      result = FamilyAnalysis.analyze_family(family, sample_class_lookup(), "/nonexistent")

      # binance has 4 methods: describe, fetchMarkets, sign, handleErrors
      # binanceus defines: describe
      # binancecoinm defines: describe, transferIn, transferOut
      # All overridden: describe, transferIn, transferOut (transferIn/Out are new, not in root)
      # Shared = root methods not overridden by anyone = fetchMarkets, sign, handleErrors
      assert result["shared_method_count"] == 3
    end

    @tag :tmp_dir
    test "logs warning when root describe file is missing", %{tmp_dir: tmp_dir} do
      family = Enum.find(sample_families(), &(&1["root"] == "binance"))
      member_path = Path.join(tmp_dir, "binanceus.json")
      File.write!(member_path, Jason.encode!(%{"describe" => %{"id" => "binanceus"}}))

      log =
        capture_log(fn ->
          result = FamilyAnalysis.analyze_family(family, sample_class_lookup(), tmp_dir)
          member = Enum.find(result["members"], &(&1["id"] == "binanceus"))
          assert member["describe_changed_keys"] == []
        end)

      assert log =~ "Missing describe file for root exchange binance"
      assert log =~ Path.join(tmp_dir, "binance.json")
    end

    @tag :tmp_dir
    test "does not log warning when member describe file is missing", %{tmp_dir: tmp_dir} do
      family = Enum.find(sample_families(), &(&1["root"] == "binance"))
      root_path = Path.join(tmp_dir, "binance.json")
      File.write!(root_path, Jason.encode!(%{"describe" => %{"id" => "binance"}}))

      log =
        capture_log(fn ->
          result = FamilyAnalysis.analyze_family(family, sample_class_lookup(), tmp_dir)
          member = Enum.find(result["members"], &(&1["id"] == "binanceus"))
          assert member["describe_changed_keys"] == []
        end)

      assert log == ""
    end
  end

  describe "build_summary/1" do
    test "computes correct counts" do
      # Use analyze_family to produce family analyses first
      analyses =
        Enum.map(sample_families(), fn f ->
          FamilyAnalysis.analyze_family(f, sample_class_lookup(), "/nonexistent")
        end)

      summary = FamilyAnalysis.build_summary(analyses)

      assert summary["total_families"] == 4
      assert summary["multi_member"] == 2
      assert summary["standalone"] == 2
    end

    test "computes size distribution" do
      analyses =
        Enum.map(sample_families(), fn f ->
          FamilyAnalysis.analyze_family(f, sample_class_lookup(), "/nonexistent")
        end)

      summary = FamilyAnalysis.build_summary(analyses)
      dist = summary["size_distribution"]

      assert dist["min"] == 1
      assert dist["max"] == 3
      assert is_map(dist["sizes"])
    end

    test "tracks most common own methods" do
      analyses =
        Enum.map(sample_families(), fn f ->
          FamilyAnalysis.analyze_family(f, sample_class_lookup(), "/nonexistent")
        end)

      summary = FamilyAnalysis.build_summary(analyses)
      overrides = summary["most_common_own_methods"]

      assert is_list(overrides)
      # "describe" overridden by binanceus, binancecoinm, and huobi = 3
      describe_entry = Enum.find(overrides, &(&1["method"] == "describe"))
      assert describe_entry["count"] == 3
    end

    test "handles empty input" do
      summary = FamilyAnalysis.build_summary([])

      assert summary["total_families"] == 0
      assert summary["multi_member"] == 0
      assert summary["standalone"] == 0
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON that round-trips", %{tmp_dir: tmp_dir} do
      analyses =
        Enum.map(sample_families(), fn f ->
          FamilyAnalysis.analyze_family(f, sample_class_lookup(), "/nonexistent")
        end)

      analysis = %{
        "extracted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "summary" => FamilyAnalysis.build_summary(analyses),
        "families" => analyses
      }

      output_path = Path.join(tmp_dir, "family_analysis.json")
      assert :ok = FamilyAnalysis.write!(analysis, output_path: output_path)
      assert File.exists?(output_path)

      reloaded = output_path |> File.read!() |> Jason.decode!()
      assert reloaded["summary"]["total_families"] == 4
      assert length(reloaded["families"]) == 4
    end
  end
end
