defmodule CcxtExtract.AliasesTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Aliases

  describe "alias_ids!/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "ccxt_aliases_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "returns MapSet of ids where alias == true", %{tmp: tmp} do
      path = Path.join(tmp, "exchanges.json")

      File.write!(
        path,
        Jason.encode!(%{
          "exchanges" => [
            %{"id" => "coinbase", "alias" => false},
            %{"id" => "coinbaseadvanced", "alias" => true},
            %{"id" => "htx", "alias" => false},
            %{"id" => "huobi", "alias" => true}
          ]
        })
      )

      assert Aliases.alias_ids!(path) == MapSet.new(~w(coinbaseadvanced huobi))
    end

    test "returns empty MapSet when no aliases present", %{tmp: tmp} do
      path = Path.join(tmp, "exchanges.json")

      File.write!(
        path,
        Jason.encode!(%{
          "exchanges" => [
            %{"id" => "binance", "alias" => false},
            %{"id" => "bybit", "alias" => false}
          ]
        })
      )

      assert Aliases.alias_ids!(path) == MapSet.new()
    end

    test "raises Mix.Error with remediation when file missing", %{tmp: tmp} do
      path = Path.join(tmp, "missing.json")

      assert_raise Mix.Error, ~r/Alias membership source missing.*mix ccxt_extract\.exchanges/s, fn ->
        Aliases.alias_ids!(path)
      end
    end

    test "happy path against the committed exchanges.json includes coinbaseadvanced + huobi" do
      # Smoke test the real artifact — documents the current CCXT alias set.
      # CCXT 4.5.57 retired the deprecated `gateio` alias; `gate` is now standalone.
      ids = Aliases.alias_ids!()
      assert MapSet.member?(ids, "coinbaseadvanced")
      assert MapSet.member?(ids, "huobi")
    end
  end

  describe "exclude_aliases/1" do
    test ":all passes through unchanged" do
      assert Aliases.exclude_aliases(:all) == :all
    end

    test "MapSet scope: subtracts alias ids from scope" do
      # Uses the committed exchanges.json — coinbaseadvanced + huobi are known aliases.
      scope = MapSet.new(~w(gate coinbaseadvanced htx huobi binance))
      filtered = Aliases.exclude_aliases(scope)
      refute MapSet.member?(filtered, "coinbaseadvanced")
      refute MapSet.member?(filtered, "huobi")
      assert MapSet.member?(filtered, "gate")
      assert MapSet.member?(filtered, "htx")
      assert MapSet.member?(filtered, "binance")
    end

    test "MapSet scope without aliases is unchanged" do
      scope = MapSet.new(~w(binance bybit deribit))
      assert Aliases.exclude_aliases(scope) == scope
    end
  end
end
