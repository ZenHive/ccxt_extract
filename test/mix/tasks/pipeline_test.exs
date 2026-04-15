defmodule Mix.Tasks.CcxtExtract.PipelineTest do
  @moduledoc """
  CLI-level tests for the scope flag handling in the pipeline mix task.

  The heavy assembly/validation paths are covered by
  `CcxtExtract.PipelineTest` (unit tests against the Pipeline module).
  These tests exercise the thin CLI wrapper — flag parsing, Scope
  resolution error mapping, and Mix.raise message shaping.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.CcxtExtract.Pipeline, as: PipelineTask

  describe "argument parsing" do
    test "rejects unknown options" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        PipelineTask.run(["--bogus"])
      end
    end

    test "rejects unexpected positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        PipelineTask.run(["stray"])
      end
    end
  end

  describe "scope resolution error mapping" do
    test "--all combined with --tier1 raises with a clear conflict message" do
      assert_raise Mix.Error, ~r/--all conflicts with.*--tier1/, fn ->
        PipelineTask.run(["--all", "--tier1"])
      end
    end

    test "unknown --exchange ID raises with fuzzy suggestion" do
      # The universe loaded from priv/discoveries/exchanges.json should contain
      # "binance". "xbinance" is a single-character prefix typo that Jaro
      # scores well above the 0.7 suggestion threshold.
      assert_raise Mix.Error, ~r/Unknown --exchange ID.*binance/s, fn ->
        PipelineTask.run(["--exchange", "xbinance"])
      end
    end
  end

  describe "git-status safety rail" do
    test "narrowed scope aborts when a safety path has uncommitted changes" do
      sandbox = make_git_sandbox()
      File.write!(Path.join(sandbox, "dirty.json"), "{}")

      assert_raise Mix.Error, ~r/uncommitted changes detected/, fn ->
        with_pipeline_overrides([safety_paths: [sandbox]], fn ->
          PipelineTask.run(["--tier1"])
        end)
      end
    end

    test "--force bypasses the safety rail when paths are dirty" do
      sandbox = make_git_sandbox()
      File.write!(Path.join(sandbox, "dirty.json"), "{}")

      result =
        try_pipeline_run(
          ["--tier1", "--force", "--output", make_tmp_output_dir()],
          safety_paths: [sandbox]
        )

      refute rail_aborted?(result), "expected --force to bypass the rail; got #{inspect(result)}"
    end

    test "--all skips the rail check (full-universe runs do not prune)" do
      sandbox = make_git_sandbox()
      File.write!(Path.join(sandbox, "dirty.json"), "{}")

      result =
        try_pipeline_run(
          ["--all", "--output", make_tmp_output_dir()],
          safety_paths: [sandbox]
        )

      refute rail_aborted?(result), "expected --all to skip the rail; got #{inspect(result)}"
    end

    test "rail protects the --output directory (not hardcoded priv/output)" do
      sandbox = make_git_sandbox()
      File.write!(Path.join(sandbox, "dirty.json"), "{}")

      # No Application env override — exercise the real default that
      # resolves to `opts[:output] || priv/output`. A dirty custom output
      # dir must trip the rail.
      assert_raise Mix.Error, ~r/uncommitted changes detected/, fn ->
        PipelineTask.run(["--tier1", "--output", sandbox])
      end
    end
  end

  defp try_pipeline_run(args, overrides) do
    with_pipeline_overrides(overrides, fn ->
      try do
        PipelineTask.run(args)
        :ok
      rescue
        e in Mix.Error -> {:mix_error, Exception.message(e)}
      end
    end)
  end

  defp rail_aborted?({:mix_error, msg}), do: msg =~ ~r/uncommitted changes detected/
  defp rail_aborted?(_), do: false

  defp with_pipeline_overrides(overrides, fun) do
    previous = Application.get_env(:ccxt_extract, PipelineTask)
    Application.put_env(:ccxt_extract, PipelineTask, overrides)

    try do
      fun.()
    after
      restore_env(:ccxt_extract, PipelineTask, previous)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp make_tmp_output_dir do
    path =
      Path.join(System.tmp_dir!(), "ccxt_extract_pipeline_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # Creates an isolated, committed-clean git repository directory and
  # registers cleanup. Tests dirty it by writing files to verify the rail
  # fires (or leave clean to verify pass-through). Mirrors
  # `test/mix/tasks/update_test.exs:471-485`.
  defp make_git_sandbox do
    path = Path.join(System.tmp_dir!(), "ccxt_pipeline_rail_#{System.unique_integer([:positive])}")
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
end
