defmodule CcxtExtract.Test.ScopeThresholdsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Test.ScopeThresholds

  doctest CcxtExtract.Test.ScopeThresholds

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
end
