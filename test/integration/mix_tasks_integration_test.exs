defmodule CcxtExtract.MixTasksIntegrationTest do
  # async: false (default) — the setup describe uses File.cd!/2, which
  # mutates the BEAM-wide CWD. Flipping this module to async: true would
  # race with any other async test that reads relative paths.
  use ExUnit.Case

  import CcxtExtract.TaskHelpers

  alias Mix.Tasks.CcxtExtract.Setup
  alias Mix.Tasks.CcxtExtract.Summary

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 120_000

  describe "mix ccxt_extract.exchanges" do
    test "extracts exchanges and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.Exchanges)

      assert output =~ "Extracting exchange metadata"
      assert output =~ "Done."
      assert output =~ "exchanges extracted"
      assert output =~ "Certified:"
      assert output =~ "Pro:"
      assert output =~ "Aliases:"
      assert output =~ "Real (non-alias):"
      assert output =~ "Output: priv/discoveries/exchanges.json"
    end
  end

  describe "mix ccxt_extract.classes" do
    test "extracts class hierarchy and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.Classes)

      assert output =~ "Extracting class hierarchy"
      assert output =~ "Done."
      assert output =~ "classes extracted"
      assert output =~ "REST:"
      assert output =~ "WS:"
      assert output =~ "WS counterparts:"
      assert output =~ "Inheritance families:"
      assert output =~ "Largest families:"
      assert output =~ "Output: priv/discoveries/class_hierarchy.json"
    end
  end

  describe "mix ccxt_extract.summary" do
    setup do
      # Ensure input files exist (may already exist from a previous test run)
      discoveries = CcxtExtract.Paths.discoveries()
      exchanges_path = Path.join(discoveries, "exchanges.json")
      classes_path = Path.join(discoveries, "class_hierarchy.json")

      if !File.exists?(exchanges_path) do
        {:ok, exchanges} = CcxtExtract.Exchanges.extract()
        CcxtExtract.Exchanges.write!(exchanges)
      end

      if !File.exists?(classes_path) do
        {:ok, classes, _stats} = CcxtExtract.Classes.extract()
        CcxtExtract.Classes.write!(classes)
      end

      :ok
    end

    test "builds summary and prints report" do
      output = run_task_capturing_output(Summary)

      assert output =~ "Building exchange summary"
      assert output =~ "Exchange Summary"
      assert output =~ "Exchanges:"
      assert output =~ "Classes:"
      assert output =~ "Families:"
      assert output =~ "With WS:"
      assert output =~ "Top Exchange Families"
      assert output =~ "Output: priv/discoveries/exchange_summary.json"
    end

    test "raises when input files are missing" do
      exchanges_path = CcxtExtract.Paths.priv("discoveries/exchanges.json")
      backup = exchanges_path <> ".task_bak"
      File.rename!(exchanges_path, backup)

      try do
        assert_raise Mix.Error, ~r/Missing input file/, fn ->
          run_task_capturing_output(Summary)
        end
      after
        File.rename!(backup, exchanges_path)
      end
    end
  end

  describe "mix ccxt_extract.setup" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      real_ccxt = "ccxt" |> CcxtExtract.Paths.priv() |> Path.expand()
      real_node_modules_ccxt = Path.expand("node_modules/ccxt")

      tmp_priv = Path.join(tmp_dir, "priv")
      tmp_ccxt = Path.join(tmp_priv, "ccxt")
      tmp_node_modules_ccxt = Path.join([tmp_dir, "node_modules", "ccxt"])

      File.mkdir_p!(tmp_priv)
      File.mkdir_p!(Path.dirname(tmp_node_modules_ccxt))

      # --no-hardlinks keeps checkouts in the clone fully isolated from the
      # real repo's object store; --local is still fast (no protocol). Origin
      # stays pointed at the local real_ccxt so `git fetch origin tag vX`
      # resolves from the dev's already-present objects — no network needed.
      {_, 0} =
        System.cmd(
          "git",
          ["clone", "--local", "--no-hardlinks", real_ccxt, tmp_ccxt],
          stderr_to_stdout: true
        )

      # node_modules/ccxt is mutated by --latest and --ccxt-version; copy so
      # the real tree is untouched.
      File.cp_r!(real_node_modules_ccxt, tmp_node_modules_ccxt)

      Application.put_env(:ccxt_extract, :priv_dir_override, tmp_priv)
      on_exit(fn -> Application.delete_env(:ccxt_extract, :priv_dir_override) end)

      :ok
    end

    test "verifies existing setup without reinstalling", %{tmp_dir: tmp_dir} do
      output = File.cd!(tmp_dir, fn -> run_task_capturing_output(Setup) end)

      # Since CCXT is already installed, it should skip npm install
      assert output =~ "already installed" or output =~ "Installing CCXT"
      assert output =~ "Bundle already in priv" or output =~ "Copied browser bundle"
      assert output =~ "TypeScript source available"
      assert output =~ "Verifying QuickBEAM"
      assert output =~ "QuickBEAM: loaded CCXT"
      assert output =~ "Verifying OXC"
      assert output =~ "OXC: parsed binance.ts"
      assert output =~ "Setup complete"
      assert output =~ "CCXT version:"
    end

    # No test for `--latest`: that branch couples to npm-registry-vs-git-HEAD
    # drift. When the registry has advanced past the developer's priv/ccxt
    # tag, `record_versions` fatals with a version mismatch — a legitimate
    # production guard, but untestable in isolation without stubbing npm.
    # The versioned path (--ccxt-version) covers the structurally-equivalent
    # update_ts_source/install_npm_package branches below.

    test "--ccxt-version with current version succeeds", %{tmp_dir: tmp_dir} do
      # Read the currently installed version so we pin to something that works
      current_version =
        [tmp_dir, "node_modules/ccxt/package.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()
        |> Map.get("version")

      output =
        File.cd!(tmp_dir, fn ->
          run_task_capturing_output(Setup, ["--ccxt-version", current_version])
        end)

      assert output =~ "Installing CCXT version #{current_version}"
      assert output =~ "Updating TS source to v#{current_version}"
      assert output =~ "Setup complete"
    end

    test "--ccxt-version with nonexistent version raises", %{tmp_dir: tmp_dir} do
      File.cd!(tmp_dir, fn ->
        assert_raise Mix.Error, ~r/Could not checkout v0\.0\.1/, fn ->
          run_task_capturing_output(Setup, ["--ccxt-version", "0.0.1"])
        end
      end)
    end
  end
end
