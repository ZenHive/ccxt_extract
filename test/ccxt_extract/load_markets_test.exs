defmodule CcxtExtract.LoadMarketsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.LoadMarkets

  describe "extract/1 input validation" do
    test "rejects concurrency: 0" do
      assert_raise ArgumentError, ~r/concurrency must be a positive integer/, fn ->
        LoadMarkets.extract(concurrency: 0, exchanges: ["dydx"])
      end
    end

    test "rejects negative concurrency" do
      assert_raise ArgumentError, ~r/concurrency must be a positive integer/, fn ->
        LoadMarkets.extract(concurrency: -1, exchanges: ["dydx"])
      end
    end

    test "rejects negative delay_ms" do
      assert_raise ArgumentError, ~r/delay_ms must be a non-negative integer/, fn ->
        LoadMarkets.extract(delay_ms: -1, exchanges: ["dydx"])
      end
    end

    test "rejects empty exchanges list" do
      assert_raise ArgumentError, ~r/exchanges must be a non-empty list/, fn ->
        LoadMarkets.extract(exchanges: [])
      end
    end

    test "rejects non-integer delay_ms" do
      assert_raise ArgumentError, ~r/delay_ms must be a non-negative integer/, fn ->
        LoadMarkets.extract(delay_ms: 1.5, exchanges: ["dydx"])
      end
    end
  end
end
