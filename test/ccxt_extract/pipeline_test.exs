defmodule CcxtExtract.PipelineTest do
  @moduledoc """
  Unit tests for Pipeline pure functions.
  Uses synthetic data — no file I/O, no QuickBEAM/OXC.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Pipeline
  alias CcxtExtract.Schema

  @schema_opts [ccxt_version: "4.5.45", extracted_at: "2026-03-30T12:00:00Z"]

  @sample_method_ast %{
    "async" => false,
    "params" => [%{"name" => "path", "type" => "string"}],
    "return_type" => nil,
    "statements" => 12,
    "body" => %{"type" => "BlockStatement", "start" => 100, "end" => 500, "body" => []}
  }

  @rest_class %{
    "node_key" => "rest:testex",
    "class_name" => "testex",
    "type" => "rest",
    "extends_resolved" => "Exchange",
    "parent_key" => "Exchange",
    "file" => "testex.ts",
    "method_count" => 42,
    "methods" => ["describe", "fetchTicker"],
    "method_details" => []
  }

  @ws_class %{
    "node_key" => "ws:testex",
    "class_name" => "testex",
    "type" => "ws",
    "extends_resolved" => "testex",
    "parent_key" => "rest:testex",
    "file" => "testex.ts",
    "method_count" => 10,
    "methods" => ["watchTicker"],
    "method_details" => []
  }

  @method_sig %{
    "name" => "fetchTicker",
    "async" => true,
    "params" => [%{"name" => "symbol", "type" => "string"}],
    "return_type" => "Ticker",
    "statements" => 5
  }

  # Builds a data lookup with all layers populated for "testex"
  defp full_data do
    %{
      exchanges: [full_meta()],
      describe: %{"testex" => %{"id" => "testex", "has" => %{"fetchTicker" => true}}},
      load_markets: %{
        "testex" => %{"market_count" => 100, "markets" => %{"BTC/USDT" => %{"active" => true}}}
      },
      classes: %{"testex" => [@rest_class, @ws_class]},
      methods_rest: %{"testex" => [@method_sig]},
      methods_ws: %{"testex" => [@method_sig]},
      sign_methods: %{"testex" => @sample_method_ast},
      handle_errors: %{
        "testex" => %{
          "id" => "testex",
          "handle_errors" => @sample_method_ast,
          "exceptions" => %{"broad" => %{"error" => "ExchangeError"}, "exact" => %{}},
          "http_exceptions" => %{"429" => "RateLimitExceeded"}
        }
      },
      parse_methods: %{
        "testex" => %{
          "id" => "testex",
          "parse_methods" => %{"parseTicker" => @sample_method_ast},
          "parse_method_count" => 1
        }
      },
      ws_methods: %{
        "testex" => %{
          "id" => "testex",
          "ws_methods" => %{"watchTicker" => @sample_method_ast},
          "ws_method_count" => 1
        }
      },
      overrides: %{},
      missing_files: []
    }
  end

  defp full_meta do
    %{
      "id" => "testex",
      "name" => "Test Exchange",
      "certified" => true,
      "pro" => true,
      "version" => "v3",
      "country" => ["US"],
      "alias" => false,
      "referral" => %{"url" => "https://test.com/ref", "discount" => 0.1}
    }
  end

  defp alias_meta do
    %{
      "id" => "aliasex",
      "name" => "Alias Exchange",
      "certified" => false,
      "pro" => false,
      "version" => nil,
      "country" => [],
      "alias" => true,
      "referral" => nil
    }
  end

  # Data lookup with no data for "aliasex"
  defp empty_data do
    %{
      exchanges: [alias_meta()],
      describe: %{},
      load_markets: %{},
      classes: %{},
      methods_rest: %{},
      methods_ws: %{},
      sign_methods: %{},
      handle_errors: %{},
      parse_methods: %{},
      ws_methods: %{},
      overrides: %{},
      missing_files: []
    }
  end

  describe "build_exchange_data/3" do
    test "assembles full exchange with all layers" do
      result = Pipeline.build_exchange_data(full_meta(), full_data(), @schema_opts)

      assert result["schema_version"] == "1.0"
      assert result["ccxt_version"] == "4.5.45"
      assert result["exchange"]["id"] == "testex"
      assert result["exchange"]["pro"] == true

      # Runtime
      assert result["runtime"]["describe"]["has"]["fetchTicker"] == true
      assert result["runtime"]["markets"]["market_count"] == 100

      # Structure
      assert result["structure"]["class_info"]["rest"]["node_key"] == "rest:testex"
      assert result["structure"]["class_info"]["ws"]["node_key"] == "ws:testex"
      assert result["structure"]["methods"]["rest"] == [@method_sig]
      assert result["structure"]["methods"]["ws"] == [@method_sig]
      assert result["structure"]["sign_method"]["statements"] == 12
      assert result["structure"]["parse_methods"]["parseTicker"]["statements"] == 12
      assert result["structure"]["ws_methods"]["watchTicker"]["statements"] == 12
    end

    test "assembles alias exchange with nil layers" do
      result = Pipeline.build_exchange_data(alias_meta(), empty_data(), @schema_opts)

      assert result["exchange"]["alias"] == true
      assert result["runtime"]["describe"] == nil
      assert result["runtime"]["markets"] == nil
      assert result["structure"]["class_info"] == nil
      assert result["structure"]["methods"] == nil
      assert result["structure"]["sign_method"] == nil
      assert result["structure"]["handle_errors"] == nil
      assert result["structure"]["parse_methods"] == nil
      assert result["structure"]["ws_methods"] == nil
      assert result["structure"]["overrides"] == nil
    end

    test "renames handle_errors fields correctly" do
      result = Pipeline.build_exchange_data(full_meta(), full_data(), @schema_opts)
      he = result["structure"]["handle_errors"]

      # "handle_errors" from extraction → "method" in schema
      assert he["method"]["statements"] == 12
      assert he["exceptions"]["broad"]["error"] == "ExchangeError"
      assert he["http_exceptions"]["429"] == "RateLimitExceeded"

      # Original key name should not be present
      refute Map.has_key?(he, "handle_errors")
    end

    test "returns nil handle_errors when method is null" do
      null_entry = %{
        "id" => "testex",
        "handle_errors" => nil,
        "exceptions" => %{"broad" => %{}, "exact" => %{}},
        "http_exceptions" => %{}
      }

      data = %{full_data() | handle_errors: %{"testex" => null_entry}}
      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)

      assert result["structure"]["handle_errors"] == nil
    end

    test "renames overrides fields correctly" do
      override_entry = %{
        "id" => "derivedex",
        "extends" => "testex",
        "parent_key" => "rest:testex",
        "overrides" => %{"describe" => @sample_method_ast},
        "new_methods" => %{"fetchCustom" => @sample_method_ast},
        "inherited_methods" => ["fetchTicker", "fetchBalance"],
        "override_count" => 1,
        "new_method_count" => 1,
        "inherited_count" => 2
      }

      # Overrides are grouped by id (list of entries per exchange)
      data = %{full_data() | overrides: %{"testex" => [override_entry]}}
      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      ov = result["structure"]["overrides"]

      assert ov["extends"] == "testex"

      # REST entry with renamed fields
      rest = ov["rest"]
      assert rest["overridden"]["describe"]["statements"] == 12
      assert rest["inherited"] == ["fetchTicker", "fetchBalance"]
      assert rest["new_methods"]["fetchCustom"]["statements"] == 12
      assert rest["parent_key"] == "rest:testex"

      # No WS entry for this single-entry case
      assert ov["ws"] == nil

      # Original key names should not be present
      refute Map.has_key?(rest, "overrides")
      refute Map.has_key?(rest, "inherited_methods")
    end

    test "preserves both REST and WS overrides" do
      rest_entry = %{
        "id" => "derivedex",
        "extends" => "testex",
        "parent_key" => "rest:testex",
        "overrides" => %{"describe" => @sample_method_ast},
        "new_methods" => %{},
        "inherited_methods" => ["fetchTicker"]
      }

      ws_entry = %{
        "id" => "derivedex",
        "extends" => "testex",
        "parent_key" => "ws:testex",
        "overrides" => %{"describe" => @sample_method_ast},
        "new_methods" => %{"watchTicker" => @sample_method_ast},
        "inherited_methods" => ["handleTicker"]
      }

      data = %{full_data() | overrides: %{"testex" => [rest_entry, ws_entry]}}
      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      ov = result["structure"]["overrides"]

      assert ov["extends"] == "testex"

      # Both REST and WS are present
      assert ov["rest"]["parent_key"] == "rest:testex"
      assert ov["rest"]["inherited"] == ["fetchTicker"]
      assert ov["ws"]["parent_key"] == "ws:testex"
      assert ov["ws"]["new_methods"]["watchTicker"]["statements"] == 12
      assert ov["ws"]["inherited"] == ["handleTicker"]
    end

    test "splits class_info into rest and ws entries" do
      result = Pipeline.build_exchange_data(full_meta(), full_data(), @schema_opts)
      ci = result["structure"]["class_info"]

      assert ci["rest"]["type"] == "rest"
      assert ci["ws"]["type"] == "ws"
    end

    test "class_info ws is nil when no ws class exists" do
      data = %{full_data() | classes: %{"testex" => [@rest_class]}}
      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)

      assert result["structure"]["class_info"]["rest"]["type"] == "rest"
      assert result["structure"]["class_info"]["ws"] == nil
    end

    test "parse_methods is nil when empty map" do
      data = %{
        full_data()
        | parse_methods: %{
            "testex" => %{"id" => "testex", "parse_methods" => %{}, "parse_method_count" => 0}
          }
      }

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      assert result["structure"]["parse_methods"] == nil
    end

    test "ws_methods is nil when empty map" do
      data = %{
        full_data()
        | ws_methods: %{
            "testex" => %{"id" => "testex", "ws_methods" => %{}, "ws_method_count" => 0}
          }
      }

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      assert result["structure"]["ws_methods"] == nil
    end
  end

  describe "validation" do
    test "full exchange passes schema validation" do
      result = Pipeline.build_exchange_data(full_meta(), full_data(), @schema_opts)
      assert :ok = Schema.validate(result)
    end

    test "alias exchange passes schema validation" do
      result = Pipeline.build_exchange_data(alias_meta(), empty_data(), @schema_opts)
      assert :ok = Schema.validate(result)
    end

    test "exchange with overrides passes validation" do
      override_entry = %{
        "id" => "testex",
        "extends" => "parentex",
        "parent_key" => "rest:parentex",
        "overrides" => %{"describe" => @sample_method_ast},
        "new_methods" => %{},
        "inherited_methods" => ["fetchTicker"]
      }

      data = %{full_data() | overrides: %{"testex" => [override_entry]}}
      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      assert :ok = Schema.validate(result)
    end
  end
end
