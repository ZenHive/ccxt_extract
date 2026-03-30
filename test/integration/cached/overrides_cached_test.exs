defmodule CcxtExtract.Integration.Cached.OverridesCachedTest do
  @moduledoc """
  Structure tests for overrides.json — reads cached discovery output.
  Same assertions as OverridesIntegrationTest but without OXC parsing.
  """
  use ExUnit.Case, async: true

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixtures_dir Path.expand("../../fixtures/discoveries", __DIR__)
  @fixture_path Path.join(@fixtures_dir, "overrides.json")

  # Reference derived exchanges with known override patterns
  @rest_variants ~w(binanceus binancecoinm binanceusdm)
  @ws_exchanges ~w(binance bybit okx deribit kraken kucoin gate htx bitmex)

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_key = Map.new(data["exchanges"], &{"#{&1["type"]}:#{&1["id"]}", &1})
    %{data: data, exchanges: data["exchanges"], by_key: by_key}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_overrides"])
      assert is_integer(data["total_overrides"])
      assert is_integer(data["total_new_methods"])
      assert is_list(data["exchanges"])
    end

    test "counts are consistent", %{data: data} do
      assert data["count"] == length(data["exchanges"])

      actual_with_overrides = Enum.count(data["exchanges"], fn e -> e["override_count"] > 0 end)
      assert data["with_overrides"] == actual_with_overrides

      actual_total_overrides = Enum.sum(Enum.map(data["exchanges"], & &1["override_count"]))
      assert data["total_overrides"] == actual_total_overrides

      actual_total_new = Enum.sum(Enum.map(data["exchanges"], & &1["new_method_count"]))
      assert data["total_new_methods"] == actual_total_new
    end

    test "at least 80 derived exchanges", %{data: data} do
      assert data["count"] >= 80
    end

    test "all derived exchanges have overrides", %{data: data} do
      # Every exchange that extends another should override at least describe
      assert data["with_overrides"] == data["count"]
    end
  end

  describe "exchange structure" do
    test "every exchange has required fields", %{exchanges: exchanges} do
      for exchange <- exchanges do
        id = exchange["id"]
        assert is_binary(id), "missing id"
        assert is_binary(exchange["type"]), "missing type on #{id}"
        assert is_binary(exchange["file"]), "missing file on #{id}"
        assert is_binary(exchange["node_key"]), "missing node_key on #{id}"
        assert is_binary(exchange["parent_key"]), "missing parent_key on #{id}"
        assert is_binary(exchange["extends"]), "missing extends on #{id}"
        assert is_integer(exchange["own_method_count"]), "missing own_method_count on #{id}"
        assert is_integer(exchange["override_count"]), "missing override_count on #{id}"
        assert is_integer(exchange["new_method_count"]), "missing new_method_count on #{id}"
        assert is_integer(exchange["inherited_count"]), "missing inherited_count on #{id}"
        assert is_map(exchange["overrides"]), "missing overrides on #{id}"
        assert is_map(exchange["new_methods"]), "missing new_methods on #{id}"
        assert is_list(exchange["inherited_methods"]), "missing inherited_methods on #{id}"
      end
    end

    test "exchanges are sorted by id", %{exchanges: exchanges} do
      ids = Enum.map(exchanges, & &1["id"])
      assert ids == Enum.sort(ids)
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

    test "no exchange extends Exchange directly", %{exchanges: exchanges} do
      for exchange <- exchanges do
        refute exchange["parent_key"] == "Exchange",
               "#{exchange["node_key"]} should not extend Exchange directly"
      end
    end
  end

  describe "method data completeness" do
    test "all override entries have required fields", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["overrides"] do
        assert is_list(data["params"]), "missing params on #{exchange["node_key"]}.#{name}"
        assert is_boolean(data["async"]), "missing async on #{exchange["node_key"]}.#{name}"
        assert is_integer(data["statements"]), "missing statements on #{exchange["node_key"]}.#{name}"
        assert is_map(data["body"]), "missing body on #{exchange["node_key"]}.#{name}"
      end
    end

    test "all new_method entries have required fields", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["new_methods"] do
        assert is_list(data["params"]), "missing params on #{exchange["node_key"]}.#{name}"
        assert is_boolean(data["async"]), "missing async on #{exchange["node_key"]}.#{name}"
        assert is_integer(data["statements"]), "missing statements on #{exchange["node_key"]}.#{name}"
        assert is_map(data["body"]), "missing body on #{exchange["node_key"]}.#{name}"
      end
    end

    test "override body ASTs have byte offsets", %{exchanges: exchanges} do
      for exchange <- exchanges,
          {name, data} <- exchange["overrides"] do
        body = data["body"]
        assert is_integer(body["start"]), "missing start on #{exchange["node_key"]}.#{name}"
        assert is_integer(body["end"]), "missing end on #{exchange["node_key"]}.#{name}"
        assert body["end"] > body["start"], "invalid offsets on #{exchange["node_key"]}.#{name}"
      end
    end
  end

  # REST variant spot checks
  for variant <- @rest_variants do
    test "rest:#{variant} overrides describe", %{by_key: by_key} do
      key = "rest:" <> unquote(variant)
      assert Map.has_key?(by_key, key), "Missing #{key}"

      exchange = by_key[key]
      assert exchange["extends"] == "binance"

      assert Map.has_key?(exchange["overrides"], "describe"),
             "Expected #{key} to override describe"
    end
  end

  test "rest:binanceus has no new methods (only describe override)", %{by_key: by_key} do
    exchange = by_key["rest:binanceus"]
    assert exchange["override_count"] == 1
    assert exchange["new_method_count"] == 0
    assert exchange["inherited_count"] >= 150
  end

  # WS exchange spot checks
  for ws_id <- @ws_exchanges do
    test "ws:#{ws_id} is present and overrides describe", %{by_key: by_key} do
      key = "ws:" <> unquote(ws_id)
      assert Map.has_key?(by_key, key), "Missing #{key}"

      exchange = by_key[key]

      assert Map.has_key?(exchange["overrides"], "describe"),
             "Expected #{key} to override describe"
    end
  end

  test "ws:binance has many new methods (watch/handle)", %{by_key: by_key} do
    exchange = by_key["ws:binance"]
    assert exchange["new_method_count"] >= 50
    new_names = Map.keys(exchange["new_methods"])

    # Should have watch and handle methods
    assert Enum.any?(new_names, &String.starts_with?(&1, "watch")),
           "Expected ws:binance to have watch* new methods"

    assert Enum.any?(new_names, &String.starts_with?(&1, "handle")),
           "Expected ws:binance to have handle* new methods"
  end

  describe "describe is universal override" do
    test "every derived exchange overrides describe", %{exchanges: exchanges} do
      for exchange <- exchanges do
        assert Map.has_key?(exchange["overrides"], "describe"),
               "Expected #{exchange["node_key"]} to override describe"
      end
    end
  end
end
