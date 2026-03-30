defmodule CcxtExtract.ParseMethodsIntegrationTest do
  # async: false — run_task_capturing_output mutates global Mix.shell
  use ExUnit.Case, async: false

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.ParseMethods

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 60_000

  # Reference exchanges from CLAUDE.md tiers
  @reference_exchanges ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex)

  # DEX exchanges
  @dex_exchanges ~w(hyperliquid aster lighter)

  # All reference exchanges
  @all_reference @reference_exchanges ++ @dex_exchanges

  # Common parse methods most exchanges should have
  @common_parse_methods ~w(parseTicker parseOrder parseTrade)

  setup_all do
    {:ok, exchanges, stats} = ParseMethods.extract()
    by_id = Map.new(exchanges, &{&1["id"], &1})
    %{exchanges: exchanges, stats: stats, by_id: by_id}
  end

  describe "extract/0 overall" do
    test "parses all files without errors", %{stats: stats} do
      assert stats.errors == [],
             "Parse errors: #{inspect(stats.errors)}"
    end

    test "extracts reasonable number of exchanges", %{exchanges: exchanges} do
      assert length(exchanges) >= 100
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "most exchanges have parse methods", %{exchanges: exchanges} do
      with_parse = Enum.count(exchanges, fn e -> e["parse_method_count"] > 0 end)
      assert with_parse >= 95, "Expected >= 95 with parse methods, got #{with_parse}"
    end

    test "total parse methods across all exchanges is substantial", %{exchanges: exchanges} do
      total = Enum.sum(Enum.map(exchanges, & &1["parse_method_count"]))
      assert total >= 1400, "Expected >= 1400 total parse methods, got #{total}"
    end
  end

  describe "reference exchange presence" do
    for exchange <- @all_reference do
      test "#{exchange} is present in extraction", %{by_id: by_id} do
        exchange_id = unquote(exchange)

        assert Map.has_key?(by_id, exchange_id),
               "Reference exchange '#{exchange_id}' missing from parse methods extraction"
      end
    end
  end

  describe "reference exchanges have common parse methods" do
    for exchange <- @reference_exchanges do
      test "#{exchange} has parseTicker, parseOrder, parseTrade", %{by_id: by_id} do
        exchange_id = unquote(exchange)
        methods = by_id[exchange_id]["parse_methods"]

        for method_name <- @common_parse_methods do
          assert Map.has_key?(methods, method_name),
                 "Expected #{exchange_id} to have #{method_name}"
        end
      end
    end

    test "binance has substantial number of parse methods", %{by_id: by_id} do
      assert by_id["binance"]["parse_method_count"] >= 20,
             "Expected binance >= 20 parse methods, got #{by_id["binance"]["parse_method_count"]}"
    end

    test "all parse methods are synchronous", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["parse_methods"] do
        assert data["async"] == false,
               "Expected #{exchange["id"]}.#{name} to be sync, got async"
      end
    end
  end

  describe "parse method data structure" do
    test "every method has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["parse_methods"] do
        assert is_list(data["params"]), "Missing params on #{exchange["id"]}.#{name}"
        assert is_boolean(data["async"]), "Missing async on #{exchange["id"]}.#{name}"
        assert is_integer(data["statements"]), "Missing statements on #{exchange["id"]}.#{name}"
        assert is_map(data["body"]), "Missing body on #{exchange["id"]}.#{name}"
      end
    end

    test "binance parseTicker has typical parse signature", %{by_id: by_id} do
      ticker = by_id["binance"]["parse_methods"]["parseTicker"]
      param_names = Enum.map(ticker["params"], & &1["name"])

      assert "ticker" in param_names || "response" in param_names,
             "Expected first param to be data-like, got #{inspect(param_names)}"

      assert ticker["statements"] >= 5,
             "Expected parseTicker to have substantial complexity"
    end
  end

  describe "body AST structure" do
    test "body has type and nested statements", %{by_id: by_id} do
      body = by_id["binance"]["parse_methods"]["parseTicker"]["body"]

      assert is_map(body)

      body_type = Map.get(body, :type) || Map.get(body, "type")
      assert is_binary(body_type), "Body AST missing 'type' field"

      body_stmts = Map.get(body, :body) || Map.get(body, "body")
      assert is_list(body_stmts)
      assert length(body_stmts) >= 5
    end

    test "body AST nodes have type fields", %{by_id: by_id} do
      body = by_id["binance"]["parse_methods"]["parseTicker"]["body"]
      stmts = Map.get(body, :body) || Map.get(body, "body")

      for stmt <- stmts do
        type = Map.get(stmt, :type) || Map.get(stmt, "type")
        assert is_binary(type), "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["parse_methods"]["parseTicker"]["body"]

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
        assert is_map(exchange["parse_methods"]), "Missing 'parse_methods' on #{exchange["id"]}"
        assert is_integer(exchange["parse_method_count"]), "Missing 'parse_method_count' on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "Missing 'class_name' on #{exchange["id"]}"
      end
    end

    test "parse_method_count matches actual method count", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert exchange["parse_method_count"] == map_size(exchange["parse_methods"]),
               "Count mismatch on #{exchange["id"]}: #{exchange["parse_method_count"]} != #{map_size(exchange["parse_methods"])}"
      end
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with correct envelope", %{exchanges: exchanges, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "parse_methods.json")

      ParseMethods.write!(exchanges, output_path)

      with_parse = Enum.count(exchanges, fn e -> e["parse_method_count"] > 0 end)
      total_methods = Enum.sum(Enum.map(exchanges, & &1["parse_method_count"]))

      parsed = output_path |> File.read!() |> Jason.decode!()
      assert parsed["count"] == length(exchanges)
      assert parsed["with_parse_methods"] == with_parse
      assert parsed["total_methods"] == total_methods
      assert is_list(parsed["exchanges"])
      assert is_binary(parsed["extracted_at"])

      # Verify JSON round-trip preserved body structure
      binance = Enum.find(parsed["exchanges"], &(&1["id"] == "binance"))
      ticker = binance["parse_methods"]["parseTicker"]
      assert ticker["body"]["type"]
      assert is_list(ticker["body"]["body"])
    end
  end

  describe "mix ccxt_extract.parse_methods" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.ParseMethods)

      assert output =~ "Extracting parse*() method ASTs"
      assert output =~ "Done."
      assert output =~ "with parse methods"
      assert output =~ "Output: priv/discoveries/parse_methods.json"
    end
  end
end
