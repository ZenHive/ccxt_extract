defmodule CcxtExtract.JsonIOTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.JsonIO

  describe "read_json/1" do
    @tag :tmp_dir
    test "returns {:ok, decoded} for valid JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "valid.json")
      File.write!(path, ~s({"hello": "world"}))
      assert {:ok, %{"hello" => "world"}} = JsonIO.read_json(path)
    end

    @tag :tmp_dir
    test "returns {:error, {:missing_input, path}} with bare path for missing file",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.json")
      assert {:error, {:missing_input, ^path}} = JsonIO.read_json(path)
    end

    @tag :tmp_dir
    test "returns {:error, {:missing_input, path}} for other read errors (eisdir)",
         %{tmp_dir: tmp_dir} do
      # Reading a directory as a file — File.read returns {:error, :eisdir}.
      assert {:error, {:missing_input, ^tmp_dir}} = JsonIO.read_json(tmp_dir)
    end

    @tag :tmp_dir
    test "returns {:error, {:invalid_json, _}} for malformed JSON",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.json")
      File.write!(path, "{not json")
      assert {:error, {:invalid_json, detail}} = JsonIO.read_json(path)
      assert detail =~ "bad.json"
    end
  end

  describe "read_json!/1" do
    @tag :tmp_dir
    test "returns decoded term for valid JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "valid.json")
      File.write!(path, ~s({"hello": "world"}))
      assert %{"hello" => "world"} = JsonIO.read_json!(path)
    end

    @tag :tmp_dir
    test "raises File.Error for missing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.json")
      assert_raise File.Error, fn -> JsonIO.read_json!(path) end
    end

    @tag :tmp_dir
    test "raises Jason.DecodeError for malformed JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.json")
      File.write!(path, "{not json")
      assert_raise Jason.DecodeError, fn -> JsonIO.read_json!(path) end
    end
  end

  describe "write_json!/2" do
    @tag :tmp_dir
    test "normalizes map keys before writing deterministic JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "out.json")

      assert :ok = JsonIO.write_json!(path, %{b: 2, a: 1})

      assert File.read!(path) == ~s({"a":1,"b":2})
    end

    @tag :tmp_dir
    test "passes Jason encoding options through", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "pretty.json")

      assert :ok = JsonIO.write_json!(path, %{b: 2, a: 1}, pretty: true)

      assert File.read!(path) == ~s({\n  "a": 1,\n  "b": 2\n})
    end
  end
end
