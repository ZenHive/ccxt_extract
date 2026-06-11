defmodule CcxtExtract.Integration.Cached.ValidationCachedTest do
  @moduledoc """
  Cached integration tests for Validation — runs full JSON Schema validation
  and round-trip comparison against discovery data in priv/discoveries/.
  No QuickBEAM/OXC needed.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Pipeline
  alias CcxtExtract.Test.StagedDiscoveries
  alias CcxtExtract.Validation

  @moduletag :integration
  @moduletag timeout: 120_000

  @fixtures_dir CcxtExtract.Paths.discoveries()
  @pipeline_opts_base [
    ccxt_version: "4.5.45",
    extracted_at: "2026-03-30T12:00:00Z"
  ]

  @tier1 ~w(binance bybit okx deribit coinbaseexchange)
  @tier2 ~w(kraken kucoin gate htx bitmex)
  @dex ~w(hyperliquid)
  @all_reference @tier1 ++ @tier2 ++ @dex
  # CCXT renamed `gateio` → `gate` upstream; `gateio` is no longer a registered
  # exchange/alias (no TS source, no class_hierarchy entry, no emitted output), so
  # it must not appear here or the widened audit matrix counts a phantom exchange.
  @audit_aliases ~w(coinbaseadvanced huobi)
  @audit_roots ~w(binance bybit okx)
  @audit_derived ~w(bequant binanceusdm okxus)
  @audit_dex ~w(hyperliquid apex aftermath)
  # Derived from manifest — exchanges that failed loadMarkets() change with each extraction.
  # Guarded by File.exists?/1 so this module compiles when the corpus isn't materialized
  # (CI offline-only path): empty list → the `for` loop below generates zero parameterized
  # tests, and the :integration tag exclusion drops the rest of the module at runtime.
  @audit_load_markets_failures (
                                 manifest_path = Path.join(@fixtures_dir, "load_markets/_manifest.json")

                                 if File.exists?(manifest_path) do
                                   manifest_path
                                   |> File.read!()
                                   |> Jason.decode!()
                                   |> Map.get("failed", [])
                                   |> Enum.map(& &1["id"])
                                 else
                                   []
                                 end
                               )
  @audit_matrix Enum.uniq(@audit_aliases ++ @audit_roots ++ @audit_derived ++ @audit_dex ++ @audit_load_markets_failures)
  @audit_clean_pool (@audit_aliases ++ @audit_roots ++ @audit_derived ++ @audit_dex) -- @audit_load_markets_failures

  # Write pipeline output to a temp dir, then validate the emitted files.
  # This proves validation reads actual JSON from disk, not in-memory data.
  setup_all do
    output_dir = Path.join(System.tmp_dir!(), "ccxt_validate_cached_#{:rand.uniform(100_000)}")
    fixtures_dir = StagedDiscoveries.stage!(@fixtures_dir)
    on_exit(fn -> File.rm_rf!(fixtures_dir) end)

    pipeline_opts = Keyword.put(@pipeline_opts_base, :discoveries_dir, fixtures_dir)

    {:ok, exchanges, _stats} = Pipeline.extract(pipeline_opts)
    Pipeline.write!(exchanges, output_dir, discoveries_dir: fixtures_dir)

    validation_opts = [output_dir: output_dir, discoveries_dir: fixtures_dir]

    {:ok, report} = Validation.validate_all(validation_opts)
    lookup = Map.new(report["exchanges"], &{&1["id"], &1})

    {:ok, audit_report} =
      Validation.validate_all(Keyword.put(validation_opts, :reference_exchanges, @audit_matrix))

    audit_lookup = Map.new(audit_report["exchanges"], &{&1["id"], &1})

    on_exit(fn -> File.rm_rf!(output_dir) end)

    %{report: report, lookup: lookup, audit_report: audit_report, audit_lookup: audit_lookup}
  end

  describe "JSON Schema validation" do
    test "all exchanges pass schema validation", %{report: report} do
      failures =
        report["exchanges"]
        |> Enum.reject(& &1["schema_valid"])
        |> Enum.map(&{&1["id"], &1["schema_errors"]})

      assert failures == [],
             "Schema validation failures: #{inspect(failures, limit: 5)}"
    end

    test "schema_pass count matches exchange count", %{report: report} do
      assert report["summary"]["schema_pass"] == report["exchange_count"]
      assert report["summary"]["schema_fail"] == 0
    end
  end

  describe "round-trip comparison" do
    test "reference exchanges were checked", %{report: report} do
      assert report["summary"]["roundtrip_checked"] == length(@all_reference)
    end

    for exchange_id <- @tier1 ++ @tier2 ++ @dex do
      @exchange_id exchange_id

      test "#{@exchange_id} round-trip has no errors", %{lookup: lookup} do
        result = lookup[@exchange_id]
        assert result, "#{@exchange_id} not found in validation results"

        errors = Enum.filter(result["roundtrip_findings"], &(&1["severity"] == "error"))

        assert errors == [],
               "#{@exchange_id} round-trip errors: #{inspect(errors)}"
      end
    end
  end

  describe "Audit 6 widened matrix" do
    test "audit matrix checks more exchanges than the default reference set", %{audit_report: audit_report} do
      assert length(@audit_matrix) > length(@all_reference)
      assert audit_report["summary"]["roundtrip_checked"] == length(@audit_matrix)
    end

    for exchange_id <- @audit_clean_pool do
      @exchange_id exchange_id

      test "#{@exchange_id} stays clean in the widened audit matrix", %{audit_lookup: audit_lookup} do
        result = audit_lookup[@exchange_id]
        assert result, "#{@exchange_id} not found in widened audit results"
        assert result["roundtrip_findings"] == []
      end
    end

    for exchange_id <- @audit_load_markets_failures do
      @exchange_id exchange_id

      test "#{@exchange_id} classifies load_markets manifest failures as info", %{audit_lookup: audit_lookup} do
        result = audit_lookup[@exchange_id]
        assert result, "#{@exchange_id} not found in widened audit results"

        errors = Enum.filter(result["roundtrip_findings"], &(&1["severity"] == "error"))

        infos =
          Enum.filter(result["roundtrip_findings"], fn finding ->
            finding["severity"] == "info" && finding["path"] == "markets.symbols_index"
          end)

        assert errors == [],
               "#{@exchange_id} widened audit errors: #{inspect(errors)}"

        assert infos != [],
               "#{@exchange_id} expected an informational load_markets failure finding"
      end
    end
  end

  describe "report structure" do
    test "has required top-level keys", %{report: report} do
      assert is_binary(report["validated_at"])
      assert is_integer(report["exchange_count"])
      assert report["exchange_count"] > 100
      assert report["schema_version"] == CcxtExtract.Schema.schema_version()
      assert is_map(report["pipeline_stats"])
    end

    test "pipeline_stats surfaces integrity entry buckets", %{report: report} do
      ps = report["pipeline_stats"]
      assert is_list(ps["missing_entries"])
      assert is_list(ps["corrupt_entries"])
      assert is_list(ps["orphan_entries"])
      assert is_list(ps["id_mismatch_entries"])
      assert is_list(ps["validation_errors"])
    end

    test "summary has all expected fields", %{report: report} do
      summary = report["summary"]

      for key <- ~w(schema_pass schema_fail roundtrip_checked roundtrip_clean
                     roundtrip_with_findings total_errors total_warnings total_info) do
        assert Map.has_key?(summary, key), "Missing summary key: #{key}"
        assert is_integer(summary[key]), "#{key} should be integer, got #{inspect(summary[key])}"
      end
    end

    test "findings_by_severity has all severity levels", %{report: report} do
      fbs = report["findings_by_severity"]
      assert is_list(fbs["error"])
      assert is_list(fbs["warning"])
      assert is_list(fbs["info"])
    end

    test "each exchange result has expected shape", %{report: report} do
      for result <- report["exchanges"] do
        assert is_binary(result["id"])
        assert is_boolean(result["schema_valid"])
        assert is_list(result["schema_errors"])
        assert is_list(result["roundtrip_findings"])
      end
    end
  end

  describe "write round-trip" do
    @tag :tmp_dir
    test "writes and reads back valid JSON", %{report: report, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "_validation_report.json")
      Validation.write!(report, path)

      assert File.exists?(path)
      loaded = path |> File.read!() |> Jason.decode!()
      assert loaded["exchange_count"] == report["exchange_count"]
      assert loaded["summary"]["schema_pass"] == report["summary"]["schema_pass"]
    end
  end
end
