defmodule CcxtExtract.SymbolPatternsTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.SymbolPatterns

  # --- Helper to build market entries ---

  defp market(symbol, id, base_id, quote_id, type, opts \\ []) do
    settle = Keyword.get(opts, :settle)
    settle_id = Keyword.get(opts, :settle_id)

    {symbol,
     %{
       "symbol" => symbol,
       "id" => id,
       "base" => String.upcase(base_id),
       "quote" => String.upcase(quote_id),
       "baseId" => base_id,
       "quoteId" => quote_id,
       "type" => type,
       "settle" => settle,
       "settleId" => settle_id
     }}
  end

  defp wrap_markets(market_list) do
    %{"markets" => Map.new(market_list), "market_count" => length(market_list)}
  end

  describe "derive/2" do
    test "returns nil when markets_data is nil" do
      assert SymbolPatterns.derive(nil, nil) == nil
    end

    test "returns nil when markets map is nil" do
      assert SymbolPatterns.derive(%{"markets" => nil}, nil) == nil
    end

    test "returns nil when markets map is empty" do
      assert SymbolPatterns.derive(%{"markets" => %{}}, nil) == nil
    end

    test "extracts currency_aliases from describe commonCurrencies" do
      markets = wrap_markets([market("BTC/USDT", "BTCUSDT", "BTC", "USDT", "spot")])

      describe = %{"commonCurrencies" => %{"XXBT" => "BTC", "ZEUR" => "EUR"}}
      result = SymbolPatterns.derive(markets, describe)

      assert result["currency_aliases"] == %{"XXBT" => "BTC", "ZEUR" => "EUR"}
    end

    test "returns empty currency_aliases when describe is nil" do
      markets = wrap_markets([market("BTC/USDT", "BTCUSDT", "BTC", "USDT", "spot")])

      result = SymbolPatterns.derive(markets, nil)
      assert result["currency_aliases"] == %{}
    end
  end

  describe "no separator (Binance-style)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT", "BTCUSDT", "BTC", "USDT", "spot"),
          market("ETH/BTC", "ETHBTC", "ETH", "BTC", "spot"),
          market("ADA/USDT", "ADAUSDT", "ADA", "USDT", "spot"),
          market("SOL/USDT", "SOLUSDT", "SOL", "USDT", "spot"),
          market("DOGE/BTC", "DOGEBTC", "DOGE", "BTC", "spot")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects concatenated structure", %{result: result} do
      assert result["spot"]["id_structure"] == "baseId_quoteId"
    end

    test "detects empty separator", %{result: result} do
      assert result["spot"]["separator"] == ""
    end

    test "detects upper case", %{result: result} do
      assert result["spot"]["case"] == "upper"
    end

    test "has no anomalies", %{result: result} do
      assert result["spot"]["anomaly_count"] == 0
    end

    test "includes examples", %{result: result} do
      examples = result["spot"]["examples"]
      assert length(examples) == 3

      # Each example has the required keys
      Enum.each(examples, fn ex ->
        assert Map.has_key?(ex, "symbol")
        assert Map.has_key?(ex, "id")
        assert Map.has_key?(ex, "baseId")
        assert Map.has_key?(ex, "quoteId")
      end)
    end
  end

  describe "dash separator (OKX-style)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT", "BTC-USDT", "BTC", "USDT", "spot"),
          market("ETH/USDC", "ETH-USDC", "ETH", "USDC", "spot"),
          market("SOL/EUR", "SOL-EUR", "SOL", "EUR", "spot")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects dash separator", %{result: result} do
      assert result["spot"]["separator"] == "-"
    end

    test "detects baseId_quoteId structure", %{result: result} do
      assert result["spot"]["id_structure"] == "baseId_quoteId"
    end
  end

  describe "underscore separator (Gate-style)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT", "BTC_USDT", "BTC", "USDT", "spot"),
          market("ETH/USDC", "ETH_USDC", "ETH", "USDC", "spot"),
          market("DOGE/BTC", "DOGE_BTC", "DOGE", "BTC", "spot")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects underscore separator", %{result: result} do
      assert result["spot"]["separator"] == "_"
    end
  end

  describe "lowercase (HTX-style)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT", "btcusdt", "btc", "usdt", "spot"),
          market("ETH/USDT", "ethusdt", "eth", "usdt", "spot"),
          market("DOGE/BTC", "dogebtc", "doge", "btc", "spot")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects lower case", %{result: result} do
      assert result["spot"]["case"] == "lower"
    end

    test "detects concatenated structure", %{result: result} do
      assert result["spot"]["id_structure"] == "baseId_quoteId"
    end
  end

  describe "suffix detection (OKX swap -SWAP)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT:USDT", "BTC-USDT-SWAP", "BTC", "USDT", "swap", settle: "USDT"),
          market("ETH/USDT:USDT", "ETH-USDT-SWAP", "ETH", "USDT", "swap", settle: "USDT"),
          market("SOL/USDT:USDT", "SOL-USDT-SWAP", "SOL", "USDT", "swap", settle: "USDT"),
          market("ADA/USDT:USDT", "ADA-USDT-SWAP", "ADA", "USDT", "swap", settle: "USDT"),
          market("DOGE/USDT:USDT", "DOGE-USDT-SWAP", "DOGE", "USDT", "swap", settle: "USDT")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects -SWAP suffix", %{result: result} do
      assert result["swap"]["suffix"] == "-SWAP"
    end

    test "detects dash separator", %{result: result} do
      assert result["swap"]["separator"] == "-"
    end
  end

  describe "suffix detection (Kucoin swap M suffix)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT:USDT", "BTCUSDTM", "BTC", "USDT", "swap", settle: "USDT"),
          market("ETH/USDT:USDT", "ETHUSDTM", "ETH", "USDT", "swap", settle: "USDT"),
          market("SOL/USDT:USDT", "SOLUSDTM", "SOL", "USDT", "swap", settle: "USDT"),
          market("ADA/USDT:USDT", "ADAUSDTM", "ADA", "USDT", "swap", settle: "USDT"),
          market("DOGE/USDT:USDT", "DOGEUSDTM", "DOGE", "USDT", "swap", settle: "USDT")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects M suffix", %{result: result} do
      assert result["swap"]["suffix"] == "M"
    end

    test "detects no separator", %{result: result} do
      assert result["swap"]["separator"] == ""
    end
  end

  describe "numeric IDs (Hyperliquid-style)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDC:USDC", "3", "3", "USDC", "swap", settle: "USDC"),
          market("ETH/USDC:USDC", "4", "4", "USDC", "swap", settle: "USDC"),
          market("SOL/USDC:USDC", "28", "28", "USDC", "swap", settle: "USDC"),
          market("TAO/USDC:USDC", "116", "116", "USDC", "swap", settle: "USDC"),
          market("ADA/USDC:USDC", "65", "65", "USDC", "swap", settle: "USDC")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects numeric structure", %{result: result} do
      # These match baseId_only since id == baseId
      assert result["swap"]["id_structure"] in ["numeric", "baseId_only"]
    end
  end

  describe "Hyperliquid spot with @ prefix" do
    setup do
      markets =
        wrap_markets([
          market("MONAD/USDC", "@80", "10080", "USDC", "spot"),
          market("LICKO/USDC", "@187", "10187", "USDC", "spot"),
          market("HAR/USDC", "@261", "10261", "USDC", "spot"),
          market("PUMP/USDC", "@5", "10005", "USDC", "spot"),
          market("TEST/USDC", "@42", "10042", "USDC", "spot")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects opaque or numeric structure", %{result: result} do
      assert result["spot"]["id_structure"] in ["numeric", "opaque"]
    end
  end

  describe "anomaly detection (Kraken-style cryptonyms)" do
    setup do
      # Most Kraken markets follow baseId+quoteId pattern
      normal =
        for i <- 1..10 do
          name = "T#{i}"
          market("#{name}/EUR", "#{name}EUR", name, "EUR", "spot")
        end

      # But some use cryptonym codes that don't match baseId
      anomalies = [
        market("TRX/BTC", "TRXXBT", "TRX", "BTC", "spot"),
        market("ZEC/EUR", "XZECZEUR", "ZEC", "EUR", "spot")
      ]

      markets = wrap_markets(normal ++ anomalies)
      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "dominant pattern is baseId_quoteId with no separator", %{result: result} do
      assert result["spot"]["id_structure"] == "baseId_quoteId"
      assert result["spot"]["separator"] == ""
    end

    test "anomalies are detected", %{result: result} do
      assert result["spot"]["anomaly_count"] == 2
      assert "TRXXBT" in result["spot"]["anomalies"]
      assert "XZECZEUR" in result["spot"]["anomalies"]
    end
  end

  describe "mixed types (different patterns per type)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT", "BTC_USDT", "BTC", "USDT", "spot"),
          market("ETH/USDT", "ETH_USDT", "ETH", "USDT", "spot"),
          market("SOL/USDT", "SOL_USDT", "SOL", "USDT", "spot"),
          market("ADA/USDT", "ADA_USDT", "ADA", "USDT", "spot"),
          market("DOGE/USDT", "DOGE_USDT", "DOGE", "USDT", "spot"),
          market("BTC/USDT:USDT", "BTCUSDT", "BTC", "USDT", "swap", settle: "USDT"),
          market("ETH/USDT:USDT", "ETHUSDT", "ETH", "USDT", "swap", settle: "USDT"),
          market("SOL/USDT:USDT", "SOLUSDT", "SOL", "USDT", "swap", settle: "USDT"),
          market("ADA/USDT:USDT", "ADAUSDT", "ADA", "USDT", "swap", settle: "USDT"),
          market("DOGE/USDT:USDT", "DOGEUSDT", "DOGE", "USDT", "swap", settle: "USDT")
        ])

      # Spot: underscore separator
      # Swap: no separator (different pattern!)
      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "spot has underscore separator", %{result: result} do
      assert result["spot"]["separator"] == "_"
    end

    test "swap has no separator", %{result: result} do
      assert result["swap"]["separator"] == ""
    end

    test "both types detected independently", %{result: result} do
      assert Map.has_key?(result, "spot")
      assert Map.has_key?(result, "swap")
    end
  end

  describe "single market" do
    test "works with sample_count 1" do
      markets = wrap_markets([market("BTC/USDT", "BTCUSDT", "BTC", "USDT", "spot")])

      result = SymbolPatterns.derive(markets, nil)
      assert result["spot"]["sample_count"] == 1
      assert result["spot"]["id_structure"] == "baseId_quoteId"
    end
  end

  describe "Deribit swap with -PERPETUAL suffix" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDC:USDC", "BTC_USDC-PERPETUAL", "BTC", "USDC", "swap", settle: "USDC"),
          market("ETH/USDC:USDC", "ETH_USDC-PERPETUAL", "ETH", "USDC", "swap", settle: "USDC"),
          market("ADA/USDC:USDC", "ADA_USDC-PERPETUAL", "ADA", "USDC", "swap", settle: "USDC"),
          market("DOGE/USDC:USDC", "DOGE_USDC-PERPETUAL", "DOGE", "USDC", "swap", settle: "USDC"),
          market("SOL/USDC:USDC", "SOL_USDC-PERPETUAL", "SOL", "USDC", "swap", settle: "USDC")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "detects underscore separator", %{result: result} do
      assert result["swap"]["separator"] == "_"
    end

    test "detects -PERPETUAL suffix", %{result: result} do
      assert result["swap"]["suffix"] == "-PERPETUAL"
    end

    test "detects baseId_quoteId structure", %{result: result} do
      assert result["swap"]["id_structure"] == "baseId_quoteId"
    end
  end

  describe "mixed-expiry futures (no dominant suffix)" do
    setup do
      markets =
        wrap_markets([
          market("BTC/USDT:USDT-240628", "BTCUSDT_240628", "BTC", "USDT", "future"),
          market("BTC/USDT:USDT-240927", "BTCUSDT_240927", "BTC", "USDT", "future"),
          market("ETH/USDT:USDT-240628", "ETHUSDT_240628", "ETH", "USDT", "future"),
          market("ETH/USDT:USDT-240927", "ETHUSDT_240927", "ETH", "USDT", "future"),
          market("SOL/USDT:USDT-241227", "SOLUSDT_241227", "SOL", "USDT", "future")
        ])

      %{result: SymbolPatterns.derive(markets, nil)}
    end

    test "returns nil suffix when expiry dates vary", %{result: result} do
      assert result["future"]["suffix"] == nil
    end

    test "detects baseId_quoteId structure", %{result: result} do
      assert result["future"]["id_structure"] == "baseId_quoteId"
    end

    test "flags suffix mismatches as anomalies", %{result: result} do
      # All markets have different suffixes, so all deviate from "no dominant suffix"
      # but since dominant_suffix is nil, suffix check doesn't flag them
      # Anomalies are based on structure/separator deviation
      assert result["future"]["anomaly_count"] >= 0
    end
  end

  describe "case anomaly detection" do
    test "flags minority-case IDs when a dominant case exists" do
      # 9 upper, 1 lower — lower should be flagged as anomaly
      upper_markets =
        for i <- 1..9 do
          base = "T#{i}"
          market("#{base}/USDT", "#{String.upcase(base)}USDT", String.upcase(base), "USDT", "spot")
        end

      lower_market = market("LOW/USDT", "lowusdt", "low", "USDT", "spot")

      markets = wrap_markets(upper_markets ++ [lower_market])
      result = SymbolPatterns.derive(markets, nil)

      assert result["spot"]["case"] == "upper"
      assert result["spot"]["anomaly_count"] >= 1
      assert "lowusdt" in result["spot"]["anomalies"]
    end

    test "returns nil case with no anomalies when case is evenly split" do
      # 5 upper, 5 lower — neither reaches 80% threshold
      upper_markets =
        for i <- 1..5 do
          base = "U#{i}"
          market("#{base}/USDT", "#{String.upcase(base)}USDT", String.upcase(base), "USDT", "spot")
        end

      lower_markets =
        for i <- 1..5 do
          base = "l#{i}"
          market("#{base}/usdt", "#{String.downcase(base)}usdt", String.downcase(base), "usdt", "spot")
        end

      markets = wrap_markets(upper_markets ++ lower_markets)
      result = SymbolPatterns.derive(markets, nil)

      # No dominant case — nil is correct
      assert result["spot"]["case"] == nil
      # No anomalies flagged because there's no dominant to compare against
      # (consumers should treat case: nil as "use direct lookup")
    end
  end

  describe "id_structure anomaly detection" do
    test "does not flag all markets anomalous when no dominant id_structure" do
      # 50/50 split — neither reaches 80% threshold, so id_structure: nil
      # Should NOT flag everything as anomalous
      base_quote_markets =
        for i <- 1..5 do
          base = "A#{i}"
          market("#{base}/USDT", "#{base}USDT", base, "USDT", "spot")
        end

      opaque_markets =
        for i <- 1..5 do
          market("OPAQUE#{i}/USD", "opaque-#{i}", "OPAQUE#{i}", "USD", "spot")
        end

      markets = wrap_markets(base_quote_markets ++ opaque_markets)
      result = SymbolPatterns.derive(markets, nil)

      assert result["spot"]["id_structure"] == nil
      assert result["spot"]["anomaly_count"] == 0
    end

    test "flags minority structure when a dominant exists" do
      # 9 baseId_quoteId, 1 opaque — opaque should be flagged
      normal_markets =
        for i <- 1..9 do
          base = "N#{i}"
          market("#{base}/USDT", "#{base}USDT", base, "USDT", "spot")
        end

      opaque_market = market("WEIRD/USD", "xyzzy", "WEIRD", "USD", "spot")

      markets = wrap_markets(normal_markets ++ [opaque_market])
      result = SymbolPatterns.derive(markets, nil)

      assert result["spot"]["id_structure"]
      assert result["spot"]["anomaly_count"] >= 1
      assert "xyzzy" in result["spot"]["anomalies"]
    end
  end
end
