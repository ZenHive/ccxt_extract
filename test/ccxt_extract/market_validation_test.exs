defmodule CcxtExtract.MarketValidationTest do
  @moduledoc """
  Unit tests for MarketValidation pure functions.
  Uses synthetic market data — no file I/O, no QuickBEAM.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.MarketValidation
  alias Mix.Tasks.CcxtExtract.ValidateMarkets

  # --- Synthetic test data ---

  @valid_spot_market %{
    "symbol" => "BTC/USDT",
    "id" => "BTCUSDT",
    "base" => "BTC",
    "quote" => "USDT",
    "type" => "spot",
    "spot" => true,
    "swap" => false,
    "future" => false,
    "option" => false,
    "contract" => false,
    "active" => true,
    "linear" => "__undefined",
    "inverse" => "__undefined",
    "precision" => %{"amount" => 0.001, "price" => 0.01},
    "limits" => %{
      "amount" => %{"min" => 0.001, "max" => 1000},
      "price" => %{"min" => 0.01, "max" => 100_000}
    }
  }

  @valid_swap_market %{
    "symbol" => "BTC/USDT:USDT",
    "id" => "BTCUSDT",
    "base" => "BTC",
    "quote" => "USDT",
    "type" => "swap",
    "spot" => false,
    "swap" => true,
    "future" => false,
    "option" => false,
    "contract" => true,
    "active" => true,
    "linear" => true,
    "inverse" => false,
    "precision" => %{"amount" => 0.001, "price" => 0.01},
    "limits" => %{
      "amount" => %{"min" => 0.001, "max" => 1000},
      "price" => %{"min" => 0.01, "max" => 100_000}
    }
  }

  @valid_exchange %{
    "id" => "testexchange",
    "market_count" => 2,
    "markets" => %{
      "BTC/USDT" => @valid_spot_market,
      "BTC/USDT:USDT" => @valid_swap_market
    }
  }

  describe "validate_exchange/1" do
    test "returns clean report for valid exchange" do
      report = MarketValidation.validate_exchange(@valid_exchange)

      assert report["id"] == "testexchange"
      assert report["market_count"] == 2
      assert report["errors"] == []
      assert report["warnings"] == []
    end

    test "includes undefined density" do
      report = MarketValidation.validate_exchange(@valid_exchange)
      density = report["undefined_density"]

      assert is_integer(density["undefined_count"])
      assert is_integer(density["total_fields"])
      assert is_float(density["density_pct"])
    end
  end

  describe "market_count consistency" do
    test "mismatched market_count produces error" do
      exchange = %{
        "id" => "test",
        "market_count" => 99,
        "markets" => %{"BTC/USDT" => @valid_spot_market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "market_count mismatch"))
    end

    test "matching market_count produces no error" do
      report = MarketValidation.validate_exchange(@valid_exchange)
      refute Enum.any?(report["errors"], &String.contains?(&1, "market_count"))
    end

    test "nil market_count is tolerated" do
      exchange = %{
        "id" => "test",
        "markets" => %{"BTC/USDT" => @valid_spot_market}
      }

      report = MarketValidation.validate_exchange(exchange)
      refute Enum.any?(report["errors"], &String.contains?(&1, "market_count"))
    end
  end

  describe "required field checks" do
    test "missing symbol produces error" do
      market = Map.delete(@valid_spot_market, "symbol")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "symbol"))
    end

    test "nil required field produces error" do
      market = Map.put(@valid_spot_market, "base", nil)

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "base"))
    end

    test "__undefined required field produces error" do
      market = Map.put(@valid_spot_market, "type", "__undefined")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "type"))
    end
  end

  describe "type checks" do
    test "non-boolean spot field produces error" do
      market = Map.put(@valid_spot_market, "spot", "true")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "spot"))
    end

    test "non-map precision produces error" do
      market = Map.put(@valid_spot_market, "precision", "bad")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "precision"))
    end

    test "non-map limits produces error" do
      market = Map.put(@valid_spot_market, "limits", [1, 2])

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "limits"))
    end

    test "non-boolean linear field produces error" do
      market = Map.put(@valid_swap_market, "linear", "true")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "linear"))
    end

    test "non-boolean inverse field produces error" do
      market = Map.put(@valid_swap_market, "inverse", "false")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["errors"], &String.contains?(&1, "inverse"))
    end

    test "__undefined boolean fields are tolerated as warning not error" do
      market = Map.put(@valid_spot_market, "contract", "__undefined")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"OK" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      # __undefined booleans are warnings, not errors — CCXT sometimes leaves them undefined
      assert report["errors"] == [] or
               not Enum.any?(report["errors"], &String.contains?(&1, "contract"))
    end
  end

  describe "consistency checks (warnings)" do
    test "type=swap with swap=false produces warning" do
      market = %{@valid_swap_market | "swap" => false}

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["warnings"], &String.contains?(&1, "swap"))
    end

    test "type=spot with spot=false produces warning" do
      market = %{@valid_spot_market | "spot" => false}

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["warnings"], &String.contains?(&1, "spot"))
    end

    test "contract=true with type=spot produces warning" do
      market = %{@valid_spot_market | "contract" => true}

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["warnings"], &String.contains?(&1, "contract"))
    end

    test "linear=true with contract=false produces warning" do
      market = %{@valid_spot_market | "linear" => true, "contract" => false}

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"BAD" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      assert Enum.any?(report["warnings"], &String.contains?(&1, "linear"))
    end
  end

  describe "mix task CLI validation" do
    test "legacy --exchanges flag (plural) is no longer accepted" do
      assert_raise Mix.Error, ~r/(unknown|invalid|--exchange)/i, fn ->
        ValidateMarkets.run(["--exchanges", "binance"])
      end
    end
  end

  describe "validate/1 file-level" do
    @tag :tmp_dir
    test "returns error when manifest is missing", %{tmp_dir: tmp_dir} do
      assert {:error, {:missing_input, path}} = MarketValidation.validate(input_dir: tmp_dir)
      assert path =~ "_manifest.json"
    end

    @tag :tmp_dir
    test "returns error when manifest references missing exchange file", %{tmp_dir: tmp_dir} do
      manifest = %{"succeeded" => ["ghost_exchange"], "failed" => []}
      File.write!(Path.join(tmp_dir, "_manifest.json"), Jason.encode!(manifest))

      assert {:error, {:missing_input, path}} = MarketValidation.validate(input_dir: tmp_dir)
      assert path =~ "ghost_exchange.json"
    end

    @tag :tmp_dir
    test "succeeds when all manifest exchange files exist", %{tmp_dir: tmp_dir} do
      exchange_data = %{
        "id" => "testex",
        "market_count" => 1,
        "markets" => %{"BTC/USDT" => @valid_spot_market}
      }

      manifest = %{"succeeded" => ["testex"], "failed" => []}
      File.write!(Path.join(tmp_dir, "_manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(tmp_dir, "testex.json"), Jason.encode!(exchange_data))

      assert {:ok, report} = MarketValidation.validate(input_dir: tmp_dir)
      assert report["exchange_count"] == 1
    end

    @tag :tmp_dir
    test "raises when manifest is malformed and succeeded key is missing", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "_manifest.json"), Jason.encode!(%{"failed" => []}))

      assert_raise Protocol.UndefinedError, fn ->
        MarketValidation.validate(input_dir: tmp_dir)
      end
    end

    @tag :tmp_dir
    test "spot-check skips cleanly when scope narrows succeeded list to empty", %{tmp_dir: tmp_dir} do
      # Regression guard: pre-fix, `spot_check_sample/2` returned [] and the
      # downstream `spot_check/2` crashed. Post-fix, `spot_check` is nil and
      # the rest of the report is still produced.
      exchange_data = %{
        "id" => "testex",
        "market_count" => 1,
        "markets" => %{"BTC/USDT" => @valid_spot_market}
      }

      manifest = %{"succeeded" => ["testex"], "failed" => []}
      File.write!(Path.join(tmp_dir, "_manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(tmp_dir, "testex.json"), Jason.encode!(exchange_data))

      assert {:ok, report} =
               MarketValidation.validate(
                 input_dir: tmp_dir,
                 spot_check: true,
                 scope: MapSet.new(["nonexistent"])
               )

      assert report["exchange_count"] == 0
      assert report["spot_check"] == nil
    end
  end

  describe "undefined density" do
    test "counts __undefined fields" do
      market =
        @valid_spot_market
        |> Map.put("maker", "__undefined")
        |> Map.put("taker", "__undefined")
        |> Map.put("expiry", "__undefined")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"M" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      density = report["undefined_density"]

      # The market had 2 __undefined already (linear, inverse) + 3 added = 5
      # But density counts ALL values including nested maps
      assert density["undefined_count"] >= 5
      assert density["total_fields"] > 0
      assert density["density_pct"] > 0
    end

    test "market with no __undefined has zero density" do
      market = Map.delete(@valid_swap_market, "lowercaseId")

      exchange = %{
        "id" => "test",
        "market_count" => 1,
        "markets" => %{"M" => market}
      }

      report = MarketValidation.validate_exchange(exchange)
      density = report["undefined_density"]
      assert density["undefined_count"] == 0
    end
  end
end
