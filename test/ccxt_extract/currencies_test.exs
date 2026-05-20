defmodule CcxtExtract.CurrenciesTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Currencies

  describe "derive/1" do
    test "returns nil for nil input" do
      assert Currencies.derive(nil) == nil
    end

    test "returns nil when currencies key is nil" do
      assert Currencies.derive(%{"currencies" => nil}) == nil
    end

    test "returns nil when currencies is empty map" do
      assert Currencies.derive(%{"currencies" => %{}}) == nil
    end

    test "returns nil for unexpected shapes" do
      assert Currencies.derive(%{}) == nil
      assert Currencies.derive("nope") == nil
      assert Currencies.derive([]) == nil
    end

    test "normalizes a simple currency and strips info" do
      input = %{
        "currencies" => %{
          "BTC" => %{
            "id" => "BTC",
            "code" => "BTC",
            "precision" => 8,
            "info" => %{"raw" => "huge"},
            "networks" => %{
              "BTC" => %{"id" => "BTC", "fee" => 0.0001, "info" => %{"vendor" => "x"}}
            }
          }
        }
      }

      assert Currencies.derive(input) == %{
               "BTC" => %{
                 "id" => "BTC",
                 "code" => "BTC",
                 "precision" => 8,
                 "networks" => %{
                   "BTC" => %{"id" => "BTC", "fee" => 0.0001}
                 }
               }
             }
    end

    test "wrapper with sparse currency fields preserves them (info strip + networks default only)" do
      input = %{"currencies" => %{"USDT" => %{"code" => "USDT", "networks" => %{}}}}

      assert Currencies.derive(input) == %{
               "USDT" => %{"code" => "USDT", "networks" => %{}}
             }
    end

    test "non-map currency entry collapses to empty map" do
      assert Currencies.derive(%{"currencies" => %{"BAD" => "not-a-map"}}) ==
               %{"BAD" => %{}}
    end

    test "non-map networks value falls back to empty map" do
      input = %{"currencies" => %{"BTC" => %{"id" => "BTC", "networks" => "not-a-map"}}}

      assert Currencies.derive(input) == %{"BTC" => %{"id" => "BTC", "networks" => %{}}}
    end

    test "non-map network entry collapses to empty map" do
      input = %{"currencies" => %{"BTC" => %{"networks" => %{"BTC" => "not-a-map"}}}}

      assert Currencies.derive(input) ==
               %{"BTC" => %{"networks" => %{"BTC" => %{}}}}
    end

    test "drops currency-level __undefined sentinels (QuickBEAM undefined leak)" do
      input = %{
        "currencies" => %{
          "XRP" => %{
            "id" => "XRP",
            "code" => "XRP",
            "precision" => "__undefined",
            "active" => "__undefined",
            "fee" => 0.0001,
            "networks" => %{}
          }
        }
      }

      assert Currencies.derive(input) == %{
               "XRP" => %{
                 "id" => "XRP",
                 "code" => "XRP",
                 "fee" => 0.0001,
                 "networks" => %{}
               }
             }
    end

    test "drops network-level __undefined sentinels recursively" do
      input = %{
        "currencies" => %{
          "XTZ" => %{
            "code" => "XTZ",
            "networks" => %{
              "XTZ" => %{"id" => "XTZ", "precision" => "__undefined", "fee" => "__undefined"}
            }
          }
        }
      }

      assert Currencies.derive(input) == %{
               "XTZ" => %{
                 "code" => "XTZ",
                 "networks" => %{"XTZ" => %{"id" => "XTZ"}}
               }
             }
    end

    test "walks list-valued fields, stripping __undefined inside nested maps" do
      input = %{
        "currencies" => %{
          "BTC" => %{
            "code" => "BTC",
            "tiers" => [%{"level" => 1, "rate" => "__undefined"}],
            "networks" => %{}
          }
        }
      }

      assert Currencies.derive(input) == %{
               "BTC" => %{
                 "code" => "BTC",
                 "tiers" => [%{"level" => 1}],
                 "networks" => %{}
               }
             }
    end

    test "strips __undefined nested inside non-typed maps (limits, fees)" do
      input = %{
        "currencies" => %{
          "BTC" => %{
            "code" => "BTC",
            "limits" => %{"amount" => %{"min" => "__undefined", "max" => 21_000_000}},
            "networks" => %{}
          }
        }
      }

      assert Currencies.derive(input) == %{
               "BTC" => %{
                 "code" => "BTC",
                 "limits" => %{"amount" => %{"max" => 21_000_000}},
                 "networks" => %{}
               }
             }
    end
  end
end
