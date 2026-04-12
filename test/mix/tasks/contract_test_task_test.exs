defmodule Mix.Tasks.CcxtExtract.ContractTestTaskTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.CcxtExtract.ContractTest, as: Task

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "ccxt_contract_task_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp write_exchange(dir, id, payload) do
    File.write!(Path.join(dir, "#{id}.json"), Jason.encode!(Map.put(payload, "id", id)))
  end

  defp clean_exchange(id) do
    %{
      "id" => id,
      "runtime" => %{
        "describe" => %{"has" => %{"fetchOHLCV" => true}, "api" => %{"public" => %{}}}
      },
      "structure" => %{
        "unified_endpoints" => %{"fetchOHLCV" => ["x"]},
        "authenticated_sections" => [],
        "handle_errors" => %{"error_code_fields" => []}
      }
    }
  end

  defp violating_exchange(id) do
    %{
      "id" => id,
      "runtime" => %{
        "describe" => %{"has" => %{"fetchOHLCV" => "__undefined"}, "api" => %{"public" => %{}}}
      },
      "structure" => %{
        "unified_endpoints" => %{"fetchOHLCV" => ["x"]},
        "authenticated_sections" => [],
        "handle_errors" => %{"error_code_fields" => []}
      }
    }
  end

  test "writes report to --report path and exits normally on clean corpus", %{tmp: tmp} do
    write_exchange(tmp, "ok", clean_exchange("ok"))
    report_path = Path.join(tmp, "custom_report.json")

    Task.run(["--output", tmp, "--report", report_path])

    assert File.exists?(report_path)
    report = report_path |> File.read!() |> Jason.decode!()
    assert report["summary"]["total_findings"] == 0
  end

  test "--strict raises when findings exist", %{tmp: tmp} do
    write_exchange(tmp, "bad", violating_exchange("bad"))
    report_path = Path.join(tmp, "report.json")

    assert_raise Mix.Error, ~r/strict mode/, fn ->
      Task.run(["--output", tmp, "--report", report_path, "--strict"])
    end

    # Report is still written before raise
    assert File.exists?(report_path)
  end

  test "findings are sorted deterministically across runs", %{tmp: tmp} do
    write_exchange(tmp, "zeta", violating_exchange("zeta"))
    write_exchange(tmp, "alpha", violating_exchange("alpha"))
    report_path = Path.join(tmp, "report.json")

    Task.run(["--output", tmp, "--report", report_path])

    report = report_path |> File.read!() |> Jason.decode!()
    ids = Enum.map(report["findings"], & &1["exchange"])
    assert ids == Enum.sort(ids)
  end

  test "rejects unknown options", %{tmp: tmp} do
    assert_raise Mix.Error, ~r/Unknown option/, fn ->
      Task.run(["--bogus", "x", "--output", tmp])
    end
  end
end
