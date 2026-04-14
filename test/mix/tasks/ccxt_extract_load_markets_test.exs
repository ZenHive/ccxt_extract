defmodule Mix.Tasks.CcxtExtract.LoadMarketsTest do
  @moduledoc """
  Argument-parsing and tier-flag expansion tests for `mix ccxt_extract.load_markets`.

  Does not invoke the underlying QuickBEAM-driven extraction (network-bound).
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Tiers
  alias Mix.Tasks.CcxtExtract.LoadMarkets

  describe "tier flag → exchange list expansion" do
    test "--tier1 expands to Tier 1 members (roots + variants/aliases)" do
      {exchanges, label} = Tiers.collect_tier_exchanges(tier1: true)
      assert exchanges == Enum.sort(Tiers.tier1_members())
      assert "binance" in exchanges
      assert "binanceus" in exchanges
      assert label == "TIER 1 (#{length(exchanges)})"
    end

    test "--tier1 --tier2 --dex unions members and dedups, sorted" do
      {exchanges, label} = Tiers.collect_tier_exchanges(tier1: true, tier2: true, dex: true)
      expected = Enum.sort(Tiers.tier1_members() ++ Tiers.tier2_members() ++ Tiers.dex_members())
      assert exchanges == expected
      assert label == "TIER 1 + TIER 2 + DEX (#{length(exchanges)})"
    end

    test "all four tiers cover the full priority universe (members)" do
      {exchanges, _} = Tiers.collect_tier_exchanges(tier1: true, tier2: true, tier3: true, dex: true)

      total =
        length(Tiers.tier1_members()) +
          length(Tiers.tier2_members()) +
          length(Tiers.tier3_members()) +
          length(Tiers.dex_members())

      assert length(exchanges) == total
    end
  end

  describe "task argument validation" do
    test "--exchanges + tier flag is rejected" do
      assert_raise Mix.Error, ~r/mutually exclusive/, fn ->
        LoadMarkets.run(["--exchanges", "binance", "--tier1"])
      end
    end

    test "unknown option is rejected" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        LoadMarkets.run(["--bogus"])
      end
    end

    test "positional arg is rejected" do
      assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
        LoadMarkets.run(["binance"])
      end
    end
  end
end
