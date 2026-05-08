defmodule CcxtExtract.SchemaTest do
  @moduledoc """
  Unit tests for Schema pure functions.
  Uses synthetic data — no file I/O, no QuickBEAM/OXC.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Schema

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
      "symbols_index" => %{
        "BTC/USDT" => %{"spot" => true, "swap" => false},
        "BTC/USDT:USDT" => %{"spot" => false, "swap" => true}
      },
      "symbol_patterns" => %{"spot" => %{"separator" => "", "case" => "upper"}, "currency_aliases" => %{}},
      "url_templates" => %{
        "public" => %{
          "api_param" => "public",
          "http_method" => "GET",
          "sample_path" => "ticker",
          "resolved_url" => "https://api.testex.com/api/v1/ticker",
          "url_prefix" => "https://api.testex.com/api/v1/"
        }
      },
      "testnet_urls" => CcxtExtract.TestnetUrls.none_record(),
      "request_headers" => %{
        "user_agent" => "Mozilla/5.0 (TestEx) AppleWebKit/537.36",
        "default_headers" => %{"X-Test-Header" => "ccxt"}
      }
    }
  end

  # Builds a full structure data map
  defp full_structure do
    %{
      "class_info" => %{"rest" => @sample_class_entry, "ws" => nil},
      "methods" => %{"rest" => [@sample_method_sig], "ws" => nil},
      "sign_method" => @sample_method_ast,
      "authenticated_sections" => ["private", "sapi"],
      "handle_errors" => %{
        "method" => @sample_method_ast,
        "exceptions" => %{"broad" => %{"error" => "ExchangeError"}, "exact" => %{}},
        "http_exceptions" => %{"429" => "RateLimitExceeded"},
        "error_code_fields" => [
          %{
            "object" => "response",
            "object_path" => nil,
            "field" => "code",
            "method" => "safeString",
            "field2" => nil,
            "roles" => ["error_code", "error_message"],
            "sentinel_values" => nil
          }
        ],
        "throw_dispatches" => [
          %{
            "helper" => "throwExactlyMatchedException",
            "exceptions_source" => "exceptions.exact",
            "exceptions_source_raw" => "this.exceptions['exact']",
            "lookup" => %{
              "object" => "response",
              "object_path" => nil,
              "field" => "code",
              "field2" => nil,
              "method" => "safeString"
            },
            "message_lookup" => nil
          }
        ]
      },
      "interface_signatures" => %{
        "publicGetTicker" => %{
          "name" => "publicGetTicker",
          "params" => [%{"name" => "params", "type" => "typeliteral"}],
          "return_type" => "Promise<implicitReturnType>"
        }
      },
      "pagination" => %{
        "fetchTrades" => [
          %{
            "strategy" => "dynamic",
            "max_entries_per_request" => 1000,
            "containing_method" => "fetchTrades",
            "target_method" => "fetchTrades"
          }
        ]
      },
      "overrides" => nil
    }
  end

  # Null runtime for alias exchanges
  defp alias_runtime do
    %{
      "describe" => nil,
      "symbols_index" => nil,
      "symbol_patterns" => nil,
      "url_templates" => nil,
      "testnet_urls" => CcxtExtract.TestnetUrls.none_record(),
      "request_headers" => CcxtExtract.RequestHeaders.empty_record()
    }
  end

  # Null structure for alias exchanges
  defp alias_structure do
    %{
      "class_info" => nil,
      "methods" => nil,
      "sign_method" => nil,
      "authenticated_sections" => nil,
      "handle_errors" => nil,
      "interface_signatures" => nil,
      "pagination" => nil,
      "overrides" => nil,
      "unified_endpoints" => nil,
      "request_defaults" => nil
    }
  end

  # --- schema_version/0 ---

  test "schema_version returns a valid semver string" do
    version = Schema.schema_version()
    assert version =~ ~r/^\d+\.\d+\.\d+$/
  end

  # --- build_exchange/4 ---

  describe "build_exchange/4" do
    test "builds complete output for a full exchange" do
      result = Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)

      assert result["schema_version"] == Schema.schema_version()
      assert result["extracted_at"] == "2026-03-30T12:00:00Z"
      assert result["ccxt_version"] == "4.5.45"

      assert result["exchange"]["id"] == "testex"
      assert result["exchange"]["name"] == "Test Exchange"
      assert result["exchange"]["pro"] == true
      assert result["exchange"]["alias"] == false
      assert result["exchange"]["referral"]["discount"] == 0.1

      assert result["runtime"]["describe"]["has"]["fetchTicker"] == true
      assert is_map(result["runtime"]["symbols_index"])
      assert result["runtime"]["symbols_index"]["BTC/USDT"] == %{"spot" => true, "swap" => false}
      assert result["runtime"]["symbols_index"]["BTC/USDT:USDT"] == %{"spot" => false, "swap" => true}

      assert result["structure"]["sign_method"]["body"]["type"] == "BlockStatement"
      # parse_methods + ws_methods pruned in schema 3.0.0 (Task 117) — no longer emitted.
      refute Map.has_key?(result["structure"], "parse_methods")
      refute Map.has_key?(result["structure"], "ws_methods")
      assert result["structure"]["overrides"] == nil
    end

    test "builds output for alias exchange with null layers" do
      result = Schema.build_exchange(@alias_meta, alias_runtime(), alias_structure(), @base_opts)

      assert result["exchange"]["alias"] == true
      assert result["runtime"]["describe"] == nil
      assert result["runtime"]["symbols_index"] == nil
      assert result["structure"]["sign_method"] == nil
    end

    test "builds output for non-pro exchange (no WS layers)" do
      meta = %{@full_meta | "pro" => false}
      structure = %{full_structure() | "methods" => %{"rest" => [@sample_method_sig], "ws" => nil}}
      result = Schema.build_exchange(meta, full_runtime(), structure, @base_opts)

      assert result["exchange"]["pro"] == false
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

    test "accepts null values for optional structure fields" do
      structure = %{
        "class_info" => nil,
        "methods" => nil,
        "sign_method" => nil,
        "authenticated_sections" => nil,
        "handle_errors" => nil,
        "interface_signatures" => nil,
        "pagination" => nil,
        "overrides" => nil,
        "unified_endpoints" => nil,
        "request_defaults" => nil
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
