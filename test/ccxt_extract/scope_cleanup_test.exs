defmodule CcxtExtract.ScopeCleanupTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ScopeCleanup

  setup do
    tmp = Path.join(System.tmp_dir!(), "ccxt_scope_cleanup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "prune_out_of_scope/3" do
    test "deletes out-of-scope per-exchange files, keeps in-scope", %{tmp: tmp} do
      write_files(tmp, ["binance.json", "kraken.json", "_manifest.json"])

      assert {:ok, [removed]} =
               ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(["binance"]))

      assert Path.basename(removed) == "kraken.json"
      assert File.exists?(Path.join(tmp, "binance.json"))
      assert File.exists?(Path.join(tmp, "_manifest.json"))
      refute File.exists?(Path.join(tmp, "kraken.json"))
    end

    test "preserves all _-prefixed aggregate files", %{tmp: tmp} do
      write_files(tmp, ["_manifest.json", "_base_methods.json"])

      assert {:ok, []} = ScopeCleanup.prune_out_of_scope(tmp, MapSet.new())
      assert File.exists?(Path.join(tmp, "_manifest.json"))
      assert File.exists?(Path.join(tmp, "_base_methods.json"))
    end

    test ":preserve list keeps non-underscore files", %{tmp: tmp} do
      write_files(tmp, ["exchange_v3.json", "kraken.json"])

      assert {:ok, [removed]} =
               ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(), preserve: ["exchange_v3.json"])

      assert Path.basename(removed) == "kraken.json"
      assert File.exists?(Path.join(tmp, "exchange_v3.json"))
    end

    test "no-op when everything is in scope", %{tmp: tmp} do
      write_files(tmp, ["binance.json", "kraken.json"])

      assert {:ok, []} =
               ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(["binance", "kraken"]))

      assert File.exists?(Path.join(tmp, "binance.json"))
      assert File.exists?(Path.join(tmp, "kraken.json"))
    end

    test "no-op on empty directory", %{tmp: tmp} do
      assert {:ok, []} = ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(["binance"]))
    end

    test "recurse: true descends into subdirectories", %{tmp: tmp} do
      describe_dir = Path.join(tmp, "describe")
      File.mkdir_p!(describe_dir)
      write_files(describe_dir, ["binance.json", "kraken.json", "_manifest.json"])

      assert {:ok, [removed]} =
               ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(["binance"]), recurse: true)

      assert Path.basename(removed) == "kraken.json"
      assert File.exists?(describe_dir)
      assert File.exists?(Path.join(describe_dir, "binance.json"))
      assert File.exists?(Path.join(describe_dir, "_manifest.json"))
      refute File.exists?(Path.join(describe_dir, "kraken.json"))
    end

    test "recurse: false (default) leaves subdirectory files alone", %{tmp: tmp} do
      nested = Path.join(tmp, "nested")
      File.mkdir_p!(nested)
      write_files(nested, ["kraken.json"])

      assert {:ok, []} = ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(["binance"]))
      assert File.exists?(Path.join(nested, "kraken.json"))
    end

    test "ignores non-.json files (README.md, etc.)", %{tmp: tmp} do
      write_files(tmp, ["binance.json", "kraken.json", "README.md"])

      assert {:ok, [removed]} =
               ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(["binance"]))

      assert Path.basename(removed) == "kraken.json"
      assert File.exists?(Path.join(tmp, "binance.json"))
      assert File.exists?(Path.join(tmp, "README.md"))
      refute File.exists?(Path.join(tmp, "kraken.json"))
    end

    test "ignores non-.json files even with recurse: true", %{tmp: tmp} do
      sub = Path.join(tmp, "describe")
      File.mkdir_p!(sub)
      write_files(sub, ["binance.json", "kraken.json", "NOTES.txt"])

      assert {:ok, [removed]} =
               ScopeCleanup.prune_out_of_scope(tmp, MapSet.new(["binance"]), recurse: true)

      assert Path.basename(removed) == "kraken.json"
      assert File.exists?(Path.join(sub, "binance.json"))
      assert File.exists?(Path.join(sub, "NOTES.txt"))
      refute File.exists?(Path.join(sub, "kraken.json"))
    end

    test "removed list is sorted for determinism", %{tmp: tmp} do
      write_files(tmp, ["zzz.json", "aaa.json", "mmm.json"])

      assert {:ok, removed} = ScopeCleanup.prune_out_of_scope(tmp, MapSet.new())
      assert removed == Enum.sort(removed)
      assert length(removed) == 3
    end
  end

  describe "git_status_clean?/2" do
    test "returns :ok on clean subtree", %{tmp: tmp} do
      init_git_repo(tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello")
      git!(tmp, ["add", "."])
      git!(tmp, ["commit", "-q", "-m", "init"])

      assert :ok = ScopeCleanup.git_status_clean?(".", cd: tmp)
    end

    test "returns dirty list when tracked file is modified", %{tmp: tmp} do
      init_git_repo(tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello")
      git!(tmp, ["add", "."])
      git!(tmp, ["commit", "-q", "-m", "init"])
      File.write!(Path.join(tmp, "a.txt"), "changed")

      assert {:error, [line]} = ScopeCleanup.git_status_clean?(".", cd: tmp)
      assert line =~ "a.txt"
    end

    test "returns dirty list when untracked file present", %{tmp: tmp} do
      init_git_repo(tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello")
      git!(tmp, ["add", "."])
      git!(tmp, ["commit", "-q", "-m", "init"])
      File.write!(Path.join(tmp, "new.txt"), "untracked")

      assert {:error, dirty} = ScopeCleanup.git_status_clean?(".", cd: tmp)
      assert Enum.any?(dirty, &(&1 =~ "new.txt"))
    end

    test "raises Mix.Error outside a git repository", %{tmp: tmp} do
      assert_raise Mix.Error, fn ->
        ScopeCleanup.git_status_clean?(".", cd: tmp)
      end
    end
  end

  defp write_files(dir, names) do
    for name <- names do
      File.write!(Path.join(dir, name), "{}")
    end
  end

  defp init_git_repo(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    git!(dir, ["config", "commit.gpgsign", "false"])
  end

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{out}")
    end
  end
end
