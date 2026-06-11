defmodule CcxtExtract.Integration.Cached.WsOrderbookSemanticsCachedTest do
  @moduledoc """
  Asserts against the committed `priv/discoveries/ws_orderbook_semantics.json`
  corpus.

  Fast — does not re-run extraction. Dispatches on observed counts, not
  envelope stamps, so it tolerates a scoped or full-universe corpus.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.WsOrderbookSemantics, as: OB

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "ws_orderbook_semantics.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_handle_orderbook"])
      assert is_integer(data["with_discriminator"])
      assert is_integer(data["with_checksum"])
      assert is_list(data["exchanges"])
    end

    test "envelope counts agree with the entries list", %{data: data} do
      entries = data["exchanges"]
      assert data["count"] == length(entries)

      assert data["with_handle_orderbook"] ==
               Enum.count(entries, &get_in(&1, ["orderbook", "defined"]))

      assert data["with_checksum"] ==
               Enum.count(entries, &get_in(&1, ["orderbook", "checksum", "present"]))
    end

    test "at least the WS universe is present on a full-universe corpus", %{data: data} do
      if full_universe?(data) do
        assert data["count"] >= 70, "full-universe expected 70+ WS exchanges, got #{data["count"]}"
      else
        assert data["count"] > 0
      end
    end
  end

  describe "per-entry raw shape" do
    test "every entry carries the raw orderbook fact keys", %{exchanges: exchanges} do
      for e <- exchanges do
        assert is_binary(e["id"])
        assert Map.has_key?(e, "extends")
        o = e["orderbook"]

        assert match?(
                 %{
                   "defined" => _,
                   "comparisons" => _,
                   "sequence_keys" => _,
                   "checksum" => _,
                   "applies_deltas" => _,
                   "resets_book" => _
                 },
                 o
               )

        assert is_list(o["comparisons"])
        assert is_list(o["sequence_keys"])
        assert is_boolean(o["applies_deltas"])
        assert is_boolean(o["resets_book"])
      end
    end

    test "comparisons are field→value string pairs", %{exchanges: exchanges} do
      for e <- exchanges, c <- get_in(e, ["orderbook", "comparisons"]) do
        assert is_binary(c["field"])
        assert is_binary(c["value"])
      end
    end

    test "checksum facts are coherent: present implies a field or crc32 algorithm", %{exchanges: exchanges} do
      for e <- exchanges do
        cs = get_in(e, ["orderbook", "checksum"])

        if cs["present"] do
          assert cs["field"] != nil or cs["algorithm"] == "crc32"
        else
          assert is_nil(cs["field"])
          assert is_nil(cs["algorithm"])
        end
      end
    end
  end

  describe "derivation over the real corpus" do
    test "build/2 produces a schema-shaped, coherent record for every entry", %{exchanges: exchanges, by_id: by_id} do
      for e <- exchanges do
        record = OB.build(e, by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(OB.required_keys())
        assert record["apply_mode"] in OB.apply_modes()
        assert record["source"] in OB.sources()
        assert record["unresolved_reason"] in [nil | OB.unresolved_reasons()]

        disc = record["discriminator"]
        assert Enum.all?(disc["snapshot_values"], &(&1 in OB.snapshot_value_vocab()))
        assert Enum.all?(disc["delta_values"], &(&1 in OB.delta_value_vocab()))
        assert Enum.all?(record["sequence_fields"], &(&1 in OB.sequence_field_vocab()))

        case record["apply_mode"] do
          "none" ->
            assert record["handle_orderbook_defined"] == false
            assert record["source"] == "none"

          "unknown" ->
            assert record["unresolved_reason"] == "orderbook_not_classifiable"

          mode when mode in ~w(incremental replace both) ->
            assert record["handle_orderbook_defined"] == true
            assert is_nil(record["unresolved_reason"])
        end
      end
    end

    test "priority exchanges resolve to a defined orderbook handler", %{by_id: by_id} do
      present =
        for id <- ~w(binance okx bybit deribit), entry = by_id[id], not is_nil(entry) do
          record = OB.build(entry, by_id)
          assert record["handle_orderbook_defined"] == true, "#{id}: expected a defined handler"
          assert record["apply_mode"] in ~w(incremental replace both unknown)
          id
        end

      assert present != [], "expected at least one priority WS exchange in the corpus"
    end

    test "binanceusdm inherits binance's orderbook semantics via the extends chain", %{by_id: by_id} do
      if entry = by_id["binanceusdm"] do
        record = OB.build(entry, by_id)

        if !get_in(entry, ["orderbook", "defined"]) do
          assert record["resolved_from"] == "binance"
          assert record["handle_orderbook_defined"] == true
        end
      end
    end
  end
end
