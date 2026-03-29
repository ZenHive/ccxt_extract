defmodule CcxtExtract.ExchangesTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Exchanges

  describe "write!/1" do
    @tag :tmp_dir
    test "writes valid JSON with metadata envelope", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "exchanges.json")

      exchanges = [
        %{
          "id" => "test_exchange",
          "name" => "Test",
          "certified" => false,
          "pro" => false,
          "version" => "v1",
          "country" => ["US"],
          "alias" => false,
          "referral" => nil
        }
      ]

      assert :ok = Exchanges.write!(exchanges, output_path)
      assert File.exists?(output_path)

      output = output_path |> File.read!() |> Jason.decode!()
      assert is_binary(output["extracted_at"])
      assert output["count"] == 1
      assert length(output["exchanges"]) == 1
      assert hd(output["exchanges"])["id"] == "test_exchange"
    end
  end

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
