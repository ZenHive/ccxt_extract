defmodule CcxtExtract.Integration.Cached.DescribeKeyAnalysisCachedTest do
  @moduledoc """
  Structure tests for describe_key_analysis.json — reads cached discovery output.
  Same assertions as DescribeKeyAnalysisIntegrationTest but without QuickBEAM boot.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir CcxtExtract.Paths.discoveries()
  @discovery_path Path.join(@fixtures_dir, "describe_key_analysis.json")

  # Keys that every CCXT exchange's describe() should have — must be universal tier
  @universal_keys ~w(id name has urls api)

  # Keys known to have nested structure (depth > 0)
  @nested_keys ~w(api has options fees exceptions)

  setup_all do
    analysis = @discovery_path |> File.read!() |> Jason.decode!()
    %{analysis: analysis}
  end

  describe "structure" do
    test "returns complete analysis with all required fields", %{analysis: analysis} do
      assert is_integer(analysis["exchange_count"])
      assert analysis["exchange_count"] >= 90
      assert is_integer(analysis["key_count"])
      assert analysis["key_count"] >= 10
      assert is_list(analysis["keys"])
      assert is_map(analysis["tiers"])
      assert is_binary(analysis["extracted_at"])
    end

    test "key_count matches keys list length", %{analysis: analysis} do
      assert analysis["key_count"] == length(analysis["keys"])
    end

    test "every key entry has required fields", %{analysis: analysis} do
      required_fields = ~w(key count percentage tier max_nesting_depth types)

      for key_stat <- analysis["keys"] do
        for field <- required_fields do
          assert Map.has_key?(key_stat, field),
                 "Key '#{key_stat["key"]}' missing field '#{field}'"
        end
      end
    end

    test "percentages are valid (0-100)", %{analysis: analysis} do
      for key_stat <- analysis["keys"] do
        assert key_stat["percentage"] >= 0.0 and key_stat["percentage"] <= 100.0,
               "Key '#{key_stat["key"]}' has invalid percentage: #{key_stat["percentage"]}"
      end
    end

    test "type counts sum to key count per entry", %{analysis: analysis} do
      for key_stat <- analysis["keys"] do
        type_total = key_stat["types"] |> Map.values() |> Enum.sum()

        assert type_total == key_stat["count"],
               "Key '#{key_stat["key"]}': type counts (#{type_total}) != count (#{key_stat["count"]})"
      end
    end

    test "keys sorted by count descending", %{analysis: analysis} do
      counts = Enum.map(analysis["keys"], & &1["count"])
      assert counts == Enum.sort(counts, :desc)
    end
  end

  describe "tier classification" do
    test "universal tier contains expected keys", %{analysis: analysis} do
      universal = analysis["tiers"]["universal"] || []

      for key <- @universal_keys do
        assert key in universal,
               "'#{key}' should be in universal tier, got: #{inspect(universal)}"
      end
    end

    test "every key appears in exactly one tier", %{analysis: analysis} do
      all_tier_keys =
        analysis["tiers"]
        |> Map.values()
        |> List.flatten()

      key_names = Enum.map(analysis["keys"], & &1["key"])

      assert length(all_tier_keys) == length(key_names),
             "Tier keys count (#{length(all_tier_keys)}) != total keys (#{length(key_names)})"

      assert Enum.sort(all_tier_keys) == Enum.sort(key_names)
    end

    test "tiers use valid tier names", %{analysis: analysis} do
      valid_tiers = ~w(universal common frequent uncommon rare)

      for {tier_name, _keys} <- analysis["tiers"] do
        assert tier_name in valid_tiers,
               "Invalid tier name: #{inspect(tier_name)}"
      end
    end

    test "universal keys have 100% percentage", %{analysis: analysis} do
      universal_keys = analysis["tiers"]["universal"] || []

      for key_stat <- analysis["keys"],
          key_stat["key"] in universal_keys do
        assert key_stat["percentage"] == 100.0,
               "Universal key '#{key_stat["key"]}' should be 100%, got #{key_stat["percentage"]}"
      end
    end
  end

  describe "nesting depth" do
    test "all keys have nesting depth values", %{analysis: analysis} do
      for key_stat <- analysis["keys"] do
        assert is_integer(key_stat["max_nesting_depth"]),
               "Key '#{key_stat["key"]}' missing nesting depth"
      end
    end

    for key <- @nested_keys do
      test "#{key} has nesting depth > 0", %{analysis: analysis} do
        key_stat = Enum.find(analysis["keys"], &(&1["key"] == unquote(key)))

        assert key_stat,
               "Expected key '#{unquote(key)}' in analysis but not found"

        assert key_stat["max_nesting_depth"] > 0,
               "'#{unquote(key)}' should have depth > 0, got #{key_stat["max_nesting_depth"]}"
      end
    end

    test "primitive keys have depth 0", %{analysis: analysis} do
      id_stat = Enum.find(analysis["keys"], &(&1["key"] == "id"))
      assert id_stat["max_nesting_depth"] == 0
    end
  end

  describe "type consistency" do
    test "id is always string type", %{analysis: analysis} do
      id_stat = Enum.find(analysis["keys"], &(&1["key"] == "id"))
      assert id_stat["types"] == %{"string" => id_stat["count"]}
    end

    test "has is always object type", %{analysis: analysis} do
      has_stat = Enum.find(analysis["keys"], &(&1["key"] == "has"))
      assert has_stat["types"] == %{"object" => has_stat["count"]}
    end

    test "some keys have mixed types (type inconsistency exists)", %{analysis: analysis} do
      mixed_type_keys =
        Enum.filter(analysis["keys"], fn stat -> map_size(stat["types"]) > 1 end)

      assert mixed_type_keys != [],
             "Expected at least one key with mixed types across exchanges"
    end
  end
end
