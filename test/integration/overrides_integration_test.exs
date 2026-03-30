defmodule CcxtExtract.OverridesIntegrationTest do
  # async: false — run_task_capturing_output mutates global Mix.shell
  use ExUnit.Case, async: false

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Overrides

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 120_000

  # REST variants that extend another exchange (not Exchange base)
  @rest_variants ~w(binanceus binancecoinm binanceusdm)

  # WS exchanges that extend their REST counterpart
  @ws_exchanges ~w(binance bybit okx deribit kraken kucoin gate htx bitmex)

  setup_all do
    {:ok, exchanges, stats} = Overrides.extract()
    by_key = Map.new(exchanges, &{"#{&1["type"]}:#{&1["id"]}", &1})
    %{exchanges: exchanges, stats: stats, by_key: by_key}
  end

  describe "extract/0 overall" do
    test "extracts without errors", %{stats: stats} do
      assert stats.errors == [], "Parse errors: #{inspect(stats.errors)}"
    end

    test "stats include class hierarchy errors and skipped", %{stats: stats} do
      assert is_list(stats.class_errors), "missing class_errors in stats"
      assert is_list(stats.class_skipped), "missing class_skipped in stats"
    end

    test "extracts at least 80 derived exchanges", %{exchanges: exchanges} do
      assert length(exchanges) >= 80
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "no exchange extends Exchange directly", %{exchanges: exchanges} do
      for exchange <- exchanges do
        refute exchange["parent_key"] == "Exchange",
               "#{exchange["node_key"]} should not extend Exchange directly"
      end
    end

    test "all exchanges have overrides", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert exchange["override_count"] > 0,
               "#{exchange["node_key"]} has no overrides"
      end
    end
  end

  describe "exchange structure" do
    test "every exchange has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        nk = exchange["node_key"]
        assert is_binary(exchange["id"]), "missing id on #{nk}"
        assert is_binary(exchange["type"]), "missing type on #{nk}"
        assert is_binary(exchange["file"]), "missing file on #{nk}"
        assert is_binary(exchange["node_key"]), "missing node_key"
        assert is_binary(exchange["parent_key"]), "missing parent_key on #{nk}"
        assert is_binary(exchange["extends"]), "missing extends on #{nk}"
        assert is_integer(exchange["own_method_count"]), "missing own_method_count on #{nk}"
        assert is_integer(exchange["override_count"]), "missing override_count on #{nk}"
        assert is_integer(exchange["new_method_count"]), "missing new_method_count on #{nk}"
        assert is_integer(exchange["inherited_count"]), "missing inherited_count on #{nk}"
        assert is_map(exchange["overrides"]), "missing overrides on #{nk}"
        assert is_map(exchange["new_methods"]), "missing new_methods on #{nk}"
        assert is_list(exchange["inherited_methods"]), "missing inherited_methods on #{nk}"
      end
    end

    test "own_method_count = override_count + new_method_count", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert exchange["own_method_count"] ==
                 exchange["override_count"] + exchange["new_method_count"],
               "Count mismatch on #{exchange["node_key"]}"
      end
    end

    test "inherited_methods are sorted", %{exchanges: exchanges} do
      for exchange <- exchanges do
        inherited = exchange["inherited_methods"]
        assert inherited == Enum.sort(inherited), "Unsorted inherited on #{exchange["node_key"]}"
      end
    end
  end

  describe "method data structure" do
    test "all overrides have required fields", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["overrides"] do
        nk = exchange["node_key"]
        assert is_list(data["params"]), "missing params on #{nk}.#{name}"
        assert is_boolean(data["async"]), "missing async on #{nk}.#{name}"
        assert is_integer(data["statements"]), "missing statements on #{nk}.#{name}"
        assert is_map(data["body"]), "missing body on #{nk}.#{name}"
      end
    end

    test "all new methods have required fields", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["new_methods"] do
        nk = exchange["node_key"]
        assert is_list(data["params"]), "missing params on #{nk}.#{name}"
        assert is_boolean(data["async"]), "missing async on #{nk}.#{name}"
        assert is_integer(data["statements"]), "missing statements on #{nk}.#{name}"
        assert is_map(data["body"]), "missing body on #{nk}.#{name}"
      end
    end

    test "override body ASTs have byte offsets", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["overrides"] do
        body = data["body"]
        start_offset = Map.get(body, :start) || Map.get(body, "start")
        end_offset = Map.get(body, :end) || Map.get(body, "end")

        assert is_integer(start_offset), "missing start on #{exchange["node_key"]}.#{name}"
        assert is_integer(end_offset), "missing end on #{exchange["node_key"]}.#{name}"
        assert end_offset > start_offset, "invalid offsets on #{exchange["node_key"]}.#{name}"
      end
    end
  end

  describe "REST variant spot checks" do
    for variant <- @rest_variants do
      test "rest:#{variant} extends binance and overrides describe", %{by_key: by_key} do
        key = "rest:" <> unquote(variant)
        assert Map.has_key?(by_key, key), "Missing #{key}"

        exchange = by_key[key]
        assert exchange["extends"] == "binance"
        assert Map.has_key?(exchange["overrides"], "describe")
      end
    end

    test "rest:binanceus has 1 override and no new methods", %{by_key: by_key} do
      exchange = by_key["rest:binanceus"]
      assert exchange["override_count"] == 1
      assert exchange["new_method_count"] == 0
      assert exchange["inherited_count"] >= 150
    end
  end

  describe "WS exchange spot checks" do
    for ws_id <- @ws_exchanges do
      test "ws:#{ws_id} overrides describe", %{by_key: by_key} do
        key = "ws:" <> unquote(ws_id)
        assert Map.has_key?(by_key, key), "Missing #{key}"
        assert Map.has_key?(by_key[key]["overrides"], "describe")
      end
    end

    test "ws:binance has many new methods", %{by_key: by_key} do
      exchange = by_key["ws:binance"]
      assert exchange["new_method_count"] >= 50

      new_names = Map.keys(exchange["new_methods"])
      assert Enum.any?(new_names, &String.starts_with?(&1, "watch"))
      assert Enum.any?(new_names, &String.starts_with?(&1, "handle"))
    end
  end

  describe "describe is universal override" do
    test "every derived exchange overrides describe", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert Map.has_key?(exchange["overrides"], "describe"),
               "Expected #{exchange["node_key"]} to override describe"
      end
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with correct envelope", %{exchanges: exchanges, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "overrides.json")

      summary = Overrides.write!(exchanges, output_path)

      assert is_integer(summary.with_overrides)
      assert is_integer(summary.total_overrides)
      assert is_integer(summary.total_new)

      parsed = output_path |> File.read!() |> Jason.decode!()
      assert parsed["count"] == length(exchanges)
      assert is_integer(parsed["with_overrides"])
      assert is_integer(parsed["total_overrides"])
      assert is_integer(parsed["total_new_methods"])
      assert is_list(parsed["exchanges"])
      assert is_binary(parsed["extracted_at"])

      # Verify JSON round-trip preserved body structure
      binanceus = Enum.find(parsed["exchanges"], &(&1["id"] == "binanceus" and &1["type"] == "rest"))
      describe = binanceus["overrides"]["describe"]
      assert describe["body"]["type"]
      assert is_list(describe["body"]["body"])
    end
  end

  describe "mix ccxt_extract.overrides" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.Overrides)

      assert output =~ "Extracting method overrides"
      assert output =~ "Done."
      assert output =~ "with overrides"
      assert output =~ "Output: priv/discoveries/overrides.json"
    end
  end
end
