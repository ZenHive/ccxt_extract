defmodule CcxtExtract.MethodAnalysisIntegrationTest do
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers
  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.MethodAnalysis

  @moduletag :integration
  @moduletag timeout: 30_000

  # Reference exchanges from CLAUDE.md tiers
  @tier1_rest ~w(binance bybit okx deribit coinbaseexchange)
  @tier2_rest ~w(kraken kucoin gate htx bitmex)
  @dex_rest ~w(hyperliquid)

  # Methods that should be universal across all REST exchanges
  @universal_rest_methods ~w(describe)

  # Known CCXT prefix families that must appear
  @expected_rest_families ~w(fetch parse create cancel sign)
  @expected_ws_families ~w(watch handle)

  # Run full extraction once — reads from JSON files, no runtime needed
  # Also load raw method data so integration tests can verify per-exchange coverage
  setup_all do
    {:ok, analysis} = MethodAnalysis.extract()

    rest_path = CcxtExtract.Paths.priv(Path.join("discoveries", "methods_rest.json"))
    raw_rest = rest_path |> File.read!() |> Jason.decode!()
    rest_by_exchange = Map.new(raw_rest["exchanges"], &{&1["id"], &1})

    %{analysis: analysis, rest_by_exchange: rest_by_exchange}
  end

  describe "extract/0 structure" do
    test "returns complete analysis with all sections", %{analysis: analysis} do
      assert is_map(analysis["rest"])
      assert is_map(analysis["ws"])
      assert is_map(analysis["cross_type"])
      assert is_binary(analysis["extracted_at"])
    end
  end

  describe "REST analysis" do
    test "has reasonable exchange and method counts", %{analysis: analysis} do
      rest = analysis["rest"]

      # Task 13b: dispatch on the canonical envelope stamp from
      # `describe/_manifest.json` rather than observed counts. Post-Task-13a,
      # `MethodAnalysis.write!/2` stamps `tier_scope` correctly, but the
      # in-memory return of `extract/0` does not surface it; the corpus
      # anchor is the scope-of-record for cross-extractor analyses.
      if corpus_full_universe?() do
        assert rest["exchange_count"] >= 100
        assert rest["total_methods"] >= 4000
        assert rest["unique_method_names"] >= 100
      else
        # Scoped run: assert internal consistency only. Absolute floors are
        # not meaningful when the corpus is a tier subset.
        assert rest["exchange_count"] > 0
        assert rest["total_methods"] > 0
        assert rest["unique_method_names"] > 0
      end
    end

    test "families contain expected prefix groups", %{analysis: analysis} do
      family_names = Map.keys(analysis["rest"]["families"])

      for family <- @expected_rest_families do
        assert family in family_names,
               "Expected REST family '#{family}', got: #{inspect(Enum.sort(family_names))}"
      end
    end

    test "fetch family is the largest", %{analysis: analysis} do
      families = analysis["rest"]["families"]
      fetch_count = families["fetch"]["count"]

      for {prefix, data} <- families, prefix != "fetch" do
        assert fetch_count >= data["count"],
               "Expected fetch (#{fetch_count}) >= #{prefix} (#{data["count"]})"
      end
    end

    test "universal methods include describe", %{analysis: analysis} do
      universal_names = Enum.map(analysis["rest"]["universal_methods"], & &1["name"])

      for method <- @universal_rest_methods do
        assert method in universal_names,
               "'#{method}' should be universal, got: #{inspect(universal_names)}"
      end
    end

    test "universal methods have 100% percentage", %{analysis: analysis} do
      for method <- analysis["rest"]["universal_methods"] do
        assert method["percentage"] == 100.0,
               "Universal method '#{method["name"]}' should be 100%, got #{method["percentage"]}"
      end
    end

    test "unique methods have exactly 1 exchange", %{analysis: analysis} do
      unique = analysis["rest"]["unique_methods"]
      assert is_list(unique)
      assert unique != [], "Expected at least some unique REST methods"

      for method <- unique do
        assert method["count"] == 1,
               "Unique method '#{method["name"]}' should have count 1, got #{method["count"]}"
      end
    end

    test "unique methods are a subset of rare methods", %{analysis: analysis} do
      unique_names = MapSet.new(analysis["rest"]["unique_methods"], & &1["name"])
      rare_names = MapSet.new(analysis["rest"]["rare_methods"], & &1["name"])

      assert MapSet.subset?(unique_names, rare_names),
             "All unique methods (count==1) should also be rare (count<5)"
    end

    test "rare methods have fewer than 5 exchanges", %{analysis: analysis} do
      for method <- analysis["rest"]["rare_methods"] do
        assert method["count"] < 5,
               "Rare method '#{method["name"]}' has #{method["count"]} exchanges (expected < 5)"
      end
    end

    test "method count distribution has valid stats", %{analysis: analysis} do
      dist = analysis["rest"]["method_count_distribution"]

      assert dist["min"] > 0
      assert dist["max"] >= dist["min"]
      assert dist["median"] >= dist["min"]
      assert dist["median"] <= dist["max"]
      assert dist["mean"] > 0
      assert dist["p25"] <= dist["median"]
      assert dist["p75"] >= dist["median"]
    end

    test "family method percentages are valid (0-100)", %{analysis: analysis} do
      for {_prefix, family_data} <- analysis["rest"]["families"],
          method <- family_data["methods"] do
        assert method["percentage"] >= 0.0 and method["percentage"] <= 100.0,
               "Method '#{method["name"]}' has invalid percentage: #{method["percentage"]}"
      end
    end

    for exchange <- @tier1_rest ++ @tier2_rest ++ @dex_rest do
      test "family methods cover reference exchange #{exchange}", %{
        analysis: analysis,
        rest_by_exchange: rest_by_exchange
      } do
        exchange_id = unquote(exchange)

        # Verify this reference exchange exists in the source data
        assert Map.has_key?(rest_by_exchange, exchange_id),
               "Reference exchange '#{exchange_id}' missing from methods_rest.json"

        exchange_data = rest_by_exchange[exchange_id]
        exchange_methods = MapSet.new(exchange_data["methods"], & &1["name"])

        # All family methods in the analysis
        all_family_methods =
          analysis["rest"]["families"]
          |> Enum.flat_map(fn {_prefix, data} -> Enum.map(data["methods"], & &1["name"]) end)
          |> MapSet.new()

        # Every method from this reference exchange should appear in the family analysis
        missing = MapSet.difference(exchange_methods, all_family_methods)

        assert MapSet.size(missing) == 0,
               "Methods from #{exchange_id} missing in family analysis: #{inspect(MapSet.to_list(missing))}"

        # Sanity: exchange should have a reasonable number of methods
        assert MapSet.size(exchange_methods) >= 3,
               "Reference exchange #{exchange_id} has only #{MapSet.size(exchange_methods)} methods"
      end
    end
  end

  describe "WS analysis" do
    test "has reasonable exchange and method counts", %{analysis: analysis} do
      ws = analysis["ws"]

      if corpus_full_universe?() do
        assert ws["exchange_count"] >= 60
        assert ws["total_methods"] >= 1000
        assert ws["unique_method_names"] >= 30
      else
        assert ws["exchange_count"] > 0
        assert ws["total_methods"] > 0
        assert ws["unique_method_names"] > 0
      end
    end

    test "families contain expected prefix groups", %{analysis: analysis} do
      family_names = Map.keys(analysis["ws"]["families"])

      for family <- @expected_ws_families do
        assert family in family_names,
               "Expected WS family '#{family}', got: #{inspect(Enum.sort(family_names))}"
      end
    end

    test "watch and handle families are prominent", %{analysis: analysis} do
      families = analysis["ws"]["families"]

      # watch and handle should have substantial method counts
      assert families["watch"]["count"] >= 5
      assert families["handle"]["count"] >= 5
    end
  end

  describe "cross-type analysis" do
    test "has all required fields", %{analysis: analysis} do
      cross = analysis["cross_type"]

      assert is_list(cross["shared_methods"])
      assert is_list(cross["rest_only_methods"])
      assert is_list(cross["ws_only_methods"])
      assert is_integer(cross["shared_count"])
      assert is_integer(cross["rest_only_count"])
      assert is_integer(cross["ws_only_count"])
    end

    test "describe is a shared method", %{analysis: analysis} do
      assert "describe" in analysis["cross_type"]["shared_methods"]
    end

    test "watch methods are WS-only", %{analysis: analysis} do
      ws_only = analysis["cross_type"]["ws_only_methods"]
      watch_methods = Enum.filter(ws_only, &String.starts_with?(&1, "watch"))

      assert length(watch_methods) >= 5,
             "Expected at least 5 watch* methods in WS-only, got #{length(watch_methods)}"
    end

    test "fetch methods are REST-only", %{analysis: analysis} do
      rest_only = analysis["cross_type"]["rest_only_methods"]
      fetch_methods = Enum.filter(rest_only, &String.starts_with?(&1, "fetch"))

      assert length(fetch_methods) >= 5,
             "Expected at least 5 fetch* methods in REST-only, got #{length(fetch_methods)}"
    end

    test "lists are sorted alphabetically", %{analysis: analysis} do
      cross = analysis["cross_type"]

      assert cross["shared_methods"] == Enum.sort(cross["shared_methods"])
      assert cross["rest_only_methods"] == Enum.sort(cross["rest_only_methods"])
      assert cross["ws_only_methods"] == Enum.sort(cross["ws_only_methods"])
    end

    test "counts match list lengths", %{analysis: analysis} do
      cross = analysis["cross_type"]

      assert cross["shared_count"] == length(cross["shared_methods"])
      assert cross["rest_only_count"] == length(cross["rest_only_methods"])
      assert cross["ws_only_count"] == length(cross["ws_only_methods"])
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON roundtrip", %{analysis: analysis, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "method_analysis.json")

      assert :ok = MethodAnalysis.write!(analysis, output_path: output_path)
      assert File.exists?(output_path)

      parsed = output_path |> File.read!() |> Jason.decode!()
      assert parsed["rest"]["exchange_count"] == analysis["rest"]["exchange_count"]
      assert parsed["ws"]["exchange_count"] == analysis["ws"]["exchange_count"]
      assert parsed["cross_type"]["shared_count"] == analysis["cross_type"]["shared_count"]
    end
  end

  describe "mix ccxt_extract.method_analysis" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.MethodAnalysis)

      assert output =~ "Analyzing method families"
      assert output =~ "Done."
      assert output =~ "REST:"
      assert output =~ "WS:"
      assert output =~ "Cross-type:"
      assert output =~ "Output: priv/discoveries/method_analysis.json"
    end
  end
end
