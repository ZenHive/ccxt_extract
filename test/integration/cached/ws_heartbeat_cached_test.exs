defmodule CcxtExtract.Integration.Cached.WsHeartbeatCachedTest do
  @moduledoc """
  Asserts against the committed `priv/discoveries/ws_heartbeat.json` corpus.

  Fast — does not re-run extraction. Dispatches on observed counts, not
  envelope stamps, so it tolerates a scoped or full-universe corpus.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.WsHeartbeat

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "ws_heartbeat.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_ping_method"])
      assert is_integer(data["with_pong_handler"])
      assert is_integer(data["with_streaming"])
      assert is_list(data["exchanges"])
    end

    test "envelope counts agree with the entries list", %{data: data} do
      entries = data["exchanges"]
      assert data["count"] == length(entries)
      assert data["with_ping_method"] == Enum.count(entries, &get_in(&1, ["ping", "defined"]))
      assert data["with_streaming"] == Enum.count(entries, &get_in(&1, ["streaming", "present"]))
    end

    test "at least the WS universe is present on a full-universe corpus", %{data: data} do
      if full_universe?(data) do
        assert data["count"] >= 70, "full-universe ws_heartbeat expected 70+ WS exchanges, got #{data["count"]}"
      else
        assert data["count"] > 0
      end
    end
  end

  describe "per-entry raw shape" do
    test "every entry carries the raw fact keys", %{exchanges: exchanges} do
      for e <- exchanges do
        assert is_binary(e["id"])
        assert Map.has_key?(e, "extends")
        assert match?(%{"defined" => _, "shape" => _, "return_value" => _}, e["ping"])
        assert match?(%{"pong" => _, "handlePong" => _, "handlePing" => _}, e["pong_methods"])
        assert match?(%{"present" => _, "keep_alive_ms" => _, "has_ping_property" => _}, e["streaming"])
      end
    end

    test "ping shape is always a known structural tag", %{exchanges: exchanges} do
      for e <- exchanges do
        assert e["ping"]["shape"] in [nil, "string", "object", "other"]
      end
    end
  end

  describe "derivation over the real corpus" do
    test "build/2 produces a schema-shaped record for every entry", %{exchanges: exchanges, by_id: by_id} do
      for e <- exchanges do
        record = WsHeartbeat.build(e, by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsHeartbeat.required_keys())
        assert record["ping_kind"] in WsHeartbeat.ping_kinds()
        assert record["source"] in WsHeartbeat.sources()
        assert record["unresolved_reason"] in [nil | WsHeartbeat.unresolved_reasons()]
      end
    end

    test "priority exchanges resolve to their expected heartbeat", %{by_id: by_id} do
      expected = %{
        "binance" => %{"ping_kind" => "native_frame", "keep_alive_ms" => 180_000, "keep_alive_resolved_from" => "self"},
        "binanceusdm" => %{
          "ping_kind" => "native_frame",
          "keep_alive_ms" => 180_000,
          "keep_alive_resolved_from" => "binance"
        },
        "bybit" => %{"ping_kind" => "json_message", "keep_alive_ms" => 18_000, "ping_payload" => %{"op" => "ping"}},
        "okx" => %{"ping_kind" => "string_message", "keep_alive_ms" => 18_000, "ping_payload" => "ping"},
        "deribit" => %{"ping_kind" => "native_frame", "keep_alive_ms" => 30_000, "source" => "base_default"},
        "hyperliquid" => %{
          "ping_kind" => "json_message",
          "keep_alive_ms" => 20_000,
          "ping_payload" => %{"method" => "ping"}
        },
        "derive" => %{"ping_kind" => "native_frame", "keep_alive_ms" => 9000}
      }

      present =
        for {id, want} <- expected, entry = by_id[id], not is_nil(entry) do
          record = WsHeartbeat.build(entry, by_id)

          for {key, value} <- want do
            assert record[key] == value, "#{id}.#{key}: expected #{inspect(value)}, got #{inspect(record[key])}"
          end

          id
        end

      assert present != [], "expected at least one priority exchange in the corpus"
    end
  end
end
