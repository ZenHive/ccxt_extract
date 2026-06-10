defmodule CcxtExtract.RawBroadcastIntegrationTest do
  use ExUnit.Case, async: false

  alias CcxtExtract.RawBroadcast

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 120_000

  setup_all do
    {:ok, exchanges, stats} = RawBroadcast.extract()
    {:ok, exchanges: exchanges, stats: stats, by_id: Map.new(exchanges, &{&1["id"], &1})}
  end

  describe "RawBroadcast.extract/0 against real CCXT source" do
    test "parses all source files without errors", %{stats: stats} do
      assert stats.errors == [], "Parse errors: #{inspect(stats.errors)}"
    end

    test "hyperliquid promotes write methods reached via signL1Action / signUserSignedAction",
         %{by_id: by_id} do
      bm = by_id["hyperliquid"]["broadcast_methods"]

      # AC: signL1Action detected as a broadcast helper on real write methods.
      assert bm["createOrder"] == ["signL1Action", "signUserSignedAction"]
      assert "signL1Action" in bm["withdraw"]
      assert "signL1Action" in bm["setLeverage"]

      # fetch* reads are excluded (authentication, not broadcast).
      refute Enum.any?(Map.keys(bm), &String.starts_with?(&1, "fetch"))
    end

    test "paradex (starknet family) promotes via starknetSign", %{by_id: by_id} do
      bm = by_id["paradex"]["broadcast_methods"]

      assert bm["createOrder"] == ["starknetSign"]
      assert Map.has_key?(bm, "setLeverage")
      assert by_id["paradex"]["signing_imports"] == ["noble-curves"]
      refute Enum.any?(Map.keys(bm), &String.starts_with?(&1, "fetch"))
    end

    test "grvt (EIP-712 DEX) promotes via createSignedRequest and flags the eip712 builder",
         %{by_id: by_id} do
      grvt = by_id["grvt"]
      assert grvt["eip712_builder"] == true
      assert grvt["broadcast_methods"]["createOrder"] == ["createSignedRequest"]
      assert "createSignedRequest" in grvt["broadcast_methods"]["withdraw"]
    end

    test "plain CEX (binance) carries no curated broadcast helper", %{by_id: by_id} do
      # binance imports noble-curves for ed25519 signing support, so it DOES
      # carry a corroborating signal — but no curated broadcast helper, so
      # broadcast_methods is empty and it never promotes an on-chain endpoint.
      case by_id["binance"] do
        nil -> :ok
        entry -> assert entry["broadcast_methods"] == %{}
      end
    end
  end
end

defmodule CcxtExtract.RawBroadcastPipelineIntegrationTest do
  use ExUnit.Case, async: false

  alias CcxtExtract.DiscoveryLoader
  alias CcxtExtract.JsonIO
  alias CcxtExtract.Pipeline

  @moduletag :integration
  @moduletag :extraction
  @moduletag timeout: 120_000

  setup_all do
    dir = CcxtExtract.Paths.priv("discoveries")
    {:ok, exch_json} = JsonIO.read_json(Path.join(dir, "exchanges.json"))
    data = DiscoveryLoader.load_all!(dir, exch_json)
    {:ok, data: data}
  end

  defp classification(data, id) do
    meta = Enum.find(data.exchanges, &(&1["id"] == id)) || %{"id" => id}
    ex = Pipeline.build_exchange_data(meta, data, ccxt_version: "test", extracted_at: "t")
    get_in(ex, ["endpoints", "transaction_classification"]) || %{}
  end

  describe "end-to-end transaction_classification promotion" do
    test "hyperliquid createOrder + withdraw promoted to on_chain + transactional", %{data: data} do
      tc = classification(data, "hyperliquid")
      assert tc["createOrder"] == %{"transactional" => true, "on_chain" => true}
      assert tc["withdraw"] == %{"transactional" => true, "on_chain" => true}
    end

    test "paradex createOrder promoted to on_chain + transactional", %{data: data} do
      tc = classification(data, "paradex")
      assert tc["createOrder"] == %{"transactional" => true, "on_chain" => true}
    end

    test "lighter sendTx implicit-API endpoints promoted from describe().api", %{data: data} do
      tc = classification(data, "lighter")
      assert tc["publicPostSendTx"] == %{"transactional" => true, "on_chain" => true}
      assert tc["publicPostSendTxBatch"] == %{"transactional" => true, "on_chain" => true}
    end

    test "binance keeps the name-only base — only withdraw is on_chain (negative gate intact)",
         %{data: data} do
      tc = classification(data, "binance")

      on_chain = for {name, %{"on_chain" => true}} <- tc, do: name
      assert on_chain == ["withdraw"]

      # createOrder is transactional but NOT on_chain — a consumer can trust
      # on_chain == false here.
      assert tc["createOrder"] == %{"transactional" => true, "on_chain" => false}
    end

    test "every on_chain entry is also transactional across the DEX targets", %{data: data} do
      for id <- ~w(hyperliquid paradex grvt lighter) do
        for {name, flags} <- classification(data, id), flags["on_chain"] do
          assert flags["transactional"] == true,
                 "#{id}.#{name} is on_chain but not transactional"
        end
      end
    end
  end
end
