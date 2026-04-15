defmodule CcxtExtract.CoverageReportTest do
  @moduledoc """
  Unit tests for CoverageReport pure functions.
  Uses synthetic data — no file I/O, no QuickBEAM/OXC.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.CoverageReport

  # --- Synthetic exchanges ---

  @full_exchange %{"id" => "fullex", "alias" => false, "pro" => true}
  @alias_exchange %{"id" => "aliasex", "alias" => true, "pro" => false}
  @no_ws_exchange %{"id" => "nowsex", "alias" => false, "pro" => false}

  # --- Synthetic inputs with everything present ---

  @full_inputs %{
    describe_ids: MapSet.new(["fullex", "nowsex"]),
    load_markets_succeeded: MapSet.new(["fullex", "nowsex"]),
    load_markets_failed: MapSet.new(),
    class_ids: MapSet.new(["fullex", "nowsex", "aliasex"]),
    class_lookup: %{
      "fullex" => %{"id" => "fullex", "parent_key" => "rest:baseex"},
      "nowsex" => %{"id" => "nowsex", "parent_key" => "rest:Exchange"},
      "aliasex" => %{"id" => "aliasex", "parent_key" => "rest:fullex"}
    },
    methods_rest_ids: MapSet.new(["fullex", "nowsex", "aliasex"]),
    methods_ws_ids: MapSet.new(["fullex"]),
    sign_lookup: %{
      "fullex" => %{"id" => "fullex", "sign" => %{"body" => %{}}},
      "nowsex" => %{"id" => "nowsex", "sign" => %{"body" => %{}}}
    },
    handle_errors_lookup: %{
      "fullex" => %{"id" => "fullex", "handle_errors" => %{"body" => %{}}},
      "nowsex" => %{"id" => "nowsex", "handle_errors" => %{"body" => %{}}}
    },
    parse_methods_lookup: %{
      "fullex" => %{"id" => "fullex", "parse_method_count" => 12},
      "nowsex" => %{"id" => "nowsex", "parse_method_count" => 8}
    },
    ws_methods_lookup: %{
      "fullex" => %{"id" => "fullex", "ws_method_count" => 13}
    },
    overrides_ids: MapSet.new(["fullex"]),
    missing_files: []
  }

  # --- exchange_coverage/2 tests ---

  describe "exchange_coverage/2" do
    test "full coverage exchange gets 100%" do
      result = CoverageReport.exchange_coverage(@full_exchange, @full_inputs)

      assert result["id"] == "fullex"
      assert result["coverage_pct"] == 100.0
      assert result["coverage_score"] == result["coverage_max"]
      assert result["gaps"] == []
    end

    test "alias exchange — inapplicable layers excluded from scoring" do
      result = CoverageReport.exchange_coverage(@alias_exchange, @full_inputs)

      assert result["is_alias"] == true

      # Aliases: describe, load_markets, sign, handle_errors, parse_methods are not applicable
      for layer_name <- ~w(describe load_markets sign_method handle_errors parse_methods) do
        layer = result["layers"][layer_name]
        assert layer["applicable"] == false, "#{layer_name} should not be applicable for alias"
      end

      # class_hierarchy and methods_rest should be applicable and present
      assert result["layers"]["class_hierarchy"]["present"] == true
      assert result["layers"]["methods_rest"]["present"] == true

      # methods_ws not applicable (pro: false)
      assert result["layers"]["methods_ws"]["applicable"] == false

      # ws_methods not applicable (pro: false)
      assert result["layers"]["ws_methods"]["applicable"] == false

      # overrides not applicable (aliasex is not in overrides_ids)
      assert result["layers"]["overrides"]["applicable"] == false

      assert result["gaps"] == []
    end

    test "non-pro exchange — WS layers excluded from scoring" do
      result = CoverageReport.exchange_coverage(@no_ws_exchange, @full_inputs)

      assert result["has_pro"] == false

      # methods_ws and ws_methods should not be applicable
      assert result["layers"]["methods_ws"]["applicable"] == false
      assert result["layers"]["methods_ws"]["reason"] == "no_ws_exchange"
      assert result["layers"]["ws_methods"]["applicable"] == false
      assert result["layers"]["ws_methods"]["reason"] == "no_ws_exchange"

      # overrides not applicable (nowsex not in overrides_ids — it's a root exchange)
      assert result["layers"]["overrides"]["applicable"] == false
      assert result["layers"]["overrides"]["reason"] == "root_exchange"

      # Should still have full coverage for applicable layers
      assert result["coverage_pct"] == 100.0
      assert result["gaps"] == []
    end

    test "missing describe — gap reported" do
      inputs = %{@full_inputs | describe_ids: MapSet.new()}
      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["layers"]["describe"]["present"] == false
      assert result["layers"]["describe"]["reason"] == "not_extracted"
      assert "describe: not_extracted" in result["gaps"]
      assert result["coverage_pct"] < 100.0
    end

    test "failed load_markets — gap with 'failed' reason" do
      inputs = %{
        @full_inputs
        | load_markets_succeeded: MapSet.new(),
          load_markets_failed: MapSet.new(["fullex"])
      }

      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["layers"]["load_markets"]["present"] == false
      assert result["layers"]["load_markets"]["reason"] == "failed"
      assert "load_markets: failed" in result["gaps"]
    end

    test "null sign body — gap with 'no_sign_method' reason" do
      inputs = %{
        @full_inputs
        | sign_lookup: %{"fullex" => %{"id" => "fullex", "sign" => nil}}
      }

      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["layers"]["sign_method"]["present"] == false
      assert result["layers"]["sign_method"]["reason"] == "no_sign_method"
    end

    test "null handle_errors body — gap with reason" do
      inputs = %{
        @full_inputs
        | handle_errors_lookup: %{"fullex" => %{"id" => "fullex", "handle_errors" => nil}}
      }

      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["layers"]["handle_errors"]["present"] == false
      assert result["layers"]["handle_errors"]["reason"] == "no_handle_errors"
    end

    test "zero parse methods — gap with reason" do
      inputs = %{
        @full_inputs
        | parse_methods_lookup: %{"fullex" => %{"id" => "fullex", "parse_method_count" => 0}}
      }

      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["layers"]["parse_methods"]["present"] == false
      assert result["layers"]["parse_methods"]["reason"] == "no_parse_methods"
    end

    test "exchange not found in sign_methods — 'not_found' reason" do
      inputs = %{@full_inputs | sign_lookup: %{}}
      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["layers"]["sign_method"]["present"] == false
      assert result["layers"]["sign_method"]["reason"] == "not_found"
    end

    test "zero ws_method_count — gap with 'no_ws_methods' reason" do
      inputs = %{
        @full_inputs
        | ws_methods_lookup: %{"fullex" => %{"id" => "fullex", "ws_method_count" => 0}}
      }

      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["layers"]["ws_methods"]["present"] == false
      assert result["layers"]["ws_methods"]["applicable"] == true
      assert result["layers"]["ws_methods"]["reason"] == "no_ws_methods"
    end

    test "non-pro exchange with WS data — layers marked applicable and present" do
      # Simulate a non-pro exchange that has real WS data (like coincheck, coinone)
      non_pro_ws = %{"id" => "nonprows", "alias" => false, "pro" => false}

      inputs = %{
        @full_inputs
        | describe_ids: MapSet.new(["nonprows"]),
          load_markets_succeeded: MapSet.new(["nonprows"]),
          class_ids: MapSet.new(["nonprows"]),
          class_lookup: %{"nonprows" => %{"id" => "nonprows", "parent_key" => "rest:Exchange"}},
          methods_rest_ids: MapSet.new(["nonprows"]),
          methods_ws_ids: MapSet.new(["nonprows"]),
          sign_lookup: %{"nonprows" => %{"id" => "nonprows", "sign" => %{"body" => %{}}}},
          handle_errors_lookup: %{
            "nonprows" => %{"id" => "nonprows", "handle_errors" => %{"body" => %{}}}
          },
          parse_methods_lookup: %{"nonprows" => %{"id" => "nonprows", "parse_method_count" => 5}},
          ws_methods_lookup: %{"nonprows" => %{"id" => "nonprows", "ws_method_count" => 8}}
      }

      result = CoverageReport.exchange_coverage(non_pro_ws, inputs)

      # Both WS layers should be applicable and present despite pro: false
      assert result["layers"]["methods_ws"]["applicable"] == true
      assert result["layers"]["methods_ws"]["present"] == true
      assert result["layers"]["ws_methods"]["applicable"] == true
      assert result["layers"]["ws_methods"]["present"] == true
    end

    test "coverage score and max correctly computed" do
      # Remove 2 applicable layers for fullex
      inputs = %{
        @full_inputs
        | describe_ids: MapSet.new(),
          sign_lookup: %{}
      }

      result = CoverageReport.exchange_coverage(@full_exchange, inputs)

      assert result["coverage_max"] == 10
      assert result["coverage_score"] == 8
      assert result["coverage_pct"] == 80.0
    end
  end

  # --- analyze/2 tests ---

  describe "analyze/2" do
    test "summary statistics computed correctly" do
      exchanges = [@full_exchange, @alias_exchange, @no_ws_exchange]
      report = CoverageReport.analyze(exchanges, @full_inputs)

      assert report["exchange_count"] == 3
      assert is_binary(report["extracted_at"])
      assert is_list(report["exchanges"])
      assert length(report["exchanges"]) == 3

      summary = report["summary"]
      assert summary["full_coverage"] + summary["partial_coverage"] + summary["no_coverage"] == 3
      assert summary["avg_coverage_pct"] > 0.0
      assert is_map(summary["per_layer"])
      assert summary["missing_files"] == []
    end

    test "per_layer counts are consistent" do
      exchanges = [@full_exchange, @alias_exchange, @no_ws_exchange]
      report = CoverageReport.analyze(exchanges, @full_inputs)

      for {_name, layer_stats} <- report["summary"]["per_layer"] do
        assert layer_stats["present"] >= 0
        assert layer_stats["missing"] >= 0
        assert layer_stats["applicable"] == layer_stats["present"] + layer_stats["missing"]
      end
    end

    test "gaps_summary lists exchanges with gaps sorted by gap count" do
      # Remove describe for fullex to create a gap
      inputs = %{@full_inputs | describe_ids: MapSet.new()}
      exchanges = [@full_exchange, @no_ws_exchange]
      report = CoverageReport.analyze(exchanges, inputs)

      gaps = report["gaps_summary"]
      assert is_list(gaps)

      for gap <- gaps do
        assert is_binary(gap["id"])
        assert gap["gap_count"] > 0
        assert length(gap["gaps"]) == gap["gap_count"]
      end

      # Should be sorted by gap count descending
      gap_counts = Enum.map(gaps, & &1["gap_count"])
      assert gap_counts == Enum.sort(gap_counts, :desc)
    end

    test "empty exchange list returns zero summary" do
      report = CoverageReport.analyze([], @full_inputs)

      assert report["exchange_count"] == 0
      assert report["summary"]["full_coverage"] == 0
      assert report["summary"]["avg_coverage_pct"] == 0.0
      assert report["exchanges"] == []
      assert report["gaps_summary"] == []
    end

    test "missing_files propagated to summary" do
      inputs = %{@full_inputs | missing_files: ["sign_methods.json", "ws_methods.json"]}
      report = CoverageReport.analyze([@full_exchange], inputs)

      assert report["summary"]["missing_files"] == ["sign_methods.json", "ws_methods.json"]
    end
  end

  # --- write!/2 round-trip test ---

  describe "write!/2" do
    @tag :tmp_dir
    test "round-trips JSON to file", %{tmp_dir: tmp_dir} do
      report = CoverageReport.analyze([@full_exchange], @full_inputs)
      output_path = Path.join(tmp_dir, "coverage_report.json")

      assert :ok = CoverageReport.write!(report, output_path: output_path)
      assert File.exists?(output_path)

      decoded = output_path |> File.read!() |> Jason.decode!()
      assert decoded["exchange_count"] == 1
      assert is_list(decoded["exchanges"])
      assert decoded["tier_scope"] == "all"
    end
  end
end
