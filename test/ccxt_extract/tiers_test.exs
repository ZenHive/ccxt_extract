defmodule CcxtExtract.TiersTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Tiers

  doctest Tiers

  describe "tier roots (hand-curated)" do
    test "tier1_exchanges/0 contains the must-have set and excludes variants" do
      roots = Tiers.tier1_exchanges()
      assert "binance" in roots
      assert "bybit" in roots
      assert "okx" in roots
      assert "deribit" in roots

      # coinbaseexchange was demoted to tier3 in the 2026-05-20 narrowing.
      refute "coinbaseexchange" in roots

      refute "binanceus" in roots
      refute "binancecoinm" in roots
      refute "okxus" in roots
    end

    test "tier2_exchanges/0 is intentionally empty — the re-add staging bucket" do
      # Tier 2's former roots (kraken, kucoin, gate, htx, bitmex, bitfinex)
      # were demoted to tier3 on 2026-05-20. The key is kept empty as the
      # staging bucket for re-adding exchanges in matching family groups.
      assert Tiers.tier2_exchanges() == []
    end

    test "tier3_exchanges/0 contains the deprioritized CEX + niche DEX set" do
      roots = Tiers.tier3_exchanges()

      for ex <- ~w(bitget bingx bitmart coinex cryptocom mexc hashkey woo
                   dydx paradex apex woofipro modetrade) do
        assert ex in roots
      end

      # Demoted in the 2026-05-20 narrowing: coinbaseexchange (from tier1),
      # the six former tier2 roots, and aster/lighter (from dex).
      for ex <- ~w(coinbaseexchange kraken kucoin gate htx bitmex bitfinex aster lighter) do
        assert ex in roots
      end
    end

    test "dex_exchanges/0 contains the priority DEX set" do
      assert Tiers.dex_exchanges() == ["hyperliquid", "derive"]
    end

    test "root tier lists are disjoint" do
      all = Tiers.tier1_exchanges() ++ Tiers.tier2_exchanges() ++ Tiers.tier3_exchanges() ++ Tiers.dex_exchanges()
      assert length(all) == length(Enum.uniq(all))
    end
  end

  describe "tier members (roots + variants/aliases)" do
    test "tier1_members/0 includes binance family variants" do
      members = Tiers.tier1_members()
      assert "binance" in members
      assert "binanceus" in members
      assert "binancecoinm" in members
      assert "binanceusdm" in members
      assert "okxus" in members
      assert "myokx" in members
    end

    test "tier2_members/0 is empty while tier2 has no roots" do
      assert Tiers.tier2_members() == []
    end

    test "tier3_members/0 includes the demoted alias/variant families" do
      members = Tiers.tier3_members()
      # Family inheritance still resolves — the demoted roots carry their
      # variants and aliases into tier3.
      assert "kucoin" in members
      assert "kucoinfutures" in members
      assert "gate" in members
      assert "htx" in members
      assert "huobi" in members
    end

    test "member tier lists are disjoint" do
      all = Tiers.tier1_members() ++ Tiers.tier2_members() ++ Tiers.tier3_members() ++ Tiers.dex_members()
      assert length(all) == length(Enum.uniq(all))
    end

    test "roots are always a subset of members" do
      assert MapSet.subset?(MapSet.new(Tiers.tier1_exchanges()), MapSet.new(Tiers.tier1_members()))
      assert MapSet.subset?(MapSet.new(Tiers.tier2_exchanges()), MapSet.new(Tiers.tier2_members()))
      assert MapSet.subset?(MapSet.new(Tiers.tier3_exchanges()), MapSet.new(Tiers.tier3_members()))
      assert MapSet.subset?(MapSet.new(Tiers.dex_exchanges()), MapSet.new(Tiers.dex_members()))
    end
  end

  describe "exchanges_for_tier/1" do
    test "returns roots for each atom" do
      assert Tiers.exchanges_for_tier(:tier1) == Tiers.tier1_exchanges()
      assert Tiers.exchanges_for_tier(:tier2) == Tiers.tier2_exchanges()
      assert Tiers.exchanges_for_tier(:tier3) == Tiers.tier3_exchanges()
      assert Tiers.exchanges_for_tier(:dex) == Tiers.dex_exchanges()
    end
  end

  describe "members_for_tier/1" do
    test "returns expanded members for each atom" do
      assert Tiers.members_for_tier(:tier1) == Tiers.tier1_members()
      assert Tiers.members_for_tier(:tier2) == Tiers.tier2_members()
      assert Tiers.members_for_tier(:tier3) == Tiers.tier3_members()
      assert Tiers.members_for_tier(:dex) == Tiers.dex_members()
    end
  end

  describe "get_priority_tier/1" do
    test "classifies known root exchanges" do
      assert Tiers.get_priority_tier("binance") == :tier1
      assert Tiers.get_priority_tier("kraken") == :tier3
      assert Tiers.get_priority_tier("bitget") == :tier3
      assert Tiers.get_priority_tier("hyperliquid") == :dex
      assert Tiers.get_priority_tier("derive") == :dex
    end

    test "variants inherit the family root's tier" do
      assert Tiers.get_priority_tier("binanceus") == :tier1
      assert Tiers.get_priority_tier("binancecoinm") == :tier1
      assert Tiers.get_priority_tier("binanceusdm") == :tier1
      assert Tiers.get_priority_tier("okxus") == :tier1
      assert Tiers.get_priority_tier("myokx") == :tier1
      assert Tiers.get_priority_tier("kucoinfutures") == :tier3
    end

    test "aliases inherit the family root's tier" do
      # `gateio` (root `gate`, tier3) was retired by CCXT 4.5.57; `huobi`
      # (root `htx`, tier3) still exercises alias tier inheritance.
      assert Tiers.get_priority_tier("huobi") == :tier3
    end

    test "returns :unclassified for unknown ids" do
      assert Tiers.get_priority_tier("not_a_real_exchange_xyz") == :unclassified
      assert Tiers.get_priority_tier("some_imaginary_exchange_99") == :unclassified
    end
  end

  describe "tier predicates" do
    test "tier1?/1 covers roots and variants" do
      assert Tiers.tier1?("binance")
      assert Tiers.tier1?("binanceus")
      assert Tiers.tier1?("okxus")
      refute Tiers.tier1?("kraken")
    end

    test "tier2?/1 is false for every id while tier2 is empty" do
      refute Tiers.tier2?("kraken")
      refute Tiers.tier2?("huobi")
      refute Tiers.tier2?("binance")
    end

    test "tier3?/1 and dex?/1 predicates" do
      assert Tiers.tier3?("bitget")
      assert Tiers.tier3?("kraken")
      assert Tiers.tier3?("coinbaseexchange")
      refute Tiers.tier3?("binance")

      assert Tiers.dex?("hyperliquid")
      assert Tiers.dex?("derive")
      refute Tiers.dex?("binance")
    end
  end

  describe "has_tier_flags?/1" do
    test "true when at least one tier flag is set" do
      assert Tiers.has_tier_flags?(tier1: true)
      assert Tiers.has_tier_flags?(tier2: true)
      assert Tiers.has_tier_flags?(tier3: true)
      assert Tiers.has_tier_flags?(dex: true)
      assert Tiers.has_tier_flags?(tier1: true, dex: true)
    end

    test "false when no tier flags or all false" do
      refute Tiers.has_tier_flags?([])
      refute Tiers.has_tier_flags?(strict: true)
      refute Tiers.has_tier_flags?(tier1: false, tier2: false, tier3: false, dex: false)
    end
  end

  describe "collect_tier_exchanges/1" do
    test "single tier flag returns expanded members, sorted" do
      {exchanges, label} = Tiers.collect_tier_exchanges(tier1: true)
      assert exchanges == Enum.sort(Tiers.tier1_members())
      assert "binance" in exchanges
      assert "binanceus" in exchanges
      assert label == "TIER 1 (#{length(exchanges)})"
    end

    test "multiple tier flags merge expanded members, sort, and uniq" do
      {exchanges, label} = Tiers.collect_tier_exchanges(tier1: true, tier2: true, dex: true)
      expected = Enum.sort(Tiers.tier1_members() ++ Tiers.tier2_members() ++ Tiers.dex_members())
      assert exchanges == expected
      assert "binanceus" in exchanges
      assert "hyperliquid" in exchanges
      # The label reflects the flags passed, so empty tier2 still shows.
      assert label == "TIER 1 + TIER 2 + DEX (#{length(exchanges)})"
    end

    test "no flags returns empty list with empty label suffix" do
      assert {[], " (0)"} = Tiers.collect_tier_exchanges([])
    end
  end

  describe "tier_display_name/1" do
    test "all four tier atoms have human-readable names" do
      assert Tiers.tier_display_name(:tier1) == "TIER 1"
      assert Tiers.tier_display_name(:tier2) == "TIER 2"
      assert Tiers.tier_display_name(:tier3) == "TIER 3"
      assert Tiers.tier_display_name(:dex) == "DEX"
    end
  end
end
