defmodule CcxtExtract.Test.ScopeThresholdsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Test.ScopeThresholds

  doctest ScopeThresholds

  describe "full_universe?/1" do
    test "true when tier_scope == \"all\"" do
      assert ScopeThresholds.full_universe?(%{"tier_scope" => "all"})
    end

    test "false when tier_scope is a list" do
      refute ScopeThresholds.full_universe?(%{"tier_scope" => ["tier1"]})
      refute ScopeThresholds.full_universe?(%{"tier_scope" => ["tier1", "tier2", "dex"]})
      refute ScopeThresholds.full_universe?(%{"tier_scope" => ["exchange:binance"]})
    end

    test "true when tier_scope is missing (legacy fixture compatibility)" do
      assert ScopeThresholds.full_universe?(%{})
      assert ScopeThresholds.full_universe?(%{"count" => 110})
    end
  end

  describe "proportional/2" do
    test "rounds to nearest integer" do
      assert ScopeThresholds.proportional(100, 0.75) == 75
      assert ScopeThresholds.proportional(34, 0.5) == 17
      assert ScopeThresholds.proportional(7, 0.3) == 2
    end

    test "handles zero observed" do
      assert ScopeThresholds.proportional(0, 0.75) == 0
    end
  end

  describe "in_scope?/2" do
    test "all scope includes every exchange" do
      assert ScopeThresholds.in_scope?("bitget", "all")
      assert ScopeThresholds.in_scope?("binance", "all")
    end

    test "tier list resolves via Tiers.members_for_tier/1" do
      assert ScopeThresholds.in_scope?("binance", ["tier1", "dex"])
      assert ScopeThresholds.in_scope?("hyperliquid", ["tier1", "dex"])
      refute ScopeThresholds.in_scope?("bitget", ["tier1", "dex"])
      refute ScopeThresholds.in_scope?("kucoin", ["tier1", "dex"])
    end

    test "exchange: entries add explicit IDs" do
      assert ScopeThresholds.in_scope?("bitget", ["exchange:bitget"])
      refute ScopeThresholds.in_scope?("binance", ["exchange:bitget"])
    end

    test "implicit scope uses on-disk output files" do
      on_disk =
        "output"
        |> CcxtExtract.Paths.priv()
        |> CcxtExtract.TaskScope.rebuild_manifest_exchanges()

      for id <- on_disk do
        assert ScopeThresholds.in_scope?(id, :implicit)
      end

      refute ScopeThresholds.in_scope?("definitely_not_in_fixture_scope_xyz", :implicit)
    end
  end

  describe "corpus_in_scope?/1" do
    test "reads output manifest tier_scope at runtime" do
      # Linked corpus: output manifest lacks tier_scope → implicit on-disk scope.
      # binance is always present (test_helper sentinel); bitget is tier3 and absent.
      assert ScopeThresholds.corpus_in_scope?("binance")
      refute ScopeThresholds.corpus_in_scope?("bitget")
    end
  end

  describe "skip_unless_corpus_in_scope!/1" do
    test "returns :proceed for in-scope exchanges" do
      assert ScopeThresholds.skip_unless_corpus_in_scope!("binance") == :proceed
    end

    test "returns :skip for out-of-scope exchanges" do
      assert ScopeThresholds.skip_unless_corpus_in_scope!("bitget") == :skip
    end
  end
end
