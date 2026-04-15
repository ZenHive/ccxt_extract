defmodule CcxtExtract.DescribeKeyAnalysisTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.DescribeKeyAnalysis

  # 10 mock exchanges — enough to exercise all tier thresholds
  @mock_exchanges [
    %{
      "id" => "ex1",
      "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object", "rare_key" => "string"}
    },
    %{"id" => "ex2", "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object"}},
    %{"id" => "ex3", "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object"}},
    %{"id" => "ex4", "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object"}},
    %{"id" => "ex5", "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object"}},
    %{
      "id" => "ex6",
      "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object", "uncommon" => "boolean"}
    },
    %{
      "id" => "ex7",
      "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object", "uncommon" => "boolean"}
    },
    %{
      "id" => "ex8",
      "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object", "uncommon" => "boolean"}
    },
    %{
      "id" => "ex9",
      "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object", "uncommon" => "boolean"}
    },
    %{
      "id" => "ex10",
      "keys" => %{"id" => "string", "name" => "string", "has" => "object", "api" => "object", "uncommon" => "boolean"}
    }
  ]

  describe "classify_tier/2" do
    test "universal when count equals total" do
      assert DescribeKeyAnalysis.classify_tier(100, 100) == "universal"
    end

    test "common when >90%" do
      assert DescribeKeyAnalysis.classify_tier(95, 100) == "common"
    end

    test "frequent when >50%" do
      assert DescribeKeyAnalysis.classify_tier(60, 100) == "frequent"
    end

    test "uncommon when >=5 but <=50%" do
      assert DescribeKeyAnalysis.classify_tier(10, 100) == "uncommon"
    end

    test "rare when <5 exchanges" do
      assert DescribeKeyAnalysis.classify_tier(3, 100) == "rare"
    end

    test "rare when total is 0" do
      assert DescribeKeyAnalysis.classify_tier(0, 0) == "rare"
    end

    test "boundary: exactly 90% is not common (requires >90%)" do
      # 90/100 = exactly 90%, not > 90%
      assert DescribeKeyAnalysis.classify_tier(90, 100) == "frequent"
    end

    test "boundary: exactly 50% is not frequent (requires >50%)" do
      assert DescribeKeyAnalysis.classify_tier(50, 100) == "uncommon"
    end

    test "boundary: exactly 5 exchanges is uncommon" do
      assert DescribeKeyAnalysis.classify_tier(5, 100) == "uncommon"
    end

    test "boundary: 4 exchanges is rare" do
      assert DescribeKeyAnalysis.classify_tier(4, 100) == "rare"
    end
  end

  describe "build_key_stats/3" do
    test "counts occurrences and computes percentages" do
      stats = DescribeKeyAnalysis.build_key_stats(@mock_exchanges, 10, %{})

      id_stat = Enum.find(stats, &(&1["key"] == "id"))
      assert id_stat["count"] == 10
      assert id_stat["percentage"] == 100.0
      assert id_stat["tier"] == "universal"
    end

    test "classifies rare keys correctly" do
      stats = DescribeKeyAnalysis.build_key_stats(@mock_exchanges, 10, %{})

      rare_stat = Enum.find(stats, &(&1["key"] == "rare_key"))
      assert rare_stat["count"] == 1
      assert rare_stat["percentage"] == 10.0
      assert rare_stat["tier"] == "rare"
    end

    test "classifies uncommon keys correctly" do
      stats = DescribeKeyAnalysis.build_key_stats(@mock_exchanges, 10, %{})

      uncommon_stat = Enum.find(stats, &(&1["key"] == "uncommon"))
      assert uncommon_stat["count"] == 5
      assert uncommon_stat["percentage"] == 50.0
      assert uncommon_stat["tier"] == "uncommon"
    end

    test "includes type breakdown" do
      stats = DescribeKeyAnalysis.build_key_stats(@mock_exchanges, 10, %{})

      id_stat = Enum.find(stats, &(&1["key"] == "id"))
      assert id_stat["types"] == %{"string" => 10}

      has_stat = Enum.find(stats, &(&1["key"] == "has"))
      assert has_stat["types"] == %{"object" => 10}
    end

    test "includes nesting depth when provided" do
      depths = %{"id" => 0, "api" => 4, "has" => 1}
      stats = DescribeKeyAnalysis.build_key_stats(@mock_exchanges, 10, depths)

      id_stat = Enum.find(stats, &(&1["key"] == "id"))
      assert id_stat["max_nesting_depth"] == 0

      api_stat = Enum.find(stats, &(&1["key"] == "api"))
      assert api_stat["max_nesting_depth"] == 4
    end

    test "nesting depth is nil when not provided" do
      stats = DescribeKeyAnalysis.build_key_stats(@mock_exchanges, 10, %{})

      id_stat = Enum.find(stats, &(&1["key"] == "id"))
      assert id_stat["max_nesting_depth"] == nil
    end

    test "sorted by count descending then key ascending" do
      stats = DescribeKeyAnalysis.build_key_stats(@mock_exchanges, 10, %{})
      keys = Enum.map(stats, & &1["key"])

      # Universal keys (count=10) come first, sorted alphabetically
      universal_keys = Enum.take_while(keys, fn k -> k in ~w(api has id name) end)
      assert universal_keys == Enum.sort(universal_keys)
    end

    test "handles empty exchange list" do
      assert DescribeKeyAnalysis.build_key_stats([], 0, %{}) == []
    end

    test "handles exchanges with nil keys" do
      exchanges = [%{"id" => "test", "keys" => nil}]
      assert DescribeKeyAnalysis.build_key_stats(exchanges, 1, %{}) == []
    end
  end

  describe "build_key_stats/3 with mixed types" do
    test "tracks multiple types for same key" do
      exchanges = [
        %{"id" => "ex1", "keys" => %{"markets" => "object"}},
        %{"id" => "ex2", "keys" => %{"markets" => "undefined"}},
        %{"id" => "ex3", "keys" => %{"markets" => "object"}}
      ]

      stats = DescribeKeyAnalysis.build_key_stats(exchanges, 3, %{})
      markets_stat = Enum.find(stats, &(&1["key"] == "markets"))

      assert markets_stat["types"] == %{"object" => 2, "undefined" => 1}
      assert markets_stat["count"] == 3
    end
  end

  describe "analyze/2" do
    test "produces complete analysis structure" do
      analysis = DescribeKeyAnalysis.analyze(@mock_exchanges)

      assert analysis["exchange_count"] == 10
      assert is_integer(analysis["key_count"])
      assert analysis["key_count"] > 0
      assert is_list(analysis["keys"])
      assert is_map(analysis["tiers"])
      assert is_binary(analysis["extracted_at"])
    end

    test "tiers contain correct keys" do
      analysis = DescribeKeyAnalysis.analyze(@mock_exchanges)

      assert "id" in analysis["tiers"]["universal"]
      assert "name" in analysis["tiers"]["universal"]
      assert "rare_key" in analysis["tiers"]["rare"]
      assert "uncommon" in analysis["tiers"]["uncommon"]
    end

    test "all keys appear in exactly one tier" do
      analysis = DescribeKeyAnalysis.analyze(@mock_exchanges)

      all_tier_keys =
        analysis["tiers"]
        |> Map.values()
        |> List.flatten()

      key_names = Enum.map(analysis["keys"], & &1["key"])

      assert Enum.sort(all_tier_keys) == Enum.sort(key_names)
    end

    test "merges nesting depths into stats" do
      depths = %{"id" => 0, "has" => 1}
      analysis = DescribeKeyAnalysis.analyze(@mock_exchanges, depths)

      id_stat = Enum.find(analysis["keys"], &(&1["key"] == "id"))
      assert id_stat["max_nesting_depth"] == 0
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with analysis data", %{tmp_dir: tmp_dir} do
      analysis = DescribeKeyAnalysis.analyze(@mock_exchanges)
      output_path = Path.join(tmp_dir, "analysis.json")

      assert :ok = DescribeKeyAnalysis.write!(analysis, output_path: output_path)
      assert File.exists?(output_path)

      parsed = output_path |> File.read!() |> Jason.decode!()

      assert parsed["exchange_count"] == 10
      assert is_list(parsed["keys"])
      assert is_map(parsed["tiers"])
      assert is_binary(parsed["extracted_at"])
    end
  end
end
