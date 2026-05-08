defmodule CcxtExtract.ErrorHierarchyTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.ErrorHierarchy

  doctest ErrorHierarchy

  describe "hierarchy/0" do
    test "returns a non-empty map of class -> parent" do
      h = ErrorHierarchy.hierarchy()

      assert is_map(h)
      assert map_size(h) > 30, "expected at least the CCXT base hierarchy (~40 classes)"
    end

    test "BaseError points at JS Error" do
      assert ErrorHierarchy.hierarchy()["BaseError"] == "Error"
    end

    test "ExchangeError extends BaseError" do
      assert ErrorHierarchy.hierarchy()["ExchangeError"] == "BaseError"
    end

    test "DDoSProtection extends NetworkError" do
      assert ErrorHierarchy.hierarchy()["DDoSProtection"] == "NetworkError"
    end

    test "no entry has nil parent (every class extends something)" do
      for {class, parent} <- ErrorHierarchy.hierarchy() do
        refute is_nil(parent), "class #{class} has nil parent"
      end
    end
  end

  describe "ancestors/1" do
    test "walks chain up to the JS Error root" do
      assert ErrorHierarchy.ancestors("RateLimitExceeded") == [
               "RateLimitExceeded",
               "NetworkError",
               "OperationFailed",
               "BaseError",
               "Error"
             ]
    end

    test "returns [class] for unknown classes" do
      assert ErrorHierarchy.ancestors("ExchangeSpecificMystery") == ["ExchangeSpecificMystery"]
    end

    test "BaseError walks to Error" do
      assert ErrorHierarchy.ancestors("BaseError") == ["BaseError", "Error"]
    end

    test "nil returns empty list" do
      assert ErrorHierarchy.ancestors(nil) == []
    end
  end

  describe "bucket_for/1" do
    test "rate_limit takes priority over network for DDoSProtection" do
      assert ErrorHierarchy.bucket_for("DDoSProtection") == "rate_limit"
    end

    test "rate_limit for RateLimitExceeded" do
      assert ErrorHierarchy.bucket_for("RateLimitExceeded") == "rate_limit"
    end

    test "auth for AuthenticationError + descendants" do
      assert ErrorHierarchy.bucket_for("AuthenticationError") == "auth"
      assert ErrorHierarchy.bucket_for("PermissionDenied") == "auth"
      assert ErrorHierarchy.bucket_for("AccountSuspended") == "auth"
      assert ErrorHierarchy.bucket_for("AccountNotEnabled") == "auth"
    end

    test "server_busy for ExchangeNotAvailable / OnMaintenance / BadResponse / NullResponse" do
      assert ErrorHierarchy.bucket_for("ExchangeNotAvailable") == "server_busy"
      assert ErrorHierarchy.bucket_for("OnMaintenance") == "server_busy"
      assert ErrorHierarchy.bucket_for("BadResponse") == "server_busy"
      assert ErrorHierarchy.bucket_for("NullResponse") == "server_busy"
    end

    test "network for non-rate-limit NetworkError descendants" do
      assert ErrorHierarchy.bucket_for("NetworkError") == "network"
      assert ErrorHierarchy.bucket_for("RequestTimeout") == "network"
      assert ErrorHierarchy.bucket_for("InvalidNonce") == "network"
      assert ErrorHierarchy.bucket_for("ChecksumError") == "network"
    end

    test "non_retryable for ExchangeError-tree leaves not in another bucket" do
      assert ErrorHierarchy.bucket_for("InvalidOrder") == "non_retryable"
      assert ErrorHierarchy.bucket_for("BadRequest") == "non_retryable"
      assert ErrorHierarchy.bucket_for("BadSymbol") == "non_retryable"
      assert ErrorHierarchy.bucket_for("InsufficientFunds") == "non_retryable"
      assert ErrorHierarchy.bucket_for("NotSupported") == "non_retryable"
    end

    test "non_retryable for unknown classes" do
      assert ErrorHierarchy.bucket_for("ExchangeSpecificMystery") == "non_retryable"
      assert ErrorHierarchy.bucket_for("BinanceWeirdness") == "non_retryable"
    end

    test "non_retryable for nil" do
      assert ErrorHierarchy.bucket_for(nil) == "non_retryable"
    end
  end

  describe "buckets/0" do
    test "returns a fixed five-element list" do
      assert ErrorHierarchy.buckets() == ~w(rate_limit auth server_busy network non_retryable)
    end

    test "every class in hierarchy has a bucket in the list" do
      buckets = ErrorHierarchy.buckets()

      for {class, _parent} <- ErrorHierarchy.hierarchy() do
        assert ErrorHierarchy.bucket_for(class) in buckets,
               "class #{class} bucketed outside the official list"
      end
    end
  end

  describe "parse_source!/0 (drift detection — needs priv/ccxt)" do
    @describetag :extraction

    test "committed @hierarchy matches CCXT's base/errors.ts source" do
      parsed = ErrorHierarchy.parse_source!()
      committed = ErrorHierarchy.hierarchy()

      assert parsed == committed,
             "Hierarchy drift detected — upstream CCXT changed base/errors.ts. " <>
               "Regenerate `@hierarchy` in error_hierarchy.ex.\n" <>
               "Diff: #{inspect(diff(parsed, committed), pretty: true)}"
    end
  end

  defp diff(parsed, committed) do
    Enum.flat_map(parsed, fn {k, v} ->
      cv = Map.get(committed, k, :missing_in_committed)
      if v == cv, do: [], else: [{k, parsed: v, committed: cv}]
    end) ++
      (committed
       |> Map.keys()
       |> Enum.reject(&Map.has_key?(parsed, &1))
       |> Enum.map(&{&1, parsed: :missing_in_parsed, committed: Map.get(committed, &1)}))
  end
end
