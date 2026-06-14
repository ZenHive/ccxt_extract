defmodule Mix.Tasks.CcxtExtract.PruneTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.CcxtExtract.Prune, as: PruneTask

  describe "argument parsing" do
    test "rejects unknown options" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        PruneTask.run(["--bogus"])
      end
    end

    test "rejects unexpected positional arguments" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        PruneTask.run(["stray"])
      end
    end

    test "--all combined with --tier1 is rejected during scope resolution" do
      assert {:error, {:all_with_narrowing, conflicting}} =
               CcxtExtract.Scope.resolve([all: true, tier1: true], ["binance"])

      assert :tier1 in conflicting
    end
  end
end
