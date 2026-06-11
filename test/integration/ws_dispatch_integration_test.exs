defmodule CcxtExtract.WsDispatchIntegrationTest do
  @moduledoc """
  Runs the `ws_dispatch` extractor against the real CCXT Pro source.

  Tagged `:extraction` — excluded by default; run with
  `mix test.json --include extraction`.
  """
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Paths
  alias CcxtExtract.WsDispatch

  @moduletag :extraction
  @moduletag :integration
  @moduletag timeout: 60_000

  describe "mix ccxt_extract.ws_dispatch" do
    test "extracts a well-formed dispatch-table discovery file from real Pro source" do
      output =
        run_task_capturing_output(Mix.Tasks.CcxtExtract.WsDispatch, ["--tier1", "--dex"])

      assert output =~ "Extracting WebSocket dispatch tables"
      assert output =~ "Done."
      assert output =~ "define handleMessage()"
      assert output =~ "Output: priv/discoveries/ws_dispatch.json"

      data =
        "discoveries"
        |> Path.join("ws_dispatch.json")
        |> Paths.out()
        |> File.read!()
        |> Jason.decode!()

      assert data["tier_scope"] == ["tier1", "dex"]
      assert data["count"] == length(data["exchanges"])
      assert data["count"] > 0

      by_id = Map.new(data["exchanges"], &{&1["id"], &1})

      # Raw channel→handler facts read straight from the Pro-class
      # `handleMessage` AST. bybit dispatches kline frames to handleOHLCV.
      bybit_entries = get_in(by_id, ["bybit", "handle_message", "entries"])
      assert %{"channel" => "kline", "handler" => "handleOHLCV"} in bybit_entries
      assert "topic" in get_in(by_id, ["bybit", "handle_message", "discriminators"])

      # Derivation over the freshly-extracted entries.
      bybit = WsDispatch.build(by_id["bybit"], by_id)
      assert bybit["kind"] == "routed"
      assert bybit["resolved_from"] == "self"

      # binanceusdm defines no handleMessage() of its own — it inherits binance's.
      binanceusdm = WsDispatch.build(by_id["binanceusdm"], by_id)

      if !get_in(by_id, ["binanceusdm", "handle_message", "defined"]) do
        assert binanceusdm["resolved_from"] == "binance"
        assert binanceusdm["kind"] == "routed"
      end
    end
  end
end
