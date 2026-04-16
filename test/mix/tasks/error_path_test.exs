defmodule Mix.Tasks.ErrorPathTest do
  @moduledoc """
  Tests that Mix tasks raise `Mix.Error` with an actionable message when
  their prerequisite input files are missing.

  Each test runs with `:priv_dir_override` pointing at an empty tmp dir, so
  the task's first input read returns `{:error, {:missing_input, path}}` and
  the task translates that into a `Mix.raise/1`. No real `priv/discoveries/`
  files are touched.
  """

  # async: false — tests mutate :priv_dir_override application env.
  use ExUnit.Case, async: false

  alias CcxtExtract.Paths
  alias Mix.Tasks.CcxtExtract.DescribeKeyAnalysis
  alias Mix.Tasks.CcxtExtract.FamilyAnalysis
  alias Mix.Tasks.CcxtExtract.MethodAnalysis

  setup do
    tmp = Path.join(System.tmp_dir!(), "ccxt_error_path_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "discoveries"))
    # Seed an empty ts_src so TaskScope's pre-check passes. The tasks under
    # test fail on missing discovery JSON (the scenario we're verifying),
    # not on missing CCXT TypeScript source.
    File.mkdir_p!(Path.join(tmp, "ccxt/ts/src"))

    prior = Application.get_env(:ccxt_extract, :priv_dir_override)
    Application.put_env(:ccxt_extract, :priv_dir_override, tmp)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:ccxt_extract, :priv_dir_override)
        val -> Application.put_env(:ccxt_extract, :priv_dir_override, val)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp_priv: tmp}
  end

  describe "mix ccxt_extract.describe_key_analysis" do
    test "raises when describe_keys.json is missing" do
      expected_path = Paths.priv("discoveries/describe_keys.json")

      error = assert_raise Mix.Error, fn -> DescribeKeyAnalysis.run([]) end

      assert Exception.message(error) ==
               "Missing input file: #{expected_path}\nRun `mix ccxt_extract.describe_keys` first."
    end
  end

  describe "mix ccxt_extract.family_analysis" do
    test "raises when class_hierarchy.json is missing" do
      expected_path = Paths.priv("discoveries/class_hierarchy.json")

      error = assert_raise Mix.Error, fn -> FamilyAnalysis.run([]) end

      assert Exception.message(error) ==
               "Missing input file: #{expected_path}\nRun `mix ccxt_extract.summary` and `mix ccxt_extract.describe` first."
    end
  end

  describe "mix ccxt_extract.method_analysis" do
    test "raises when methods_rest.json is missing" do
      expected_path = Paths.priv("discoveries/methods_rest.json")

      error = assert_raise Mix.Error, fn -> MethodAnalysis.run([]) end

      assert Exception.message(error) ==
               "Missing input file: #{expected_path}\nRun `mix ccxt_extract.methods` first."
    end
  end
end
