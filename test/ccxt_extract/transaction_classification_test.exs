defmodule CcxtExtract.TransactionClassificationTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.TransactionClassification

  describe "derive/1" do
    test "returns nil for nil input" do
      assert TransactionClassification.derive(nil) == nil
    end

    test "returns nil for empty map" do
      assert TransactionClassification.derive(%{}) == nil
    end

    test "classifies known-transactional methods as transactional" do
      result =
        TransactionClassification.derive(%{
          "createOrder" => ["privatePostOrder"],
          "withdraw" => ["privatePostWithdraw"],
          "transfer" => ["privatePostTransfer"]
        })

      assert result["createOrder"] == %{"transactional" => true, "on_chain" => false}
      assert result["withdraw"] == %{"transactional" => true, "on_chain" => true}
      assert result["transfer"] == %{"transactional" => true, "on_chain" => false}
    end

    test "classifies known-read-only methods as not transactional" do
      result =
        TransactionClassification.derive(%{
          "fetchTicker" => ["publicGetTicker"],
          "fetchOHLCV" => ["publicGetKlines"],
          "fetchBalance" => ["privateGetBalance"]
        })

      assert result["fetchTicker"] == %{"transactional" => false, "on_chain" => false}
      assert result["fetchOHLCV"] == %{"transactional" => false, "on_chain" => false}
      assert result["fetchBalance"] == %{"transactional" => false, "on_chain" => false}
    end

    test "ignores the call list values — classifies by name only" do
      # Same call name with different interface methods produces same flags
      a = TransactionClassification.derive(%{"createOrder" => ["a"]})
      b = TransactionClassification.derive(%{"createOrder" => ["a", "b", "c"]})
      assert a == b
    end

    test "preserves all input keys in the output" do
      input = %{
        "fetchTicker" => [],
        "createOrder" => [],
        "cancelAllOrders" => [],
        "withdraw" => [],
        "transfer" => [],
        "setLeverage" => []
      }

      assert input |> TransactionClassification.derive() |> Map.keys() |> Enum.sort() ==
               Enum.sort(Map.keys(input))
    end

    test "every entry has exactly the two boolean keys" do
      result =
        TransactionClassification.derive(%{
          "fetchTicker" => [],
          "withdraw" => []
        })

      for {_name, entry} <- result do
        assert entry |> Map.keys() |> Enum.sort() == ["on_chain", "transactional"]
        assert is_boolean(entry["transactional"])
        assert is_boolean(entry["on_chain"])
      end
    end
  end

  describe "transactional?/1" do
    test "false for fetch* methods" do
      refute TransactionClassification.transactional?("fetchTicker")
      refute TransactionClassification.transactional?("fetchOHLCV")
      refute TransactionClassification.transactional?("fetchBalance")
      refute TransactionClassification.transactional?("fetchOrder")
      refute TransactionClassification.transactional?("fetchMyTrades")
    end

    test "true for write-side prefixes" do
      assert TransactionClassification.transactional?("createOrder")
      assert TransactionClassification.transactional?("createOrders")
      assert TransactionClassification.transactional?("cancelOrder")
      assert TransactionClassification.transactional?("cancelAllOrders")
      assert TransactionClassification.transactional?("editOrder")
      assert TransactionClassification.transactional?("withdraw")
      assert TransactionClassification.transactional?("transfer")
      assert TransactionClassification.transactional?("setLeverage")
      assert TransactionClassification.transactional?("setMarginMode")
      assert TransactionClassification.transactional?("addMargin")
      assert TransactionClassification.transactional?("reduceMargin")
      assert TransactionClassification.transactional?("borrowCrossMargin")
      assert TransactionClassification.transactional?("repayIsolatedMargin")
      assert TransactionClassification.transactional?("closePosition")
    end
  end

  describe "on_chain?/1" do
    test "true only for withdraw* family" do
      assert TransactionClassification.on_chain?("withdraw")
      assert TransactionClassification.on_chain?("withdrawAll")
      assert TransactionClassification.on_chain?("withdrawCrypto")
    end

    test "false for transfer (internal exchange transfer)" do
      refute TransactionClassification.on_chain?("transfer")
      refute TransactionClassification.on_chain?("transferIn")
      refute TransactionClassification.on_chain?("transferOut")
    end

    test "false for other transactional methods" do
      refute TransactionClassification.on_chain?("createOrder")
      refute TransactionClassification.on_chain?("cancelOrder")
      refute TransactionClassification.on_chain?("setLeverage")
    end

    test "false for read methods" do
      refute TransactionClassification.on_chain?("fetchDepositAddress")
      refute TransactionClassification.on_chain?("fetchWithdrawals")
    end
  end

  describe "classify/1" do
    test "every on_chain endpoint is transactional (invariant)" do
      for name <- ["withdraw", "withdrawAll", "withdrawCrypto"] do
        flags = TransactionClassification.classify(name)
        assert flags["on_chain"] == true
        assert flags["transactional"] == true
      end
    end

    test "transactional ⊇ on_chain (the inverse is not required)" do
      # transactional but not on_chain
      flags = TransactionClassification.classify("createOrder")
      assert flags["transactional"] == true
      assert flags["on_chain"] == false
    end
  end
end
