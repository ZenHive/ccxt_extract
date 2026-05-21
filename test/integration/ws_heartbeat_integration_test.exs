defmodule CcxtExtract.WsHeartbeatIntegrationTest do
  @moduledoc """
  Runs the `ws_heartbeat` extractor against the real CCXT Pro source.

  Tagged `:extraction` — excluded by default; run with
  `mix test.json --include extraction`.
  """
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Paths
  alias CcxtExtract.WsHeartbeat

  @moduletag :extraction
  @moduletag :integration
  @moduletag timeout: 60_000

  describe "mix ccxt_extract.ws_heartbeat" do
    test "extracts a well-formed heartbeat discovery file from real Pro source" do
      output =
        run_task_capturing_output(Mix.Tasks.CcxtExtract.WsHeartbeat, ["--tier1", "--dex"])

      assert output =~ "Extracting WebSocket heartbeat config"
      assert output =~ "Done."
      assert output =~ "define ping()"
      assert output =~ "Output: priv/discoveries/ws_heartbeat.json"

      data =
        "discoveries"
        |> Path.join("ws_heartbeat.json")
        |> Paths.out()
        |> File.read!()
        |> Jason.decode!()

      assert data["tier_scope"] == ["tier1", "dex"]
      assert data["count"] == length(data["exchanges"])
      assert data["count"] > 0

      by_id = Map.new(data["exchanges"], &{&1["id"], &1})

      # Raw facts read straight from the Pro-class AST.
      assert get_in(by_id, ["bybit", "ping", "shape"]) == "object"
      assert get_in(by_id, ["okx", "ping", "shape"]) == "string"
      assert get_in(by_id, ["binance", "streaming", "keep_alive_ms"]) == 180_000
      refute get_in(by_id, ["binance", "ping", "defined"])

      # Derivation over the freshly-extracted entries.
      okx = WsHeartbeat.build(by_id["okx"], by_id)
      assert okx["ping_kind"] == "string_message"
      assert okx["ping_payload"] == "ping"
    end
  end

  describe "base client default drift guard" do
    test "the pinned keepAlive default still matches base/ws/Client.ts" do
      client_ts =
        ~w(ccxt ts src base ws Client.ts) |> Path.join() |> Paths.priv() |> File.read!()

      # A Pro class with a streaming block but no keepAlive falls back to the
      # base client default — build/2 surfaces the value WsHeartbeat pins.
      base =
        WsHeartbeat.build(
          %{
            "id" => "probe",
            "extends" => "probeRest",
            "ping" => %{"defined" => false, "shape" => nil, "return_value" => nil},
            "pong_methods" => %{"pong" => false, "handlePong" => false, "handlePing" => false},
            "streaming" => %{
              "present" => true,
              "keep_alive_ms" => nil,
              "max_ping_pong_misses" => nil,
              "has_ping_property" => false
            }
          },
          %{}
        )

      keep_alive = base["keep_alive_ms"]

      assert client_ts =~ ~r/['"]?keepAlive['"]?\s*:\s*#{keep_alive}\b/,
             "WsHeartbeat pins keepAlive=#{keep_alive}, but base/ws/Client.ts no longer declares that default — update @base_keep_alive_ms"

      assert client_ts =~ ~r/['"]?maxPingPongMisses['"]?\s*:\s*2(\.0)?\b/,
             "base/ws/Client.ts no longer declares maxPingPongMisses=2 — update @base_max_ping_pong_misses"

      assert base["max_ping_pong_misses"] == 2.0
    end
  end
end
