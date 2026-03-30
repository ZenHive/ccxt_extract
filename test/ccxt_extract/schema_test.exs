defmodule CcxtExtract.SchemaTest do
  @moduledoc """
  Unit tests for Schema pure functions.
  Uses synthetic data — no file I/O, no QuickBEAM/OXC.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Schema

  # --- Synthetic data builders ---

  @base_opts [ccxt_version: "4.5.45", extracted_at: "2026-03-30T12:00:00Z"]

  @full_meta %{
    "id" => "testex",
    "name" => "Test Exchange",
    "certified" => true,
    "pro" => true,
    "version" => "v3",
    "country" => ["US", "GB"],
    "alias" => false,
    "referral" => %{"url" => "https://test.com/ref", "discount" => 0.1}
  }

  @alias_meta %{
    "id" => "aliasex",
    "name" => "Alias Exchange",
    "certified" => false,
    "pro" => false,
    "version" => nil,
    "country" => [],
    "alias" => true,
    "referral" => nil
  }

  @sample_method_ast %{
    "async" => false,
    "params" => [%{"name" => "path", "type" => "string"}, %{"name" => "api", "type" => nil}],
    "return_type" => nil,
    "statements" => 12,
    "body" => %{"type" => "BlockStatement", "start" => 100, "end" => 500, "body" => []}
  }

  @sample_class_entry %{
    "node_key" => "rest:testex",
    "class_name" => "testex",
    "id" => "testex",
    "type" => "rest",
    "extends_raw" => "Exchange",
    "extends_resolved" => "Exchange",
    "parent_key" => "Exchange",
    "file" => "testex.ts",
    "method_count" => 42,
    "methods" => ["describe", "fetchTicker"],
    "method_details" => [
      %{"name" => "describe", "async" => false, "params" => 0, "statements" => 1}
    ]
  }

  @sample_method_sig %{
    "name" => "fetchTicker",
    "async" => true,
    "params" => [%{"name" => "symbol", "type" => "string"}],
    "return_type" => "Ticker",
    "statements" => 5
  }

  # Builds a full runtime data map
  defp full_runtime do
    %{
      "describe" => %{"id" => "testex", "has" => %{"fetchTicker" => true}},
      "markets" => %{"market_count" => 100, "markets" => %{"BTC/USDT" => %{"active" => true}}}
    }
  end

  # Builds a full structure data map
  defp full_structure do
    %{
      "class_info" => %{"rest" => @sample_class_entry, "ws" => nil},
      "methods" => %{"rest" => [@sample_method_sig], "ws" => nil},
      "sign_method" => @sample_method_ast,
      "handle_errors" => %{
        "method" => @sample_method_ast,
        "exceptions" => %{"broad" => %{"error" => "ExchangeError"}, "exact" => %{}},
        "http_exceptions" => %{"429" => "RateLimitExceeded"}
      },
      "parse_methods" => %{"parseTicker" => @sample_method_ast},
      "ws_methods" => %{"watchTicker" => @sample_method_ast},
      "overrides" => nil
    }
  end

  # Null runtime for alias exchanges
  defp alias_runtime do
    %{"describe" => nil, "markets" => nil}
  end

  # Null structure for alias exchanges
  defp alias_structure do
    %{
      "class_info" => nil,
      "methods" => nil,
      "sign_method" => nil,
      "handle_errors" => nil,
      "parse_methods" => nil,
      "ws_methods" => nil,
      "overrides" => nil
    }
  end

  # --- schema_version/0 ---

  test "schema_version returns 1.0" do
    assert Schema.schema_version() == "1.0"
  end

  # --- build_exchange/4 ---

  describe "build_exchange/4" do
    test "builds complete output for a full exchange" do
      result = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)

      assert result["schema_version"] == "1.0"
      assert result["extracted_at"] == "2026-03-30T12:00:00Z"
      assert result["ccxt_version"] == "4.5.45"

      assert result["exchange"]["id"] == "testex"
      assert result["exchange"]["name"] == "Test Exchange"
      assert result["exchange"]["pro"] == true
      assert result["exchange"]["alias"] == false
      assert result["exchange"]["referral"]["discount"] == 0.1

      assert result["runtime"]["describe"]["has"]["fetchTicker"] == true
      assert result["runtime"]["markets"]["market_count"] == 100

      assert result["structure"]["sign_method"]["body"]["type"] == "BlockStatement"
      assert result["structure"]["parse_methods"]["parseTicker"]["statements"] == 12
      assert result["structure"]["ws_methods"]["watchTicker"]["async"] == false
      assert result["structure"]["overrides"] == nil
    end

    test "builds output for alias exchange with null layers" do
      result = Schema.build_exchange(@alias_meta, alias_runtime(), alias_structure(), @base_opts)

      assert result["exchange"]["alias"] == true
      assert result["runtime"]["describe"] == nil
      assert result["runtime"]["markets"] == nil
      assert result["structure"]["sign_method"] == nil
      assert result["structure"]["parse_methods"] == nil
      assert result["structure"]["ws_methods"] == nil
    end

    test "builds output for non-pro exchange (no WS layers)" do
      meta = %{@full_meta | "pro" => false}
      structure = %{full_structure() | "ws_methods" => nil, "methods" => %{"rest" => [@sample_method_sig], "ws" => nil}}
      result = Schema.build_exchange(meta, full_runtime(), structure, @base_opts)

      assert result["exchange"]["pro"] == false
      assert result["structure"]["ws_methods"] == nil
      assert result["structure"]["methods"]["ws"] == nil
    end

    test "builds output for derived exchange with overrides" do
      overrides = %{
        "extends" => "parentex",
        "parent_key" => "rest:parentex",
        "overridden" => %{"describe" => @sample_method_ast},
        "new_methods" => %{"fetchCustom" => @sample_method_ast},
        "inherited" => ["fetchTicker", "fetchBalance"]
      }

      structure = %{full_structure() | "overrides" => overrides}
      result = Schema.build_exchange(@full_meta, full_runtime(), structure, @base_opts)

      assert result["structure"]["overrides"]["extends"] == "parentex"
      assert result["structure"]["overrides"]["overridden"]["describe"]["statements"] == 12
      assert result["structure"]["overrides"]["inherited"] == ["fetchTicker", "fetchBalance"]
    end

    test "defaults extracted_at to current time when not provided" do
      opts = Keyword.delete(@base_opts, :extracted_at)
      result = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), opts)

      assert is_binary(result["extracted_at"])
      assert String.contains?(result["extracted_at"], "T")
    end

    test "raises when ccxt_version is missing" do
      assert_raise KeyError, fn ->
        Schema.build_exchange(@full_meta, full_runtime(), full_structure(), [])
      end
    end

    test "defaults missing boolean fields to false" do
      sparse_meta = %{"id" => "sparse", "name" => "Sparse", "alias" => false}
      result = Schema.build_exchange(sparse_meta, alias_runtime(), alias_structure(), @base_opts)

      assert result["exchange"]["certified"] == false
      assert result["exchange"]["pro"] == false
    end
  end

  # --- validate/1 ---

  describe "validate/1" do
    test "accepts a valid full exchange" do
      exchange = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
      assert :ok = Schema.validate(exchange)
    end

    test "accepts a valid alias exchange" do
      exchange = Schema.build_exchange(@alias_meta, alias_runtime(), alias_structure(), @base_opts)
      assert :ok = Schema.validate(exchange)
    end

    test "rejects non-map input" do
      assert {:error, ["expected a map"]} = Schema.validate("not a map")
    end

    test "rejects missing top-level keys" do
      assert {:error, reasons} = Schema.validate(%{})
      assert Enum.any?(reasons, &String.contains?(&1, "top-level"))
    end

    test "rejects missing exchange section keys" do
      bad = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
      bad = put_in(bad, ["exchange"], %{})
      assert {:error, reasons} = Schema.validate(bad)
      assert Enum.any?(reasons, &String.contains?(&1, "exchange"))
    end

    test "rejects wrong schema version" do
      bad = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
      bad = Map.put(bad, "schema_version", "2.0")
      assert {:error, reasons} = Schema.validate(bad)
      assert Enum.any?(reasons, &String.contains?(&1, "schema_version"))
    end

    test "rejects non-map runtime.describe" do
      bad = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
      bad = put_in(bad, ["runtime", "describe"], "not a map")
      assert {:error, reasons} = Schema.validate(bad)
      assert Enum.any?(reasons, &String.contains?(&1, "runtime.describe"))
    end

    test "rejects non-map structure.parse_methods values" do
      bad = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
      bad = put_in(bad, ["structure", "parse_methods"], %{"bad" => "not a method"})
      assert {:error, reasons} = Schema.validate(bad)
      assert Enum.any?(reasons, &String.contains?(&1, "parse_methods.bad"))
    end

    test "rejects MethodAST missing body key" do
      incomplete_ast = Map.delete(@sample_method_ast, "body")
      bad = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
      bad = put_in(bad, ["structure", "sign_method"], incomplete_ast)
      assert {:error, reasons} = Schema.validate(bad)
      assert Enum.any?(reasons, &String.contains?(&1, "sign_method"))
    end

    test "accepts null values for optional structure fields" do
      structure = %{
        "class_info" => nil,
        "methods" => nil,
        "sign_method" => nil,
        "handle_errors" => nil,
        "parse_methods" => nil,
        "ws_methods" => nil,
        "overrides" => nil
      }

      exchange = Schema.build_exchange(@full_meta, full_runtime(), structure, @base_opts)
      assert :ok = Schema.validate(exchange)
    end
  end

  # --- validate!/1 ---

  describe "validate!/1" do
    test "returns :ok for valid data" do
      exchange = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
      assert :ok = Schema.validate!(exchange)
    end

    test "raises for invalid data" do
      assert_raise RuntimeError, ~r/Schema validation failed/, fn ->
        Schema.validate!(%{})
      end
    end
  end
end
