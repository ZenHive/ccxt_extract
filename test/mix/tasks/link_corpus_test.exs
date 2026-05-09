defmodule Mix.Tasks.CcxtExtract.LinkCorpusTest do
  @moduledoc """
  Coverage for `mix ccxt_extract.link_corpus` and `mix ccxt_extract.unlink_corpus`.

  Tests build a synthetic source/target pair under `System.tmp_dir!/0` and
  exercise the symlink lifecycle without touching the real worktree corpus.
  `File.cd!/2` scopes cwd changes — the tasks read `File.cwd!/0` to pick the
  target.

  `async: false` is required: `File.cd!/2` is VM-global, and `Mix.shell/0` is
  swapped to `Mix.Shell.Process` to capture task output.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.CcxtExtract.LinkCorpus
  alias Mix.Tasks.CcxtExtract.UnlinkCorpus

  setup do
    prior_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(prior_shell) end)

    base = Path.join(System.tmp_dir!(), "link_corpus_test_#{System.unique_integer([:positive])}")
    source = Path.join(base, "source")
    target = Path.join(base, "target")

    File.mkdir_p!(Path.join(source, "priv/output"))
    File.mkdir_p!(Path.join(source, "priv/discoveries/describe"))
    File.write!(Path.join(source, "priv/ccxt_bundle.js"), "// fake bundle")
    File.write!(Path.join(source, "priv/output/binance.json"), ~s({"id":"binance"}))
    File.write!(Path.join(source, "priv/discoveries/exchanges.json"), "[]")
    File.write!(Path.join(source, "priv/discoveries/describe/binance.json"), "{}")
    # Tracked file present in both source and worktree — must be left alone.
    File.write!(Path.join(source, "priv/discoveries/class_hierarchy.json"), "{}")

    File.mkdir_p!(Path.join(target, "priv/discoveries"))
    # Tracked file already present in worktree (mirrors real worktree state).
    File.write!(Path.join(target, "priv/discoveries/class_hierarchy.json"), ~s({"real":true}))

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, source: source, target: target}
  end

  describe "link_corpus" do
    test "symlinks gitignored corpus into target", %{source: source, target: target} do
      File.cd!(target, fn -> LinkCorpus.run(["--from", source]) end)

      for rel <- ["priv/ccxt_bundle.js", "priv/output", "priv/discoveries/exchanges.json", "priv/discoveries/describe"] do
        target_path = Path.join(target, rel)
        assert {:ok, %{type: :symlink}} = File.lstat(target_path)
        assert {:ok, link_target} = File.read_link(target_path)
        assert link_target == Path.join(source, rel)
      end
    end

    test "leaves committed class_hierarchy.json untouched", %{source: source, target: target} do
      File.cd!(target, fn -> LinkCorpus.run(["--from", source]) end)

      ch_path = Path.join(target, "priv/discoveries/class_hierarchy.json")
      assert {:ok, %{type: :regular}} = File.lstat(ch_path)
      assert File.read!(ch_path) == ~s({"real":true})
    end

    test "skips entries that already exist as regular files", %{source: source, target: target} do
      conflict = Path.join(target, "priv/ccxt_bundle.js")
      File.mkdir_p!(Path.dirname(conflict))
      File.write!(conflict, "// pre-existing")

      File.cd!(target, fn -> LinkCorpus.run(["--from", source]) end)

      assert {:ok, %{type: :regular}} = File.lstat(conflict)
      assert File.read!(conflict) == "// pre-existing"
    end

    test "refreshes existing symlinks instead of skipping", %{source: source, target: target} do
      stale_target = Path.join(target, "priv/output")
      File.mkdir_p!(Path.dirname(stale_target))
      File.ln_s!("/nonexistent/stale", stale_target)

      File.cd!(target, fn -> LinkCorpus.run(["--from", source]) end)

      assert {:ok, link_target} = File.read_link(stale_target)
      assert link_target == Path.join(source, "priv/output")
    end

    test "raises when source == target", %{source: source} do
      assert_raise Mix.Error, ~r/Refusing to link a checkout to itself/, fn ->
        File.cd!(source, fn -> LinkCorpus.run(["--from", source]) end)
      end
    end

    test "raises when source priv/ does not exist", %{target: target} do
      missing = Path.join(System.tmp_dir!(), "definitely_not_a_checkout_#{System.unique_integer([:positive])}")

      assert_raise Mix.Error, ~r/Source priv\/ directory does not exist/, fn ->
        File.cd!(target, fn -> LinkCorpus.run(["--from", missing]) end)
      end
    end
  end

  describe "unlink_corpus" do
    test "removes only symlinks, never regular files", %{source: source, target: target} do
      File.cd!(target, fn -> LinkCorpus.run(["--from", source]) end)
      File.cd!(target, fn -> UnlinkCorpus.run([]) end)

      for rel <- ["priv/ccxt_bundle.js", "priv/output", "priv/discoveries/exchanges.json"] do
        refute File.exists?(Path.join(target, rel)), "expected #{rel} to be removed"
      end

      ch_path = Path.join(target, "priv/discoveries/class_hierarchy.json")
      assert {:ok, %{type: :regular}} = File.lstat(ch_path)
    end

    test "no-op when nothing is linked", %{target: target} do
      File.cd!(target, fn -> UnlinkCorpus.run([]) end)

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Removed 0 symlink"
    end
  end
end
