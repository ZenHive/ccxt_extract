defmodule CcxtExtract.PublicExchangesIntegrationTest do
  use ExUnit.Case, async: true

  import CcxtExtract.TaskHelpers

  alias CcxtExtract.PublicExchanges

  @moduletag :integration
  @moduletag timeout: 30_000

  # Reference exchanges from CLAUDE.md — Tier 1
  @tier_1 ~w(binance bybit okx deribit coinbaseexchange)
  # Tier 2
  @tier_2 ~w(kraken kucoin gate htx bitmex)
  # DEX
  @dex ~w(hyperliquid aster lighter)
  @all_reference @tier_1 ++ @tier_2 ++ @dex

  # Known credential patterns for reference exchanges
  @expected_patterns %{
    "binance" => ["apiKey", "secret"],
    "bybit" => ["apiKey", "secret"],
    "okx" => ["apiKey", "password", "secret"],
    "deribit" => ["apiKey", "secret"],
    "coinbaseexchange" => ["apiKey", "password", "secret"],
    "kraken" => ["apiKey", "secret"],
    "kucoin" => ["apiKey", "password", "secret"],
    "gate" => ["apiKey", "secret"],
    "htx" => ["apiKey", "secret"],
    "bitmex" => ["apiKey", "secret"],
    "hyperliquid" => ["privateKey", "walletAddress"],
    "aster" => ["apiKey", "secret"],
    "lighter" => ["privateKey"]
  }

  setup_all do
    {:ok, analysis} = PublicExchanges.extract()
    %{analysis: analysis}
  end

  describe "extract/0" do
    test "classifies 90+ exchanges", %{analysis: analysis} do
      assert analysis["exchange_count"] >= 90,
             "Expected 90+ exchanges, got #{analysis["exchange_count"]}"
    end

    test "summary fields are present", %{analysis: analysis} do
      summary = analysis["summary"]
      assert is_boolean(summary["all_have_fetch_markets"])
      assert is_integer(summary["credential_pattern_count"])
      assert is_integer(summary["fully_public_count"])
      assert is_integer(summary["fetch_markets_advertised_count"])
    end

    test "all exchanges advertise fetchMarkets", %{analysis: analysis} do
      assert analysis["summary"]["all_have_fetch_markets"],
             "Expected all exchanges to advertise fetchMarkets"

      assert analysis["summary"]["fetch_markets_advertised_count"] == analysis["exchange_count"]
    end

    test "at least one fully public exchange exists", %{analysis: analysis} do
      assert analysis["summary"]["fully_public_count"] >= 1
    end

    test "credential patterns sum to total exchange count", %{analysis: analysis} do
      pattern_sum =
        analysis["credential_patterns"]
        |> Enum.map(& &1["count"])
        |> Enum.sum()

      assert pattern_sum == analysis["exchange_count"],
             "Pattern sum #{pattern_sum} != exchange count #{analysis["exchange_count"]}"
    end

    test "credential patterns are sorted by count descending", %{analysis: analysis} do
      counts = Enum.map(analysis["credential_patterns"], & &1["count"])
      assert counts == Enum.sort(counts, :desc)
    end

    test "exchanges are sorted by id", %{analysis: analysis} do
      ids = Enum.map(analysis["exchanges"], & &1["id"])
      assert ids == Enum.sort(ids)
    end
  end

  describe "reference exchanges present" do
    for id <- @all_reference do
      test "#{id} is classified", %{analysis: analysis} do
        exchange = Enum.find(analysis["exchanges"], &(&1["id"] == unquote(id)))
        assert exchange, "#{unquote(id)} should be in output"
        assert exchange["has_fetch_markets"] == true
        assert is_list(exchange["credential_pattern"])
        assert is_map(exchange["required_credentials"])
      end
    end
  end

  describe "reference exchange credential patterns" do
    for {id, expected_pattern} <- @expected_patterns do
      test "#{id} has credential pattern #{inspect(expected_pattern)}", %{analysis: analysis} do
        exchange = Enum.find(analysis["exchanges"], &(&1["id"] == unquote(id)))
        assert exchange, "#{unquote(id)} should be in output"

        assert exchange["credential_pattern"] == unquote(Macro.escape(expected_pattern)),
               "#{unquote(id)} expected pattern #{inspect(unquote(Macro.escape(expected_pattern)))}, " <>
                 "got #{inspect(exchange["credential_pattern"])}"
      end
    end
  end

  describe "exchange classification structure" do
    test "every exchange has required fields", %{analysis: analysis} do
      for exchange <- analysis["exchanges"] do
        assert is_binary(exchange["id"]), "id should be a string"
        assert is_boolean(exchange["has_fetch_markets"]), "has_fetch_markets should be boolean for #{exchange["id"]}"
        assert is_list(exchange["credential_pattern"]), "credential_pattern should be a list for #{exchange["id"]}"
        assert is_map(exchange["required_credentials"]), "required_credentials should be a map for #{exchange["id"]}"

        # loadMarkets_callable removed — has_fetch_markets is the advertised capability
      end
    end

    test "credential patterns contain only known credential types", %{analysis: analysis} do
      known_types = ~w(accountId apiKey login password privateKey secret token twofa uid walletAddress)

      for exchange <- analysis["exchanges"] do
        for cred <- exchange["credential_pattern"] do
          assert cred in known_types,
                 "Unknown credential type '#{cred}' for #{exchange["id"]}"
        end
      end
    end
  end

  describe "analyze/1 pure function" do
    test "works with minimal mock data" do
      exchanges = [
        {"public_ex",
         %{"has" => %{"fetchMarkets" => true}, "requiredCredentials" => %{"apiKey" => false, "secret" => false}}},
        {"private_ex",
         %{"has" => %{"fetchMarkets" => true}, "requiredCredentials" => %{"apiKey" => true, "secret" => true}}}
      ]

      result = PublicExchanges.analyze(exchanges)

      assert result["exchange_count"] == 2
      assert result["summary"]["fully_public_count"] == 1
      assert result["summary"]["fetch_markets_advertised_count"] == 2
      assert length(result["credential_patterns"]) == 2
    end

    test "handles exchange with no requiredCredentials key" do
      exchanges = [
        {"bare_ex", %{"has" => %{"fetchMarkets" => true}}}
      ]

      result = PublicExchanges.analyze(exchanges)
      assert result["exchange_count"] == 1

      exchange = hd(result["exchanges"])
      assert exchange["credential_pattern"] == []
    end
  end

  describe "write!/1" do
    @tag :tmp_dir
    test "writes output file", %{analysis: analysis, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "public_exchanges.json")

      PublicExchanges.write!(analysis, output_path)
      assert File.exists?(output_path)

      written = output_path |> File.read!() |> Jason.decode!()
      assert written["exchange_count"] == analysis["exchange_count"]
      assert length(written["exchanges"]) == analysis["exchange_count"]
    end
  end

  describe "mix ccxt_extract.public_exchanges" do
    test "runs task and prints summary" do
      output = run_task_capturing_output(Mix.Tasks.CcxtExtract.PublicExchanges)

      assert output =~ "Analyzing exchange credential requirements"
      assert output =~ "Done."
      assert output =~ "exchanges classified"
      assert output =~ "fetchMarkets advertised"
      assert output =~ "Credential patterns"
    end
  end
end
