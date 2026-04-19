defmodule CcxtExtract.TestnetUrlsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.TestnetUrls

  describe "derive/1 — separate_host pattern" do
    test "flat section map with no placeholders (binance-style)" do
      describe = %{
        "hostname" => "binance.com",
        "urls" => %{
          "test" => %{
            "fapiPrivate" => "https://testnet.binancefuture.com/fapi/v1",
            "fapiPublic" => "https://testnet.binancefuture.com/fapi/v1"
          }
        }
      }

      assert %{
               "pattern" => "separate_host",
               "urls" => %{
                 "fapiPrivate" => "https://testnet.binancefuture.com/fapi/v1",
                 "fapiPublic" => "https://testnet.binancefuture.com/fapi/v1"
               },
               "sandbox_flag_field" => nil,
               "unresolved_reason" => nil
             } = TestnetUrls.derive(describe)
    end

    test "flat map with {hostname} placeholders (bybit-style)" do
      describe = %{
        "hostname" => "bybit.com",
        "urls" => %{
          "test" => %{
            "public" => "https://api-testnet.{hostname}",
            "private" => "https://api-testnet.{hostname}",
            "spot" => "https://api-testnet.{hostname}"
          }
        }
      }

      result = TestnetUrls.derive(describe)

      assert result["pattern"] == "separate_host"
      assert result["urls"]["public"] == "https://api-testnet.bybit.com"
      assert result["urls"]["private"] == "https://api-testnet.bybit.com"
      assert result["urls"]["spot"] == "https://api-testnet.bybit.com"
      refute String.contains?(result["urls"]["public"], "{hostname}")
    end

    test "nested url set (host → section map)" do
      describe = %{
        "hostname" => "example.com",
        "urls" => %{
          "test" => %{
            "api-host-1" => %{"public" => "https://t1.{hostname}", "private" => "https://t1-priv.{hostname}"},
            "api-host-2" => %{"public" => "https://t2.{hostname}"}
          }
        }
      }

      result = TestnetUrls.derive(describe)

      assert result["pattern"] == "separate_host"
      assert result["urls"]["api-host-1"]["public"] == "https://t1.example.com"
      assert result["urls"]["api-host-1"]["private"] == "https://t1-priv.example.com"
      assert result["urls"]["api-host-2"]["public"] == "https://t2.example.com"
    end

    test "okx-style: same-host rest URL + sandboxMode flag coexist" do
      describe = %{
        "hostname" => "www.okx.com",
        "urls" => %{"test" => %{"rest" => "https://{hostname}"}},
        "options" => %{"sandboxMode" => false}
      }

      assert %{
               "pattern" => "separate_host",
               "urls" => %{"rest" => "https://www.okx.com"},
               "sandbox_flag_field" => "sandboxMode",
               "unresolved_reason" => nil
             } = TestnetUrls.derive(describe)
    end

    test "{hostname} survives when describe has no hostname" do
      describe = %{
        "urls" => %{"test" => %{"public" => "https://api-testnet.{hostname}"}}
      }

      result = TestnetUrls.derive(describe)

      assert result["pattern"] == "separate_host"
      # Unresolvable placeholder stays literal — contract invariant flags it.
      assert result["urls"]["public"] == "https://api-testnet.{hostname}"
    end

    test "empty urls.test map is not separate_host" do
      describe = %{"hostname" => "x.com", "urls" => %{"test" => %{}}}
      assert %{"pattern" => "none"} = TestnetUrls.derive(describe)
    end
  end

  describe "derive/1 — sandbox_flag pattern" do
    test "sandboxMode present, urls.test absent" do
      describe = %{"options" => %{"sandboxMode" => false}, "urls" => %{"api" => %{"public" => "https://api.x"}}}

      assert %{
               "pattern" => "sandbox_flag",
               "urls" => nil,
               "sandbox_flag_field" => "sandboxMode",
               "unresolved_reason" => nil
             } = TestnetUrls.derive(describe)
    end

    test "sandboxMode present even when value is true" do
      describe = %{"options" => %{"sandboxMode" => true}}
      assert %{"pattern" => "sandbox_flag", "sandbox_flag_field" => "sandboxMode"} = TestnetUrls.derive(describe)
    end
  end

  describe "derive/1 — none pattern" do
    test "no urls.test and no sandboxMode" do
      describe = %{"urls" => %{"api" => %{"public" => "https://api.x"}}}

      assert %{
               "pattern" => "none",
               "urls" => nil,
               "sandbox_flag_field" => nil,
               "unresolved_reason" => "no_testnet_data"
             } = TestnetUrls.derive(describe)
    end

    test "empty describe" do
      assert %{"pattern" => "none", "unresolved_reason" => "no_testnet_data"} = TestnetUrls.derive(%{})
    end

    test "nil describe (alias exchange)" do
      assert %{"pattern" => "none", "unresolved_reason" => "no_testnet_data"} = TestnetUrls.derive(nil)
    end

    test "non-map input returns none" do
      assert %{"pattern" => "none"} = TestnetUrls.derive("not a map")
      assert %{"pattern" => "none"} = TestnetUrls.derive(42)
    end
  end

  describe "shape helpers" do
    test "every derive/1 output has the required keys" do
      inputs = [
        nil,
        %{},
        %{"urls" => %{"test" => %{"public" => "https://x"}}},
        %{"options" => %{"sandboxMode" => false}}
      ]

      required = TestnetUrls.required_keys()

      for input <- inputs do
        result = TestnetUrls.derive(input)
        assert result |> Map.keys() |> Enum.sort() == Enum.sort(required)
      end
    end

    test "every derive/1 output's pattern is in patterns/0" do
      patterns = TestnetUrls.patterns()

      for input <- [nil, %{}, %{"urls" => %{"test" => %{"public" => "u"}}}, %{"options" => %{"sandboxMode" => false}}] do
        assert TestnetUrls.derive(input)["pattern"] in patterns
      end
    end
  end
end
