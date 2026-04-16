defmodule CcxtExtract.UpdateTestSupport do
  @moduledoc false

  def record(task_name, args) do
    send(test_pid(), {:task_ran, task_name, args})
  end

  def write_manifest(_args) do
    # --output is no longer forwarded to sub-stages; update.ex sets
    # :priv_dir_override at the top level so Paths.priv("output") resolves
    # under the test's output_dir automatically.
    output_dir = CcxtExtract.Paths.priv("output")
    manifest_path = Path.join(output_dir, "_manifest.json")

    File.mkdir_p!(output_dir)

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "ccxt_version" => "test-version",
        "exchanges" => ["binance"]
      })
    )
  end

  defp test_pid do
    Application.get_env(:ccxt_extract, :update_test_pid, self())
  end
end

# Generate lightweight recording stubs for orchestration tests.
# Each stub sends {:task_ran, name, args} to the test process.
for task <-
      ~w(setup quickbeam_extractors oxc_extractors base_methods validate contract_test describe_keys describe_key_analysis summary family_analysis) do
  defmodule Module.concat([Mix.Tasks.Test, "Record#{Macro.camelize(task)}"]) do
    @moduledoc false
    use Mix.Task

    @task_name "test.record_#{task}"
    @impl true
    def run(args), do: CcxtExtract.UpdateTestSupport.record(@task_name, args)
  end
end

# Pipeline stub also writes a manifest so the diff summary works.
defmodule Mix.Tasks.Test.RecordPipeline do
  @moduledoc false
  use Mix.Task

  @impl true
  def run(args) do
    CcxtExtract.UpdateTestSupport.record("test.record_pipeline", args)
    CcxtExtract.UpdateTestSupport.write_manifest(args)
  end
end

defmodule Mix.Tasks.CcxtExtract.UpdateTest do
  @moduledoc """
  Tests for the update task's orchestration, diff logic, and arg parsing.

  Uses lightweight fake Mix tasks to verify stage ordering without invoking the
  real extraction pipeline.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.CcxtExtract.Update

  @task_overrides [
    setup_task: "test.record_setup",
    quickbeam_extractors: ["test.record_quickbeam_extractors"],
    oxc_extractors: [
      {"test.record_oxc_extractors", :scoped},
      {"test.record_base_methods", :unscoped}
    ],
    pipeline_task: "test.record_pipeline",
    validate_task: "test.record_validate",
    contract_test_task: "test.record_contract_test",
    quickbeam_analytics: ["test.record_describe_keys", "test.record_describe_key_analysis"],
    derived_analytics: ["test.record_summary", "test.record_family_analysis"],
    # Disarm the git-status safety rail for orchestration tests that don't
    # exercise it directly. Safety-rail tests override this with a sandbox path.
    safety_paths: []
  ]

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

  describe "orchestration" do
    test "runs Stage 6 analytics after validate" do
      output_dir = make_tmp_output_dir()

      {output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--output", output_dir])
          end)
        end)

      assert output =~ "Stage 6: Contract Tests"
      assert output =~ "Stage 7: Analytics"

      # Sub-stages no longer receive `--output`: the update task sets
      # `:priv_dir_override` before dispatch, and sub-stages pick up the
      # redirect via `Paths.out/1`. See `with_priv_override/2` in update.ex.
      assert task_runs == [
               {"test.record_setup", []},
               {"test.record_quickbeam_extractors", []},
               {"test.record_oxc_extractors", []},
               {"test.record_base_methods", []},
               {"test.record_pipeline", []},
               {"test.record_validate", []},
               {"test.record_contract_test", []},
               {"test.record_describe_keys", []},
               {"test.record_describe_key_analysis", []},
               {"test.record_summary", []},
               {"test.record_family_analysis", []}
             ]
    end

    test "--tier1 --dex propagates to pipeline and contract_test stages" do
      output_dir = make_tmp_output_dir()

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--tier1", "--dex", "--output", output_dir])
          end)
        end)

      assert {"test.record_pipeline", ["--tier1", "--dex"]} in task_runs
      assert {"test.record_contract_test", ["--tier1", "--dex"]} in task_runs
    end

    test "--tier1 --dex propagates to OXC extractor stage" do
      output_dir = make_tmp_output_dir()

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--tier1", "--dex", "--output", output_dir])
          end)
        end)

      assert {"test.record_oxc_extractors", ["--tier1", "--dex"]} in task_runs
      # Unscoped extractors (e.g. base_methods — single-file parse) receive
      # no scope flags even when the caller passes them. Guards the invariant.
      assert {"test.record_base_methods", []} in task_runs
    end

    test "--tier1 --dex propagates to analytics stage (Task 7)" do
      output_dir = make_tmp_output_dir()

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--tier1", "--dex", "--output", output_dir])
          end)
        end)

      # Both QuickBEAM and derived analytics must receive the scope flags.
      # Pre-Task-7 they silently received `[]` while extractors were scoped —
      # producing universe-wide analytics on a scoped pipeline run (manifest /
      # scope mismatch). All eight analytics are scope-aware (Honesty Rule —
      # no `:unscoped` carve-out), so every one in the override list must show
      # the flags propagated.
      assert {"test.record_describe_keys", ["--tier1", "--dex"]} in task_runs
      assert {"test.record_describe_key_analysis", ["--tier1", "--dex"]} in task_runs
      assert {"test.record_summary", ["--tier1", "--dex"]} in task_runs
      assert {"test.record_family_analysis", ["--tier1", "--dex"]} in task_runs
    end

    test "--exchange repeated and comma-split fans out as sorted unique pairs" do
      output_dir = make_tmp_output_dir()

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--exchange", "binance,kraken", "--exchange", "deribit", "--output", output_dir])
          end)
        end)

      pipeline_args =
        Enum.find_value(task_runs, fn
          {"test.record_pipeline", args} -> args
          _ -> nil
        end)

      assert pipeline_args == [
               "--exchange",
               "binance",
               "--exchange",
               "deribit",
               "--exchange",
               "kraken"
             ]
    end

    test "--exchange propagates to contract_test stage (canonical scope flags)" do
      output_dir = make_tmp_output_dir()

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--exchange", "binance", "--output", output_dir])
          end)
        end)

      contract_test_args =
        Enum.find_value(task_runs, fn
          {"test.record_contract_test", args} -> args
          _ -> nil
        end)

      assert contract_test_args == ["--exchange", "binance"]
    end

    test "--all propagates to contract_test stage (canonical scope flags)" do
      output_dir = make_tmp_output_dir()

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--all", "--output", output_dir])
          end)
        end)

      contract_test_args =
        Enum.find_value(task_runs, fn
          {"test.record_contract_test", args} -> args
          _ -> nil
        end)

      assert contract_test_args == ["--all"]
    end
  end

  describe "git-status safety rail" do
    test "aborts when a safety path has uncommitted changes" do
      sandbox = make_git_sandbox()
      dirty_file = Path.join(sandbox, "dirty.json")
      File.write!(dirty_file, "{}")

      overrides = Keyword.put(@task_overrides, :safety_paths, [sandbox])

      assert_raise Mix.Error, ~r/uncommitted changes detected/, fn ->
        with_update_task_overrides(overrides, fn ->
          Update.run([])
        end)
      end
    end

    test "--force bypasses the safety rail when paths are dirty" do
      sandbox = make_git_sandbox()
      File.write!(Path.join(sandbox, "dirty.json"), "{}")

      overrides = Keyword.put(@task_overrides, :safety_paths, [sandbox])

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(overrides, fn ->
            Update.run(["--force"])
          end)
        end)

      # If the rail did not abort, we at least got to the pipeline stage.
      assert Enum.any?(task_runs, fn {name, _args} -> name == "test.record_pipeline" end)
    end

    test "passes cleanly when safety paths have no uncommitted changes" do
      sandbox = make_git_sandbox()
      overrides = Keyword.put(@task_overrides, :safety_paths, [sandbox])

      {_output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(overrides, fn ->
            Update.run([])
          end)
        end)

      assert Enum.any?(task_runs, fn {name, _args} -> name == "test.record_pipeline" end)
    end
  end

  describe "orchestration extras" do
    test "--skip-setup skips extractors and QuickBEAM analytics but still runs cached analytics" do
      output_dir = make_tmp_output_dir()

      {output, task_runs} =
        capture_task_run(fn ->
          with_update_task_overrides(@task_overrides, fn ->
            Update.run(["--skip-setup", "--output", output_dir])
          end)
        end)

      assert output =~ "Stage 6: Contract Tests"
      assert output =~ "Stage 7: Analytics"

      assert task_runs == [
               {"test.record_pipeline", []},
               {"test.record_validate", []},
               {"test.record_contract_test", []},
               {"test.record_summary", []},
               {"test.record_family_analysis", []}
             ]
    end
  end

  # Captures Mix.shell() output using Process shell + message collection.
  # Uses try/after for cleanup and runs with async: false because Mix.shell is global.
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

  defp capture_task_run(fun) do
    output = capture_shell(fun)
    {output, collect_task_runs()}
  end

  defp collect_task_runs(acc \\ []) do
    receive do
      {:task_ran, task_name, args} ->
        collect_task_runs([{task_name, args} | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defp with_update_task_overrides(overrides, fun) do
    previous_overrides = Application.get_env(:ccxt_extract, Update)
    previous_test_pid = Application.get_env(:ccxt_extract, :update_test_pid)

    Application.put_env(:ccxt_extract, Update, overrides)
    Application.put_env(:ccxt_extract, :update_test_pid, self())

    try do
      fun.()
    after
      restore_env(:ccxt_extract, Update, previous_overrides)
      restore_env(:ccxt_extract, :update_test_pid, previous_test_pid)
    end
  end

  defp write_tmp_manifest(data) do
    path = Path.join(System.tmp_dir!(), "manifest_#{:rand.uniform(100_000)}.json")
    File.write!(path, Jason.encode!(data))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp make_tmp_output_dir do
    path = Path.join(System.tmp_dir!(), "ccxt_extract_update_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # Creates an isolated git repository directory and registers cleanup. The
  # returned path is a committed, clean repo suitable for safety-rail tests —
  # individual tests can dirty it by writing files and expecting the rail to
  # fire, or leave it clean to verify the rail passes through.
  defp make_git_sandbox do
    path = Path.join(System.tmp_dir!(), "ccxt_safety_rail_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {_out, 0} = System.cmd("git", ["init", "-q"], cd: path, stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_out, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: path)
    {_out, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: path)
    File.write!(Path.join(path, ".gitkeep"), "")
    {_out, 0} = System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: path, stderr_to_stdout: true)

    path
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
