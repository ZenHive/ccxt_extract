defmodule CcxtExtract.WsMethodsIntegrationTest do
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.WsMethods

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 60_000

  # Reference exchanges with WS implementations
  @reference_exchanges ~w(binance bybit okx deribit kraken kucoin gate htx bitmex)

  # Common watch methods most WS exchanges should have
  @common_watch_methods ~w(watchTicker watchOrderBook watchTrades)

  setup_all do
    {:ok, exchanges, stats} = WsMethods.extract()
    by_id = Map.new(exchanges, &{&1["id"], &1})
    %{exchanges: exchanges, stats: stats, by_id: by_id}
  end

  describe "extract/0 overall" do
    test "parses all files without errors", %{stats: stats} do
      assert stats.errors == [],
             "Parse errors: #{inspect(stats.errors)}"
    end

    test "extracts reasonable number of exchanges", %{exchanges: exchanges} do
      assert length(exchanges) >= 70
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "most exchanges have WS methods", %{exchanges: exchanges} do
      with_ws = Enum.count(exchanges, fn e -> e["ws_method_count"] > 0 end)
      assert with_ws >= 60, "Expected >= 60 with WS methods, got #{with_ws}"
    end

    test "total WS methods across all exchanges is substantial", %{exchanges: exchanges} do
      total = Enum.sum(Enum.map(exchanges, & &1["ws_method_count"]))
      assert total >= 1400, "Expected >= 1400 total WS methods, got #{total}"
    end
  end

  describe "reference exchange presence" do
    for exchange <- @reference_exchanges do
      test "#{exchange} is present in extraction", %{by_id: by_id} do
        exchange_id = unquote(exchange)

        assert Map.has_key?(by_id, exchange_id),
               "Reference exchange '#{exchange_id}' missing from WS methods extraction"
      end
    end
  end

  describe "reference exchanges have common watch methods" do
    for exchange <- @reference_exchanges do
      test "#{exchange} has watchTicker, watchOrderBook, watchTrades", %{by_id: by_id} do
        exchange_id = unquote(exchange)
        methods = by_id[exchange_id]["ws_methods"]

        for method_name <- @common_watch_methods do
          assert Map.has_key?(methods, method_name),
                 "Expected #{exchange_id} to have #{method_name}"
        end
      end
    end

    test "binance has substantial number of WS methods", %{by_id: by_id} do
      assert by_id["binance"]["ws_method_count"] >= 40,
             "Expected binance >= 40 WS methods, got #{by_id["binance"]["ws_method_count"]}"
    end

    test "all watch methods are async", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["ws_methods"],
          String.starts_with?(name, "watch") do
        assert data["async"] == true,
               "Expected #{exchange["id"]}.#{name} to be async"
      end
    end
  end

  describe "WS method data structure" do
    test "every method has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["ws_methods"] do
        assert is_list(data["params"]), "Missing params on #{exchange["id"]}.#{name}"
        assert is_boolean(data["async"]), "Missing async on #{exchange["id"]}.#{name}"
        assert is_integer(data["statements"]), "Missing statements on #{exchange["id"]}.#{name}"
        assert is_map(data["body"]), "Missing body on #{exchange["id"]}.#{name}"
      end
    end

    test "binance watchTicker has typical WS signature", %{by_id: by_id} do
      ticker = by_id["binance"]["ws_methods"]["watchTicker"]
      param_names = Enum.map(ticker["params"], & &1["name"])

      assert "symbol" in param_names,
             "Expected watchTicker to have 'symbol' param, got #{inspect(param_names)}"

      assert ticker["async"] == true
    end
  end

  describe "body AST structure" do
    test "body has type and nested statements", %{by_id: by_id} do
      body = by_id["binance"]["ws_methods"]["watchTicker"]["body"]

      assert is_map(body)

      body_type = Map.get(body, :type) || Map.get(body, "type")
      assert is_binary(body_type), "Body AST missing 'type' field"

      body_stmts = Map.get(body, :body) || Map.get(body, "body")
      assert is_list(body_stmts)
      assert body_stmts != []
    end

    test "body AST nodes have type fields", %{by_id: by_id} do
      body = by_id["binance"]["ws_methods"]["watchTicker"]["body"]
      stmts = Map.get(body, :body) || Map.get(body, "body")

      for stmt <- stmts do
        type = Map.get(stmt, :type) || Map.get(stmt, "type")
        assert is_binary(type), "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["ws_methods"]["watchTicker"]["body"]

      start_offset = Map.get(body, :start) || Map.get(body, "start")
      end_offset = Map.get(body, :end) || Map.get(body, "end")

      assert is_integer(start_offset), "Body missing 'start' byte offset"
      assert is_integer(end_offset), "Body missing 'end' byte offset"
      assert end_offset > start_offset
    end
  end

  describe "exchange output shape" do
    test "every exchange has required top-level fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert is_binary(exchange["id"]), "Missing 'id' on exchange"
        assert is_binary(exchange["file"]), "Missing 'file' on #{exchange["id"]}"
        assert is_map(exchange["ws_methods"]), "Missing 'ws_methods' on #{exchange["id"]}"
        assert is_integer(exchange["ws_method_count"]), "Missing 'ws_method_count' on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "Missing 'class_name' on #{exchange["id"]}"
      end
    end

    test "ws_method_count matches actual method count", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert exchange["ws_method_count"] == map_size(exchange["ws_methods"]),
               "Count mismatch on #{exchange["id"]}: #{exchange["ws_method_count"]} != #{map_size(exchange["ws_methods"])}"
      end
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with correct envelope", %{exchanges: exchanges, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "ws_methods.json")

      WsMethods.write!(exchanges, output_path)

      with_ws = Enum.count(exchanges, fn e -> e["ws_method_count"] > 0 end)
      total_methods = Enum.sum(Enum.map(exchanges, & &1["ws_method_count"]))

      parsed = output_path |> File.read!() |> Jason.decode!()
      assert parsed["count"] == length(exchanges)
      assert parsed["with_ws_methods"] == with_ws
      assert parsed["total_methods"] == total_methods
      assert is_list(parsed["exchanges"])
      assert is_binary(parsed["extracted_at"])

      # Verify JSON round-trip preserved body structure
      binance = Enum.find(parsed["exchanges"], &(&1["id"] == "binance"))
      ticker = binance["ws_methods"]["watchTicker"]
      assert ticker["body"]["type"]
      assert is_list(ticker["body"]["body"])
    end
  end

  describe "mix ccxt_extract.ws_methods" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.WsMethods)

      assert output =~ "Extracting watch*/handle* method ASTs"
      assert output =~ "Done."
      assert output =~ "with WS methods"
      assert output =~ "Output: priv/discoveries/ws_methods.json"
    end
  end
end
