defmodule CcxtExtract.TaskScopeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.TaskScope

  setup do
    tmp = Path.join(System.tmp_dir!(), "ccxt_task_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "rebuild_manifest_exchanges/1" do
    test "returns [] for empty directory", %{tmp: tmp} do
      assert TaskScope.rebuild_manifest_exchanges(tmp) == []
    end

    test "returns [] for non-existent directory" do
      assert TaskScope.rebuild_manifest_exchanges("/nonexistent/path/xyz") == []
    end

    test "returns sorted exchange IDs from *.json basenames", %{tmp: tmp} do
      write_files(tmp, ["kraken.json", "binance.json", "coinbaseexchange.json"])

      assert TaskScope.rebuild_manifest_exchanges(tmp) ==
               ["binance", "coinbaseexchange", "kraken"]
    end

    test "filters _-prefixed files (manifests, metadata)", %{tmp: tmp} do
      write_files(tmp, ["binance.json", "_manifest.json", "_base_methods.json"])

      assert TaskScope.rebuild_manifest_exchanges(tmp) == ["binance"]
    end

    test "ignores non-.json files", %{tmp: tmp} do
      write_files(tmp, ["binance.json", "kraken.json"])
      File.write!(Path.join(tmp, "README.md"), "x")
      File.write!(Path.join(tmp, "notes.txt"), "x")

      assert TaskScope.rebuild_manifest_exchanges(tmp) == ["binance", "kraken"]
    end

    test "mixed IDs and metadata returns only IDs, sorted", %{tmp: tmp} do
      write_files(tmp, ["deribit.json", "_manifest.json", "bybit.json", "_stats.json", "okx.json"])

      assert TaskScope.rebuild_manifest_exchanges(tmp) == ["bybit", "deribit", "okx"]
    end
  end

  defp write_files(dir, names) do
    for name <- names do
      File.write!(Path.join(dir, name), "{}")
    end
  end
end
