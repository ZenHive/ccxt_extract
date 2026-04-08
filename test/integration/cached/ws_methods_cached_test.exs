defmodule CcxtExtract.Integration.Cached.WsMethodsCachedTest do
  @moduledoc """
  Structure tests for ws_methods.json — reads cached discovery output.
  Same assertions as WsMethodsIntegrationTest but without OXC parsing.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir CcxtExtract.Paths.discoveries()
  @fixture_path Path.join(@fixtures_dir, "ws_methods.json")

  # Reference exchanges that should have WS implementations
  @reference_exchanges ~w(binance bybit okx deribit kraken kucoin gate htx bitmex)

  # Common watch methods most WS exchanges should have
  @common_watch_methods ~w(watchTicker watchOrderBook watchTrades)

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_ws_methods"])
      assert is_integer(data["total_methods"])
      assert is_list(data["exchanges"])
    end

    test "counts are consistent", %{data: data} do
      assert data["count"] == length(data["exchanges"])

      actual_with_ws = Enum.count(data["exchanges"], fn e -> e["ws_method_count"] > 0 end)
      assert data["with_ws_methods"] == actual_with_ws

      actual_total = Enum.sum(Enum.map(data["exchanges"], & &1["ws_method_count"]))
      assert data["total_methods"] == actual_total
    end

    test "at least 70 exchanges extracted", %{data: data} do
      assert data["count"] >= 70
    end

    test "at least 60 exchanges have WS methods", %{data: data} do
      assert data["with_ws_methods"] >= 60
    end

    test "at least 1400 total WS methods", %{data: data} do
      assert data["total_methods"] >= 1400
    end
  end

  describe "exchange structure" do
    test "every exchange has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert is_binary(exchange["id"]), "missing id"
        assert is_binary(exchange["file"]), "missing file"
        assert is_map(exchange["ws_methods"]), "missing ws_methods on #{exchange["id"]}"
        assert is_integer(exchange["ws_method_count"]), "missing ws_method_count on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "missing class_name on #{exchange["id"]}"
      end
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "ws_method_count matches actual method count", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert exchange["ws_method_count"] == map_size(exchange["ws_methods"]),
               "Count mismatch on #{exchange["id"]}"
      end
    end

    test "exchanges with WS methods have complete data", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["ws_methods"] do
        assert is_list(data["params"]), "missing params on #{exchange["id"]}.#{name}"
        assert is_boolean(data["async"]), "missing async on #{exchange["id"]}.#{name}"
        assert is_integer(data["statements"]), "missing statements on #{exchange["id"]}.#{name}"
        assert is_map(data["body"]), "missing body on #{exchange["id"]}.#{name}"
      end
    end
  end

  # Reference exchanges must be present
  for exchange <- @reference_exchanges do
    test "#{exchange} is present", %{by_id: by_id} do
      assert Map.has_key?(by_id, unquote(exchange)),
             "Reference exchange '#{unquote(exchange)}' missing"
    end
  end

  # Reference exchanges should have common watch methods
  for exchange <- @reference_exchanges do
    test "#{exchange} has common watch methods", %{by_id: by_id} do
      methods = by_id[unquote(exchange)]["ws_methods"]

      for method_name <- @common_watch_methods do
        assert Map.has_key?(methods, method_name),
               "Expected #{unquote(exchange)} to have #{method_name}"
      end
    end
  end

  describe "binance WS method details" do
    test "has substantial number of WS methods", %{by_id: by_id} do
      assert by_id["binance"]["ws_method_count"] >= 40
    end

    test "watch methods are async", %{by_id: by_id} do
      for {name, data} <- by_id["binance"]["ws_methods"],
          String.starts_with?(name, "watch") do
        assert data["async"] == true,
               "Expected binance.#{name} to be async"
      end
    end

    test "handle methods are synchronous", %{by_id: by_id} do
      for {name, data} <- by_id["binance"]["ws_methods"],
          String.starts_with?(name, "handle") do
        assert data["async"] == false,
               "Expected binance.#{name} to be sync"
      end
    end
  end

  describe "body AST structure" do
    test "binance watchTicker body has type and nested statements", %{by_id: by_id} do
      body = by_id["binance"]["ws_methods"]["watchTicker"]["body"]

      assert is_map(body)
      assert is_binary(body["type"])
      assert is_list(body["body"])
      assert body["body"] != []
    end

    test "body statements have type fields", %{by_id: by_id} do
      stmts = by_id["binance"]["ws_methods"]["watchTicker"]["body"]["body"]

      for stmt <- stmts do
        assert is_binary(stmt["type"]),
               "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["ws_methods"]["watchTicker"]["body"]

      assert is_integer(body["start"])
      assert is_integer(body["end"])
      assert body["end"] > body["start"]
    end
  end

  describe "watch/handle async consistency across all exchanges" do
    test "all watch methods are async", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["ws_methods"],
          String.starts_with?(name, "watch") do
        assert data["async"] == true,
               "#{exchange["id"]}.#{name} should be async"
      end
    end

    # Most handle methods are sync, but a few exceptions exist
    # (e.g., bitget.handleCheckSumError is async)
    test "vast majority of handle methods are synchronous", %{exchanges: exchanges} do
      {sync, async} =
        for exchange <- exchanges,
            {name, data} <- exchange["ws_methods"],
            String.starts_with?(name, "handle"),
            reduce: {0, 0} do
          {s, a} -> if data["async"], do: {s, a + 1}, else: {s + 1, a}
        end

      total = sync + async
      sync_ratio = sync / total

      assert sync_ratio > 0.99,
             "Expected >99% handle methods to be sync, got #{Float.round(sync_ratio * 100, 1)}% (#{async} async out of #{total})"
    end
  end
end
