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
  end
end
