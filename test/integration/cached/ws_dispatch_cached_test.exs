defmodule CcxtExtract.Integration.Cached.WsDispatchCachedTest do
  @moduledoc """
  Asserts against the committed `priv/discoveries/ws_dispatch.json` corpus.

  Fast — does not re-run extraction. Dispatches on observed counts, not
  envelope stamps, so it tolerates a scoped or full-universe corpus.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.WsDispatch

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "ws_dispatch.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_handle_message"])
      assert is_integer(data["with_entries"])
      assert is_list(data["exchanges"])
    end

    test "envelope counts agree with the entries list", %{data: data} do
      entries = data["exchanges"]
      assert data["count"] == length(entries)
      assert data["with_handle_message"] == Enum.count(entries, &get_in(&1, ["handle_message", "defined"]))

      assert data["with_entries"] ==
               Enum.count(entries, &(get_in(&1, ["handle_message", "entries"]) not in [nil, []]))
    end

    test "at least the WS universe is present on a full-universe corpus", %{data: data} do
      if full_universe?(data) do
        assert data["count"] >= 70, "full-universe ws_dispatch expected 70+ WS exchanges, got #{data["count"]}"
      else
        assert data["count"] > 0
      end
    end
  end

  describe "per-entry raw shape" do
    test "every entry carries the raw handle_message fact keys", %{exchanges: exchanges} do
      for e <- exchanges do
        assert is_binary(e["id"])
        assert Map.has_key?(e, "extends")
        hm = e["handle_message"]

        assert match?(
                 %{"defined" => _, "discriminators" => _, "entries" => _, "unresolved" => _},
                 hm
               )

        assert is_list(hm["discriminators"])
        assert is_list(hm["entries"])
        assert is_list(hm["unresolved"])
      end
    end

    test "entries are channel→handler string pairs with a handle* handler", %{exchanges: exchanges} do
      for e <- exchanges, pair <- get_in(e, ["handle_message", "entries"]) do
        assert is_binary(pair["channel"])
        assert is_binary(pair["handler"])
        assert String.starts_with?(pair["handler"], "handle")
      end
    end

    test "unresolved findings carry a closed-vocabulary reason", %{exchanges: exchanges} do
      for e <- exchanges, u <- get_in(e, ["handle_message", "unresolved"]) do
        assert u["reason"] in WsDispatch.unresolved_entry_reasons()
      end
    end
  end

  describe "derivation over the real corpus" do
    test "build/2 produces a schema-shaped, coherent record for every entry", %{exchanges: exchanges, by_id: by_id} do
      for e <- exchanges do
        record = WsDispatch.build(e, by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsDispatch.required_keys())
        assert record["kind"] in WsDispatch.kinds()
        assert record["source"] in WsDispatch.sources()
        assert record["unresolved_reason"] in [nil | WsDispatch.unresolved_reasons()]

        case record["kind"] do
          "routed" -> assert record["entries"] != []
          "opaque" -> assert record["unresolved_reason"] == "dispatch_not_classifiable"
          "none" -> assert record["handle_message_defined"] == false
        end
      end
    end

    test "priority exchanges resolve to a routed table with known handlers", %{by_id: by_id} do
      expected = %{
        "bybit" => "handleOHLCV",
        "binance" => "handleOrderBook",
        "okx" => "handleOrderBook",
        "hashkey" => "handleOHLCV"
      }

      present =
        for {id, handler} <- expected, entry = by_id[id], not is_nil(entry) do
          record = WsDispatch.build(entry, by_id)
          assert record["kind"] == "routed", "#{id}: expected routed, got #{record["kind"]}"
          handlers = Enum.map(record["entries"], & &1["handler"])
          assert handler in handlers, "#{id}: expected #{handler} among #{inspect(Enum.uniq(handlers))}"
          id
        end

      assert present != [], "expected at least one priority WS exchange in the corpus"
    end

    test "binanceusdm inherits binance's dispatch table via the extends chain", %{by_id: by_id} do
      if entry = by_id["binanceusdm"] do
        record = WsDispatch.build(entry, by_id)

        if !get_in(entry, ["handle_message", "defined"]) do
          assert record["resolved_from"] == "binance"
          assert record["kind"] == "routed"
        end
      end
    end
  end
end
