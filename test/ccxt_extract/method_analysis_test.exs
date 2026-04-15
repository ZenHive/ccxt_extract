defmodule CcxtExtract.MethodAnalysisTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.MethodAnalysis

  # Mock exchanges — 5 REST exchanges with known method distributions
  @mock_rest_exchanges [
    %{
      "id" => "alpha",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{
          "name" => "fetchTicker",
          "async" => true,
          "params" => [%{"name" => "symbol", "type" => "string"}],
          "return_type" => "Promise<Ticker>",
          "statements" => 3
        },
        %{
          "name" => "parseTicker",
          "async" => false,
          "params" => [%{"name" => "ticker", "type" => "Dict"}],
          "return_type" => "Ticker",
          "statements" => 5
        },
        %{
          "name" => "fetchBalance",
          "async" => true,
          "params" => [],
          "return_type" => "Promise<Balances>",
          "statements" => 2
        },
        %{"name" => "createOrder", "async" => true, "params" => [], "return_type" => nil, "statements" => 4},
        %{"name" => "sign", "async" => false, "params" => [], "return_type" => nil, "statements" => 10},
        %{"name" => "nonce", "async" => false, "params" => [], "return_type" => nil, "statements" => 1},
        %{"name" => "rareMethod", "async" => false, "params" => [], "return_type" => nil, "statements" => 1}
      ]
    },
    %{
      "id" => "beta",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{"name" => "fetchTicker", "async" => true, "params" => [], "return_type" => nil, "statements" => 2},
        %{"name" => "parseTicker", "async" => false, "params" => [], "return_type" => nil, "statements" => 3},
        %{"name" => "fetchBalance", "async" => true, "params" => [], "return_type" => nil, "statements" => 2},
        %{"name" => "createOrder", "async" => true, "params" => [], "return_type" => nil, "statements" => 3},
        %{"name" => "sign", "async" => false, "params" => [], "return_type" => nil, "statements" => 8}
      ]
    },
    %{
      "id" => "gamma",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{"name" => "fetchTicker", "async" => true, "params" => [], "return_type" => nil, "statements" => 4},
        %{"name" => "parseTicker", "async" => false, "params" => [], "return_type" => nil, "statements" => 6},
        %{"name" => "sign", "async" => false, "params" => [], "return_type" => nil, "statements" => 12}
      ]
    },
    %{
      "id" => "delta",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{"name" => "fetchTicker", "async" => true, "params" => [], "return_type" => nil, "statements" => 2},
        %{"name" => "cancelOrder", "async" => true, "params" => [], "return_type" => nil, "statements" => 3}
      ]
    },
    %{
      "id" => "epsilon",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{"name" => "fetchTicker", "async" => true, "params" => [], "return_type" => nil, "statements" => 3},
        %{"name" => "parseTicker", "async" => false, "params" => [], "return_type" => nil, "statements" => 4},
        %{"name" => "sign", "async" => false, "params" => [], "return_type" => nil, "statements" => 6},
        %{"name" => "handleErrors", "async" => false, "params" => [], "return_type" => nil, "statements" => 15}
      ]
    }
  ]

  # Mock WS exchanges — 3 exchanges
  @mock_ws_exchanges [
    %{
      "id" => "alpha",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{"name" => "watchTicker", "async" => true, "params" => [], "return_type" => nil, "statements" => 5},
        %{"name" => "handleTicker", "async" => false, "params" => [], "return_type" => nil, "statements" => 8}
      ]
    },
    %{
      "id" => "beta",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{"name" => "watchTicker", "async" => true, "params" => [], "return_type" => nil, "statements" => 4},
        %{"name" => "handleTicker", "async" => false, "params" => [], "return_type" => nil, "statements" => 6},
        %{"name" => "watchOrderBook", "async" => true, "params" => [], "return_type" => nil, "statements" => 7}
      ]
    },
    %{
      "id" => "gamma",
      "methods" => [
        %{"name" => "describe", "async" => false, "params" => [], "return_type" => "any", "statements" => 1},
        %{"name" => "watchTicker", "async" => true, "params" => [], "return_type" => nil, "statements" => 3}
      ]
    }
  ]

  describe "extract_prefix/1" do
    test "extracts known prefixes from camelCase names" do
      assert MethodAnalysis.extract_prefix("fetchTicker") == "fetch"
      assert MethodAnalysis.extract_prefix("parseTrade") == "parse"
      assert MethodAnalysis.extract_prefix("createOrder") == "create"
      assert MethodAnalysis.extract_prefix("cancelOrder") == "cancel"
      assert MethodAnalysis.extract_prefix("editOrder") == "edit"
      assert MethodAnalysis.extract_prefix("watchTicker") == "watch"
      assert MethodAnalysis.extract_prefix("handleTicker") == "handle"
      assert MethodAnalysis.extract_prefix("setLeverage") == "set"
      assert MethodAnalysis.extract_prefix("getMarket") == "get"
      assert MethodAnalysis.extract_prefix("loadMarkets") == "load"
      assert MethodAnalysis.extract_prefix("buildHeaders") == "build"
      assert MethodAnalysis.extract_prefix("encodeBody") == "encode"
      assert MethodAnalysis.extract_prefix("decodeMessage") == "decode"
    end

    test "single-word known prefix returns itself" do
      assert MethodAnalysis.extract_prefix("sign") == "sign"
      assert MethodAnalysis.extract_prefix("fetch") == "fetch"
      assert MethodAnalysis.extract_prefix("encode") == "encode"
    end

    test "single-word unknown method goes to other" do
      assert MethodAnalysis.extract_prefix("describe") == "other"
      assert MethodAnalysis.extract_prefix("nonce") == "other"
    end

    test "unknown prefix goes to other" do
      assert MethodAnalysis.extract_prefix("rareMethod") == "other"
      assert MethodAnalysis.extract_prefix("customHelper") == "other"
    end
  end

  describe "group_by_family/1" do
    test "groups methods by prefix" do
      methods = %{
        "fetchTicker" => 5,
        "fetchBalance" => 4,
        "parseTicker" => 4,
        "describe" => 5,
        "sign" => 4
      }

      families = MethodAnalysis.group_by_family(methods)

      assert length(families["fetch"]) == 2
      assert length(families["parse"]) == 1
      assert length(families["sign"]) == 1
      assert length(families["other"]) == 1
    end

    test "includes count in each method entry" do
      methods = %{"fetchTicker" => 5, "fetchBalance" => 3}
      families = MethodAnalysis.group_by_family(methods)

      fetch_methods = families["fetch"]
      ticker = Enum.find(fetch_methods, &(&1["name"] == "fetchTicker"))
      assert ticker["count"] == 5
    end

    test "handles empty input" do
      assert MethodAnalysis.group_by_family(%{}) == %{}
    end
  end

  describe "method_count_distribution/1" do
    test "computes stats from exchanges" do
      dist = MethodAnalysis.method_count_distribution(@mock_rest_exchanges)

      # Counts: alpha=8, beta=6, gamma=4, delta=3, epsilon=5 → sorted: [3, 4, 5, 6, 8]
      assert dist["min"] == 3
      assert dist["max"] == 8
      assert dist["median"] == 5
      assert dist["mean"] == 5.2
      assert dist["p25"] == 4
      assert dist["p75"] == 6
    end

    test "handles empty list" do
      dist = MethodAnalysis.method_count_distribution([])
      assert dist["min"] == 0
      assert dist["max"] == 0
    end

    test "handles single exchange" do
      dist = MethodAnalysis.method_count_distribution([hd(@mock_rest_exchanges)])
      assert dist["min"] == 8
      assert dist["max"] == 8
      assert dist["median"] == 8
    end
  end

  describe "analyze_type/1" do
    test "produces complete structure" do
      result = MethodAnalysis.analyze_type(@mock_rest_exchanges)

      assert result["exchange_count"] == 5
      assert result["total_methods"] == 26
      assert is_integer(result["unique_method_names"])
      assert is_map(result["families"])
      assert is_list(result["universal_methods"])
      assert is_list(result["rare_methods"])
      assert is_map(result["method_count_distribution"])
    end

    test "identifies universal methods" do
      result = MethodAnalysis.analyze_type(@mock_rest_exchanges)

      universal_names = Enum.map(result["universal_methods"], & &1["name"])
      # describe and fetchTicker appear on all 5 exchanges
      assert "describe" in universal_names
      assert "fetchTicker" in universal_names
    end

    test "identifies unique methods (exactly 1 exchange)" do
      result = MethodAnalysis.analyze_type(@mock_rest_exchanges)

      unique_names = Enum.map(result["unique_methods"], & &1["name"])
      # rareMethod only on alpha, cancelOrder only on delta, handleErrors only on epsilon
      assert "rareMethod" in unique_names
      assert "cancelOrder" in unique_names
      assert "handleErrors" in unique_names

      # All unique methods must have count == 1
      for method <- result["unique_methods"] do
        assert method["count"] == 1,
               "Unique method '#{method["name"]}' should have count 1, got #{method["count"]}"
      end
    end

    test "identifies rare methods (fewer than 5 exchanges)" do
      result = MethodAnalysis.analyze_type(@mock_rest_exchanges)

      rare_names = Enum.map(result["rare_methods"], & &1["name"])
      # rareMethod only on alpha, cancelOrder only on delta, handleErrors only on epsilon
      assert "rareMethod" in rare_names
      assert "cancelOrder" in rare_names
      assert "handleErrors" in rare_names
    end

    test "families contain per-method exchange counts" do
      result = MethodAnalysis.analyze_type(@mock_rest_exchanges)

      fetch_family = result["families"]["fetch"]
      assert fetch_family["count"] == 2

      ticker = Enum.find(fetch_family["methods"], &(&1["name"] == "fetchTicker"))
      assert ticker["exchange_count"] == 5
      assert ticker["percentage"] == 100.0

      balance = Enum.find(fetch_family["methods"], &(&1["name"] == "fetchBalance"))
      assert balance["exchange_count"] == 2
      assert balance["percentage"] == 40.0
    end

    test "handles empty exchange list" do
      result = MethodAnalysis.analyze_type([])
      assert result["exchange_count"] == 0
      assert result["total_methods"] == 0
      assert result["families"] == %{}
    end
  end

  describe "analyze/2" do
    test "produces rest, ws, and cross_type sections" do
      rest_data = %{"exchanges" => @mock_rest_exchanges}
      ws_data = %{"exchanges" => @mock_ws_exchanges}
      analysis = MethodAnalysis.analyze(rest_data, ws_data)

      assert is_map(analysis["rest"])
      assert is_map(analysis["ws"])
      assert is_map(analysis["cross_type"])
      assert is_binary(analysis["extracted_at"])
    end

    test "cross-type identifies shared methods" do
      rest_data = %{"exchanges" => @mock_rest_exchanges}
      ws_data = %{"exchanges" => @mock_ws_exchanges}
      analysis = MethodAnalysis.analyze(rest_data, ws_data)
      cross = analysis["cross_type"]

      # describe appears in both REST and WS
      assert "describe" in cross["shared_methods"]
      assert cross["shared_count"] > 0
    end

    test "cross-type identifies REST-only methods" do
      rest_data = %{"exchanges" => @mock_rest_exchanges}
      ws_data = %{"exchanges" => @mock_ws_exchanges}
      analysis = MethodAnalysis.analyze(rest_data, ws_data)
      cross = analysis["cross_type"]

      # fetchTicker is REST-only in our mock data
      assert "fetchTicker" in cross["rest_only_methods"]
      assert "sign" in cross["rest_only_methods"]
    end

    test "cross-type identifies WS-only methods" do
      rest_data = %{"exchanges" => @mock_rest_exchanges}
      ws_data = %{"exchanges" => @mock_ws_exchanges}
      analysis = MethodAnalysis.analyze(rest_data, ws_data)
      cross = analysis["cross_type"]

      # watchTicker is WS-only
      assert "watchTicker" in cross["ws_only_methods"]
      assert "handleTicker" in cross["ws_only_methods"]
    end

    test "handles nil exchanges gracefully" do
      rest_data = %{"exchanges" => nil}
      ws_data = %{"exchanges" => nil}
      analysis = MethodAnalysis.analyze(rest_data, ws_data)

      assert analysis["rest"]["exchange_count"] == 0
      assert analysis["ws"]["exchange_count"] == 0
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "writes valid JSON with analysis data", %{tmp_dir: tmp_dir} do
      rest_data = %{"exchanges" => @mock_rest_exchanges}
      ws_data = %{"exchanges" => @mock_ws_exchanges}
      analysis = MethodAnalysis.analyze(rest_data, ws_data)
      output_path = Path.join(tmp_dir, "analysis.json")

      assert :ok = MethodAnalysis.write!(analysis, output_path: output_path)
      assert File.exists?(output_path)

      parsed = output_path |> File.read!() |> Jason.decode!()
      assert is_map(parsed["rest"])
      assert is_map(parsed["ws"])
      assert is_map(parsed["cross_type"])
    end
  end
end
