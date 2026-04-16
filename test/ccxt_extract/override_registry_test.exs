defmodule CcxtExtract.OverrideRegistryTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.OverrideRegistry

  describe "load/1 — production files" do
    test "every committed override file loads cleanly" do
      for id <- OverrideRegistry.list_exchanges() do
        assert [_ | _] = OverrideRegistry.load(id), "expected non-empty overrides for #{id}"
      end
    end

    test "returns :none for an exchange with no override file" do
      assert OverrideRegistry.load("__does_not_exist__") == :none
    end

    test "every loaded file carries the authenticated_sections entry (Task 60 migration)" do
      for id <- OverrideRegistry.list_exchanges() do
        overrides = OverrideRegistry.load(id)

        assert {:ok, %{"value" => value, "reason" => reason}} =
                 OverrideRegistry.find(overrides, "/structure/authenticated_sections"),
               "#{id}: missing /structure/authenticated_sections entry"

        assert is_list(value), "#{id}: value must be a list"
        assert is_binary(reason) and reason != "", "#{id}: reason must be non-empty string"
      end
    end
  end

  describe "find/2" do
    test "returns {:ok, entry} when path matches" do
      overrides = [%{"path" => "/foo", "value" => 1, "reason" => "x"}]
      assert {:ok, %{"value" => 1}} = OverrideRegistry.find(overrides, "/foo")
    end

    test "returns :none when path missing" do
      overrides = [%{"path" => "/foo", "value" => 1, "reason" => "x"}]
      assert :none == OverrideRegistry.find(overrides, "/bar")
    end
  end

  describe "validation — load_path/1 raises on malformed files" do
    setup do
      dir = Path.join(System.tmp_dir!(), "override_registry_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, tmp_dir: dir}
    end

    test "returns :none when path does not exist", %{tmp_dir: dir} do
      assert :none == OverrideRegistry.load_path(Path.join(dir, "nothing.json"))
    end

    test "rejects missing schema_version", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"overrides": [{"path": "/a", "value": 1, "reason": "r"}]}),
        ~r/missing required top-level keys/
      )
    end

    test "rejects wrong schema_version", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "2", "overrides": []}),
        ~r/expected schema_version "1"/
      )
    end

    test "rejects empty overrides list", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": []}),
        ~r/must be non-empty/
      )
    end

    test "rejects unknown top-level key", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1, "reason": "r"}], "junk": 1}),
        ~r/unknown top-level keys/
      )
    end

    test "rejects missing required entry keys", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1}]}),
        ~r/missing required keys/
      )
    end

    test "rejects unknown entry keys", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1, "reason": "r", "junk": true}]}),
        ~r/unknown keys/
      )
    end

    test "rejects non-pointer path", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": [{"path": "foo", "value": 1, "reason": "r"}]}),
        ~r/JSON Pointer string starting with/
      )
    end

    test "rejects empty reason", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1, "reason": ""}]}),
        ~r/non-empty string/
      )
    end

    test "rejects verified_against + unverified: true combo", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1, "reason": "r", "verified_against": "src:1", "unverified": true}]}),
        ~r/cannot set both/
      )
    end

    test "rejects duplicate paths", %{tmp_dir: dir} do
      assert_load_raise(
        dir,
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1, "reason": "r"}, {"path": "/a", "value": 2, "reason": "r"}]}),
        ~r/duplicate paths/
      )
    end

    test "accepts verified_against without unverified", %{tmp_dir: dir} do
      body =
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1, "reason": "r", "verified_against": "src:1"}]})

      path = write_tmp(dir, body)
      assert [_] = OverrideRegistry.load_path(path)
    end

    test "accepts unverified: true without verified_against", %{tmp_dir: dir} do
      body =
        ~s({"schema_version": "1", "overrides": [{"path": "/a", "value": 1, "reason": "r", "unverified": true}]})

      path = write_tmp(dir, body)
      assert [%{"unverified" => true}] = OverrideRegistry.load_path(path)
    end
  end

  # --- helpers ---

  # Writes a JSON body to a tmp file (cleaned up with the tmp_dir), returns the path.
  defp write_tmp(tmp_dir, body) do
    path = Path.join(tmp_dir, "override_#{:erlang.unique_integer([:positive])}.json")
    File.write!(path, body)
    path
  end

  defp assert_load_raise(tmp_dir, body, pattern) do
    path = write_tmp(tmp_dir, body)
    assert_raise RuntimeError, pattern, fn -> OverrideRegistry.load_path(path) end
  end
end
