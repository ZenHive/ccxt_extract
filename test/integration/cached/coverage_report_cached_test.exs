defmodule CcxtExtract.Integration.Cached.CoverageReportCachedTest do
  @moduledoc """
  Cached integration tests for CoverageReport — reads fixture JSON files.
  No QuickBEAM/OXC needed.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir CcxtExtract.Paths.discoveries()

  # Reference exchanges from CLAUDE.md
  @tier1 ~w(binance bybit okx deribit coinbaseexchange)
  @tier2 ~w(kraken kucoin gate htx bitmex)
  @dex ~w(hyperliquid)

  setup_all do
    report = CcxtExtract.CoverageReport.extract(discoveries_dir: @fixtures_dir)

    case report do
      {:ok, data} ->
        by_id = Map.new(data["exchanges"], &{&1["id"], &1})
        %{report: data, by_id: by_id}

      {:error, reason} ->
        raise "Failed to generate coverage report from fixtures: #{inspect(reason)}"
    end
  end

  describe "report structure" do
    test "has required top-level fields", %{report: report} do
      assert is_binary(report["extracted_at"])
      assert is_integer(report["exchange_count"])
      assert is_map(report["summary"])
      assert is_list(report["exchanges"])
      assert is_list(report["gaps_summary"])
    end

    test "exchange count matches exchanges.json fixture", %{report: report} do
      exchanges_path = Path.join(@fixtures_dir, "exchanges.json")
      exchanges_data = exchanges_path |> File.read!() |> Jason.decode!()
      assert report["exchange_count"] == length(exchanges_data["exchanges"])
    end

    test "all exchanges have entries", %{report: report} do
      assert length(report["exchanges"]) == report["exchange_count"]
    end
  end

  describe "summary consistency" do
    test "full + partial + no_coverage == exchange_count", %{report: report} do
      summary = report["summary"]

      assert summary["full_coverage"] + summary["partial_coverage"] + summary["no_coverage"] ==
               report["exchange_count"]
    end

    test "avg_coverage_pct between 0 and 100", %{report: report} do
      assert report["summary"]["avg_coverage_pct"] >= 0.0
      assert report["summary"]["avg_coverage_pct"] <= 100.0
    end

    test "per_layer covers all 10 layers", %{report: report} do
      per_layer = report["summary"]["per_layer"]

      expected_layers =
        ~w(describe load_markets class_hierarchy methods_rest methods_ws sign_method handle_errors parse_methods ws_methods overrides)

      for layer_name <- expected_layers do
        assert Map.has_key?(per_layer, layer_name), "Missing layer: #{layer_name}"
        layer = per_layer[layer_name]
        assert layer["present"] >= 0
        assert layer["missing"] >= 0
        assert layer["applicable"] == layer["present"] + layer["missing"]
      end
    end

    test "per_layer present counts are reasonable", %{report: report} do
      per_layer = report["summary"]["per_layer"]

      # Dispatch on the canonical scope envelope — `describe/_manifest.json`'s
      # `tier_scope` stamp records what produced the underlying fixtures.
      # Full-universe corpora get strict absolute floors; scoped corpora get
      # proportional floors against the describe layer's present count
      # (the actual extraction scope signal).
      if corpus_full_universe?() do
        assert per_layer["describe"]["present"] >= 100
        assert per_layer["class_hierarchy"]["present"] >= 100
        assert per_layer["methods_rest"]["present"] >= 100
        assert per_layer["sign_method"]["present"] >= 90
        assert per_layer["handle_errors"]["present"] >= 50
        assert per_layer["parse_methods"]["present"] >= 100
      else
        scoped_n = per_layer["describe"]["present"]

        assert per_layer["describe"]["present"] >= proportional(scoped_n, 0.9)
        assert per_layer["class_hierarchy"]["present"] >= proportional(scoped_n, 0.75)
        assert per_layer["methods_rest"]["present"] >= proportional(scoped_n, 0.75)
        assert per_layer["sign_method"]["present"] >= proportional(scoped_n, 0.7)
        assert per_layer["handle_errors"]["present"] >= proportional(scoped_n, 0.4)
        assert per_layer["parse_methods"]["present"] >= proportional(scoped_n, 0.75)
      end
    end
  end

  describe "per-exchange coverage" do
    test "all coverage scores between 0 and max", %{report: report} do
      for exchange <- report["exchanges"] do
        assert exchange["coverage_score"] >= 0,
               "Negative score on #{exchange["id"]}"

        assert exchange["coverage_score"] <= exchange["coverage_max"],
               "Score > max on #{exchange["id"]}"

        assert exchange["coverage_pct"] >= 0.0,
               "Negative pct on #{exchange["id"]}"

        assert exchange["coverage_pct"] <= 100.0,
               "Pct > 100 on #{exchange["id"]}"
      end
    end

    test "exchanges are sorted by id", %{report: report} do
      ids = Enum.map(report["exchanges"], & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "every exchange has 10 layer entries", %{report: report} do
      for exchange <- report["exchanges"] do
        assert map_size(exchange["layers"]) == 10,
               "Expected 10 layers on #{exchange["id"]}, got #{map_size(exchange["layers"])}"
      end
    end

    test "gaps list matches non-present applicable layers", %{report: report} do
      for exchange <- report["exchanges"] do
        expected_gaps =
          exchange["layers"]
          |> Enum.reject(fn {_name, layer} -> layer["present"] or not layer["applicable"] end)
          |> length()

        assert length(exchange["gaps"]) == expected_gaps,
               "Gap count mismatch on #{exchange["id"]}"
      end
    end
  end

  describe "reference exchange coverage" do
    for exchange_id <- @tier1 ++ @tier2 do
      test "#{exchange_id} has high coverage", %{by_id: by_id} do
        id = unquote(exchange_id)
        assert Map.has_key?(by_id, id), "Missing reference exchange: #{id}"
        exchange = by_id[id]

        # Tier 1/2 exchanges should have describe, class, methods_rest, sign, parse
        assert exchange["layers"]["describe"]["present"] == true,
               "#{id} missing describe"

        assert exchange["layers"]["class_hierarchy"]["present"] == true,
               "#{id} missing class_hierarchy"

        assert exchange["layers"]["methods_rest"]["present"] == true,
               "#{id} missing methods_rest"

        assert exchange["layers"]["sign_method"]["present"] == true,
               "#{id} missing sign_method"

        assert exchange["layers"]["parse_methods"]["present"] == true,
               "#{id} missing parse_methods"
      end
    end

    for exchange_id <- @dex do
      test "#{exchange_id} is present", %{by_id: by_id} do
        id = unquote(exchange_id)
        assert Map.has_key?(by_id, id), "Missing DEX exchange: #{id}"
      end
    end

    test "known aliases have inapplicable describe", %{by_id: by_id} do
      for alias_id <- ~w(huobi gateio) do
        if Map.has_key?(by_id, alias_id) do
          exchange = by_id[alias_id]
          assert exchange["is_alias"] == true, "#{alias_id} should be an alias"
          assert exchange["layers"]["describe"]["applicable"] == false
        end
      end
    end

    test "binance has WS coverage", %{by_id: by_id} do
      binance = by_id["binance"]
      assert binance["has_pro"] == true
      assert binance["layers"]["methods_ws"]["present"] == true
      assert binance["layers"]["ws_methods"]["present"] == true
    end
  end

  describe "gaps_summary" do
    test "sorted by gap count descending", %{report: report} do
      gap_counts = Enum.map(report["gaps_summary"], & &1["gap_count"])
      assert gap_counts == Enum.sort(gap_counts, :desc)
    end

    test "only includes exchanges with gaps", %{report: report} do
      for gap <- report["gaps_summary"] do
        assert gap["gap_count"] > 0
        assert length(gap["gaps"]) == gap["gap_count"]
      end
    end

    test "gap entries reference valid exchanges", %{by_id: by_id, report: report} do
      for gap <- report["gaps_summary"] do
        assert Map.has_key?(by_id, gap["id"]),
               "Gap references unknown exchange: #{gap["id"]}"
      end
    end
  end

  describe "write!/2 round-trip" do
    @tag :tmp_dir
    test "writes valid JSON", %{report: report, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "coverage_report.json")
      assert :ok = CcxtExtract.CoverageReport.write!(report, output_path: output_path)

      decoded = output_path |> File.read!() |> Jason.decode!()
      assert decoded["exchange_count"] == report["exchange_count"]
      assert length(decoded["exchanges"]) == length(report["exchanges"])
    end
  end
end
