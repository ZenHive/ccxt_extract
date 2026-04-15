defmodule Mix.Tasks.CcxtExtract.QuickbeamScopeFlagsTest do
  @moduledoc """
  CLI-level tests for the four Task-4 QuickBEAM-backed extractor tasks:
  describe, url_templates, signing_fixtures, load_markets.

  Mirrors `oxc_scope_flags_test.exs`. Asserts the scope flag surface —
  argument parsing, `Scope.resolve/2` error mapping, `Mix.raise` message
  shaping — fires before the QuickBEAM stage, so tests stay fast and do
  not require a live JS runtime.

  Argument-rejection tests (unknown options, stray positional args) run
  entirely off the CCXT source tree. Scope-resolution tests (`--all` +
  `--tier1`, unknown `--exchange`) call `TaskScope.load_universe/0`, which
  scans `priv/ccxt/ts/src/*.ts` — those tests require
  `mix ccxt_extract.setup` to have pulled the TS tree at least once.
  """
  use ExUnit.Case, async: false

  @tasks [
    Mix.Tasks.CcxtExtract.Describe,
    Mix.Tasks.CcxtExtract.UrlTemplates,
    Mix.Tasks.CcxtExtract.SigningFixtures,
    Mix.Tasks.CcxtExtract.LoadMarkets
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
        # `xbinance` is a single-character prefix typo — Jaro similarity
        # is well above the 0.7 threshold, so `binance` should appear.
        ts_src = CcxtExtract.Paths.ts_src()

        if File.dir?(ts_src) do
          assert_raise Mix.Error, ~r/Unknown --exchange ID.*binance/s, fn ->
            unquote(task).run(["--exchange", "xbinance"])
          end
        end
      end
    end
  end
end
