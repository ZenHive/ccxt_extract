defmodule CcxtExtract.PathsTest do
  # async: false — priv_dir/1 tests mutate :priv_dir_override application env.
  use ExUnit.Case, async: false

  alias CcxtExtract.Paths

  describe "priv_dir/0" do
    test "returns an absolute path" do
      assert String.starts_with?(Paths.priv_dir(), "/")
    end
  end

  describe "priv/1" do
    test "joins relative path to priv dir" do
      result = Paths.priv("some/file.json")
      assert String.ends_with?(result, "priv/some/file.json")
    end
  end

  describe "bundle/0" do
    test "returns path ending in ccxt_bundle.js" do
      assert String.ends_with?(Paths.bundle(), "ccxt_bundle.js")
    end
  end

  describe "ts_src/0" do
    test "returns path ending in ccxt/ts/src" do
      assert String.ends_with?(Paths.ts_src(), "ccxt/ts/src")
    end
  end

  describe "version_file/0" do
    test "returns path ending in ccxt_version.json" do
      assert String.ends_with?(Paths.version_file(), "ccxt_version.json")
    end
  end

  describe "discoveries/0" do
    test "returns path ending in discoveries" do
      assert String.ends_with?(Paths.discoveries(), "discoveries")
    end
  end

  describe ":priv_dir_override" do
    setup do
      on_exit(fn -> Application.delete_env(:ccxt_extract, :priv_dir_override) end)
      :ok
    end

    test "priv_dir/0 returns the override when set" do
      Application.put_env(:ccxt_extract, :priv_dir_override, "/tmp/fake_priv")
      assert Paths.priv_dir() == "/tmp/fake_priv"
    end

    test "all accessors follow the override" do
      Application.put_env(:ccxt_extract, :priv_dir_override, "/tmp/fake_priv")
      assert Paths.priv("some/file.json") == "/tmp/fake_priv/some/file.json"
      assert Paths.bundle() == "/tmp/fake_priv/ccxt_bundle.js"
      assert Paths.ts_src() == "/tmp/fake_priv/ccxt/ts/src"
      assert Paths.version_file() == "/tmp/fake_priv/ccxt_version.json"
      assert Paths.discoveries() == "/tmp/fake_priv/discoveries"
    end
  end
end
