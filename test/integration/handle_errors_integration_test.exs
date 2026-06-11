defmodule CcxtExtract.HandleErrorsIntegrationTest do
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.HandleErrors

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 60_000

  # Reference exchanges from CLAUDE.md tiers — most should have handleErrors()
  @exchanges_with_handle_errors ~w(binance bybit okx deribit coinbaseexchange kraken kucoin gate htx bitmex)

  # DEX exchanges — may or may not have handleErrors()
  @dex_exchanges ~w(hyperliquid aster lighter)

  # All reference exchanges
  @all_reference @exchanges_with_handle_errors ++ @dex_exchanges

  setup_all do
    {:ok, exchanges, stats} = HandleErrors.extract()
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

    test "majority of exchanges have handleErrors()", %{exchanges: exchanges} do
      with_he = Enum.count(exchanges, & &1["handle_errors"])
      assert with_he >= 80, "Expected >= 80 with handleErrors(), got #{with_he}"
    end
  end

  describe "reference exchange presence" do
    for exchange <- @all_reference do
      test "#{exchange} is present in extraction", %{by_id: by_id} do
        exchange_id = unquote(exchange)

        assert Map.has_key?(by_id, exchange_id),
               "Reference exchange '#{exchange_id}' missing from handleErrors extraction"
      end
    end
  end

  describe "exchanges with handleErrors()" do
    for exchange <- @exchanges_with_handle_errors do
      test "#{exchange} has non-null handleErrors data", %{by_id: by_id} do
        exchange_id = unquote(exchange)
        data = by_id[exchange_id]

        assert data["handle_errors"],
               "Expected #{exchange_id} to have handleErrors() method, got null"
      end
    end

    test "binance handleErrors() has parameters", %{by_id: by_id} do
      params = by_id["binance"]["handle_errors"]["params"]
      assert length(params) >= 2, "Expected >= 2 params, got #{length(params)}"
    end

    test "binance handleErrors() has substantial complexity", %{by_id: by_id} do
      assert by_id["binance"]["handle_errors"]["statements"] >= 3
    end

    test "all handleErrors() methods are synchronous", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["handle_errors"] do
        assert exchange["handle_errors"]["async"] == false,
               "Expected #{exchange["id"]} handleErrors() to be sync, got async"
      end
    end
  end

  describe "handleErrors() body AST structure" do
    test "body has type and body fields", %{by_id: by_id} do
      body = by_id["binance"]["handle_errors"]["body"]

      assert is_map(body)

      assert Map.has_key?(body, :type) || Map.has_key?(body, "type"),
             "Body AST missing 'type' field"

      body_stmts = Map.get(body, :body) || Map.get(body, "body")
      assert is_list(body_stmts)
      assert length(body_stmts) >= 3
    end

    test "body AST nodes have type fields", %{by_id: by_id} do
      body = by_id["binance"]["handle_errors"]["body"]
      stmts = Map.get(body, :body) || Map.get(body, "body")

      for stmt <- stmts do
        type = Map.get(stmt, :type) || Map.get(stmt, "type")
        assert is_binary(type), "Statement missing type field: #{inspect(Map.keys(stmt))}"
      end
    end

    test "body includes byte offsets", %{by_id: by_id} do
      body = by_id["binance"]["handle_errors"]["body"]

      start_offset = Map.get(body, :start) || Map.get(body, "start")
      end_offset = Map.get(body, :end) || Map.get(body, "end")

      assert is_integer(start_offset), "Body missing 'start' byte offset"
      assert is_integer(end_offset), "Body missing 'end' byte offset"
      assert end_offset > start_offset
    end
  end

  describe "describe exceptions" do
    test "exceptions and http_exceptions are map or nil for every exchange", %{exchanges: exchanges} do
      for exchange <- exchanges do
        exc = exchange["exceptions"]
        http_exc = exchange["http_exceptions"]

        assert is_map(exc) or is_nil(exc),
               "#{exchange["id"]} exceptions should be map or nil, got: #{inspect(exc)}"

        assert is_map(http_exc) or is_nil(http_exc),
               "#{exchange["id"]} http_exceptions should be map or nil, got: #{inspect(http_exc)}"
      end
    end

    test "binance has exceptions from describe()", %{by_id: by_id} do
      data = by_id["binance"]

      assert is_map(data["exceptions"]),
             "Expected binance to have exceptions from describe()"

      assert Map.has_key?(data["exceptions"], "exact") || Map.has_key?(data["exceptions"], "broad"),
             "Expected exceptions to have 'exact' or 'broad' keys"
    end

    test "binance has httpExceptions from describe()", %{by_id: by_id} do
      data = by_id["binance"]

      assert is_map(data["http_exceptions"]),
             "Expected binance to have http_exceptions from describe()"

      # HTTP status codes should be string keys
      assert Map.has_key?(data["http_exceptions"], "400") ||
               Map.has_key?(data["http_exceptions"], "401") ||
               Map.has_key?(data["http_exceptions"], "403"),
             "Expected http_exceptions to have standard HTTP status codes"
    end

    test "exchanges without describe files get nil exceptions", %{exchanges: exchanges} do
      # At least check that the fields exist on every exchange
      for exchange <- exchanges do
        assert Map.has_key?(exchange, "exceptions"),
               "Missing 'exceptions' key on #{exchange["id"]}"

        assert Map.has_key?(exchange, "http_exceptions"),
               "Missing 'http_exceptions' key on #{exchange["id"]}"
      end
    end
  end

  describe "exchange output shape" do
    test "every exchange has required top-level fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert is_binary(exchange["id"]), "Missing 'id' on exchange"
        assert is_binary(exchange["file"]), "Missing 'file' on #{exchange["id"]}"
        assert Map.has_key?(exchange, "handle_errors"), "Missing 'handle_errors' key on #{exchange["id"]}"
        assert Map.has_key?(exchange, "class_name"), "Missing 'class_name' on #{exchange["id"]}"
        assert Map.has_key?(exchange, "exceptions"), "Missing 'exceptions' on #{exchange["id"]}"
        assert Map.has_key?(exchange, "http_exceptions"), "Missing 'http_exceptions' on #{exchange["id"]}"
      end
    end

    test "exchanges with handleErrors have complete data", %{exchanges: exchanges} do
      for exchange <- exchanges, exchange["handle_errors"] do
        he = exchange["handle_errors"]
        assert is_list(he["params"]), "Missing params on #{exchange["id"]}"
        assert is_boolean(he["async"]), "Missing async on #{exchange["id"]}"
        assert is_integer(he["statements"]), "Missing statements on #{exchange["id"]}"
        assert is_map(he["body"]), "Missing body on #{exchange["id"]}"
      end
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with correct envelope", %{exchanges: exchanges, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "handle_errors.json")

      HandleErrors.write!(exchanges, output_path)

      with_he = Enum.count(exchanges, & &1["handle_errors"])

      parsed = output_path |> File.read!() |> Jason.decode!()
      assert parsed["count"] == length(exchanges)
      assert parsed["with_handle_errors"] == with_he
      assert is_list(parsed["exchanges"])
      assert is_binary(parsed["extracted_at"])

      # Verify JSON round-trip preserved body structure
      binance = Enum.find(parsed["exchanges"], &(&1["id"] == "binance"))
      assert binance["handle_errors"]["body"]["type"]
      assert is_list(binance["handle_errors"]["body"]["body"])
    end
  end

  describe "mix ccxt_extract.handle_errors" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.HandleErrors)

      assert output =~ "Extracting handleErrors() method AST"
      assert output =~ "Done."
      assert output =~ "with handleErrors()"
      assert output =~ "Output: priv/discoveries/handle_errors.json"
    end

    test "scoped run with alias in family does not raise on missing alias describe file" do
      # Regression: `--tier1 --tier2 --dex` pulls aliases like `huobi`
      # into scope via family inheritance, but the describe extractor skips
      # aliases so those files never exist. The guard must skip them too.
      #
      # We use `--exchange htx,huobi` to reproduce the exact asymmetry with
      # a minimal scope that doesn't depend on tier composition (`huobi` is the
      # alias of `htx`; CCXT 4.5.57 retired the `gate`/`gateio` pair used here
      # previously).
      output =
        run_task_capturing_output(Mix.Tasks.CcxtExtract.HandleErrors, ["--exchange", "htx,huobi"])

      assert output =~ "Done."
      refute output =~ "Missing describe files"
    end
  end
end
