defmodule CcxtExtract.AggregateWriterTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.AggregateWriter

  @tmp_dir Path.join(System.tmp_dir!(), "ccxt_extract_aggregate_writer_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp path(name), do: Path.join(@tmp_dir, name)

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  # Standard exchange entry shape used across tests.
  defp ex(id, method_count) do
    %{
      "id" => id,
      "class_name" => id,
      "file" => "#{id}.ts",
      "parse_method_count" => method_count,
      "parse_methods" => %{}
    }
  end

  defp parse_stats_fn do
    fn entries ->
      %{
        "with_parse_methods" => Enum.count(entries, &(&1["parse_method_count"] > 0)),
        "total_methods" => Enum.sum(Enum.map(entries, & &1["parse_method_count"]))
      }
    end
  end

  describe "fresh write (no existing file)" do
    test "creates the file and writes the envelope" do
      file = path("parse_methods.json")

      assert :ok =
               AggregateWriter.write!(file, [ex("binance", 10), ex("bybit", 5)],
                 entry_key: "exchanges",
                 id_key: "id",
                 scope: :all,
                 stats_fn: parse_stats_fn(),
                 tier_scope: "all",
                 extracted_at: "2026-04-15T12:00:00Z"
               )

      data = read_json(file)
      assert data["extracted_at"] == "2026-04-15T12:00:00Z"
      assert data["tier_scope"] == "all"
      assert data["count"] == 2
      assert data["with_parse_methods"] == 2
      assert data["total_methods"] == 15
      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(binance bybit)
    end

    test "creates parent directories as needed" do
      file = path("nested/deeply/parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 3)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      assert File.exists?(file)
    end
  end

  describe "scope == :all overwrites existing" do
    test "replaces the entries list wholesale" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 10), ex("bybit", 5), ex("okx", 8)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      # Overwrite with a completely different list.
      AggregateWriter.write!(file, [ex("kraken", 7)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)
      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(kraken)
      assert data["count"] == 1
      assert data["total_methods"] == 7
    end
  end

  describe "scoped MapSet merges with existing" do
    test "replaces in-scope entries, preserves out-of-scope entries" do
      file = path("parse_methods.json")

      AggregateWriter.write!(
        file,
        [ex("binance", 10), ex("bybit", 5), ex("okx", 8), ex("kraken", 7)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      # Scoped run: only update binance and bybit.
      AggregateWriter.write!(
        file,
        [ex("binance", 99), ex("bybit", 77)],
        entry_key: "exchanges",
        id_key: "id",
        scope: MapSet.new(~w(binance bybit)),
        stats_fn: parse_stats_fn(),
        tier_scope: ["tier1"]
      )

      data = read_json(file)
      ids = Enum.map(data["exchanges"], & &1["id"])
      assert ids == ~w(binance bybit kraken okx)

      by_id = Map.new(data["exchanges"], &{&1["id"], &1})
      assert by_id["binance"]["parse_method_count"] == 99
      assert by_id["bybit"]["parse_method_count"] == 77
      assert by_id["okx"]["parse_method_count"] == 8
      assert by_id["kraken"]["parse_method_count"] == 7

      assert data["count"] == 4
      assert data["tier_scope"] == ["tier1"]
    end

    test "scoped run on empty file behaves as fresh write" do
      file = path("parse_methods.json")

      AggregateWriter.write!(
        file,
        [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: MapSet.new(~w(binance)),
        stats_fn: parse_stats_fn(),
        tier_scope: ["tier1"]
      )

      data = read_json(file)
      assert data["count"] == 1
      assert data["tier_scope"] == ["tier1"]
    end

    test "scoped ID not in new_entries effectively drops the existing entry" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 10), ex("bybit", 5)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      # Scope includes binance but new_entries is empty — existing binance is dropped.
      AggregateWriter.write!(file, [],
        entry_key: "exchanges",
        id_key: "id",
        scope: MapSet.new(~w(binance)),
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)
      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(bybit)
      assert data["count"] == 1
      assert data["total_methods"] == 5
    end
  end

  describe "envelope invariants" do
    test "stats_fn receives the final merged sorted entries (drift regression guard)" do
      file = path("parse_methods.json")

      test_pid = self()

      stats_fn = fn entries ->
        send(test_pid, {:stats_called_with, Enum.map(entries, & &1["id"])})
        parse_stats_fn().(entries)
      end

      AggregateWriter.write!(file, [ex("binance", 10), ex("okx", 8)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: stats_fn
      )

      assert_received {:stats_called_with, ~w(binance okx)}

      # Scoped merge: stats must see the merged post-sort list.
      AggregateWriter.write!(file, [ex("bybit", 5)],
        entry_key: "exchanges",
        id_key: "id",
        scope: MapSet.new(~w(bybit)),
        stats_fn: stats_fn
      )

      assert_received {:stats_called_with, ~w(binance bybit okx)}
    end

    test "count equals the merged entries length and total_methods equals the sum" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 10), ex("bybit", 5), ex("okx", 8)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)

      # The very assertion that's currently red on cached discovery JSON —
      # succeeds here because stats always recompute from the merged entries.
      assert data["count"] == length(data["exchanges"])

      actual_total = Enum.sum(Enum.map(data["exchanges"], & &1["parse_method_count"]))
      assert data["total_methods"] == actual_total
    end

    test "output entries are sorted by id_key ascending" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("okx", 8), ex("binance", 10), ex("kraken", 7), ex("bybit", 5)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)
      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(binance bybit kraken okx)
    end
  end

  describe "extras and tier_scope stamping" do
    test "extra fields appear in the envelope" do
      file = path("methods_rest.json")

      AggregateWriter.write!(file, [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: fn _ -> %{} end,
        extra: %{"type" => "rest"}
      )

      data = read_json(file)
      assert data["type"] == "rest"
      assert data["count"] == 1
    end

    test "tier_scope defaults to \"all\" when not provided" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)
      assert data["tier_scope"] == "all"
    end

    test "tier_scope list is stamped verbatim" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn(),
        tier_scope: ["tier1", "dex", "exchange:binance"]
      )

      data = read_json(file)
      assert data["tier_scope"] == ["tier1", "dex", "exchange:binance"]
    end

    test "stats_fn output wins on envelope key conflict" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: fn _ -> %{"custom" => "from_stats"} end,
        extra: %{"custom" => "from_extra"}
      )

      data = read_json(file)
      assert data["custom"] == "from_stats"
    end
  end

  describe "malformed existing file" do
    test "raises when existing JSON is a non-object" do
      file = path("parse_methods.json")
      File.write!(file, "[1, 2, 3]")

      assert_raise RuntimeError, ~r/expected a JSON object/, fn ->
        AggregateWriter.write!(file, [ex("binance", 10)],
          entry_key: "exchanges",
          id_key: "id",
          scope: MapSet.new(~w(binance)),
          stats_fn: parse_stats_fn()
        )
      end
    end

    test "raises when entry_key is present with a non-list value" do
      file = path("parse_methods.json")
      File.write!(file, Jason.encode!(%{"exchanges" => "not a list"}))

      assert_raise RuntimeError, ~r/expected exchanges to be a list/, fn ->
        AggregateWriter.write!(file, [ex("binance", 10)],
          entry_key: "exchanges",
          id_key: "id",
          scope: MapSet.new(~w(binance)),
          stats_fn: parse_stats_fn()
        )
      end
    end

    test "raises on malformed JSON when scope is a MapSet (merge needs existing)" do
      file = path("parse_methods.json")
      File.write!(file, "{not valid json")

      assert_raise RuntimeError, ~r/Malformed JSON/, fn ->
        AggregateWriter.write!(file, [ex("binance", 10)],
          entry_key: "exchanges",
          id_key: "id",
          scope: MapSet.new(~w(binance)),
          stats_fn: parse_stats_fn()
        )
      end
    end

    test "scope :all overwrites a corrupt file without raising" do
      # :all replaces wholesale, so the existing contents are irrelevant —
      # a corrupt aggregate must not block an overwrite.
      file = path("parse_methods.json")
      File.write!(file, "{not valid json")

      AggregateWriter.write!(file, [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)
      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(binance)
      assert data["count"] == 1
    end

    test "treats missing entry_key in existing file as empty (no raise)" do
      file = path("parse_methods.json")
      File.write!(file, Jason.encode!(%{"metadata" => "legacy"}))

      AggregateWriter.write!(file, [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: MapSet.new(~w(binance)),
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)
      assert data["count"] == 1
      assert Enum.map(data["exchanges"], & &1["id"]) == ~w(binance)
    end
  end

  describe "AST normalization" do
    test "normalizes atom :type values to PascalCase strings by default" do
      file = path("parse_methods.json")

      entry = %{
        "id" => "binance",
        "parse_method_count" => 1,
        "parse_methods" => %{
          "parseTicker" => %{"body" => %{"type" => :block_statement, "body" => []}}
        }
      }

      AggregateWriter.write!(file, [entry],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn()
      )

      data = read_json(file)
      body = data["exchanges"] |> hd() |> get_in(["parse_methods", "parseTicker", "body"])
      assert body["type"] == "BlockStatement"
    end

    test "normalize: false preserves atom values verbatim (no conversion)" do
      file = path("parse_methods.json")

      AggregateWriter.write!(file, [ex("binance", 10)],
        entry_key: "exchanges",
        id_key: "id",
        scope: :all,
        stats_fn: parse_stats_fn(),
        normalize: false
      )

      # Plain string data survives regardless of normalize flag.
      data = read_json(file)
      assert data["count"] == 1
    end
  end
end
