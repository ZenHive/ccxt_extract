defmodule Mix.Tasks.Test.DeterminismFrozenClock do
  @moduledoc false
  use Mix.Task

  @impl true
  def run(_args) do
    timestamp =
      Application.get_env(:ccxt_extract, :extracted_at) ||
        "volatile-#{System.unique_integer([:positive, :monotonic])}"

    path = CcxtExtract.Paths.out("discoveries/frozen_clock_probe.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"extracted_at" => timestamp, "observed_at" => timestamp}))
  end
end

defmodule CcxtExtract.DeterminismCheckTestSupport do
  @moduledoc false

  def write_json(name, data) do
    path = CcxtExtract.Paths.out("discoveries/#{name}.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
  end

  def write_raw(name, data) do
    path = CcxtExtract.Paths.out("discoveries/#{name}.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
  end

  def test_pid do
    Application.get_env(:ccxt_extract, :determinism_check_test_pid, self())
  end
end

defmodule Mix.Tasks.Test.DeterminismArgs do
  @moduledoc false
  use Mix.Task

  @impl true
  def run(args) do
    send(CcxtExtract.DeterminismCheckTestSupport.test_pid(), {:determinism_args, args})
    CcxtExtract.DeterminismCheckTestSupport.write_json("args_probe", %{"ok" => true})
  end
end

defmodule Mix.Tasks.Test.DeterminismNoWrite do
  @moduledoc false
  use Mix.Task

  @impl true
  def run(_args), do: :ok
end

defmodule Mix.Tasks.Test.DeterminismDiff do
  @moduledoc false
  use Mix.Task

  @impl true
  def run(_args) do
    CcxtExtract.DeterminismCheckTestSupport.write_json("diff_probe", %{
      "stable" => true,
      "volatile" => System.unique_integer([:positive, :monotonic])
    })
  end
end

defmodule Mix.Tasks.Test.DeterminismMissing do
  @moduledoc false
  use Mix.Task

  @impl true
  def run(_args) do
    if Application.fetch_env!(:ccxt_extract, :priv_write_override) =~ "run_a" do
      CcxtExtract.DeterminismCheckTestSupport.write_json("missing_probe", %{"ok" => true})
    end
  end
end

defmodule Mix.Tasks.Test.DeterminismInvalidJson do
  @moduledoc false
  use Mix.Task

  @impl true
  def run(_args) do
    CcxtExtract.DeterminismCheckTestSupport.write_raw("invalid_probe", "{not json")
  end
end

defmodule Mix.Tasks.CcxtExtract.DeterminismCheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.CcxtExtract.DeterminismCheck

  setup do
    prior_shell = Mix.shell()
    prior_extracted_at = Application.get_env(:ccxt_extract, :extracted_at)
    prior_test_pid = Application.get_env(:ccxt_extract, :determinism_check_test_pid)
    Application.put_env(:ccxt_extract, :determinism_check_test_pid, self())
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(prior_shell)
      restore_env(:extracted_at, prior_extracted_at)
      restore_env(:determinism_check_test_pid, prior_test_pid)
    end)

    :ok
  end

  test "freezes timestamp-producing tasks instead of relying on stripped keys" do
    assert :ok =
             DeterminismCheck.run([
               "--task",
               "test.determinism_frozen_clock",
               "--diff-dirs",
               "discoveries"
             ])

    assert_receive {:mix_shell, :info, ["Determinism check OK: 1/1 equal, 0 diverged, 0 side-only, 0 errors"]}
  end

  test "forwards parsed scope args to each task and restores preexisting frozen env" do
    Application.put_env(:ccxt_extract, :extracted_at, "caller-value")

    assert :ok =
             DeterminismCheck.run([
               "--task",
               "test.determinism_args",
               "--scope-args=--tier1 --dex",
               "--diff-dirs=discoveries"
             ])

    assert_receive {:determinism_args, ["--tier1", "--dex"]}
    assert_receive {:determinism_args, ["--tier1", "--dex"]}
    assert Application.get_env(:ccxt_extract, :extracted_at) == "caller-value"
  end

  test "rejects unknown options and unexpected positional arguments" do
    assert_raise Mix.Error, ~r/Unknown option/, fn ->
      DeterminismCheck.run(["--bogus"])
    end

    assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
      DeterminismCheck.run(["extra"])
    end
  end

  test "fails loudly when no files are compared" do
    assert_raise Mix.Error, ~r/0 files compared/, fn ->
      DeterminismCheck.run(["--task", "test.determinism_no_write", "--diff-dirs=discoveries"])
    end
  end

  test "reports real unstripped diffs" do
    assert_raise Mix.Error, ~r/1 diverged/, fn ->
      DeterminismCheck.run(["--task", "test.determinism_diff", "--diff-dirs=discoveries"])
    end

    assert_receive {:mix_shell, :error, ["  DIFF discoveries/diff_probe.json" <> _]}
  end

  test "custom strip keys still allow callers to ignore selected fields" do
    assert :ok =
             DeterminismCheck.run([
               "--task",
               "test.determinism_diff",
               "--diff-dirs=discoveries",
               "--strip-keys=volatile"
             ])

    assert_receive {:mix_shell, :info, ["Determinism check OK: 1/1 equal, 0 diverged, 0 side-only, 0 errors"]}
  end

  test "reports side-only files and invalid JSON errors" do
    assert_raise Mix.Error, ~r/1 side-only/, fn ->
      DeterminismCheck.run(["--task", "test.determinism_missing", "--diff-dirs=discoveries"])
    end

    assert_receive {:mix_shell, :error, ["  MISSING discoveries/missing_probe.json (only in run_a)"]}

    assert_raise Mix.Error, ~r/1 errors/, fn ->
      DeterminismCheck.run(["--task", "test.determinism_invalid_json", "--diff-dirs=discoveries"])
    end

    assert_receive {:mix_shell, :error, ["  ERROR discoveries/invalid_probe.json:" <> _]}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ccxt_extract, key)
  defp restore_env(key, value), do: Application.put_env(:ccxt_extract, key, value)
end
