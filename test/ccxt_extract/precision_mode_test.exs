defmodule CcxtExtract.PrecisionModeTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.PrecisionMode

  describe "derive/1" do
    test "returns nil for nil input" do
      assert PrecisionMode.derive(nil) == nil
    end

    test "returns nil for non-map input" do
      assert PrecisionMode.derive("nope") == nil
      assert PrecisionMode.derive([]) == nil
      assert PrecisionMode.derive(4) == nil
    end

    test "returns nil when describe carries no precisionMode key" do
      assert PrecisionMode.derive(%{}) == nil
      assert PrecisionMode.derive(%{"paddingMode" => 5, "id" => "x"}) == nil
    end

    test "decodes tick_size mode (4) + no_padding (5)" do
      assert PrecisionMode.derive(%{"precisionMode" => 4, "paddingMode" => 5}) ==
               %{"mode" => "tick_size", "padding_mode" => "no_padding"}
    end

    test "decodes decimal_places mode (2)" do
      assert PrecisionMode.derive(%{"precisionMode" => 2, "paddingMode" => 5}) ==
               %{"mode" => "decimal_places", "padding_mode" => "no_padding"}
    end

    test "decodes significant_digits mode (3)" do
      assert PrecisionMode.derive(%{"precisionMode" => 3, "paddingMode" => 5}) ==
               %{"mode" => "significant_digits", "padding_mode" => "no_padding"}
    end

    test "decodes pad_with_zero padding mode (6)" do
      assert PrecisionMode.derive(%{"precisionMode" => 4, "paddingMode" => 6}) ==
               %{"mode" => "tick_size", "padding_mode" => "pad_with_zero"}
    end

    test "padding_mode is nil when paddingMode key is absent" do
      assert PrecisionMode.derive(%{"precisionMode" => 4}) ==
               %{"mode" => "tick_size", "padding_mode" => nil}
    end

    test "unrecognized precisionMode integer decodes mode to nil, record still present" do
      assert PrecisionMode.derive(%{"precisionMode" => 99, "paddingMode" => 5}) ==
               %{"mode" => nil, "padding_mode" => "no_padding"}
    end

    test "unrecognized paddingMode decodes padding_mode to nil" do
      assert PrecisionMode.derive(%{"precisionMode" => 4, "paddingMode" => 0}) ==
               %{"mode" => "tick_size", "padding_mode" => nil}
    end

    test "ignores unrelated describe keys" do
      describe = %{
        "id" => "binance",
        "precisionMode" => 4,
        "paddingMode" => 5,
        "rateLimit" => 50,
        "urls" => %{"api" => "https://api.binance.com"}
      }

      assert PrecisionMode.derive(describe) ==
               %{"mode" => "tick_size", "padding_mode" => "no_padding"}
    end
  end
end
