defmodule CcxtExtract.Integration.Cached.WsTradesSemanticsCachedTest do
  @moduledoc """
  Asserts against the committed `priv/discoveries/ws_trades_semantics.json`
  corpus.

  Fast — does not re-run extraction. Dispatches on observed counts, not
  envelope stamps, so it tolerates a scoped or full-universe corpus.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.WsTradesSemantics

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "ws_trades_semantics.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_trades"])
      assert is_integer(data["with_my_trades"])
      assert is_list(data["exchanges"])
    end

    test "envelope counts agree with the entries list", %{data: data} do
      entries = data["exchanges"]
      assert data["count"] == length(entries)
      assert data["with_trades"] == Enum.count(entries, &get_in(&1, ["trades", "defined"]))
      assert data["with_my_trades"] == Enum.count(entries, &get_in(&1, ["my_trades", "defined"]))
    end

    test "at least the WS universe is present on a full-universe corpus", %{data: data} do
      if full_universe?(data) do
        assert data["count"] >= 70, "full-universe ws_trades_semantics expected 70+ WS exchanges, got #{data["count"]}"
      else
        assert data["count"] > 0
      end
    end
  end

  describe "per-entry raw shape" do
    test "every entry carries the raw trades fact keys", %{exchanges: exchanges} do
      for e <- exchanges do
        assert is_binary(e["id"])
        assert Map.has_key?(e, "extends")

        for key <- ~w(trades my_trades) do
          record = e[key]

          assert match?(
                   %{
                     "defined" => _,
                     "update_model" => _,
                     "cache_type" => _,
                     "dedup_key" => _,
                     "cache_limit_field" => _,
                     "cache_limit_default" => _,
                     "unresolved" => _
                   },
                   record
                 )

          assert is_list(record["unresolved"])
        end
      end
    end

    test "unresolved findings carry a closed-vocabulary reason", %{exchanges: exchanges} do
      for e <- exchanges, key <- ~w(trades my_trades), u <- get_in(e, [key, "unresolved"]) do
        assert u["reason"] in WsTradesSemantics.unresolved_entry_reasons()
      end
    end
  end

  describe "derivation over the real corpus" do
    test "build/2 produces a schema-shaped, coherent record for every entry", %{exchanges: exchanges, by_id: by_id} do
      for e <- exchanges do
        record = WsTradesSemantics.build(e, by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsTradesSemantics.required_keys())
        assert record["update_model"] in WsTradesSemantics.update_models()
        assert record["source"] in WsTradesSemantics.sources()
        assert record["unresolved_reason"] in [nil | WsTradesSemantics.unresolved_reasons()]

        case record["update_model"] do
          "append" -> assert record["trades_defined"] == true
          "unknown" -> assert record["unresolved_reason"] == "trades_not_classifiable"
          "none" -> assert record["trades_defined"] == false
          _ -> :ok
        end
      end
    end

    test "priority exchanges with trade handlers resolve to known update models", %{by_id: by_id} do
      present =
        for id <- ~w(binance bybit okx deribit), entry = by_id[id], not is_nil(entry) do
          record = WsTradesSemantics.build(entry, by_id)
          assert record["update_model"] in WsTradesSemantics.update_models()
          id
        end

      assert present != [], "expected at least one priority WS exchange in the corpus"
    end
  end
end
