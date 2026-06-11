defmodule CcxtExtract.Integration.Cached.WsSubscribeCachedTest do
  @moduledoc """
  Asserts against the committed `priv/discoveries/ws_subscribe.json` corpus.

  Fast — does not re-run extraction. Dispatches on observed counts, not
  envelope stamps, so it tolerates a scoped or full-universe corpus.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.WsSubscribe

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "ws_subscribe.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_envelope"])
      assert is_integer(data["with_channels"])
      assert is_list(data["exchanges"])
    end

    test "envelope counts agree with the entries list", %{data: data} do
      entries = data["exchanges"]
      assert data["count"] == length(entries)

      assert data["with_envelope"] ==
               Enum.count(entries, &(not is_nil(get_in(&1, ["envelope", "discriminant"]))))

      assert data["with_channels"] == Enum.count(entries, &(map_size(&1["channels"]) > 0))
    end

    test "at least the WS universe is present on a full-universe corpus", %{data: data} do
      if full_universe?(data) do
        assert data["count"] >= 70, "full-universe ws_subscribe expected 70+ WS exchanges, got #{data["count"]}"
      else
        assert data["count"] > 0
      end
    end
  end

  describe "per-entry raw shape" do
    test "every entry carries the raw envelope + channels fact keys", %{exchanges: exchanges} do
      for e <- exchanges do
        assert is_binary(e["id"])
        assert Map.has_key?(e, "extends")
        env = e["envelope"]

        assert match?(
                 %{
                   "discriminant" => _,
                   "subscribe" => _,
                   "unsubscribe" => _,
                   "args_key" => _,
                   "subscribe_keys" => _,
                   "unsubscribe_keys" => _
                 },
                 env
               )

        assert is_list(env["subscribe_keys"])
        assert is_map(e["channels"])
      end
    end

    test "every channel template list is a list of strings", %{exchanges: exchanges} do
      for e <- exchanges, {_method, templates} <- e["channels"] do
        assert is_list(templates)
        assert Enum.all?(templates, &is_binary/1)
      end
    end
  end

  describe "derivation over the real corpus" do
    test "build/2 produces a schema-shaped record for every entry", %{exchanges: exchanges, by_id: by_id} do
      for e <- exchanges do
        record = WsSubscribe.build(e, by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsSubscribe.required_keys())
        assert record["mechanism"] in WsSubscribe.mechanisms()
        assert record["source"] in WsSubscribe.sources()
        assert record["unresolved_reason"] in [nil | WsSubscribe.unresolved_reasons()]
      end
    end

    test "priority exchanges resolve to their expected subscribe envelope", %{by_id: by_id} do
      expected = %{
        "bybit" => %{"mechanism" => "json_message", "discriminant" => "op", "subscribe_op" => "subscribe"},
        "okx" => %{"mechanism" => "json_message", "discriminant" => "op", "subscribe_op" => "subscribe"},
        "binance" => %{"mechanism" => "json_message", "discriminant" => "method", "subscribe_op" => "SUBSCRIBE"}
      }

      present =
        for {id, want} <- expected, entry = by_id[id], not is_nil(entry) do
          record = WsSubscribe.build(entry, by_id)

          for {key, value} <- want do
            assert record[key] == value, "#{id}.#{key}: expected #{inspect(value)}, got #{inspect(record[key])}"
          end

          id
        end

      assert present != [], "expected at least one priority exchange in the corpus"
    end

    test "binanceusdm inherits binance's subscribe envelope via the extends chain", %{by_id: by_id} do
      if entry = by_id["binanceusdm"] do
        record = WsSubscribe.build(entry, by_id)
        assert record["mechanism"] == "json_message"
        assert record["resolved_from"] == "binance"
      end
    end

    test "at least one exchange carries a resolved channel template", %{exchanges: exchanges, by_id: by_id} do
      with_channels =
        Enum.filter(exchanges, fn e ->
          record = WsSubscribe.build(e, by_id)
          map_size(record["channels"]) > 0
        end)

      assert with_channels != [], "expected at least one exchange with resolved channel templates"
    end
  end
end
