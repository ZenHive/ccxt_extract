defmodule Mix.Tasks.CcxtExtract.ContractTestTaskTest do
  # async: false — Mix.shell/1 is a global setting.
  use ExUnit.Case, async: false

  alias CcxtExtract.Test.ExchangeFixtures
  alias Mix.Tasks.CcxtExtract.ContractTest, as: Task

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "ccxt_contract_task_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Mix.shell(prev_shell)
    end)

    {:ok, tmp: tmp}
  end

  defp write_exchange(dir, id, payload) do
    File.write!(Path.join(dir, "#{id}.json"), Jason.encode!(Map.put(payload, "id", id)))
  end

  # Every fixture in this test passes through `schema_conformant/2`, so
  # the `provenance_covers_schema` invariant produces zero findings
  # against clean fixtures. `violating_exchange/1` layers a
  # `has.fetchOHLCV = "__undefined"` to trigger the unified-endpoints
  # invariant only.
  defp clean_exchange(id) do
    ExchangeFixtures.schema_conformant(id,
      describe: %{"has" => %{"fetchOHLCV" => true}, "api" => %{"public" => %{}}},
      unified_endpoints: %{"fetchOHLCV" => ["x"]}
    )
  end

  defp violating_exchange(id) do
    id
    |> clean_exchange()
    |> put_in(["runtime", "describe", "has"], %{"fetchOHLCV" => "__undefined"})
  end

  test "writes report to --report path and exits normally on clean corpus", %{tmp: tmp} do
    write_exchange(tmp, "binance", clean_exchange("binance"))
    report_path = Path.join(tmp, "custom_report.json")

    Task.run(["--output", tmp, "--report", report_path, "--exchange", "binance"])

    assert File.exists?(report_path)
    report = report_path |> File.read!() |> Jason.decode!()
    assert report["summary"]["total_findings"] == 0
  end

  test "--strict raises when findings exist", %{tmp: tmp} do
    write_exchange(tmp, "binance", violating_exchange("binance"))
    report_path = Path.join(tmp, "report.json")

    assert_raise Mix.Error, ~r/strict mode/, fn ->
      Task.run([
        "--output",
        tmp,
        "--report",
        report_path,
        "--strict",
        "--exchange",
        "binance"
      ])
    end

    # Report is still written before raise
    assert File.exists?(report_path)
  end

  test "findings are sorted deterministically across runs", %{tmp: tmp} do
    write_exchange(tmp, "binance", violating_exchange("binance"))
    write_exchange(tmp, "deribit", violating_exchange("deribit"))
    report_path = Path.join(tmp, "report.json")

    Task.run([
      "--output",
      tmp,
      "--report",
      report_path,
      "--exchange",
      "binance,deribit"
    ])

    report = report_path |> File.read!() |> Jason.decode!()
    ids = Enum.map(report["findings"], & &1["exchange"])
    assert ids == Enum.sort(ids)
  end

  test "rejects unknown options", %{tmp: tmp} do
    assert_raise Mix.Error, ~r/Unknown option/, fn ->
      Task.run(["--bogus", "x", "--output", tmp])
    end
  end

  describe "--tier1 scoping" do
    test "loads only in-scope tier1 member files; exchanges_checked reflects scope", %{tmp: tmp} do
      # In-scope: binance (root) and binanceus (variant — must inherit tier1)
      write_exchange(tmp, "binance", violating_exchange("binance"))
      write_exchange(tmp, "binanceus", violating_exchange("binanceus"))
      # Out-of-scope: tier2 root, tier3 root, and a random unclassified id
      write_exchange(tmp, "kraken", violating_exchange("kraken"))
      write_exchange(tmp, "bitget", violating_exchange("bitget"))
      write_exchange(tmp, "aftermath", violating_exchange("aftermath"))

      report_path = Path.join(tmp, "tier1_report.json")
      Task.run(["--output", tmp, "--report", report_path, "--tier1"])

      report = report_path |> File.read!() |> Jason.decode!()

      # Only files for tier1 members should have been loaded.
      assert report["summary"]["exchanges_checked"] == 2

      found_ids = report["findings"] |> Enum.map(& &1["exchange"]) |> Enum.uniq() |> Enum.sort()
      assert found_ids == ["binance", "binanceus"]
    end

    test "missing scoped files are skipped with a note, not crashed", %{tmp: tmp} do
      # tier1 flag enabled, but only binance exists on disk — the rest
      # (bybit, okx, variants, etc.) are missing. Should warn and proceed.
      write_exchange(tmp, "binance", clean_exchange("binance"))
      report_path = Path.join(tmp, "partial_report.json")

      Task.run(["--output", tmp, "--report", report_path, "--tier1"])

      assert Enum.any?(drain_shell_info(), &String.contains?(&1, "scoped exchange(s) missing"))

      assert File.exists?(report_path)
      report = report_path |> File.read!() |> Jason.decode!()
      assert report["summary"]["exchanges_checked"] == 1
    end
  end

  describe "--exchange scoping" do
    test "loads exactly the explicitly named exchange", %{tmp: tmp} do
      write_exchange(tmp, "binance", clean_exchange("binance"))
      write_exchange(tmp, "deribit", clean_exchange("deribit"))
      report_path = Path.join(tmp, "report.json")

      Task.run(["--output", tmp, "--report", report_path, "--exchange", "binance"])

      report = report_path |> File.read!() |> Jason.decode!()
      assert report["summary"]["exchanges_checked"] == 1
    end

    test "unknown --exchange id aborts with fuzzy suggestion", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/did you mean.*binance/, fn ->
        Task.run(["--output", tmp, "--exchange", "binancee"])
      end
    end
  end

  describe "universe mismatch guard" do
    test "no-flag run fails loud when corpus is a partial view", %{tmp: tmp} do
      write_exchange(tmp, "binance", clean_exchange("binance"))

      assert_raise Mix.Error, ~r/Universe mismatch/, fn ->
        Task.run(["--output", tmp])
      end
    end

    test "--all also enforces the universe check", %{tmp: tmp} do
      write_exchange(tmp, "binance", clean_exchange("binance"))

      assert_raise Mix.Error, ~r/Universe mismatch/, fn ->
        Task.run(["--output", tmp, "--all"])
      end
    end

    test "error message names the remediation commands", %{tmp: tmp} do
      write_exchange(tmp, "binance", clean_exchange("binance"))

      error =
        assert_raise Mix.Error, fn ->
          Task.run(["--output", tmp])
        end

      assert error.message =~ "mix ccxt_extract.update"
      assert error.message =~ "--tier1"
      assert error.message =~ "--exchange"
    end
  end

  describe "flag validation" do
    test "--all combined with --tier1 aborts with narrowing-conflict message", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/--all conflicts with narrowing flag/, fn ->
        Task.run(["--output", tmp, "--all", "--tier1"])
      end
    end

    test "--all combined with --exchange aborts", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/--all conflicts with narrowing flag/, fn ->
        Task.run(["--output", tmp, "--all", "--exchange", "binance"])
      end
    end
  end

  defp drain_shell_info(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} when is_binary(msg) -> drain_shell_info([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
