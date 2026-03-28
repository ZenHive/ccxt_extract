defmodule CcxtExtract.ExchangesTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Exchanges

  describe "normalize_referral/1" do
    test "nil returns nil" do
      assert Exchanges.normalize_referral(nil) == nil
    end

    test "string URL normalizes to object with zero discount" do
      assert Exchanges.normalize_referral("https://example.com/ref") == %{
               "url" => "https://example.com/ref",
               "discount" => 0
             }
    end

    test "object with url and discount passes through unchanged" do
      referral = %{"url" => "https://example.com/ref", "discount" => 0.1}
      assert Exchanges.normalize_referral(referral) == referral
    end

    test "object with url and zero discount passes through" do
      referral = %{"url" => "https://example.com/ref", "discount" => 0}
      assert Exchanges.normalize_referral(referral) == referral
    end

    test "object with url but no discount gets default zero discount" do
      assert Exchanges.normalize_referral(%{"url" => "https://example.com/ref"}) == %{
               "url" => "https://example.com/ref",
               "discount" => 0
             }
    end

    test "object with url and extra fields passes through" do
      referral = %{"url" => "https://example.com/ref", "discount" => 0.2, "extra" => "field"}
      assert Exchanges.normalize_referral(referral) == referral
    end

    test "unexpected type returns nil" do
      assert Exchanges.normalize_referral(42) == nil
      assert Exchanges.normalize_referral([]) == nil
      assert Exchanges.normalize_referral(%{"no_url_key" => "value"}) == nil
    end
  end
end
