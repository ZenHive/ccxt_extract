defmodule Mix.Tasks.CcxtExtract.UpdateTest do
  @moduledoc """
  Tests for the update orchestration task's diff logic and arg building.

  Tests the pure functions (manifest reading, diff reporting, arg construction)
  without running the full pipeline.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.CcxtExtract.Update

  describe "read_manifest/1" do
    test "returns nil for missing file" do
      assert Update.read_manifest("/nonexistent/path/_manifest.json") == nil
    end

    test "reads and decodes a valid manifest" do
      path =
        write_tmp_manifest(%{
          "ccxt_version" => "4.5.45",
          "exchange_count" => 110,
          "exchanges" => ["binance", "kraken"]
        })

      manifest = Update.read_manifest(path)
      assert manifest["ccxt_version"] == "4.5.45"
      assert manifest["exchange_count"] == 110
      assert manifest["exchanges"] == ["binance", "kraken"]
    end

    test "returns nil for invalid JSON" do
      path = Path.join(System.tmp_dir!(), "invalid_manifest_#{:rand.uniform(100_000)}.json")
      File.write!(path, "not json")

      on_exit(fn -> File.rm(path) end)

      assert Update.read_manifest(path) == nil
    end
  end

  describe "report_diff/2" do
    test "handles first extraction (no old manifest)" do
      output = capture_shell(fn -> Update.report_diff(nil, %{"ccxt_version" => "4.5.45"}) end)
      assert output =~ "First extraction"
    end

    test "handles missing new manifest" do
      output =
        capture_shell(fn ->
          Update.report_diff(%{"ccxt_version" => "4.5.45"}, nil)
        end)

      assert output =~ "no manifest found"
    end

    test "reports unchanged version and exchanges" do
      manifest = %{
        "ccxt_version" => "4.5.45",
        "exchanges" => ["binance", "kraken"]
      }

      output = capture_shell(fn -> Update.report_diff(manifest, manifest) end)
      assert output =~ "4.5.45 (unchanged)"
      assert output =~ "2 → 2 (unchanged)"
    end

    test "reports version change" do
      old = %{"ccxt_version" => "4.5.44", "exchanges" => ["binance"]}
      new = %{"ccxt_version" => "4.5.45", "exchanges" => ["binance"]}

      output = capture_shell(fn -> Update.report_diff(old, new) end)
      assert output =~ "4.5.44 → 4.5.45"
    end

    test "reports added exchanges" do
      old = %{"ccxt_version" => "4.5.45", "exchanges" => ["binance"]}
      new = %{"ccxt_version" => "4.5.45", "exchanges" => ["binance", "kraken"]}

      output = capture_shell(fn -> Update.report_diff(old, new) end)
      assert output =~ "1 → 2 (+1)"
      assert output =~ "Added: kraken"
    end

    test "reports removed exchanges" do
      old = %{"ccxt_version" => "4.5.45", "exchanges" => ["binance", "kraken"]}
      new = %{"ccxt_version" => "4.5.45", "exchanges" => ["binance"]}

      output = capture_shell(fn -> Update.report_diff(old, new) end)
      assert output =~ "2 → 1 (-1)"
      assert output =~ "Removed: kraken"
    end

    test "reports both added and removed exchanges" do
      old = %{"ccxt_version" => "4.5.45", "exchanges" => ["binance", "kraken"]}
      new = %{"ccxt_version" => "4.5.45", "exchanges" => ["binance", "bybit"]}

      output = capture_shell(fn -> Update.report_diff(old, new) end)
      assert output =~ "2 → 2 (unchanged)"
      assert output =~ "Added: bybit"
      assert output =~ "Removed: kraken"
    end
  end

  describe "argument parsing" do
    test "rejects unknown options" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        Update.run(["--bogus"])
      end
    end

    test "rejects unexpected arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        Update.run(["extra_arg"])
      end
    end
  end

  # Captures Mix.shell() output using Process shell + message collection.
  # Uses try/after for cleanup and avoids global Mix.shell race with async: true.
  defp capture_shell(fun) do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      fun.()
      CcxtExtract.TaskHelpers.collect_shell_output()
    after
      Mix.shell(original_shell)
    end
  end

  defp write_tmp_manifest(data) do
    path = Path.join(System.tmp_dir!(), "manifest_#{:rand.uniform(100_000)}.json")
    File.write!(path, Jason.encode!(data))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
