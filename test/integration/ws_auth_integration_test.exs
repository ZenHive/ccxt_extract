defmodule CcxtExtract.WsAuthIntegrationTest do
  @moduledoc """
  Runs the `ws_auth` extractor against the real CCXT Pro source.

  Tagged `:extraction` — excluded by default; run with
  `mix test.json --include extraction`.
  """
  use CcxtExtract.PrivWriteCase

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.Paths
  alias CcxtExtract.WsAuth

  @moduletag :extraction
  @moduletag :integration
  @moduletag timeout: 60_000

  describe "mix ccxt_extract.ws_auth" do
    test "extracts a well-formed auth-flow discovery file from real Pro source" do
      output =
        run_task_capturing_output(Mix.Tasks.CcxtExtract.WsAuth, ["--tier1", "--dex"])

      assert output =~ "Extracting WebSocket authentication flow"
      assert output =~ "Done."
      assert output =~ "define authenticate()"
      assert output =~ "Output: priv/discoveries/ws_auth.json"

      data =
        "discoveries"
        |> Path.join("ws_auth.json")
        |> Paths.out()
        |> File.read!()
        |> Jason.decode!()

      assert data["tier_scope"] == ["tier1", "dex"]
      assert data["count"] == length(data["exchanges"])
      assert data["count"] > 0

      by_id = Map.new(data["exchanges"], &{&1["id"], &1})

      # Raw facts read straight from the Pro-class `authenticate` AST.
      assert get_in(by_id, ["bybit", "authenticate", "message", "op"]) == "auth"
      # okx writes `{ op: operation }` — resolved through a local const binding.
      assert get_in(by_id, ["okx", "authenticate", "message", "op"]) == "login"
      assert get_in(by_id, ["deribit", "authenticate", "message", "method"]) == "public/auth"
      assert get_in(by_id, ["derive", "authenticate", "message", "method"]) == "public/login"
      # binance authenticates the futures user-data stream via a listenKey URL param.
      assert get_in(by_id, ["binance", "authenticate", "url_param_signal"]) == true

      # Derivation over the freshly-extracted entries.
      bybit = WsAuth.build(by_id["bybit"], by_id)
      assert bybit["mechanism"] == "sign_in_message"
      assert bybit["message"]["op"] == "auth"

      # binanceusdm defines no authenticate() of its own — it inherits binance's.
      binanceusdm = WsAuth.build(by_id["binanceusdm"], by_id)
      assert binanceusdm["mechanism"] == "url_param"
      assert binanceusdm["resolved_from"] == "binance"
    end
  end
end
