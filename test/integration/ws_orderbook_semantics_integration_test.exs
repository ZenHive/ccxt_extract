defmodule CcxtExtract.WsOrderbookSemanticsIntegrationTest do
  @moduledoc """
  Runs the `ws_orderbook_semantics` extractor against the real CCXT Pro source.

  Tagged `:extraction` — excluded by default; run with
  `mix test.json --include extraction`.
  """
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Paths
  alias CcxtExtract.WsOrderbookSemantics, as: OB

  @moduletag :extraction
  @moduletag :integration
  @moduletag timeout: 60_000

  describe "mix ccxt_extract.ws_orderbook_semantics" do
    test "extracts a well-formed orderbook-semantics discovery file from real Pro source" do
      output =
        run_task_capturing_output(Mix.Tasks.CcxtExtract.WsOrderbookSemantics, ["--tier1", "--dex"])

      assert output =~ "Extracting WebSocket orderbook semantics"
      assert output =~ "Done."
      assert output =~ "define an orderbook handler"
      assert output =~ "Output: priv/discoveries/ws_orderbook_semantics.json"

      data =
        "discoveries"
        |> Path.join("ws_orderbook_semantics.json")
        |> Paths.out()
        |> File.read!()
        |> Jason.decode!()

      assert data["tier_scope"] == ["tier1", "dex"]
      assert data["count"] == length(data["exchanges"])
      assert data["count"] > 0

      by_id = Map.new(data["exchanges"], &{&1["id"], &1})

      # bybit signals a full snapshot via a `type: 'snapshot'` discriminator
      # (the delta is the else-branch) — read straight off the handleOrderBook AST.
      bybit = OB.build(by_id["bybit"], by_id)
      assert bybit["handle_orderbook_defined"] == true
      assert bybit["discriminator"]["field"] == "type"
      assert "snapshot" in bybit["discriminator"]["snapshot_values"]
      assert bybit["apply_mode"] in ~w(incremental replace both)

      # okx discriminates snapshot/update on `action` and keys deltas by seqId.
      okx = OB.build(by_id["okx"], by_id)
      assert okx["handle_orderbook_defined"] == true
      assert okx["discriminator"]["field"] == "action"
      assert "snapshot" in okx["discriminator"]["snapshot_values"]
      assert "update" in okx["discriminator"]["delta_values"]
      assert "seqId" in okx["sequence_fields"]

      # binance keys deltas by first/final/previous update ids.
      binance = OB.build(by_id["binance"], by_id)
      assert "U" in binance["sequence_fields"]
      assert "u" in binance["sequence_fields"]

      # binanceusdm defines no orderbook handler of its own — it inherits binance's.
      if !get_in(by_id, ["binanceusdm", "orderbook", "defined"]) do
        binanceusdm = OB.build(by_id["binanceusdm"], by_id)
        assert binanceusdm["resolved_from"] == "binance"
        assert binanceusdm["handle_orderbook_defined"] == true
      end
    end
  end
end
