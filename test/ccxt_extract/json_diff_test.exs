defmodule CcxtExtract.JsonDiffTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.JsonDiff

  doctest JsonDiff

  describe "strip_volatile/2" do
    test "drops keys at top level" do
      assert JsonDiff.strip_volatile(%{"a" => 1, "extracted_at" => "now"}, ["extracted_at"]) ==
               %{"a" => 1}
    end

    test "drops keys at every nested depth" do
      input = %{
        "outer" => %{
          "generated_at" => "ts",
          "inner" => %{"generated_at" => "ts2", "kept" => true}
        }
      }

      assert JsonDiff.strip_volatile(input, ["generated_at"]) ==
               %{"outer" => %{"inner" => %{"kept" => true}}}
    end

    test "walks list elements" do
      input = [
        %{"generated_at" => 1, "v" => 1},
        %{"generated_at" => 2, "v" => 2}
      ]

      assert JsonDiff.strip_volatile(input, ["generated_at"]) ==
               [%{"v" => 1}, %{"v" => 2}]
    end

    test "passes scalars through" do
      assert JsonDiff.strip_volatile(42, ["x"]) == 42
      assert JsonDiff.strip_volatile("string", ["x"]) == "string"
      assert JsonDiff.strip_volatile(nil, ["x"]) == nil
    end

    test "default key set covers known timestamp fields" do
      keys = JsonDiff.default_volatile_keys()
      assert "extracted_at" in keys
      assert "generated_at" in keys
      assert "checked_at" in keys
      assert "validated_at" in keys
      assert "recorded_at" in keys
    end
  end

  describe "canonical_encode/1" do
    test "sorts map keys at top level" do
      a = JsonDiff.canonical_encode(%{"b" => 1, "a" => 2})
      b = JsonDiff.canonical_encode(%{"a" => 2, "b" => 1})
      assert a == b
      assert a == ~s({"a":2,"b":1})
    end

    test "sorts keys recursively at every depth" do
      a = JsonDiff.canonical_encode(%{"outer" => %{"b" => 1, "a" => 2}})
      b = JsonDiff.canonical_encode(%{"outer" => %{"a" => 2, "b" => 1}})
      assert a == b
    end

    test "preserves list element order" do
      assert JsonDiff.canonical_encode([3, 1, 2]) == "[3,1,2]"
    end

    test "atom keys coerce to strings" do
      assert JsonDiff.canonical_encode(%{a: 1, b: 2}) == ~s({"a":1,"b":2})
    end
  end

  describe "diff_terms/3" do
    test "two semantically-equal maps with different insertion order are :equal" do
      a = %{"b" => 1, "a" => 2}
      b = %{"a" => 2, "b" => 1}
      assert JsonDiff.diff_terms(a, b) == :equal
    end

    test "differing scalar values surface a byte diff" do
      assert {:diff, %{byte: pos}} = JsonDiff.diff_terms(%{"a" => 1}, %{"a" => 2})
      assert is_integer(pos)
    end

    test "volatile keys are ignored" do
      a = %{"v" => 1, "extracted_at" => "2026-01-01"}
      b = %{"v" => 1, "extracted_at" => "2026-12-31"}
      assert JsonDiff.diff_terms(a, b) == :equal
    end

    test "custom strip_keys overrides default set" do
      a = %{"v" => 1, "extracted_at" => "ts1", "custom" => "x"}
      b = %{"v" => 1, "extracted_at" => "ts2", "custom" => "y"}

      assert {:diff, _} = JsonDiff.diff_terms(a, b, strip_keys: ["custom"])
      assert JsonDiff.diff_terms(a, b, strip_keys: ["extracted_at", "custom"]) == :equal
    end
  end

  describe "diff_files/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "json_diff_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "equal files (despite key-order difference) are :equal", %{dir: dir} do
      a = Path.join(dir, "a.json")
      b = Path.join(dir, "b.json")
      File.write!(a, ~s({"y": 2, "x": 1}))
      File.write!(b, ~s({"x": 1, "y": 2}))
      assert JsonDiff.diff_files(a, b) == :equal
    end

    test "differing files surface position + context", %{dir: dir} do
      a = Path.join(dir, "a.json")
      b = Path.join(dir, "b.json")
      File.write!(a, ~s({"v": 1}))
      File.write!(b, ~s({"v": 2}))
      assert {:diff, %{byte: _, a_context: ca, b_context: cb}} = JsonDiff.diff_files(a, b)
      assert is_binary(ca) and is_binary(cb)
    end

    test "missing file surfaces a {:read, path, reason} error", %{dir: dir} do
      a = Path.join(dir, "a.json")
      File.write!(a, ~s({"v": 1}))
      assert {:error, {:read, _, _}} = JsonDiff.diff_files(a, Path.join(dir, "nope.json"))
    end

    test "invalid JSON surfaces a {:decode, path, reason} error", %{dir: dir} do
      a = Path.join(dir, "a.json")
      b = Path.join(dir, "b.json")
      File.write!(a, ~s({"v": 1}))
      File.write!(b, "not json")
      assert {:error, {:decode, _, _}} = JsonDiff.diff_files(a, b)
    end

    test "volatile key strip applied at every depth", %{dir: dir} do
      a = Path.join(dir, "a.json")
      b = Path.join(dir, "b.json")

      File.write!(a, ~s({"outer": {"v": 1, "generated_at": "t1"}, "extracted_at": "t1"}))
      File.write!(b, ~s({"outer": {"v": 1, "generated_at": "t2"}, "extracted_at": "t2"}))

      assert JsonDiff.diff_files(a, b) == :equal
    end
  end
end
