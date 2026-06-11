defmodule CcxtExtract.Integration.Cached.WsOhlcvSemanticsCachedTest do
  @moduledoc """
  Asserts against the committed `priv/discoveries/ws_ohlcv_semantics.json`
  corpus.

  Fast — does not re-run extraction. Dispatches on observed counts, not
  envelope stamps, so it tolerates a scoped or full-universe corpus.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.WsOhlcvSemantics

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "ws_ohlcv_semantics.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_ohlcv"])
      assert is_list(data["exchanges"])
    end

    test "envelope counts agree with the entries list", %{data: data} do
      entries = data["exchanges"]
      assert data["count"] == length(entries)
      assert data["with_ohlcv"] == Enum.count(entries, &get_in(&1, ["ohlcv", "defined"]))
    end

    test "at least the WS universe is present on a full-universe corpus", %{data: data} do
      if full_universe?(data) do
        assert data["count"] >= 70, "full-universe ws_ohlcv_semantics expected 70+ WS exchanges, got #{data["count"]}"
      else
        assert data["count"] > 0
      end
    end
  end

  describe "per-entry raw shape" do
    test "every entry carries the raw ohlcv fact keys", %{exchanges: exchanges} do
      for e <- exchanges do
        assert is_binary(e["id"])
        assert Map.has_key?(e, "extends")

        record = e["ohlcv"]

        assert match?(
                 %{
                   "defined" => _,
                   "update_model" => _,
                   "timeframe_key" => _,
                   "closed_signal" => _,
                   "cache_type" => _,
                   "cache_limit_field" => _,
                   "cache_limit_default" => _,
                   "unresolved" => _
                 },
                 record
               )

        assert is_list(record["unresolved"])
      end
    end

    test "unresolved findings carry a closed-vocabulary reason", %{exchanges: exchanges} do
      for e <- exchanges, u <- get_in(e, ["ohlcv", "unresolved"]) do
        assert u["reason"] in WsOhlcvSemantics.unresolved_entry_reasons()
      end
    end
  end

  describe "derivation over the real corpus" do
    test "build/2 produces a schema-shaped, coherent record for every entry", %{exchanges: exchanges, by_id: by_id} do
      for e <- exchanges do
        record = WsOhlcvSemantics.build(e, by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsOhlcvSemantics.required_keys())
        assert record["update_model"] in WsOhlcvSemantics.update_models()
        assert record["source"] in WsOhlcvSemantics.sources()
        assert record["unresolved_reason"] in [nil | WsOhlcvSemantics.unresolved_reasons()]

        case record["update_model"] do
          "replace_latest_then_append" -> assert record["ohlcv_defined"] == true
          "unknown" -> assert record["unresolved_reason"] == "ohlcv_not_classifiable"
          "none" -> assert record["ohlcv_defined"] == false
          _ -> :ok
        end
      end
    end

    test "priority exchanges with ohlcv handlers resolve to known update model", %{by_id: by_id} do
      present =
        for id <- ~w(binance bybit okx deribit), entry = by_id[id], not is_nil(entry) do
          record = WsOhlcvSemantics.build(entry, by_id)
          assert record["update_model"] in WsOhlcvSemantics.update_models()
          id
        end

      assert present != [], "expected at least one priority WS exchange in the corpus"
    end
  end
end
