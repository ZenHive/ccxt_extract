defmodule CcxtExtract.PathsTest do
  use ExUnit.Case, async: true

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
end
