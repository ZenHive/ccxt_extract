defmodule CcxtExtract.Integration.Cached.WsAuthCachedTest do
  @moduledoc """
  Asserts against the committed `priv/discoveries/ws_auth.json` corpus.

  Fast — does not re-run extraction. Dispatches on observed counts, not
  envelope stamps, so it tolerates a scoped or full-universe corpus.
  """
  use ExUnit.Case, async: true

  import CcxtExtract.Test.ScopeThresholds

  alias CcxtExtract.WsAuth

  @moduletag :integration
  @moduletag timeout: 30_000

  @fixture_path Path.join(CcxtExtract.Paths.discoveries(), "ws_auth.json")

  setup_all do
    data = @fixture_path |> File.read!() |> Jason.decode!()
    by_id = Map.new(data["exchanges"], &{&1["id"], &1})
    %{data: data, exchanges: data["exchanges"], by_id: by_id}
  end

  describe "envelope structure" do
    test "has required top-level fields", %{data: data} do
      assert is_binary(data["extracted_at"])
      assert is_integer(data["count"])
      assert is_integer(data["with_authenticate"])
      assert is_integer(data["with_sign_in_message"])
      assert is_list(data["exchanges"])
    end

    test "envelope counts agree with the entries list", %{data: data} do
      entries = data["exchanges"]
      assert data["count"] == length(entries)
      assert data["with_authenticate"] == Enum.count(entries, &get_in(&1, ["authenticate", "defined"]))

      assert data["with_sign_in_message"] ==
               Enum.count(entries, &is_map(get_in(&1, ["authenticate", "message"])))
    end

    test "at least the WS universe is present on a full-universe corpus", %{data: data} do
      if full_universe?(data) do
        assert data["count"] >= 70, "full-universe ws_auth expected 70+ WS exchanges, got #{data["count"]}"
      else
        assert data["count"] > 0
      end
    end
  end

  describe "per-entry raw shape" do
    test "every entry carries the raw authenticate fact keys", %{exchanges: exchanges} do
      for e <- exchanges do
        assert is_binary(e["id"])
        assert Map.has_key?(e, "extends")
        auth = e["authenticate"]

        assert match?(
                 %{
                   "defined" => _,
                   "async" => _,
                   "param_count" => _,
                   "credentials" => _,
                   "sends_message" => _,
                   "url_param_signal" => _,
                   "message" => _
                 },
                 auth
               )

        assert is_list(auth["credentials"])
      end
    end

    test "a present message carries op / method / keys", %{exchanges: exchanges} do
      for e <- exchanges, message = get_in(e, ["authenticate", "message"]), is_map(message) do
        assert match?(%{"op" => _, "method" => _, "keys" => _}, message)
        assert is_list(message["keys"])
      end
    end
  end

  describe "derivation over the real corpus" do
    test "build/2 produces a schema-shaped record for every entry", %{exchanges: exchanges, by_id: by_id} do
      for e <- exchanges do
        record = WsAuth.build(e, by_id)
        assert Enum.sort(Map.keys(record)) == Enum.sort(WsAuth.required_keys())
        assert record["mechanism"] in WsAuth.mechanisms()
        assert record["source"] in WsAuth.sources()
        assert record["unresolved_reason"] in [nil | WsAuth.unresolved_reasons()]
      end
    end

    test "priority exchanges resolve to their expected auth flow", %{by_id: by_id} do
      expected = %{
        "bybit" => %{"mechanism" => "sign_in_message", "op" => "auth"},
        "okx" => %{"mechanism" => "sign_in_message", "op" => "login"},
        "deribit" => %{"mechanism" => "sign_in_message", "method" => "public/auth"},
        "derive" => %{"mechanism" => "sign_in_message", "method" => "public/login"},
        "binance" => %{"mechanism" => "url_param"},
        "hyperliquid" => %{"mechanism" => "none", "unresolved_reason" => "no_ws_auth"}
      }

      present =
        for {id, want} <- expected, entry = by_id[id], not is_nil(entry) do
          record = WsAuth.build(entry, by_id)

          for {key, value} <- want do
            actual = if key in ["op", "method"], do: get_in(record, ["message", key]), else: record[key]
            assert actual == value, "#{id}.#{key}: expected #{inspect(value)}, got #{inspect(actual)}"
          end

          id
        end

      assert present != [], "expected at least one priority exchange in the corpus"
    end

    test "binanceusdm inherits binance's authenticate via the extends chain", %{by_id: by_id} do
      if entry = by_id["binanceusdm"] do
        record = WsAuth.build(entry, by_id)
        assert record["mechanism"] == "url_param"
        assert record["resolved_from"] == "binance"
      end
    end
  end
end
