defmodule CcxtExtract.WsSubscribeIntegrationTest do
  @moduledoc """
  Runs the `ws_subscribe` extractor against the real CCXT Pro source.

  Tagged `:extraction` — excluded by default; run with
  `mix test.json --include extraction`.
  """
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Paths
  alias CcxtExtract.WsSubscribe

  @moduletag :extraction
  @moduletag :integration
  @moduletag timeout: 60_000

  describe "mix ccxt_extract.ws_subscribe" do
    test "extracts a well-formed subscribe discovery file from real Pro source" do
      output =
        run_task_capturing_output(Mix.Tasks.CcxtExtract.WsSubscribe, ["--tier1", "--dex"])

      assert output =~ "Extracting WebSocket subscribe/unsubscribe shapes"
      assert output =~ "Done."
      assert output =~ "classify a subscribe envelope"
      assert output =~ "Output: priv/discoveries/ws_subscribe.json"

      data =
        "discoveries"
        |> Path.join("ws_subscribe.json")
        |> Paths.out()
        |> File.read!()
        |> Jason.decode!()

      assert data["tier_scope"] == ["tier1", "dex"]
      assert data["count"] == length(data["exchanges"])
      assert data["count"] > 0

      by_id = Map.new(data["exchanges"], &{&1["id"], &1})

      # Raw envelope facts read straight from the Pro-class subscribe object AST.
      assert get_in(by_id, ["bybit", "envelope", "subscribe"]) == "subscribe"
      assert get_in(by_id, ["bybit", "envelope", "discriminant"]) == "op"
      assert get_in(by_id, ["bybit", "envelope", "args_key"]) == "args"
      assert get_in(by_id, ["binance", "envelope", "subscribe"]) == "SUBSCRIBE"
      assert get_in(by_id, ["binance", "envelope", "discriminant"]) == "method"
      assert get_in(by_id, ["okx", "envelope", "subscribe"]) == "subscribe"

      # Channel templates resolved structurally from watch* methods.
      assert is_map(by_id["bybit"]["channels"])
      assert map_size(by_id["bybit"]["channels"]) > 0

      # Derivation over the freshly-extracted entries.
      bybit = WsSubscribe.build(by_id["bybit"], by_id)
      assert bybit["mechanism"] == "json_message"
      assert bybit["subscribe_op"] == "subscribe"

      # binanceusdm defines no subscribe envelope of its own — it inherits binance's.
      binanceusdm = WsSubscribe.build(by_id["binanceusdm"], by_id)
      assert binanceusdm["mechanism"] == "json_message"
      assert binanceusdm["resolved_from"] == "binance"
    end
  end
end
