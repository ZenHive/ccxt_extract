defmodule CcxtExtract.SymbolsIndexTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.SymbolsIndex

  describe "derive/1" do
    test "returns nil for nil input" do
      assert SymbolsIndex.derive(nil) == nil
    end

    test "returns nil when :markets key is nil" do
      assert SymbolsIndex.derive(%{"market_count" => 0, "markets" => nil}) == nil
    end

    test "returns nil when :markets is an empty map" do
      assert SymbolsIndex.derive(%{"market_count" => 0, "markets" => %{}}) == nil
    end

    test "returns nil for unexpected shape" do
      assert SymbolsIndex.derive(%{}) == nil
      assert SymbolsIndex.derive("not a map") == nil
      assert SymbolsIndex.derive([]) == nil
    end

    test "marks a market as spot when market[\"spot\"] is true" do
      data = %{
        "market_count" => 1,
        "markets" => %{
          "BTC/USDT" => %{"spot" => true, "swap" => false, "type" => "spot"}
        }
      }

      assert SymbolsIndex.derive(data) == %{
               "BTC/USDT" => %{"spot" => true, "swap" => false}
             }
    end

    test "marks a market as swap when market[\"swap\"] is true" do
      data = %{
        "market_count" => 1,
        "markets" => %{
          "BTC/USDT:USDT" => %{"spot" => false, "swap" => true, "type" => "swap"}
        }
      }

      assert SymbolsIndex.derive(data) == %{
               "BTC/USDT:USDT" => %{"spot" => false, "swap" => true}
             }
    end

    test "falls back to market[\"type\"] when boolean is missing" do
      data = %{
        "market_count" => 2,
        "markets" => %{
          "BTC/USDT" => %{"type" => "spot"},
          "BTC/USDT:USDT" => %{"type" => "swap"}
        }
      }

      assert SymbolsIndex.derive(data) == %{
               "BTC/USDT" => %{"spot" => true, "swap" => false},
               "BTC/USDT:USDT" => %{"spot" => false, "swap" => true}
             }
    end

    test "returns both false for unknown market type (e.g. future, option)" do
      data = %{
        "market_count" => 2,
        "markets" => %{
          "BTC-240628" => %{"spot" => false, "swap" => false, "type" => "future"},
          "BTC-240628-50000-C" => %{"spot" => false, "swap" => false, "type" => "option"}
        }
      }

      assert SymbolsIndex.derive(data) == %{
               "BTC-240628" => %{"spot" => false, "swap" => false},
               "BTC-240628-50000-C" => %{"spot" => false, "swap" => false}
             }
    end

    test "handles mixed spot + swap + other types in one exchange" do
      data = %{
        "market_count" => 4,
        "markets" => %{
          "BTC/USDT" => %{"spot" => true, "swap" => false, "type" => "spot"},
          "BTC/USDT:USDT" => %{"spot" => false, "swap" => true, "type" => "swap"},
          "BTC-240628" => %{"spot" => false, "swap" => false, "type" => "future"},
          "ETH/USDT" => %{"type" => "spot"}
        }
      }

      assert SymbolsIndex.derive(data) == %{
               "BTC/USDT" => %{"spot" => true, "swap" => false},
               "BTC/USDT:USDT" => %{"spot" => false, "swap" => true},
               "BTC-240628" => %{"spot" => false, "swap" => false},
               "ETH/USDT" => %{"spot" => true, "swap" => false}
             }
    end

    test "handles non-map market entry gracefully" do
      data = %{
        "market_count" => 1,
        "markets" => %{
          "BOGUS" => nil
        }
      }

      assert SymbolsIndex.derive(data) == %{
               "BOGUS" => %{"spot" => false, "swap" => false}
             }
    end

    test "output contains only the two expected keys per symbol" do
      data = %{
        "market_count" => 1,
        "markets" => %{
          "BTC/USDT" => %{
            "spot" => true,
            "type" => "spot",
            "price" => 50_000,
            "precision" => %{"amount" => 8},
            "fees" => %{"trading" => %{"maker" => 0.001}},
            "baseId" => "BTC",
            "quoteId" => "USDT"
          }
        }
      }

      result = SymbolsIndex.derive(data)
      assert result["BTC/USDT"] |> Map.keys() |> Enum.sort() == ["spot", "swap"]
    end
  end
end
