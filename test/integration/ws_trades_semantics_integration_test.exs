defmodule CcxtExtract.WsTradesSemanticsIntegrationTest do
  @moduledoc """
  Runs the `ws_trades_semantics` extractor against the real CCXT Pro source.

  Tagged `:extraction` — excluded by default; run with
  `mix test.json --include extraction`.
  """
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Paths
  alias CcxtExtract.WsTradesSemantics

  @moduletag :extraction
  @moduletag :integration
  @moduletag timeout: 60_000

  describe "mix ccxt_extract.ws_trades_semantics" do
    test "extracts a well-formed trades-semantics discovery file from real Pro source" do
      output =
        run_task_capturing_output(Mix.Tasks.CcxtExtract.WsTradesSemantics, ["--tier1", "--dex"])

      assert output =~ "Extracting WebSocket trades semantics"
      assert output =~ "Done."
      assert output =~ "define handleTrade(s)"
      assert output =~ "Output: priv/discoveries/ws_trades_semantics.json"

      data =
        "discoveries"
        |> Path.join("ws_trades_semantics.json")
        |> Paths.out()
        |> File.read!()
        |> Jason.decode!()

      assert data["tier_scope"] == ["tier1", "dex"]
      assert data["count"] == length(data["exchanges"])
      assert data["count"] > 0

      by_id = Map.new(data["exchanges"], &{&1["id"], &1})
      present = Enum.filter(~w(binance bybit okx deribit), &Map.has_key?(by_id, &1))
      assert present != [], "expected at least one priority WS exchange in the scoped corpus"

      for id <- present do
        record = WsTradesSemantics.build(by_id[id], by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsTradesSemantics.required_keys())
        assert record["update_model"] in WsTradesSemantics.update_models()
      end
    end
  end
end
