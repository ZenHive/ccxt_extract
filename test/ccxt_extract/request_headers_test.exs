defmodule CcxtExtract.RequestHeadersTest do
  @moduledoc """
  Unit tests for RequestHeaders pure functions.
  Uses synthetic data — no QuickBEAM runtime.

  The `:extraction`-tagged band reads `priv/discoveries/request_headers.json`
  and asserts type discipline + sanity overrides (coinbase / htx / bybit have
  non-nil UA; coinbase / gate / alpaca have non-empty default_headers).

  `async: false` — `@tag :tmp_dir` + `File.rm_rf!/1` in setup races under
  parallel ExUnit (EEXIST on nested paths / teardown).
  """
  use ExUnit.Case, async: false

  alias CcxtExtract.RequestHeaders

  @sample_results [
    %{
      "id" => "binance",
      "request_headers" => %{
        "user_agent" => nil,
        "default_headers" => %{}
      }
    },
    %{
      "id" => "coinbase",
      "request_headers" => %{
        "user_agent" =>
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/62.0.3202.94 Safari/537.36",
        "default_headers" => %{"CB-VERSION" => "2018-05-30"}
      }
    },
    %{
      "id" => "gate",
      "request_headers" => %{
        "user_agent" => nil,
        "default_headers" => %{"X-Gate-Channel-Id" => "ccxt"}
      }
    },
    %{
      "id" => "htx",
      "request_headers" => %{
        "user_agent" =>
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.0.0 Safari/537.36",
        "default_headers" => %{}
      }
    }
  ]

  describe "empty_record/0" do
    test "returns the always-emit wrapper with null UA and empty headers" do
      assert RequestHeaders.empty_record() == %{
               "user_agent" => nil,
               "default_headers" => %{}
             }
    end
  end

  describe "write!/1" do
    @tag :tmp_dir
    test "writes valid JSON with standard envelope", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "request_headers.json")
      assert :ok = RequestHeaders.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()

      assert is_binary(data["extracted_at"])
      assert data["count"] == 4
      assert is_list(data["exchanges"])
      assert length(data["exchanges"]) == 4
    end

    @tag :tmp_dir
    test "preserves populated user_agent and default_headers", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "request_headers.json")
      RequestHeaders.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      coinbase = Enum.find(data["exchanges"], &(&1["id"] == "coinbase"))

      assert is_binary(coinbase["request_headers"]["user_agent"])
      assert String.contains?(coinbase["request_headers"]["user_agent"], "Mozilla")
      assert coinbase["request_headers"]["default_headers"]["CB-VERSION"] == "2018-05-30"
    end

    @tag :tmp_dir
    test "preserves null user_agent for non-overriding exchanges", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "request_headers.json")
      RequestHeaders.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      binance = Enum.find(data["exchanges"], &(&1["id"] == "binance"))

      assert binance["request_headers"]["user_agent"] == nil
      assert binance["request_headers"]["default_headers"] == %{}
    end

    @tag :tmp_dir
    test "preserves UA-only and headers-only mixed cases", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "request_headers.json")
      RequestHeaders.write!(@sample_results, output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()
      gate = Enum.find(data["exchanges"], &(&1["id"] == "gate"))
      htx = Enum.find(data["exchanges"], &(&1["id"] == "htx"))

      # gate: headers only
      assert gate["request_headers"]["user_agent"] == nil
      assert gate["request_headers"]["default_headers"]["X-Gate-Channel-Id"] == "ccxt"

      # htx: UA only
      assert is_binary(htx["request_headers"]["user_agent"])
      assert htx["request_headers"]["default_headers"] == %{}
    end

    @tag :tmp_dir
    test "handles empty results", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "request_headers.json")
      assert :ok = RequestHeaders.write!([], output_path: output_path)

      data = output_path |> File.read!() |> Jason.decode!()

      assert data["count"] == 0
      assert data["exchanges"] == []
    end

    @tag :tmp_dir
    test "creates parent directories", %{tmp_dir: tmp_dir} do
      output_path = Path.join([tmp_dir, "nested", "dir", "request_headers.json"])
      assert :ok = RequestHeaders.write!(@sample_results, output_path: output_path)
      assert File.exists?(output_path)
    end
  end

  describe "write!/2 scoped merge" do
    @tag :tmp_dir
    test "scope: :all overwrites the aggregate wholesale", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "request_headers.json")
      RequestHeaders.write!(@sample_results, output_path: path)

      RequestHeaders.write!(
        [%{"id" => "binance", "request_headers" => RequestHeaders.empty_record()}],
        output_path: path,
        scope: :all
      )

      data = path |> File.read!() |> Jason.decode!()
      assert Enum.map(data["exchanges"], & &1["id"]) == ["binance"]
      assert data["count"] == 1
    end

    @tag :tmp_dir
    test "MapSet scope preserves out-of-scope entries", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "request_headers.json")
      RequestHeaders.write!(@sample_results, output_path: path)

      replacement = %{
        "id" => "binance",
        "request_headers" => %{
          "user_agent" => "ReplacedUA",
          "default_headers" => %{"X-Replaced" => "yes"}
        }
      }

      RequestHeaders.write!(
        [replacement],
        output_path: path,
        scope: MapSet.new(["binance"])
      )

      data = path |> File.read!() |> Jason.decode!()
      ids = Enum.map(data["exchanges"], & &1["id"])
      assert "binance" in ids
      assert "coinbase" in ids
      assert "gate" in ids
      assert "htx" in ids
      binance = Enum.find(data["exchanges"], &(&1["id"] == "binance"))
      assert binance["request_headers"]["user_agent"] == "ReplacedUA"
      assert binance["request_headers"]["default_headers"]["X-Replaced"] == "yes"
    end

    @tag :tmp_dir
    test "count matches exchanges length after merge (drift guard)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "request_headers.json")
      RequestHeaders.write!(@sample_results, output_path: path)

      RequestHeaders.write!(
        [%{"id" => "binance", "request_headers" => RequestHeaders.empty_record()}],
        output_path: path,
        scope: MapSet.new(["binance"])
      )

      data = path |> File.read!() |> Jason.decode!()
      assert data["count"] == length(data["exchanges"])
    end

    @tag :tmp_dir
    test "tier_scope stamped into envelope", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "request_headers.json")

      RequestHeaders.write!(@sample_results,
        output_path: path,
        scope: :all,
        tier_scope: ["tier1"]
      )

      data = path |> File.read!() |> Jason.decode!()
      assert data["tier_scope"] == ["tier1"]
    end
  end

  describe "output shape" do
    test "each exchange entry has id and request_headers keys" do
      for entry <- @sample_results do
        assert Map.has_key?(entry, "id")
        assert Map.has_key?(entry, "request_headers")
        assert is_binary(entry["id"])
        assert is_map(entry["request_headers"])
      end
    end

    test "each request_headers wrapper has user_agent + default_headers" do
      required_keys = ~w(user_agent default_headers)

      for entry <- @sample_results do
        for key <- required_keys do
          assert Map.has_key?(entry["request_headers"], key),
                 "Missing key #{key} in #{entry["id"]}"
        end

        wrapper = entry["request_headers"]
        assert is_binary(wrapper["user_agent"]) or is_nil(wrapper["user_agent"])
        assert is_map(wrapper["default_headers"])
      end
    end

    test "default_headers values are strings when present" do
      for entry <- @sample_results,
          {key, value} <- entry["request_headers"]["default_headers"] do
        assert is_binary(key)
        assert is_binary(value), "Non-string header value in #{entry["id"]}: #{inspect(value)}"
      end
    end
  end

  describe "type discipline (discovery data)" do
    @tag :extraction
    test "every entry has the always-emit wrapper" do
      data = read_discovery!()

      for %{"id" => id, "request_headers" => wrapper} <- data["exchanges"] do
        assert is_map(wrapper),
               "#{id}: request_headers must be a map, got #{inspect(wrapper)}"

        assert Map.has_key?(wrapper, "user_agent"),
               "#{id}: missing user_agent key"

        assert Map.has_key?(wrapper, "default_headers"),
               "#{id}: missing default_headers key"
      end
    end

    @tag :extraction
    test "user_agent is string or nil; default_headers is always a map" do
      data = read_discovery!()

      for %{"id" => id, "request_headers" => wrapper} <- data["exchanges"] do
        ua = wrapper["user_agent"]
        headers = wrapper["default_headers"]

        assert is_binary(ua) or is_nil(ua),
               "#{id}: user_agent must be string or nil, got #{inspect(ua)}"

        assert is_map(headers),
               "#{id}: default_headers must be a map, got #{inspect(headers)}"

        # Every header value must be a string (CCXT's Dictionary<string> contract)
        for {k, v} <- headers do
          assert is_binary(k), "#{id}: header key not a string: #{inspect(k)}"

          assert is_binary(v),
                 "#{id}: header value at #{inspect(k)} not a string: #{inspect(v)}"
        end
      end
    end

    @tag :extraction
    test "at least one exchange overrides user_agent (sanity)" do
      data = read_discovery!()

      with_ua =
        Enum.filter(data["exchanges"], fn %{"request_headers" => w} ->
          is_binary(w["user_agent"])
        end)

      assert with_ua != [],
             "Expected at least one exchange with non-nil user_agent (e.g. coinbase, htx, bybit)"
    end

    @tag :extraction
    test "at least one exchange overrides default_headers (sanity)" do
      data = read_discovery!()

      with_headers =
        Enum.filter(data["exchanges"], fn %{"request_headers" => w} ->
          map_size(w["default_headers"]) > 0
        end)

      assert with_headers != [],
             "Expected at least one exchange with non-empty default_headers (e.g. coinbase, gate, alpaca)"
    end
  end

  defp read_discovery! do
    path = CcxtExtract.Paths.priv("discoveries/request_headers.json")

    if not File.exists?(path) do
      flunk("""
      Missing discovery data!

      Run extraction first:
        mix ccxt_extract.request_headers
      """)
    end

    path |> File.read!() |> Jason.decode!()
  end
end
