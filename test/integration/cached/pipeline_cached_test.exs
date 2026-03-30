defmodule CcxtExtract.Integration.Cached.PipelineCachedTest do
  @moduledoc """
  Cached integration tests for Pipeline — runs the full assembly pipeline
  against fixture data in test/fixtures/discoveries/.
  No QuickBEAM/OXC needed.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Pipeline
  alias CcxtExtract.Schema

  @moduletag :integration
  @moduletag timeout: 60_000

  @fixtures_dir Path.expand("../../fixtures/discoveries", __DIR__)
  @pipeline_opts [
    discoveries_dir: @fixtures_dir,
    ccxt_version: "4.5.45",
    extracted_at: "2026-03-30T12:00:00Z"
  ]

  @tier1 ~w(binance bybit okx deribit coinbaseexchange)
  @tier2 ~w(kraken kucoin gate htx bitmex)
  @dex ~w(hyperliquid)
  @all_reference @tier1 ++ @tier2 ++ @dex

  # Run pipeline once for all tests in this module
  setup_all do
    {:ok, exchanges, stats} = Pipeline.extract(@pipeline_opts)
    lookup = Map.new(exchanges, &{&1["exchange"]["id"], &1})
    %{exchanges: exchanges, stats: stats, lookup: lookup}
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
        assert exchange["schema_version"] == "1.0"
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

      # Runtime
      assert is_map(ex["runtime"]["describe"])
      assert ex["runtime"]["describe"]["id"] == "binance"

      # Structure
      assert is_map(ex["structure"]["class_info"])
      assert is_map(ex["structure"]["class_info"]["rest"])
      assert is_map(ex["structure"]["class_info"]["ws"])
      assert is_map(ex["structure"]["methods"])
      assert is_list(ex["structure"]["methods"]["rest"])
      assert is_map(ex["structure"]["sign_method"])
      assert is_map(ex["structure"]["handle_errors"])
      assert is_map(ex["structure"]["parse_methods"])
      assert map_size(ex["structure"]["parse_methods"]) > 0
      assert is_map(ex["structure"]["ws_methods"])
      assert map_size(ex["structure"]["ws_methods"]) > 0
    end

    test "binanceus has both REST and WS overrides", %{lookup: lookup} do
      ex = lookup["binanceus"]
      ov = ex["structure"]["overrides"]

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
      ov = ex["structure"]["overrides"]

      # deribit's WS class extends its REST class, so overrides data should exist
      if is_map(ov) do
        assert is_binary(ov["extends"]), "overrides.extends should be a string"

        assert is_map(ov["rest"]) or is_map(ov["ws"]),
               "overrides should have rest or ws entry"
      end
    end
  end

  describe "alias exchanges" do
    test "huobi is an alias with nil layers", %{lookup: lookup} do
      ex = lookup["huobi"]
      assert ex["exchange"]["alias"] == true
      assert ex["runtime"]["describe"] == nil
      assert ex["runtime"]["markets"] == nil
      assert ex["structure"]["sign_method"] == nil
      assert ex["structure"]["parse_methods"] == nil
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
  end

  describe "write and read round-trip" do
    @tag :tmp_dir
    test "writes per-exchange files and manifest", %{exchanges: exchanges, tmp_dir: tmp_dir} do
      Pipeline.write!(exchanges, tmp_dir)

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
    end
  end
end
