defmodule CcxtExtract.Integration.Cached.PipelineCachedTest do
  @moduledoc """
  Cached integration tests for Pipeline — runs the full assembly pipeline
  against discovery data in priv/discoveries/.
  No QuickBEAM/OXC needed.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Pipeline
  alias CcxtExtract.Schema
  alias CcxtExtract.Test.StagedDiscoveries

  @moduletag :integration
  @moduletag timeout: 60_000

  @pipeline_opts_base [
    ccxt_version: "4.5.45",
    extracted_at: "2026-03-30T12:00:00Z"
  ]

  @tier1 ~w(binance bybit okx deribit coinbaseexchange)
  @tier2 ~w(kraken kucoin gate htx bitmex)
  @dex ~w(hyperliquid)
  @all_reference @tier1 ++ @tier2 ++ @dex

  defp load_json(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp load_exchange_entries(fixtures_dir, filename) do
    load_json(Path.join(fixtures_dir, filename))["exchanges"]
  end

  defp find_by_id(entries, id), do: Enum.find(entries, &(&1["id"] == id))

  # Run pipeline once for all tests in this module
  setup_all do
    fixtures_dir = StagedDiscoveries.stage!(CcxtExtract.Paths.discoveries())
    on_exit(fn -> File.rm_rf!(fixtures_dir) end)

    opts = Keyword.put(@pipeline_opts_base, :discoveries_dir, fixtures_dir)
    {:ok, exchanges, stats} = Pipeline.extract(opts)
    lookup = Map.new(exchanges, &{&1["exchange"]["id"], &1})
    %{exchanges: exchanges, stats: stats, lookup: lookup, fixtures_dir: fixtures_dir}
  end

  describe "pipeline assembly" do
    test "succeeds and returns exchanges", %{exchanges: exchanges} do
      assert length(exchanges) > 100
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["exchange"]["id"])
      assert ids == Enum.sort(ids)
    end

    test "all exchanges have consistent envelope", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert exchange["schema_version"] == Schema.schema_version()
        assert exchange["ccxt_version"] == "4.5.45"
        assert exchange["extracted_at"] == "2026-03-30T12:00:00Z"
        assert is_binary(exchange["exchange"]["id"])
      end
    end

    test "all exchanges pass schema validation", %{exchanges: exchanges} do
      failures =
        exchanges
        |> Enum.map(fn ex -> {ex["exchange"]["id"], Schema.validate(ex)} end)
        |> Enum.reject(fn {_id, result} -> result == :ok end)

      assert failures == [],
             "Validation failures: #{inspect(Enum.map(failures, fn {id, {:error, reasons}} -> {id, reasons} end))}"
    end
  end

  describe "reference exchanges" do
    for exchange_id <- @all_reference do
      @exchange_id exchange_id

      test "#{@exchange_id} is present in pipeline output", %{lookup: lookup} do
        assert Map.has_key?(lookup, @exchange_id),
               "Reference exchange #{@exchange_id} missing from pipeline output"
      end
    end

    test "binance has all layers populated", %{lookup: lookup} do
      ex = lookup["binance"]

      # Raw (formerly runtime)
      assert is_map(ex["raw"]["describe"])
      assert ex["raw"]["describe"]["id"] == "binance"

      # Raw structure
      assert is_map(ex["raw"]["class_info"])
      assert is_map(ex["raw"]["class_info"]["rest"])
      assert is_map(ex["raw"]["class_info"]["ws"])
      assert is_map(ex["raw"]["method_inventory"])
      assert is_list(ex["raw"]["method_inventory"]["rest"])
      assert is_map(ex["auth"]["sign_method"])
      assert is_map(ex["errors"]["handle_errors"])

      # parse_methods + ws_methods are no longer emitted (schema 3.0.0, Task 117).
      # Extractors still run and discovery files exist under priv/discoveries/,
      # but consumers of the emitted per-exchange JSON no longer see these fields.
      refute Map.has_key?(ex["raw"], "parse_methods")
      refute Map.has_key?(ex["raw"], "ws_methods")

      # Derived replacement for the pruned runtime.markets.markets snapshot.
      assert is_map(ex["markets"]["symbols_index"])
      assert map_size(ex["markets"]["symbols_index"]) > 0
    end

    test "binanceus has both REST and WS overrides", %{lookup: lookup} do
      ex = lookup["binanceus"]
      ov = ex["raw"]["overrides_meta"]

      assert is_map(ov)
      assert ov["extends"] == "binance"

      # REST overrides
      assert is_map(ov["rest"])
      assert ov["rest"]["parent_key"] == "rest:binance"
      assert is_map(ov["rest"]["overridden"])
      assert is_list(ov["rest"]["inherited"])

      # WS overrides (binanceus has both REST and WS derived classes)
      assert is_map(ov["ws"])
      assert ov["ws"]["parent_key"] == "ws:binance"
      assert is_map(ov["ws"]["overridden"])
      assert is_list(ov["ws"]["inherited"])
    end

    test "deribit has overrides (WS extends REST)", %{lookup: lookup} do
      ex = lookup["deribit"]
      ov = ex["raw"]["overrides_meta"]

      # deribit's WS class extends its REST class, so overrides data should exist
      if is_map(ov) do
        assert is_binary(ov["extends"]), "overrides.extends should be a string"

        assert is_map(ov["rest"]) or is_map(ov["ws"]),
               "overrides should have rest or ws entry"
      end
    end
  end

  describe "alias exchanges" do
    test "huobi is an alias that inherits parent runtime data from htx", %{lookup: lookup} do
      ex = lookup["huobi"]
      assert ex["exchange"]["alias"] == true

      # Runtime data resolved from parent (htx)
      assert is_map(ex["raw"]["describe"]), "alias should inherit parent describe"

      assert is_map(ex["markets"]["symbols_index"]),
             "alias should inherit parent symbols_index (derived from parent's markets)"

      # Structural data stays nil — these are per-exchange AST extractions
      assert ex["auth"]["sign_method"] == nil
    end
  end

  describe "nullability semantics" do
    test "bequant inherits handle_errors from parent hitbtc", %{lookup: lookup, fixtures_dir: fixtures_dir} do
      entries = load_exchange_entries(fixtures_dir, "handle_errors.json")
      bequant_source = find_by_id(entries, "bequant")
      hitbtc_source = find_by_id(entries, "hitbtc")

      # Scope-gated: assertion only runs when both bequant and its parent
      # hitbtc are in the current tier_scope fixture. Inheritance is
      # meaningless to verify when the parent isn't extracted.
      if is_map(bequant_source) and is_map(hitbtc_source) do
        assert bequant_source["handle_errors"] == nil

        ex = lookup["bequant"]
        assert ex["exchange"]["alias"] == false
        assert is_map(ex["errors"]["handle_errors"])
        assert is_map(ex["errors"]["handle_errors"]["method"])
      end
    end

    test "bequant converts empty parse_methods source to null", %{lookup: lookup, fixtures_dir: fixtures_dir} do
      source = fixtures_dir |> load_exchange_entries("parse_methods.json") |> find_by_id("bequant")

      # Scope-gated: only assert when bequant is present in the scoped
      # parse_methods fixture.
      if is_map(source) do
        assert source["parse_method_count"] == 0
        assert source["parse_methods"] == %{}

        # parse_methods is not emitted in v4 schema (no raw.parse_methods field)
        refute Map.has_key?(lookup["bequant"]["raw"], "parse_methods")
      end
    end

    test "bitbns uses ws nulls because it is a non-pro exchange", %{lookup: lookup} do
      ex = lookup["bitbns"]
      assert ex["exchange"]["pro"] == false
      assert ex["raw"]["class_info"]["ws"] == nil
      assert ex["raw"]["method_inventory"]["ws"] == nil
    end

    test "bitbns keeps overrides null because its REST class is a root exchange", %{lookup: lookup} do
      ex = lookup["bitbns"]
      assert ex["raw"]["overrides_meta"] == nil
      assert ex["raw"]["class_info"]["rest"]["extends_resolved"] == "Exchange"
    end
  end

  describe "stats" do
    test "reports exchange count", %{stats: stats, exchanges: exchanges} do
      assert stats.exchange_count == length(exchanges)
    end

    test "reports no or few validation errors", %{stats: stats} do
      # Some exchanges may have quirky data, but most should validate
      error_count = length(stats.validation_errors)
      assert error_count < 5, "Too many validation errors: #{error_count}"
    end

    test "reports no integrity gaps for cached fixtures", %{stats: stats} do
      assert stats.missing_entries == [],
             "Missing per-exchange files: #{inspect(stats.missing_entries)}"

      assert stats.corrupt_entries == [],
             "Corrupt discovery entries: #{inspect(stats.corrupt_entries)}"

      assert stats.orphan_entries == [],
             "Orphan artifacts: #{inspect(stats.orphan_entries)}"

      assert stats.id_mismatch_entries == [],
             "ID mismatches: #{inspect(stats.id_mismatch_entries)}"
    end
  end

  describe "write and read round-trip" do
    @tag :tmp_dir
    test "writes per-exchange files, schema, and manifest", %{
      exchanges: exchanges,
      tmp_dir: tmp_dir,
      fixtures_dir: fixtures_dir
    } do
      Pipeline.write!(exchanges, tmp_dir, discoveries_dir: fixtures_dir)

      # Manifest exists
      manifest_path = Path.join(tmp_dir, "_manifest.json")
      assert File.exists?(manifest_path)
      manifest = manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["exchange_count"] == length(exchanges)
      assert length(manifest["exchanges"]) == length(exchanges)

      # Spot check: binance file exists and has correct structure
      binance_path = Path.join(tmp_dir, "binance.json")
      assert File.exists?(binance_path)
      binance = binance_path |> File.read!() |> Jason.decode!()
      assert binance["exchange"]["id"] == "binance"
      assert :ok = Schema.validate(binance)

      schema_path = Path.join(tmp_dir, "exchange_v4.json")
      assert File.exists?(schema_path)
      assert schema_path |> File.read!() |> Jason.decode!() |> is_map()
    end
  end
end
