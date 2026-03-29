defmodule CcxtExtract.MixTasksIntegrationTest do
  use ExUnit.Case

  import CcxtExtract.TaskHelpers

  alias Mix.Tasks.CcxtExtract.Setup
  alias Mix.Tasks.CcxtExtract.Summary

  @moduletag :integration
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
    setup do
      # Setup.run/1 rewrites ccxt_version.json — save and restore to avoid dirtying worktree
      version_file = CcxtExtract.Paths.version_file()
      original = File.read(version_file)

      on_exit(fn ->
        case original do
          {:ok, content} -> File.write!(version_file, content)
          {:error, :enoent} -> :ok
        end
      end)

      :ok
    end

    test "verifies existing setup without reinstalling" do
      output = run_task_capturing_output(Setup)

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
  end
end
