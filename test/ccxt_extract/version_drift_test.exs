defmodule CcxtExtract.VersionDriftTest do
  @moduledoc """
  Unit tests for `Pipeline.check_version_drift!/1` and
  `Pipeline.bundle_sha256/1` — the Task 114 / Phase 5 guard that turns
  silent CCXT version drift into a loud failure at pipeline entry.

  `async: false`: every test drives the guard by pointing
  `:priv_dir_override` at a synthetic tmp `priv/` so the version file,
  `priv/ccxt`, and `priv/ccxt_bundle.js` are all controllable. The
  override is VM-global app env.
  """
  use ExUnit.Case, async: false

  alias CcxtExtract.Pipeline

  # sha256("abc") — FIPS 180-2 test vector.
  @abc_sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  setup do
    tmp = Path.join(System.tmp_dir!(), "ccxt_drift_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prior = Application.get_env(:ccxt_extract, :priv_dir_override)
    Application.put_env(:ccxt_extract, :priv_dir_override, tmp)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:ccxt_extract, :priv_dir_override)
        val -> Application.put_env(:ccxt_extract, :priv_dir_override, val)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "check_version_drift!/1 — bypass" do
    test "allow_version_drift: true returns :ok without reading anything", %{tmp: tmp} do
      # A malformed version file would normally raise; the bypass never
      # even reads it.
      File.write!(Path.join(tmp, "ccxt_version.json"), "{ not json")

      assert :ok = Pipeline.check_version_drift!(allow_version_drift: true)
    end
  end

  describe "check_version_drift!/1 — version file presence" do
    test "missing version file is a skip, not a failure" do
      # No ccxt_version.json in the tmp priv/ — there is no recorded
      # baseline to drift from.
      assert :ok = Pipeline.check_version_drift!([])
    end

    test "malformed JSON raises", %{tmp: tmp} do
      File.write!(Path.join(tmp, "ccxt_version.json"), "{ broken")

      assert_raise RuntimeError, ~r/Malformed priv\/ccxt_version\.json/, fn ->
        Pipeline.check_version_drift!([])
      end
    end

    test "well-formed JSON that is not an object raises", %{tmp: tmp} do
      File.write!(Path.join(tmp, "ccxt_version.json"), "42")

      assert_raise RuntimeError, ~r/expected a JSON object/, fn ->
        Pipeline.check_version_drift!([])
      end
    end
  end

  describe "check_version_drift!/1 — git SHA drift" do
    test "matching source_git_sha passes", %{tmp: tmp} do
      head = init_ccxt_git!(tmp)
      write_version_file!(tmp, %{"source_git_sha" => head})

      assert :ok = Pipeline.check_version_drift!([])
    end

    test "mismatched source_git_sha raises with a resync hint", %{tmp: tmp} do
      init_ccxt_git!(tmp)
      write_version_file!(tmp, %{"source_git_sha" => String.duplicate("a", 40)})

      assert_raise RuntimeError, ~r/CCXT source drift detected/, fn ->
        Pipeline.check_version_drift!([])
      end
    end

    test ~s(source_git_sha "unknown" is skipped even with a git repo present), %{tmp: tmp} do
      init_ccxt_git!(tmp)
      write_version_file!(tmp, %{"source_git_sha" => "unknown"})

      assert :ok = Pipeline.check_version_drift!([])
    end

    test "no .git under priv/ccxt is skipped", %{tmp: tmp} do
      # priv/ccxt exists but is not a git repo (symlinked corpus,
      # sparse checkout without .git) — HEAD is un-readable, not drifted.
      File.mkdir_p!(Path.join(tmp, "ccxt"))
      write_version_file!(tmp, %{"source_git_sha" => String.duplicate("a", 40)})

      assert :ok = Pipeline.check_version_drift!([])
    end
  end

  describe "check_version_drift!/1 — bundle hash drift" do
    test "matching bundle_sha256 passes", %{tmp: tmp} do
      bundle_path = write_bundle!(tmp, "console.log('ccxt')")
      write_version_file!(tmp, %{"bundle_sha256" => Pipeline.bundle_sha256(bundle_path)})

      assert :ok = Pipeline.check_version_drift!([])
    end

    test "mismatched bundle_sha256 raises", %{tmp: tmp} do
      write_bundle!(tmp, "console.log('ccxt')")
      write_version_file!(tmp, %{"bundle_sha256" => @abc_sha256})

      assert_raise RuntimeError, ~r/CCXT bundle drift detected/, fn ->
        Pipeline.check_version_drift!([])
      end
    end

    test "bundle_sha256 recorded but bundle file missing raises", %{tmp: tmp} do
      write_version_file!(tmp, %{"bundle_sha256" => @abc_sha256})

      assert_raise RuntimeError, ~r/bundle_sha256 but/, fn ->
        Pipeline.check_version_drift!([])
      end
    end

    test "absent bundle_sha256 is skipped — no bundle file needed", %{tmp: tmp} do
      write_version_file!(tmp, %{"npm_version" => "4.5.48"})

      assert :ok = Pipeline.check_version_drift!([])
    end
  end

  describe "bundle_sha256/1" do
    test "computes the lowercase-hex sha256 of file contents", %{tmp: tmp} do
      path = write_bundle!(tmp, "abc")

      assert Pipeline.bundle_sha256(path) == @abc_sha256
    end
  end

  defp write_version_file!(tmp, payload) do
    File.write!(Path.join(tmp, "ccxt_version.json"), Jason.encode!(payload))
  end

  defp write_bundle!(tmp, content) do
    path = Path.join(tmp, "ccxt_bundle.js")
    File.write!(path, content)
    path
  end

  # Initialises priv/ccxt as a real git repo with one empty commit and
  # returns its HEAD sha. Identity is passed via `-c` so the test does
  # not depend on the host's global git config.
  defp init_ccxt_git!(tmp) do
    dir = Path.join(tmp, "ccxt")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])

    git!(dir, [
      "-c",
      "user.email=test@example.com",
      "-c",
      "user.name=Test",
      "commit",
      "--allow-empty",
      "-q",
      "-m",
      "init"
    ])

    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir, stderr_to_stdout: true)
    String.trim(sha)
  end

  defp git!(dir, args) do
    {_output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    :ok
  end
end
