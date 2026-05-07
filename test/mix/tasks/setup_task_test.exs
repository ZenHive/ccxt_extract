defmodule Mix.Tasks.CcxtExtract.SetupTest do
  @moduledoc """
  Coverage for the auto-clone path in `Mix.Tasks.CcxtExtract.Setup` (Task 115).

  The full Setup task touches npm + QuickBEAM + OXC and is too heavy to drive
  in unit tests. These tests target the standalone helpers and the
  `check_ts_source/1` entry-point — auto-clone happy path, opt-out via flag
  and env var, version-pin file resolution, and clone-args shape.

  The auto-clone happy path uses a local file:// "remote" — a real git repo
  in a tmp dir with a `v<version>` tag and `ts/src/binance.ts` in the tree —
  injected via `:ccxt_repo_url` Application env. No network, no GitHub.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.CcxtExtract.Setup

  @env_var "CCXT_EXTRACT_SKIP_CLONE"

  setup do
    prior_priv_dir = Application.get_env(:ccxt_extract, :priv_dir_override)
    prior_repo_url = Application.get_env(:ccxt_extract, :ccxt_repo_url)
    prior_env = System.get_env(@env_var)

    on_exit(fn ->
      restore_app_env(:priv_dir_override, prior_priv_dir)
      restore_app_env(:ccxt_repo_url, prior_repo_url)

      case prior_env do
        nil -> System.delete_env(@env_var)
        val -> System.put_env(@env_var, val)
      end
    end)

    :ok
  end

  describe "build_clone_args/3" do
    test "no version pin clones default branch via sparse" do
      assert Setup.build_clone_args("https://example.com/ccxt.git", "/tmp/dir", nil) ==
               ["clone", "--depth", "1", "--sparse", "https://example.com/ccxt.git", "/tmp/dir"]
    end

    test "version pin uses --branch v<version>" do
      assert Setup.build_clone_args("https://example.com/ccxt.git", "/tmp/dir", "4.5.48") ==
               [
                 "clone",
                 "--depth",
                 "1",
                 "--branch",
                 "v4.5.48",
                 "--sparse",
                 "https://example.com/ccxt.git",
                 "/tmp/dir"
               ]
    end
  end

  describe "read_pinned_version/1" do
    test "returns source_version when present" do
      path = write_tmp_version_file(%{"source_version" => "4.5.48", "npm_version" => "4.5.50"})
      assert Setup.read_pinned_version(path) == "4.5.48"
    end

    test "falls back to npm_version when source_version missing" do
      path = write_tmp_version_file(%{"npm_version" => "4.5.50"})
      assert Setup.read_pinned_version(path) == "4.5.50"
    end

    test "returns nil when file missing" do
      assert Setup.read_pinned_version(Path.join(System.tmp_dir!(), "nope_#{System.unique_integer([:positive])}.json")) ==
               nil
    end

    test "returns nil for malformed JSON" do
      path = Path.join(System.tmp_dir!(), "bad_#{System.unique_integer([:positive])}.json")
      File.write!(path, "not json")
      on_exit(fn -> File.rm(path) end)

      assert Setup.read_pinned_version(path) == nil
    end
  end

  describe "opt_out_auto_clone?/1" do
    test "honors --no-clone flag" do
      assert Setup.opt_out_auto_clone?(no_clone: true)
      refute Setup.opt_out_auto_clone?([])
    end

    test "honors CCXT_EXTRACT_SKIP_CLONE=1" do
      System.put_env(@env_var, "1")
      assert Setup.opt_out_auto_clone?([])
    end

    test "honors CCXT_EXTRACT_SKIP_CLONE=true" do
      System.put_env(@env_var, "true")
      assert Setup.opt_out_auto_clone?([])
    end

    test "ignores other env values" do
      System.put_env(@env_var, "0")
      refute Setup.opt_out_auto_clone?([])

      System.put_env(@env_var, "")
      refute Setup.opt_out_auto_clone?([])
    end
  end

  describe "check_ts_source/1 — opt-out paths" do
    test "raises legacy missing-source message when --no-clone and source absent" do
      workspace = setup_empty_workspace()

      err =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Setup.check_ts_source(no_clone: true) end)
        end

      assert err.message =~ "CCXT TypeScript source not found"
      assert err.message =~ "Auto-clone is disabled"
      refute File.exists?(Path.join(workspace, "ccxt"))
    end

    test "raises legacy missing-source message when CCXT_EXTRACT_SKIP_CLONE=1" do
      workspace = setup_empty_workspace()
      System.put_env(@env_var, "1")

      err =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Setup.check_ts_source([]) end)
        end

      assert err.message =~ "CCXT TypeScript source not found"
      refute File.exists?(Path.join(workspace, "ccxt"))
    end

    test "no-ops when ts_check_file already present" do
      workspace = setup_empty_workspace()
      ts_dir = Path.join(workspace, "ccxt/ts/src")
      File.mkdir_p!(ts_dir)
      File.write!(Path.join(ts_dir, "binance.ts"), "// preexisting")

      output = capture_io(fn -> Setup.check_ts_source([]) end)

      assert output =~ "CCXT TypeScript source available"
    end
  end

  describe "check_ts_source/1 — auto-clone happy path" do
    @describetag :tmp_dir

    test "clones from a local fake remote pinned to the recorded version" do
      workspace = setup_empty_workspace()
      remote = build_fake_ccxt_remote("4.5.48")

      File.write!(
        Path.join(workspace, "ccxt_version.json"),
        Jason.encode!(%{
          "npm_version" => "4.5.48",
          "source_version" => "4.5.48",
          "source_git_sha" => "deadbeef",
          "recorded_at" => "2026-04-24T00:00:00Z"
        })
      )

      Application.put_env(:ccxt_extract, :ccxt_repo_url, remote)

      output = capture_io(fn -> Setup.check_ts_source([]) end)

      assert output =~ "auto-cloning"
      assert output =~ "v4.5.48"
      assert output =~ "CCXT TypeScript source cloned"

      cloned_binance = Path.join(workspace, "ccxt/ts/src/binance.ts")
      assert File.exists?(cloned_binance)

      head_tag = head_tag(Path.join(workspace, "ccxt"))
      assert head_tag == "v4.5.48"
    end

    test "respects --ccxt-version flag over recorded version" do
      workspace = setup_empty_workspace()
      remote = build_fake_ccxt_remote(["4.5.48", "4.5.50"])

      File.write!(
        Path.join(workspace, "ccxt_version.json"),
        Jason.encode!(%{"source_version" => "4.5.48"})
      )

      Application.put_env(:ccxt_extract, :ccxt_repo_url, remote)

      output =
        capture_io(fn -> Setup.check_ts_source(ccxt_version: "4.5.50") end)

      assert output =~ "v4.5.50"
      assert head_tag(Path.join(workspace, "ccxt")) == "v4.5.50"
    end

    test "falls back to default branch when no version pin available" do
      workspace = setup_empty_workspace()
      remote = build_fake_ccxt_remote(:no_tags)

      Application.put_env(:ccxt_extract, :ccxt_repo_url, remote)

      output = capture_io(fn -> Setup.check_ts_source([]) end)

      assert output =~ "default branch"
      assert File.exists?(Path.join(workspace, "ccxt/ts/src/binance.ts"))
    end

    test "raises when the clone command itself fails" do
      workspace = setup_empty_workspace()
      Application.put_env(:ccxt_extract, :ccxt_repo_url, "/no/such/path/ccxt-fake.git")

      err =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Setup.check_ts_source(no_clone: false) end)
        end

      assert err.message =~ "Failed to auto-clone CCXT"
      refute File.exists?(Path.join(workspace, "ccxt/ts/src/binance.ts"))
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp setup_empty_workspace do
    workspace =
      Path.join(System.tmp_dir!(), "ccxt_extract_setup_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    Application.put_env(:ccxt_extract, :priv_dir_override, workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    workspace
  end

  defp build_fake_ccxt_remote(versions_or_flag) do
    remote =
      Path.join(
        System.tmp_dir!(),
        "ccxt_fake_remote_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(remote)
    on_exit(fn -> File.rm_rf!(remote) end)

    # `git init --initial-branch=main` needs git ≥ 2.28; the two-step form
    # (init + symbolic-ref) is portable to older git installs.
    git!(["init"], remote)
    git!(["symbolic-ref", "HEAD", "refs/heads/main"], remote)
    git!(["config", "user.email", "test@example.com"], remote)
    git!(["config", "user.name", "Test"], remote)
    git!(["config", "commit.gpgsign", "false"], remote)

    File.mkdir_p!(Path.join(remote, "ts/src"))
    File.write!(Path.join(remote, "ts/src/binance.ts"), "// fake binance.ts\n")
    File.write!(Path.join(remote, "ts/src/kraken.ts"), "// fake kraken.ts\n")
    File.write!(Path.join(remote, "package.json"), ~s|{"name":"ccxt","version":"0.0.0"}\n|)
    File.write!(Path.join(remote, "README.md"), "# fake ccxt\n")

    git!(["add", "."], remote)
    git!(["commit", "-m", "initial"], remote)

    case versions_or_flag do
      :no_tags ->
        :ok

      versions when is_list(versions) ->
        # Each tag gets a distinct commit so head_tag/1 can disambiguate.
        Enum.each(versions, fn v ->
          File.write!(Path.join(remote, "package.json"), ~s|{"name":"ccxt","version":"#{v}"}\n|)
          git!(["add", "package.json"], remote)
          git!(["commit", "-m", "release v#{v}"], remote)
          git!(["tag", "v#{v}"], remote)
        end)

      version when is_binary(version) ->
        git!(["tag", "v#{version}"], remote)
    end

    # `git clone --branch <tag>` over a local non-bare worktree needs the
    # remote-side worktree to NOT be the currently-checked-out branch on
    # plain `git clone`, but `--branch <tag>` is fine. Either way, configure
    # uploadpack to allow shallow clone of an unreachable tag.
    git!(["config", "uploadpack.allowFilter", "true"], remote)

    remote
  end

  defp git!(args, cwd) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (exit #{code}) in #{cwd}: #{out}")
    end
  end

  defp head_tag(repo) do
    case System.cmd("git", ["describe", "--tags", "--exact-match", "HEAD"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {tag, 0} -> String.trim(tag)
      _ -> nil
    end
  end

  defp write_tmp_version_file(payload) do
    path =
      Path.join(System.tmp_dir!(), "ccxt_version_test_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(payload))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:ccxt_extract, key)
  defp restore_app_env(key, val), do: Application.put_env(:ccxt_extract, key, val)
end
