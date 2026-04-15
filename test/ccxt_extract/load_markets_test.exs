defmodule CcxtExtract.LoadMarketsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.LoadMarkets

  describe "write!/2 scoped manifest merge" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ccxt_lm_write_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test ":all discards ghost failed entries from prior manifest (codex regression)", %{dir: dir} do
      seed_manifest(dir, %{
        "succeeded_count" => 0,
        "failed_count" => 1,
        "succeeded" => [],
        "failed" => [%{"id" => "ghost_exchange", "error" => "CCXT dropped this"}]
      })

      results = %{"succeeded" => [succeeded("binance", 100)], "failed" => []}
      assert :ok = LoadMarkets.write!(results, scope: :all, output_dir: dir)

      manifest = read_manifest(dir)
      assert manifest["succeeded"] == ["binance"]
      assert manifest["failed"] == []
      assert manifest["failed_count"] == 0
      assert manifest["tier_scope"] == "all"
    end

    test "MapSet scope preserves out-of-scope failed entries", %{dir: dir} do
      seed_manifest(dir, %{
        "succeeded_count" => 0,
        "failed_count" => 2,
        "succeeded" => [],
        "failed" => [
          %{"id" => "kraken", "error" => "rate limited"},
          %{"id" => "deribit", "error" => "geo blocked"}
        ]
      })

      results = %{
        "succeeded" => [],
        "failed" => [%{"id" => "binance", "error" => "new failure"}]
      }

      assert :ok =
               LoadMarkets.write!(results,
                 scope: MapSet.new(["binance"]),
                 output_dir: dir
               )

      manifest = read_manifest(dir)
      ids = Enum.map(manifest["failed"], & &1["id"])
      assert "binance" in ids
      assert "kraken" in ids
      assert "deribit" in ids
      assert manifest["failed_count"] == 3
    end

    test "promotes IDs from failed to succeeded when a file now exists", %{dir: dir} do
      seed_manifest(dir, %{
        "succeeded_count" => 0,
        "failed_count" => 1,
        "succeeded" => [],
        "failed" => [%{"id" => "binance", "error" => "previously failed"}]
      })

      results = %{"succeeded" => [succeeded("binance", 42)], "failed" => []}

      assert :ok =
               LoadMarkets.write!(results,
                 scope: MapSet.new(["binance"]),
                 output_dir: dir
               )

      manifest = read_manifest(dir)
      assert manifest["succeeded"] == ["binance"]
      assert manifest["failed"] == []
    end

    test "counts always equal list lengths (drift guard)", %{dir: dir} do
      results = %{
        "succeeded" => [succeeded("a", 1), succeeded("b", 1)],
        "failed" => [%{"id" => "c", "error" => "x"}, %{"id" => "d", "error" => "y"}]
      }

      assert :ok = LoadMarkets.write!(results, scope: :all, output_dir: dir)

      manifest = read_manifest(dir)
      assert manifest["succeeded_count"] == length(manifest["succeeded"])
      assert manifest["failed_count"] == length(manifest["failed"])
    end

    defp seed_manifest(dir, data) do
      manifest = Map.put(data, "extracted_at", DateTime.to_iso8601(DateTime.utc_now()))
      File.write!(Path.join(dir, "_manifest.json"), Jason.encode!(manifest))
    end

    defp read_manifest(dir) do
      dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()
    end

    defp succeeded(id, count) do
      %{"id" => id, "market_count" => count, "markets" => %{}}
    end
  end

  describe "extract/1 input validation" do
    test "rejects concurrency: 0" do
      assert_raise ArgumentError, ~r/concurrency must be a positive integer/, fn ->
        LoadMarkets.extract(concurrency: 0, exchanges: ["dydx"])
      end
    end

    test "rejects negative concurrency" do
      assert_raise ArgumentError, ~r/concurrency must be a positive integer/, fn ->
        LoadMarkets.extract(concurrency: -1, exchanges: ["dydx"])
      end
    end

    test "rejects negative delay_ms" do
      assert_raise ArgumentError, ~r/delay_ms must be a non-negative integer/, fn ->
        LoadMarkets.extract(delay_ms: -1, exchanges: ["dydx"])
      end
    end

    test "rejects empty exchanges list" do
      assert_raise ArgumentError, ~r/exchanges must be a non-empty list/, fn ->
        LoadMarkets.extract(exchanges: [])
      end
    end

    test "rejects non-integer delay_ms" do
      assert_raise ArgumentError, ~r/delay_ms must be a non-negative integer/, fn ->
        LoadMarkets.extract(delay_ms: 1.5, exchanges: ["dydx"])
      end
    end
  end
end
