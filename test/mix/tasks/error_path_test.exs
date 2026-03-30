defmodule Mix.Tasks.ErrorPathTest do
  @moduledoc """
  Tests that Mix tasks raise on missing input files.

  Uses rename-and-restore to temporarily hide prerequisite files,
  verifying that each task's {:error, {:missing_input, _}} path
  triggers Mix.raise with an actionable message.
  """

  # async: false — renames shared files in priv/discoveries
  use ExUnit.Case, async: false

  alias Mix.Tasks.CcxtExtract.DescribeKeyAnalysis
  alias Mix.Tasks.CcxtExtract.FamilyAnalysis
  alias Mix.Tasks.CcxtExtract.MethodAnalysis

  @describe_keys_path CcxtExtract.Paths.priv("discoveries/describe_keys.json")
  @class_hierarchy_path CcxtExtract.Paths.priv("discoveries/class_hierarchy.json")
  @methods_rest_path CcxtExtract.Paths.priv("discoveries/methods_rest.json")

  describe "mix ccxt_extract.describe_key_analysis" do
    test "raises when describe_keys.json is missing" do
      with_renamed(@describe_keys_path, fn ->
        assert_raise Mix.Error, ~r/Missing input file/, fn ->
          DescribeKeyAnalysis.run([])
        end
      end)
    end
  end

  describe "mix ccxt_extract.family_analysis" do
    test "raises when class_hierarchy.json is missing" do
      with_renamed(@class_hierarchy_path, fn ->
        assert_raise Mix.Error, ~r/Missing input file/, fn ->
          FamilyAnalysis.run([])
        end
      end)
    end
  end

  describe "mix ccxt_extract.method_analysis" do
    test "raises when methods_rest.json is missing" do
      with_renamed(@methods_rest_path, fn ->
        assert_raise Mix.Error, ~r/Missing input file/, fn ->
          MethodAnalysis.run([])
        end
      end)
    end
  end

  # Temporarily renames a file to .bak, runs the callback, then restores it.
  defp with_renamed(path, fun) do
    backup = path <> ".bak"
    File.rename!(path, backup)

    try do
      fun.()
    after
      File.rename!(backup, path)
    end
  end
end
