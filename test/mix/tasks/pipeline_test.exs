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
end
