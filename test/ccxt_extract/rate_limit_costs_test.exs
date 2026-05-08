defmodule CcxtExtract.RateLimitCostsTest do
  @moduledoc """
  Unit tests for `CcxtExtract.RateLimitCosts` pure functions and writer.
  Uses synthetic data — no QuickBEAM runtime.

  The `:extraction`-tagged `extract/1` test (excluded by default per
  `test/test_helper.exs`) starts a real QuickBEAM runtime and asserts
  the binance / okx / deribit cost extraction shape end-to-end.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.RateLimitCosts

  @sample_results [
    %{
      "id" => "binance",
      "rate_limit_costs" => %{
        "sapi.get.system/status" => %{"cost" => 0.1, "axes" => %{}},
        "sapi.get.margin/crossMarginData" => %{
          "cost" => 0.1,
          "axes" => %{"noCoin" => 0.5}
        },
        "public.get.exchangeInfo" => %{
          "cost" => 1,
          "axes" => %{"byLimit" => [[50, 2], [100, 5], [500, 10], [1000, 20]]}
        }
      }
    },
    %{
      "id" => "deribit",
      "rate_limit_costs" => %{
        "public.get.auth" => %{"cost" => 1, "axes" => %{}},
        "public.get.get_time" => %{"cost" => 1, "axes" => %{}},
        "private.get.logout" => %{"cost" => 1, "axes" => %{}}
      }
    },
    %{
      "id" => "okx",
      "rate_limit_costs" => %{
        "public.get.market/tickers" => %{"cost" => 1, "axes" => %{}},
        "public.get.market/books" => %{"cost" => 0.5, "axes" => %{}}
      }
    },
    %{
      # Synthetic fixture covering the unresolvable-cost path. Mirrors what
      # the JS extractor emits when an exchange's endpoint config is a
      # function literal or otherwise non-numeric (e.g., paradex's
      # `cost: () => …` lambda) — surfaced as `cost: nil` per the Honesty
      # Rule rather than fabricating a default.
      "id" => "synthetic_lambda",
      "rate_limit_costs" => %{
        "public.get.computed" => %{"cost" => nil, "axes" => %{}},
        "public.get.computed_with_axis" => %{
          "cost" => nil,
          "axes" => %{"byLimit" => [[100, 1], [500, 5]]}
        }
      }
    }
  ]

  describe "empty_record/0" do
    test "returns the empty rate_limit_costs map" do
      assert RateLimitCosts.empty_record() == %{}
    end
  end

  describe "write!/1" do
    @tag :tmp_dir
    test "writes valid JSON with standard envelope", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "rate_limit_costs.json")
      assert :ok = RateLimitCosts.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()

      assert is_binary(data["extracted_at"])
      assert data["count"] == 4
      assert is_list(data["exchanges"])
      assert length(data["exchanges"]) == 4
    end

    @tag :tmp_dir
    test "envelope stats compute total_endpoints from merged entries", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "rate_limit_costs.json")
      RateLimitCosts.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()

      # binance has 3, deribit has 3, okx has 2, synthetic_lambda has 2 — total 10
      assert data["total_endpoints"] == 10
      assert data["with_rate_limit_costs"] == 4
    end

    @tag :tmp_dir
    test "preserves null cost verbatim through writer", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "rate_limit_costs.json")
      RateLimitCosts.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      synthetic = Enum.find(data["exchanges"], &(&1["id"] == "synthetic_lambda"))

      computed = synthetic["rate_limit_costs"]["public.get.computed"]
      assert is_nil(computed["cost"])
      assert computed["axes"] == %{}

      with_axis = synthetic["rate_limit_costs"]["public.get.computed_with_axis"]
      assert is_nil(with_axis["cost"])
      assert with_axis["axes"]["byLimit"] == [[100, 1], [500, 5]]
    end

    @tag :tmp_dir
    test "preserves cost numeric values verbatim", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "rate_limit_costs.json")
      RateLimitCosts.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      binance = Enum.find(data["exchanges"], &(&1["id"] == "binance"))
      okx = Enum.find(data["exchanges"], &(&1["id"] == "okx"))

      assert binance["rate_limit_costs"]["sapi.get.system/status"]["cost"] == 0.1
      assert okx["rate_limit_costs"]["public.get.market/books"]["cost"] == 0.5
    end

    @tag :tmp_dir
    test "preserves weight-axis variants verbatim", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "rate_limit_costs.json")
      RateLimitCosts.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      binance = Enum.find(data["exchanges"], &(&1["id"] == "binance"))

      crossmargin = binance["rate_limit_costs"]["sapi.get.margin/crossMarginData"]
      assert crossmargin["cost"] == 0.1
      assert crossmargin["axes"] == %{"noCoin" => 0.5}

      exchange_info = binance["rate_limit_costs"]["public.get.exchangeInfo"]
      assert exchange_info["cost"] == 1
      assert exchange_info["axes"]["byLimit"] == [[50, 2], [100, 5], [500, 10], [1000, 20]]
    end

    @tag :tmp_dir
    test "handles empty results", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "rate_limit_costs.json")
      assert :ok = RateLimitCosts.write!([], output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()

      assert data["count"] == 0
      assert data["exchanges"] == []
      assert data["total_endpoints"] == 0
      assert data["with_rate_limit_costs"] == 0
    end

    @tag :tmp_dir
    test "creates parent directories", %{tmp_dir: tmp_dir} do
      output_path = Path.join([tmp_dir, "nested", "dir", "rate_limit_costs.json"])
      assert :ok = RateLimitCosts.write!(@sample_results, output_path: output_path)
      assert File.exists?(output_path)
    end
  end

  describe "write!/2 scoped merge" do
    @tag :tmp_dir
    test "scope: :all overwrites the aggregate wholesale", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rate_limit_costs.json")
      RateLimitCosts.write!(@sample_results, output_path: path)

      RateLimitCosts.write!(
        [%{"id" => "binance", "rate_limit_costs" => %{}}],
        output_path: path,
        scope: :all
      )

      data = path |> File.read!() |> Jason.decode!()
      assert Enum.map(data["exchanges"], & &1["id"]) == ["binance"]
      assert data["count"] == 1
      assert data["total_endpoints"] == 0
    end

    @tag :tmp_dir
    test "MapSet scope preserves out-of-scope entries", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rate_limit_costs.json")
      RateLimitCosts.write!(@sample_results, output_path: path)

      replacement = %{
        "id" => "binance",
        "rate_limit_costs" => %{
          "sapi.get.system/status" => %{"cost" => 0.5, "axes" => %{}}
        }
      }

      RateLimitCosts.write!(
        [replacement],
        output_path: path,
        scope: MapSet.new(["binance"])
      )

      data = path |> File.read!() |> Jason.decode!()
      ids = Enum.map(data["exchanges"], & &1["id"])
      assert "binance" in ids
      assert "deribit" in ids
      assert "okx" in ids
      assert "synthetic_lambda" in ids

      binance = Enum.find(data["exchanges"], &(&1["id"] == "binance"))
      assert binance["rate_limit_costs"]["sapi.get.system/status"]["cost"] == 0.5

      # total_endpoints recomputed: binance=1, deribit=3, okx=2, synthetic_lambda=2
      assert data["total_endpoints"] == 8
    end

    @tag :tmp_dir
    test "count matches exchanges length after merge (drift guard)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rate_limit_costs.json")
      RateLimitCosts.write!(@sample_results, output_path: path)

      RateLimitCosts.write!(
        [%{"id" => "binance", "rate_limit_costs" => %{}}],
        output_path: path,
        scope: MapSet.new(["binance"])
      )

      data = path |> File.read!() |> Jason.decode!()
      assert data["count"] == length(data["exchanges"])
    end

    @tag :tmp_dir
    test "tier_scope stamped into envelope", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "rate_limit_costs.json")

      RateLimitCosts.write!(@sample_results,
        output_path: path,
        scope: :all,
        tier_scope: ["tier1"]
      )

      data = path |> File.read!() |> Jason.decode!()
      assert data["tier_scope"] == ["tier1"]
    end
  end

  describe "output shape" do
    test "each exchange entry has id and rate_limit_costs keys" do
      for entry <- @sample_results do
        assert Map.has_key?(entry, "id")
        assert Map.has_key?(entry, "rate_limit_costs")
        assert is_binary(entry["id"])
        assert is_map(entry["rate_limit_costs"])
      end
    end

    test "each cost entry has the cost and axes keys" do
      required_keys = ~w(cost axes)

      for entry <- @sample_results do
        for {_endpoint_key, cost_record} <- entry["rate_limit_costs"] do
          for key <- required_keys do
            assert Map.has_key?(cost_record, key),
                   "Missing key #{key} in #{entry["id"]}"
          end

          assert is_number(cost_record["cost"]) or is_nil(cost_record["cost"])
          assert is_map(cost_record["axes"])
        end
      end
    end

    test "endpoint key follows <section>.<verb>.<path> convention" do
      for entry <- @sample_results do
        for {endpoint_key, _record} <- entry["rate_limit_costs"] do
          parts = String.split(endpoint_key, ".")
          # At least 3 parts (one section, one verb, one path with no slashes)
          assert length(parts) >= 3,
                 "Endpoint key #{inspect(endpoint_key)} for #{entry["id"]} should have >= 3 dot-joined parts"
        end
      end
    end
  end

  describe "extract/1 (extraction)" do
    @describetag :extraction
    @describetag timeout: 120_000

    setup do
      Application.ensure_all_started(:quickbeam)
      :ok
    end

    test "binance produces resolvable cost entries with sapi.get.* coverage" do
      {:ok, results} = RateLimitCosts.extract(scope: MapSet.new(["binance"]))

      assert length(results) == 1
      [%{"id" => "binance", "rate_limit_costs" => costs}] = results

      assert is_map(costs)
      assert map_size(costs) > 50

      sapi_keys = costs |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "sapi.get."))
      assert length(sapi_keys) > 10

      # Every entry has cost (number or nil) + axes map
      for {_k, %{"cost" => cost, "axes" => axes}} <- costs do
        assert is_number(cost) or is_nil(cost)
        assert is_map(axes)
      end

      # margin/crossMarginData has the noCoin axis variant
      key = Enum.find(Map.keys(costs), &String.contains?(&1, "margin/crossMarginData"))
      assert key, "Expected an entry containing margin/crossMarginData in binance costs"
      assert costs[key]["cost"] == 0.1
      assert costs[key]["axes"]["noCoin"] == 0.5
    end

    test "deribit produces flat-public.get.* coverage with cost = 1 default" do
      {:ok, results} = RateLimitCosts.extract(scope: MapSet.new(["deribit"]))

      assert length(results) == 1
      [%{"id" => "deribit", "rate_limit_costs" => costs}] = results

      auth_entry = Map.get(costs, "public.get.auth")
      assert auth_entry, "Expected public.get.auth in deribit costs"
      assert auth_entry["cost"] == 1
      assert auth_entry["axes"] == %{}
    end

    test "okx produces nested public.get.market/* coverage" do
      {:ok, results} = RateLimitCosts.extract(scope: MapSet.new(["okx"]))

      assert length(results) == 1
      [%{"id" => "okx", "rate_limit_costs" => costs}] = results

      market_keys = costs |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "public.get.market/"))
      assert length(market_keys) > 5

      # market/books has cost = 0.5 (1/2 in the source)
      books = Map.get(costs, "public.get.market/books")
      assert books, "Expected public.get.market/books in okx costs"
      assert books["cost"] == 0.5
    end
  end
end
