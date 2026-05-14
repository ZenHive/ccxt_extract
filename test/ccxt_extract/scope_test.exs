defmodule CcxtExtract.ScopeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Scope
  alias CcxtExtract.Tiers

  @small_universe ["binance", "binanceus", "binancecoinm", "kraken", "deribit", "hyperliquid", "aster"]

  describe "resolve/2 — no narrowing" do
    test "no flags + empty universe → :all with empty list" do
      assert {:ok, [], :all} = Scope.resolve([], [])
    end

    test "no flags + universe → :all with full universe" do
      assert {:ok, @small_universe, :all} = Scope.resolve([], @small_universe)
    end

    test "--all explicit → :all with full universe" do
      assert {:ok, @small_universe, :all} = Scope.resolve([all: true], @small_universe)
    end
  end

  describe "resolve/2 — tiers" do
    test "single tier expands to members with count label" do
      members = Tiers.tier1_members()
      universe = Enum.uniq(members ++ @small_universe)

      assert {:ok, ids, {:scoped, label}} = Scope.resolve([tier1: true], universe)
      assert ids == Enum.sort(members)
      assert label == "TIER 1 (#{length(members)})"
    end

    test "tier union sorts and uniqs across tiers" do
      tier1 = Tiers.tier1_members()
      dex = Tiers.dex_members()
      expected = tier1 |> Enum.concat(dex) |> Enum.uniq() |> Enum.sort()
      universe = Enum.uniq(expected ++ @small_universe)

      assert {:ok, ids, {:scoped, label}} = Scope.resolve([tier1: true, dex: true], universe)
      assert ids == expected
      assert label == "TIER 1 + DEX (#{length(expected)})"
    end
  end

  describe "resolve/2 — explicit exchanges" do
    test "single --exchange" do
      assert {:ok, ["binance"], {:scoped, "binance (1)"}} =
               Scope.resolve([exchange: "binance"], @small_universe)
    end

    test "repeated --exchange (OptionParser :keep form)" do
      opts = [exchange: "binance", exchange: "deribit"]
      assert {:ok, ids, {:scoped, label}} = Scope.resolve(opts, @small_universe)
      assert ids == ["binance", "deribit"]
      assert label == "binance, deribit (2)"
    end

    test "comma-split --exchange value" do
      assert {:ok, ids, {:scoped, label}} =
               Scope.resolve([exchange: "binance,deribit"], @small_universe)

      assert ids == ["binance", "deribit"]
      assert label == "binance, deribit (2)"
    end

    test "list-form --exchange for programmatic callers" do
      assert {:ok, ids, {:scoped, label}} =
               Scope.resolve([exchange: ["binance", "deribit"]], @small_universe)

      assert ids == ["binance", "deribit"]
      assert label == "binance, deribit (2)"
    end

    test "whitespace around comma-split values is trimmed" do
      assert {:ok, ids, _label} =
               Scope.resolve([exchange: " binance , deribit "], @small_universe)

      assert ids == ["binance", "deribit"]
    end

    test "duplicate explicit IDs are deduped in output" do
      assert {:ok, ["binance"], {:scoped, label}} =
               Scope.resolve([exchange: "binance,binance"], @small_universe)

      assert label == "binance (1)"
    end
  end

  describe "resolve/2 — mixed tier + exchange" do
    test "combines tier members with explicit IDs" do
      tier1 = Tiers.tier1_members()
      universe = Enum.uniq(tier1 ++ @small_universe)
      expected_ids = (tier1 ++ ["hyperliquid"]) |> Enum.uniq() |> Enum.sort()

      assert {:ok, ids, {:scoped, label}} =
               Scope.resolve([tier1: true, exchange: "hyperliquid"], universe)

      assert ids == expected_ids
      assert label == "TIER 1 + hyperliquid (#{length(expected_ids)})"
    end

    test "explicit ID already in tier is counted once" do
      tier1 = Tiers.tier1_members()
      universe = Enum.uniq(tier1 ++ @small_universe)

      assert {:ok, ids, {:scoped, label}} =
               Scope.resolve([tier1: true, exchange: "binance"], universe)

      assert ids == Enum.sort(tier1)
      assert label == "TIER 1 + binance (#{length(tier1)})"
    end
  end

  describe "resolve/2 — tier ∩ universe" do
    test "tier members not in universe are silently dropped" do
      assert {:ok, ["binance"], {:scoped, "TIER 1 (1)"}} =
               Scope.resolve([tier1: true], ["binance"])
    end

    test "mixed tier + explicit intersects tier with universe but keeps explicit verbatim" do
      assert {:ok, ids, {:scoped, label}} =
               Scope.resolve([tier1: true, exchange: "hyperliquid"], ["binance", "hyperliquid"])

      assert ids == ["binance", "hyperliquid"]
      assert label == "TIER 1 + hyperliquid (2)"
    end

    test "tier with no overlap and no explicit yields empty in-scope set" do
      assert {:ok, [], {:scoped, "TIER 1 (0)"}} =
               Scope.resolve([tier1: true], ["zzzzzz"])
    end
  end

  describe "resolve/2 — unknown exchange" do
    test "typo with close match returns suggestions" do
      assert {:error, {:unknown_exchange, ["binanc"], suggestions}} =
               Scope.resolve([exchange: "binanc"], @small_universe)

      assert "binance" in suggestions["binanc"]
      assert length(suggestions["binanc"]) <= 3
    end

    test "typo with no close match returns empty suggestion list" do
      assert {:error, {:unknown_exchange, ["zzzzzz"], %{"zzzzzz" => []}}} =
               Scope.resolve([exchange: "zzzzzz"], @small_universe)
    end

    test "multiple unknowns reported together" do
      assert {:error, {:unknown_exchange, unknowns, suggestions}} =
               Scope.resolve([exchange: "zzzzzz,wwwwww"], @small_universe)

      assert "zzzzzz" in unknowns
      assert "wwwwww" in unknowns
      assert Map.has_key?(suggestions, "zzzzzz")
      assert Map.has_key?(suggestions, "wwwwww")
    end
  end

  describe "resolve/2 — --all conflicts" do
    test "--all with --tier1 rejected" do
      assert {:error, {:all_with_narrowing, [:tier1]}} =
               Scope.resolve([all: true, tier1: true], @small_universe)
    end

    test "--all with --exchange rejected" do
      assert {:error, {:all_with_narrowing, [:exchange]}} =
               Scope.resolve([all: true, exchange: "binance"], @small_universe)
    end

    test "--all with multiple narrowing flags lists all conflicts" do
      opts = [all: true, tier1: true, dex: true, exchange: "binance"]
      assert {:error, {:all_with_narrowing, keys}} = Scope.resolve(opts, @small_universe)
      assert :tier1 in keys
      assert :dex in keys
      assert :exchange in keys
    end
  end

  describe "to_manifest_value/1" do
    test "empty opts returns \"all\"" do
      assert Scope.to_manifest_value([]) == "all"
    end

    test "--all returns \"all\"" do
      assert Scope.to_manifest_value(all: true) == "all"
    end

    test "single tier flag" do
      assert Scope.to_manifest_value(tier1: true) == ["tier1"]
    end

    test "multiple tier flags preserve canonical order regardless of input order" do
      assert Scope.to_manifest_value(dex: true, tier1: true) == ["tier1", "dex"]
      assert Scope.to_manifest_value(tier2: true, tier1: true, dex: true) == ["tier1", "tier2", "dex"]
    end

    test "explicit exchange entries are sorted and prefixed" do
      assert Scope.to_manifest_value(exchange: "kraken,binance") == ["exchange:binance", "exchange:kraken"]
    end

    test "repeated --exchange flags deduplicate and sort" do
      opts = [exchange: "binance", exchange: "deribit", exchange: "binance"]
      assert Scope.to_manifest_value(opts) == ["exchange:binance", "exchange:deribit"]
    end

    test "mixes tiers and exchanges in tier-first order" do
      opts = [tier1: true, exchange: "hyperliquid,bybit"]
      assert Scope.to_manifest_value(opts) == ["tier1", "exchange:bybit", "exchange:hyperliquid"]
    end

    test "ignores whitespace in comma-split exchange values" do
      assert Scope.to_manifest_value(exchange: "binance, deribit ") == ["exchange:binance", "exchange:deribit"]
    end
  end

  describe "merge_manifest_values/2" do
    test "unions two tier lists in canonical tier order regardless of arg order" do
      assert Scope.merge_manifest_values(["tier1"], ["tier2"]) == ["tier1", "tier2"]
      assert Scope.merge_manifest_values(["tier2"], ["tier1"]) == ["tier1", "tier2"]
      assert Scope.merge_manifest_values(["dex"], ["tier1"]) == ["tier1", "dex"]
    end

    test "deduplicates overlapping tiers" do
      assert Scope.merge_manifest_values(["tier1"], ["tier1"]) == ["tier1"]
      assert Scope.merge_manifest_values(["tier1", "tier2"], ["tier2"]) == ["tier1", "tier2"]
    end

    test ~s("all" on either side absorbs the other) do
      assert Scope.merge_manifest_values("all", ["tier1"]) == "all"
      assert Scope.merge_manifest_values(["tier1"], "all") == "all"
      assert Scope.merge_manifest_values("all", "all") == "all"
    end

    test "exchange entries are deduplicated and sorted after tiers" do
      assert Scope.merge_manifest_values(["exchange:bybit"], ["tier1", "exchange:aave"]) ==
               ["tier1", "exchange:aave", "exchange:bybit"]

      assert Scope.merge_manifest_values(["exchange:kraken"], ["exchange:kraken"]) ==
               ["exchange:kraken"]
    end

    test "an empty list is the identity element" do
      assert Scope.merge_manifest_values([], ["tier1", "exchange:binance"]) ==
               ["tier1", "exchange:binance"]

      assert Scope.merge_manifest_values(["tier2"], []) == ["tier2"]
      assert Scope.merge_manifest_values([], []) == []
    end

    test "a merged result is byte-shape-identical to a single-shot to_manifest_value/1" do
      # The Task 114 invariant: a --tier1 then --tier2 sequence must
      # produce the same tier_scope as one --tier1 --tier2 invocation.
      sequenced = Scope.merge_manifest_values(["tier1"], ["tier2"])
      single_shot = Scope.to_manifest_value(tier1: true, tier2: true)
      assert sequenced == single_shot
    end
  end
end
