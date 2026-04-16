defmodule Mix.Tasks.CcxtExtract.AnalyticsScopeFlagsTest do
  @moduledoc """
  CLI-level tests for the analytics task scope flag surface.

  Covers the eight Task 7 analytics:
  derived (`summary`, `coverage`, `method_analysis`, `public_exchanges`,
  `validate_markets`, `family_analysis`) and QuickBEAM-backed
  (`describe_keys`, `describe_key_analysis`).

  Mirrors `oxc_scope_flags_test.exs`: assertions exercise the scope flag
  surface shared across all eight — argument parsing, `Scope.resolve/2`
  error mapping, `Mix.raise` message shaping — and fire from inside
  `TaskScope.parse_and_resolve!/3` before any file I/O or QuickBEAM start.

  Scope-resolution tests (`--all` + `--tier1`, unknown `--exchange`) call
  `TaskScope.load_universe/0`, which scans `priv/ccxt/ts/src/*.ts` —
  those tests require `mix ccxt_extract.setup` to have pulled the TS
  tree at least once.
  """
  # PrivWriteCase contains the one test (`--spot-check + --exchange`) that
  # actually executes a ValidateMarkets run to completion. Without write
  # redirection that run would mutate `priv/discoveries/market_validation.json`.
  use CcxtExtract.PrivWriteCase

  alias Mix.Tasks.CcxtExtract.ValidateMarkets

  @tasks [
    Mix.Tasks.CcxtExtract.Summary,
    Mix.Tasks.CcxtExtract.Coverage,
    Mix.Tasks.CcxtExtract.MethodAnalysis,
    Mix.Tasks.CcxtExtract.PublicExchanges,
    ValidateMarkets,
    Mix.Tasks.CcxtExtract.FamilyAnalysis,
    Mix.Tasks.CcxtExtract.DescribeKeys,
    Mix.Tasks.CcxtExtract.DescribeKeyAnalysis
  ]

  for task <- @tasks do
    describe "#{inspect(task)} argument parsing" do
      test "rejects unknown options" do
        assert_raise Mix.Error, ~r/Unknown option/, fn ->
          unquote(task).run(["--bogus"])
        end
      end

      test "rejects unexpected positional arguments" do
        assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
          unquote(task).run(["stray"])
        end
      end
    end

    describe "#{inspect(task)} scope resolution error mapping" do
      test "--all combined with --tier1 raises a clear conflict message" do
        assert_raise Mix.Error, ~r/--all conflicts with.*--tier1/, fn ->
          unquote(task).run(["--all", "--tier1"])
        end
      end

      test "unknown --exchange ID raises with a fuzzy suggestion" do
        # `xbinance` is a single-character prefix typo: Jaro similarity to
        # `binance` is well above the 0.7 suggestion threshold.
        assert_raise Mix.Error, ~r/Unknown --exchange ID.*binance/s, fn ->
          unquote(task).run(["--exchange", "xbinance"])
        end
      end
    end
  end

  describe "Mix.Tasks.CcxtExtract.ValidateMarkets flag migration" do
    test "legacy --exchanges flag (plural) is no longer accepted" do
      # Parallel to the same regression guard on `LoadMarkets` (Task 4).
      # `--exchanges` was the pre-Task-7 spot-check sample selector; it has
      # been replaced by canonical `--exchange ID` (repeatable) per the
      # Task 4 / Task 7 flag-canonicalisation pass.
      assert_raise Mix.Error, ~r/(unknown|invalid|--exchange)/i, fn ->
        ValidateMarkets.run(["--exchanges", "binance"])
      end
    end

    test "--spot-check combined with --exchange parses cleanly" do
      # Smoke that the `--spot-check` extra switch wired through
      # `TaskScope.parse_and_resolve!/3` is recognised alongside a
      # narrowing `--exchange` flag. We don't actually run the spot-check
      # (no QuickBEAM); we just assert the parse layer doesn't reject it.
      #
      # The task may still raise downstream (no manifest in test env); we
      # only care that it ISN'T a "Unknown option" error.
      try do
        ValidateMarkets.run(["--spot-check", "--exchange", "binance"])
      rescue
        e in Mix.Error ->
          refute Exception.message(e) =~ ~r/Unknown option/i,
                 "--spot-check + --exchange should parse cleanly, got: #{Exception.message(e)}"
      end
    end
  end
end
