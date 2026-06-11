defmodule Mix.Tasks.CcxtExtract.OxcScopeFlagsTest do
  @moduledoc """
  CLI-level tests for the OXC-backed extractor tasks scope flag surface.

  Covers Task 5 tasks (classes, methods, sign_methods, handle_errors,
  parse_methods, ws_methods) plus Task 6 tasks (interface_signatures,
  pagination, unified_endpoints, overrides).

  These assertions exercise the scope flag surface shared across all ten —
  argument parsing, `Scope.resolve/2` error mapping, `Mix.raise` message
  shaping — and fire before the OXC-parse stage.

  Argument-rejection tests (unknown options, stray positional args) run
  entirely off the CCXT source tree. Scope-resolution tests (`--all` +
  `--tier1`, unknown `--exchange`) call `TaskScope.load_universe/0`, which
  scans `priv/ccxt/ts/src/*.ts` — those tests require
  `mix ccxt_extract.setup` to have pulled the TS tree at least once.

  Deep extraction behavior (merge, envelope recompute) is covered by
  `CcxtExtract.AggregateWriterTest`.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.CcxtExtract.HandleErrors

  @tasks [
    Mix.Tasks.CcxtExtract.Classes,
    Mix.Tasks.CcxtExtract.Methods,
    Mix.Tasks.CcxtExtract.SignMethods,
    HandleErrors,
    Mix.Tasks.CcxtExtract.ParseMethods,
    Mix.Tasks.CcxtExtract.WsMethods,
    Mix.Tasks.CcxtExtract.InterfaceSignatures,
    Mix.Tasks.CcxtExtract.Pagination,
    Mix.Tasks.CcxtExtract.UnifiedEndpoints,
    Mix.Tasks.CcxtExtract.Overrides
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

  describe "TaskScope.scoped_ids_missing_file/2 (handle_errors dependency guard)" do
    @tmp_describe_dir Path.join(System.tmp_dir!(), "ccxt_extract_scope_describe_test")

    setup do
      File.rm_rf!(@tmp_describe_dir)
      File.mkdir_p!(@tmp_describe_dir)
      on_exit(fn -> File.rm_rf!(@tmp_describe_dir) end)
      :ok
    end

    test ":all scope returns an empty list regardless of directory contents" do
      # Nothing on disk, scope :all — still empty (full-universe runs tolerate gaps).
      assert CcxtExtract.TaskScope.scoped_ids_missing_file(:all, @tmp_describe_dir) == []
    end

    test "MapSet scope returns sorted IDs whose <id>.json is missing" do
      File.write!(Path.join(@tmp_describe_dir, "binance.json"), "{}")

      scope = MapSet.new(~w(binance bybit deribit))

      assert CcxtExtract.TaskScope.scoped_ids_missing_file(scope, @tmp_describe_dir) ==
               ~w(bybit deribit)
    end

    test "MapSet scope returns [] when every ID has a file" do
      for id <- ~w(binance bybit) do
        File.write!(Path.join(@tmp_describe_dir, "#{id}.json"), "{}")
      end

      scope = MapSet.new(~w(binance bybit))
      assert CcxtExtract.TaskScope.scoped_ids_missing_file(scope, @tmp_describe_dir) == []
    end

    test "exclude_aliases: true drops CCXT aliases before existence check" do
      # gate is a real non-alias; coinbaseadvanced + huobi are real aliases per
      # priv/discoveries/exchanges.json. With the file on disk only for gate,
      # the default guard flags coinbaseadvanced/huobi as missing; with
      # :exclude_aliases they are filtered out and the result is [].
      # (CCXT 4.5.57 retired the `gateio` alias previously used here.)
      File.write!(Path.join(@tmp_describe_dir, "gate.json"), "{}")
      scope = MapSet.new(~w(gate coinbaseadvanced huobi))

      assert CcxtExtract.TaskScope.scoped_ids_missing_file(scope, @tmp_describe_dir) ==
               ~w(coinbaseadvanced huobi)

      assert CcxtExtract.TaskScope.scoped_ids_missing_file(scope, @tmp_describe_dir, exclude_aliases: true) == []
    end

    test "exclude_aliases: true still reports non-alias missing ids" do
      # binance is not an alias, so its absence must still surface even with
      # exclude_aliases: true — the opt narrows the filter, not the check.
      File.write!(Path.join(@tmp_describe_dir, "gate.json"), "{}")
      scope = MapSet.new(~w(gate huobi binance))

      assert CcxtExtract.TaskScope.scoped_ids_missing_file(scope, @tmp_describe_dir, exclude_aliases: true) == ~w(binance)
    end
  end
end
