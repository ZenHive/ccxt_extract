defmodule CcxtExtract.FixtureParityTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.FixtureParity

  describe "diff/2" do
    test "returns match when disk and fresh are byte-equal" do
      fixture = %{"exchange" => "binance", "cases" => %{"x" => 1}, "ccxt_version" => "4.5.0"}
      disk = %{"binance" => fixture}
      report = FixtureParity.diff(disk, [fixture])

      assert report["summary"]["total"] == 1
      assert report["summary"]["match"] == 1
      assert report["summary"]["drift"] == 0
      assert [%{"exchange" => "binance", "status" => "match", "diff_keys" => []}] = report["exchanges"]
    end

    test "ignores volatile keys (generated_at)" do
      disk_fx = %{"exchange" => "bybit", "cases" => %{}, "generated_at" => "2025-01-01T00:00:00Z"}
      fresh_fx = %{"exchange" => "bybit", "cases" => %{}, "generated_at" => "2026-06-06T06:06:06Z"}

      report = FixtureParity.diff(%{"bybit" => disk_fx}, [fresh_fx])

      assert report["summary"]["match"] == 1
      assert report["summary"]["drift"] == 0
    end

    test "detects drift in nested fields and reports paths" do
      disk_fx = %{
        "exchange" => "deribit",
        "cases" => %{"public_get_ticker" => %{"url" => "https://old.example/"}}
      }

      fresh_fx = %{
        "exchange" => "deribit",
        "cases" => %{"public_get_ticker" => %{"url" => "https://new.example/"}}
      }

      report = FixtureParity.diff(%{"deribit" => disk_fx}, [fresh_fx])

      assert report["summary"]["drift"] == 1
      [entry] = report["exchanges"]
      assert entry["status"] == "drift"
      assert "/cases/public_get_ticker/url" in entry["diff_keys"]
    end

    test "detects ccxt_version drift (non-volatile)" do
      disk_fx = %{"exchange" => "kraken", "cases" => %{}, "ccxt_version" => "4.5.0"}
      fresh_fx = %{"exchange" => "kraken", "cases" => %{}, "ccxt_version" => "4.6.0"}

      report = FixtureParity.diff(%{"kraken" => disk_fx}, [fresh_fx])

      assert report["summary"]["drift"] == 1
      [entry] = report["exchanges"]
      assert "/ccxt_version" in entry["diff_keys"]
    end

    test "flags missing fixtures (in fresh but not on disk)" do
      fresh_fx = %{"exchange" => "okx", "cases" => %{}}
      report = FixtureParity.diff(%{}, [fresh_fx])

      assert report["summary"]["missing_on_disk"] == 1
      assert [%{"exchange" => "okx", "status" => "missing"}] = report["exchanges"]
    end

    test "flags extra fixtures (on disk but not fresh)" do
      disk_fx = %{"exchange" => "gone", "cases" => %{}}
      report = FixtureParity.diff(%{"gone" => disk_fx}, [])

      assert report["summary"]["extra_on_disk"] == 1
      assert [%{"exchange" => "gone", "status" => "extra"}] = report["exchanges"]
    end

    test "detects list-length differences" do
      disk_fx = %{"exchange" => "htx", "cases" => %{}, "endpoints" => ["a", "b"]}
      fresh_fx = %{"exchange" => "htx", "cases" => %{}, "endpoints" => ["a", "b", "c"]}

      report = FixtureParity.diff(%{"htx" => disk_fx}, [fresh_fx])

      assert report["summary"]["drift"] == 1
      [entry] = report["exchanges"]
      assert "/endpoints" in entry["diff_keys"]
    end
  end

  describe "has_drift?/1" do
    test "false when all match" do
      report = %{"summary" => %{"drift" => 0, "missing_on_disk" => 0, "extra_on_disk" => 0}}
      refute FixtureParity.has_drift?(report)
    end

    test "true on any deviation" do
      assert FixtureParity.has_drift?(%{"summary" => %{"drift" => 1, "missing_on_disk" => 0, "extra_on_disk" => 0}})
      assert FixtureParity.has_drift?(%{"summary" => %{"drift" => 0, "missing_on_disk" => 1, "extra_on_disk" => 0}})
      assert FixtureParity.has_drift?(%{"summary" => %{"drift" => 0, "missing_on_disk" => 0, "extra_on_disk" => 1}})
    end
  end

  describe "load_disk/1" do
    test "loads fixtures, skips any _-prefixed files (manifest, parity report)" do
      dir = Path.join(System.tmp_dir!(), "fxparity_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "binance.json"), Jason.encode!(%{"exchange" => "binance"}))
      File.write!(Path.join(dir, "bybit.json"), Jason.encode!(%{"exchange" => "bybit"}))
      File.write!(Path.join(dir, "_manifest.json"), Jason.encode!(%{"count" => 2}))
      # Regression: a stale report dropped in the fixtures dir must not be
      # loaded as a fixture (otherwise the next parity run flags it as drift).
      File.write!(Path.join(dir, "_parity_report.json"), Jason.encode!(%{"summary" => %{}}))

      loaded = FixtureParity.load_disk(dir)

      assert loaded |> Map.keys() |> Enum.sort() == ["binance", "bybit"]
      assert loaded["binance"]["exchange"] == "binance"
    end
  end
end
