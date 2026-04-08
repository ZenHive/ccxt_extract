defmodule CcxtExtract.Integration.Cached.MarketValidationCachedTest do
  @moduledoc """
  Validates MarketValidation against cached loadMarkets() data.
  Reads from priv/discoveries/load_markets/ — no QuickBEAM needed.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.MarketValidation

  @moduletag :integration
  @moduletag timeout: 30_000

  @discoveries_dir CcxtExtract.Paths.discoveries()
  @load_markets_dir Path.join(@discoveries_dir, "load_markets")

  setup_all do
    manifest_path = Path.join(@load_markets_dir, "_manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    exchange_data =
      Map.new(manifest["succeeded"], fn id ->
        data =
          @load_markets_dir
          |> Path.join("#{id}.json")
          |> File.read!()
          |> Jason.decode!()

        {id, data}
      end)

    %{manifest: manifest, exchange_data: exchange_data}
  end

  describe "validate_exchange/1 on cached data" do
    test "returns valid report structure for each exchange", %{exchange_data: data} do
      for {id, exchange} <- data do
        report = MarketValidation.validate_exchange(exchange)

        assert report["id"] == id
        assert is_integer(report["market_count"])
        assert is_list(report["errors"]), "#{id}: errors should be a list"
        assert is_list(report["warnings"]), "#{id}: warnings should be a list"
        assert is_map(report["undefined_density"]), "#{id}: undefined_density should be a map"
        assert is_integer(report["undefined_density"]["undefined_count"])
        assert is_integer(report["undefined_density"]["total_fields"])
      end
    end

    test "market_count matches actual markets", %{exchange_data: data} do
      for {id, exchange} <- data do
        report = MarketValidation.validate_exchange(exchange)
        assert report["market_count"] == map_size(exchange["markets"]), "#{id}: market_count mismatch"
      end
    end

    test "no errors on required fields for cached data", %{exchange_data: data} do
      for {id, exchange} <- data do
        report = MarketValidation.validate_exchange(exchange)

        required_errors =
          Enum.filter(report["errors"], &String.contains?(&1, "required field"))

        assert required_errors == [],
               "#{id}: unexpected required field errors: #{inspect(required_errors)}"
      end
    end

    test "undefined density is non-negative", %{exchange_data: data} do
      for {id, exchange} <- data do
        report = MarketValidation.validate_exchange(exchange)
        density = report["undefined_density"]

        assert density["undefined_count"] >= 0, "#{id}: negative undefined count"
        assert density["total_fields"] >= 0, "#{id}: negative total fields"
        assert density["density_pct"] >= 0, "#{id}: negative density percentage"
        assert density["density_pct"] <= 100, "#{id}: density > 100%"
      end
    end
  end

  describe "validate/1 pipeline" do
    test "reads cached files and produces report" do
      {:ok, report} = MarketValidation.validate(input_dir: @load_markets_dir)

      assert is_binary(report["validated_at"])
      assert is_integer(report["exchange_count"])
      assert report["exchange_count"] >= 1
      assert is_map(report["summary"])
      assert is_map(report["exchanges"])
      assert report["spot_check"] == nil
    end

    test "summary has expected fields" do
      {:ok, report} = MarketValidation.validate(input_dir: @load_markets_dir)
      summary = report["summary"]

      assert is_integer(summary["exchanges_valid"])
      assert is_integer(summary["exchanges_with_issues"])
      assert is_integer(summary["total_markets_checked"])
      assert is_integer(summary["errors"])
      assert is_integer(summary["warnings"])
      assert is_float(summary["avg_undefined_density_pct"]) or summary["avg_undefined_density_pct"] == 0
    end

    test "exchange count matches manifest" do
      {:ok, report} = MarketValidation.validate(input_dir: @load_markets_dir)
      manifest_path = Path.join(@load_markets_dir, "_manifest.json")
      manifest = manifest_path |> File.read!() |> Jason.decode!()

      assert report["exchange_count"] == manifest["succeeded_count"]
    end

    test "returns error for missing input" do
      assert {:error, {:missing_input, _path}} =
               MarketValidation.validate(input_dir: "/nonexistent/path")
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON file", %{tmp_dir: tmp_dir} do
      {:ok, report} = MarketValidation.validate(input_dir: @load_markets_dir)
      output_path = Path.join(tmp_dir, "market_validation.json")

      assert :ok = MarketValidation.write!(report, output_path)
      assert File.exists?(output_path)

      written = output_path |> File.read!() |> Jason.decode!()
      assert written["exchange_count"] == report["exchange_count"]
      assert written["summary"] == report["summary"]
    end
  end
end
