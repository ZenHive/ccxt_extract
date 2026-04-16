defmodule CcxtExtract.SignMethodIntegrationTest do
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.SignMethod

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 60_000

  # Reference exchanges from CLAUDE.md tiers — all should have sign()
  @exchanges_with_sign ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex)

  # DEX exchanges — may or may not have sign()
  @dex_exchanges ~w(hyperliquid aster lighter)

  # All reference exchanges
  @all_reference @exchanges_with_sign ++ @dex_exchanges

  # Standard sign() parameter names (most exchanges use these)
  @standard_param_names ~w(path api method params headers body)

  setup_all do
    {:ok, exchanges, stats} = SignMethod.extract()
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

    test "at least 95 exchanges have sign()", %{exchanges: exchanges} do
      with_sign = Enum.count(exchanges, & &1["sign"])
      assert with_sign >= 95, "Expected >= 95 with sign(), got #{with_sign}"
    end
  end

  describe "reference exchange presence" do
    for exchange <- @all_reference do
      test "#{exchange} is present in extraction", %{by_id: by_id} do
        exchange_id = unquote(exchange)

        assert Map.has_key?(by_id, exchange_id),
               "Reference exchange '#{exchange_id}' missing from sign method extraction"
      end
    end
  end

  describe "exchanges with sign()" do
    for exchange <- @exchanges_with_sign do
      test "#{exchange} has non-null sign data", %{by_id: by_id} do
        exchange_id = unquote(exchange)
        data = by_id[exchange_id]

        assert data["sign"],
               "Expected #{exchange_id} to have sign() method, got null"
      end
    end

    test "binance sign() has standard 6 parameters", %{by_id: by_id} do
      params = by_id["binance"]["sign"]["params"]
      param_names = Enum.map(params, & &1["name"])

      assert length(params) == 6,
             "Expected 6 params, got #{length(params)}: #{inspect(param_names)}"

      assert param_names == @standard_param_names,
             "Expected #{inspect(@standard_param_names)}, got #{inspect(param_names)}"
    end

    test "binance sign() has substantial complexity", %{by_id: by_id} do
      assert by_id["binance"]["sign"]["statements"] >= 8
    end

    test "kraken sign() has moderate complexity", %{by_id: by_id} do
      assert by_id["kraken"]["sign"]["statements"] >= 3
    end

    test "all sign() methods are synchronous", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["sign"] do
        assert exchange["sign"]["async"] == false,
               "Expected #{exchange["id"]} sign() to be sync, got async"
      end
    end
  end

  describe "sign() body AST structure" do
    test "body has type and body fields", %{by_id: by_id} do
      body = by_id["binance"]["sign"]["body"]

      assert is_map(body)

      assert Map.has_key?(body, :type) || Map.has_key?(body, "type"),
             "Body AST missing 'type' field"

      # Body contains a list of statements
      body_stmts = Map.get(body, :body) || Map.get(body, "body")
      assert is_list(body_stmts)
      assert length(body_stmts) >= 8
    end

    test "body AST nodes have type fields", %{by_id: by_id} do
      body = by_id["binance"]["sign"]["body"]
      stmts = Map.get(body, :body) || Map.get(body, "body")

      for stmt <- stmts do
        type = Map.get(stmt, :type) || Map.get(stmt, "type")
        assert is_binary(type), "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["sign"]["body"]

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
        assert Map.has_key?(exchange, "sign"), "Missing 'sign' key on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "Missing 'class_name' on #{exchange["id"]}"
      end
    end

    test "exchanges with sign have complete sign data", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["sign"] do
        sign = exchange["sign"]
        assert is_list(sign["params"]), "Missing params on #{exchange["id"]}"
        assert is_boolean(sign["async"]), "Missing async on #{exchange["id"]}"
        assert is_integer(sign["statements"]), "Missing statements on #{exchange["id"]}"
        assert is_map(sign["body"]), "Missing body on #{exchange["id"]}"
      end
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with correct envelope", %{exchanges: exchanges, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "sign_methods.json")

      # Exercise the real write!/2 path
      SignMethod.write!(exchanges, output_path)

      with_sign = Enum.count(exchanges, & &1["sign"])

      # Read back and verify
      parsed = output_path |> File.read!() |> Jason.decode!()
      assert parsed["count"] == length(exchanges)
      assert parsed["with_sign"] == with_sign
      assert is_list(parsed["exchanges"])
      assert is_binary(parsed["extracted_at"])

      # Verify JSON round-trip preserved body structure
      binance = Enum.find(parsed["exchanges"], &(&1["id"] == "binance"))
      assert binance["sign"]["body"]["type"]
      assert is_list(binance["sign"]["body"]["body"])
    end
  end

  describe "mix ccxt_extract.sign_methods" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.SignMethods)

      assert output =~ "Extracting sign() method AST"
      assert output =~ "Done."
      assert output =~ "with sign()"
      assert output =~ "Output: priv/discoveries/sign_methods.json"
    end
  end
end
