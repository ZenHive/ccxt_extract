defmodule CcxtExtract.ScopePruneTest do
  use ExUnit.Case, async: false

  alias CcxtExtract.ScopePrune

  setup do
    tmp = Path.join(System.tmp_dir!(), "ccxt_scope_prune_#{System.unique_integer([:positive])}")
    priv = Path.join(tmp, "priv")
    discoveries = Path.join(priv, "discoveries")
    output = Path.join(priv, "output")
    File.mkdir_p!(discoveries)
    File.mkdir_p!(output)

    prior = Application.get_env(:ccxt_extract, :priv_write_override)
    Application.put_env(:ccxt_extract, :priv_write_override, priv)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:ccxt_extract, :priv_write_override)
        value -> Application.put_env(:ccxt_extract, :priv_write_override, value)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, priv: priv, discoveries: discoveries, output: output}
  end

  describe "run/1" do
    test "dry-run reports removable files without deleting them", %{discoveries: discoveries, output: output} do
      describe_dir = Path.join(discoveries, "describe")
      File.mkdir_p!(describe_dir)
      write_json(Path.join(describe_dir, "binance.json"), %{"id" => "binance"})
      write_json(Path.join(describe_dir, "kraken.json"), %{"id" => "kraken"})
      write_json(Path.join(describe_dir, "_manifest.json"), %{"exchanges" => ["binance", "kraken"]})

      write_json(Path.join(output, "binance.json"), %{"exchange" => %{"id" => "binance"}})
      write_json(Path.join(output, "kraken.json"), %{"exchange" => %{"id" => "kraken"}})
      write_json(Path.join(output, "exchange_v4.json"), %{"title" => "schema"})

      write_json(
        Path.join(discoveries, "parse_methods.json"),
        envelope(["binance", "kraken"], %{"with_parse_methods" => 2, "total_methods" => 2})
      )

      in_scope = MapSet.new(["binance"])

      assert {:ok, result} =
               ScopePrune.run(in_scope: in_scope, tier_scope: ["tier1"], force: false)

      assert result.dry_run
      assert Path.basename(hd(result.removed_files)) == "kraken.json"
      assert File.exists?(Path.join(describe_dir, "kraken.json"))
      assert File.exists?(Path.join(output, "kraken.json"))
      assert "parse_methods.json" in Enum.map(result.updated_envelopes, &Path.basename/1)
    end

    test "--force deletes out-of-scope files and re-syncs manifests and envelopes", %{
      discoveries: discoveries,
      output: output
    } do
      describe_dir = Path.join(discoveries, "describe")
      File.mkdir_p!(describe_dir)
      write_json(Path.join(describe_dir, "binance.json"), %{"id" => "binance"})
      write_json(Path.join(describe_dir, "kraken.json"), %{"id" => "kraken"})

      write_json(Path.join(output, "binance.json"), %{"exchange" => %{"id" => "binance"}})
      write_json(Path.join(output, "kraken.json"), %{"exchange" => %{"id" => "kraken"}})
      write_json(Path.join(output, "exchange_v4.json"), %{"title" => "schema"})

      write_json(
        Path.join(discoveries, "parse_methods.json"),
        envelope(["binance", "kraken"], %{"with_parse_methods" => 2, "total_methods" => 20})
      )

      in_scope = MapSet.new(["binance"])

      assert {:ok, _result} =
               ScopePrune.run(in_scope: in_scope, tier_scope: ["tier1"], force: true)

      refute File.exists?(Path.join(describe_dir, "kraken.json"))
      refute File.exists?(Path.join(output, "kraken.json"))
      assert File.exists?(Path.join(output, "exchange_v4.json"))

      describe_manifest =
        describe_dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()

      assert describe_manifest["exchanges"] == ["binance"]
      assert describe_manifest["tier_scope"] == ["tier1"]
      assert describe_manifest["count"] == 1

      output_manifest = output |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()
      assert output_manifest["exchanges"] == ["binance"]
      assert output_manifest["tier_scope"] == ["tier1"]

      parse_methods =
        discoveries |> Path.join("parse_methods.json") |> File.read!() |> Jason.decode!()

      assert Enum.map(parse_methods["exchanges"], & &1["id"]) == ["binance"]
      assert parse_methods["count"] == 1
      assert parse_methods["tier_scope"] == ["tier1"]
    end

    test "never deletes class_hierarchy.json at discoveries root", %{discoveries: discoveries} do
      class_path = Path.join(discoveries, "class_hierarchy.json")
      write_json(class_path, %{"classes" => [], "count" => 0})

      assert {:ok, _result} =
               ScopePrune.run(in_scope: MapSet.new(), tier_scope: ["tier1"], force: true)

      assert File.exists?(class_path)
    end

    test "post-run ID sets match across describe, output, and envelope", %{discoveries: discoveries, output: output} do
      describe_dir = Path.join(discoveries, "describe")
      load_markets_dir = Path.join(discoveries, "load_markets")
      File.mkdir_p!(describe_dir)
      File.mkdir_p!(load_markets_dir)

      for id <- ["binance", "bybit", "okx"] do
        write_json(Path.join(describe_dir, "#{id}.json"), %{"id" => id})
        write_json(Path.join(load_markets_dir, "#{id}.json"), %{"id" => id})
        write_json(Path.join(output, "#{id}.json"), %{"exchange" => %{"id" => id}})
      end

      write_json(Path.join(output, "kraken.json"), %{"exchange" => %{"id" => "kraken"}})
      write_json(Path.join(describe_dir, "kraken.json"), %{"id" => "kraken"})

      write_json(
        Path.join(discoveries, "parse_methods.json"),
        envelope(["binance", "bybit", "okx", "kraken"], %{"with_parse_methods" => 4, "total_methods" => 4})
      )

      in_scope = MapSet.new(["binance", "bybit", "okx"])

      assert {:ok, _result} =
               ScopePrune.run(in_scope: in_scope, tier_scope: ["tier1"], force: true)

      describe_ids = manifest_ids(describe_dir)
      load_markets_ids = manifest_ids(load_markets_dir)
      output_ids = manifest_ids(output)
      envelope_ids = envelope_exchange_ids(Path.join(discoveries, "parse_methods.json"))

      assert describe_ids == load_markets_ids
      assert describe_ids == output_ids
      assert describe_ids == envelope_ids
      assert describe_ids == ["binance", "bybit", "okx"]
    end
  end

  describe "per_exchange_subdirs/1" do
    test "returns only directories containing per-exchange JSON", %{discoveries: discoveries} do
      describe_dir = Path.join(discoveries, "describe")
      File.mkdir_p!(describe_dir)
      write_json(Path.join(describe_dir, "binance.json"), %{})
      File.mkdir_p!(Path.join(discoveries, "empty_dir"))
      write_json(Path.join(discoveries, "class_hierarchy.json"), %{})

      subdirs = ScopePrune.per_exchange_subdirs(discoveries)
      assert subdirs == [describe_dir]
    end
  end

  defp envelope(ids, stats) do
    exchanges = Enum.map(ids, fn id -> %{"id" => id, "parse_method_count" => 5} end)

    Map.merge(
      %{
        "extracted_at" => "2026-01-01T00:00:00Z",
        "count" => length(ids),
        "tier_scope" => "all",
        "exchanges" => exchanges
      },
      stats
    )
  end

  defp write_json(path, data) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp manifest_ids(dir) do
    dir
    |> Path.join("_manifest.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("exchanges")
  end

  defp envelope_exchange_ids(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("exchanges", [])
    |> Enum.map(& &1["id"])
  end
end
