defmodule CcxtExtract.ValidationTest do
  @moduledoc """
  Unit tests for Validation pure functions.
  Uses synthetic data — no file I/O, no QuickBEAM/OXC.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Schema
  alias CcxtExtract.Validation

  # --- Synthetic data builders (same as SchemaTest) ---

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

  defp full_runtime do
    %{
      "describe" => %{"id" => "testex", "has" => %{"fetchTicker" => true}},
      "markets" => %{"market_count" => 100, "markets" => %{"BTC/USDT" => %{"active" => true}}}
    }
  end

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

  defp alias_runtime, do: %{"describe" => nil, "markets" => nil}

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

  defp build_full_exchange do
    Schema.build_exchange(@full_meta, full_runtime(), full_structure(), @base_opts)
  end

  defp build_alias_exchange do
    Schema.build_exchange(@alias_meta, alias_runtime(), alias_structure(), @base_opts)
  end

  # --- validate_schema/2 ---

  describe "validate_schema/2" do
    setup do
      %{root: Validation.build_schema_root()}
    end

    test "accepts valid full exchange", %{root: root} do
      assert :ok = Validation.validate_schema(build_full_exchange(), root)
    end

    test "accepts valid alias exchange with null layers", %{root: root} do
      assert :ok = Validation.validate_schema(build_alias_exchange(), root)
    end

    test "catches type error — statements as string — with actionable path", %{root: root} do
      bad_ast = %{@sample_method_ast | "statements" => "twelve"}
      exchange = put_in(build_full_exchange(), ["structure", "sign_method"], bad_ast)

      assert {:error, findings} = Validation.validate_schema(exchange, root)
      assert findings != []

      # Verify findings have actionable instance paths, not opaque blobs at "/"
      assert Enum.all?(findings, &is_binary(&1["path"]))
      assert Enum.all?(findings, &is_binary(&1["message"]))

      # At least one finding should reference the actual instance path
      paths = Enum.map(findings, & &1["path"])
      assert Enum.any?(paths, &(&1 != "/")), "Expected instance paths, got only root: #{inspect(findings)}"
    end

    test "catches missing required field", %{root: root} do
      exchange = Map.delete(build_full_exchange(), "ccxt_version")

      assert {:error, findings} = Validation.validate_schema(exchange, root)
      assert findings != []
    end

    test "catches extra property on exchange section", %{root: root} do
      exchange = put_in(build_full_exchange(), ["exchange", "extra_field"], "surprise")

      assert {:error, findings} = Validation.validate_schema(exchange, root)
      assert findings != []
    end

    test "catches wrong schema_version", %{root: root} do
      exchange = Map.put(build_full_exchange(), "schema_version", "2.0")

      assert {:error, findings} = Validation.validate_schema(exchange, root)
      assert findings != []
    end
  end

  # --- validate_roundtrip/3 ---

  describe "validate_roundtrip/3" do
    # Build source data matching the pipeline output
    defp matching_source_data do
      %{
        describe: %{"testex" => %{"id" => "testex", "has" => %{"fetchTicker" => true}}},
        load_markets: %{
          "testex" => %{"market_count" => 100, "markets" => %{"BTC/USDT" => %{"active" => true}}}
        },
        classes: %{
          "testex" => [
            %{"type" => "rest", "class_name" => "testex", "method_count" => 42}
          ]
        },
        methods_rest: %{"testex" => [@sample_method_sig]},
        methods_ws: %{},
        sign_methods: %{"testex" => @sample_method_ast},
        handle_errors: %{
          "testex" => %{
            "handle_errors" => @sample_method_ast,
            "exceptions" => %{"broad" => %{"error" => "ExchangeError"}, "exact" => %{}},
            "http_exceptions" => %{"429" => "RateLimitExceeded"}
          }
        },
        parse_methods: %{"testex" => %{"parse_methods" => %{"parseTicker" => @sample_method_ast}}},
        ws_methods: %{"testex" => %{"ws_methods" => %{"watchTicker" => @sample_method_ast}}},
        overrides: %{}
      }
    end

    test "returns no findings when output matches source" do
      exchange = build_full_exchange()
      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert findings == []
    end

    test "detects describe key mismatch" do
      exchange = build_full_exchange()

      source =
        put_in(matching_source_data(), [:describe, "testex"], %{
          "id" => "testex",
          "has" => %{"fetchTicker" => true},
          "extra_key" => "value"
        })

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "runtime.describe" && f["severity"] == "error" &&
                 String.contains?(f["message"], "missing keys")
             end)
    end

    test "detects market count mismatch" do
      exchange = build_full_exchange()

      source =
        put_in(matching_source_data(), [:load_markets, "testex"], %{
          "market_count" => 200,
          "markets" => %{}
        })

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "runtime.markets" && f["severity"] == "error" &&
                 String.contains?(f["message"], "market_count mismatch")
             end)
    end

    test "detects dropped market symbols" do
      exchange = build_full_exchange()

      source =
        put_in(matching_source_data(), [:load_markets, "testex"], %{
          "market_count" => 100,
          "markets" => %{"BTC/USDT" => %{"active" => true}, "ETH/USDT" => %{"active" => true}}
        })

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "runtime.markets" && f["severity"] == "error" &&
                 String.contains?(f["message"], "missing symbols")
             end)
    end

    test "detects corrupted market data even when count and symbols match" do
      exchange =
        put_in(build_full_exchange(), ["runtime", "markets"], %{
          "market_count" => 100,
          "markets" => %{"BTC/USDT" => %{"active" => false}}
        })

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "runtime.markets" && f["severity"] == "error" &&
                 String.contains?(f["message"], "market data mismatch")
             end)
    end

    test "detects corrupted sign_method AST" do
      corrupted_ast = %{@sample_method_ast | "statements" => 999, "async" => true}
      exchange = put_in(build_full_exchange(), ["structure", "sign_method"], corrupted_ast)

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.sign_method" && f["severity"] == "error" &&
                 String.contains?(f["message"], "data mismatch")
             end)
    end

    test "detects corrupted handle_errors method AST" do
      corrupted_ast = %{@sample_method_ast | "statements" => 999}

      exchange =
        put_in(build_full_exchange(), ["structure", "handle_errors", "method"], corrupted_ast)

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.handle_errors.method" && f["severity"] == "error" &&
                 String.contains?(f["message"], "data mismatch")
             end)
    end

    test "detects corrupted handle_errors exception mappings" do
      exchange =
        put_in(build_full_exchange(), ["structure", "handle_errors", "exceptions"], %{
          "broad" => %{"wrong_error" => "WrongClass"},
          "exact" => %{}
        })

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.handle_errors.exceptions" && f["severity"] == "error" &&
                 String.contains?(f["message"], "data mismatch")
             end)
    end

    test "detects corrupted method signature in REST inventory" do
      corrupted_sig = %{@sample_method_sig | "async" => false, "statements" => 999}
      exchange = put_in(build_full_exchange(), ["structure", "methods", "rest"], [corrupted_sig])

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.methods.rest.fetchTicker" && f["severity"] == "error" &&
                 String.contains?(f["message"], "signature mismatch")
             end)
    end

    test "detects corrupted parse method AST" do
      corrupted_ast = %{@sample_method_ast | "body" => %{"type" => "EmptyStatement"}}

      exchange =
        put_in(build_full_exchange(), ["structure", "parse_methods"], %{
          "parseTicker" => corrupted_ast
        })

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.parse_methods.parseTicker" && f["severity"] == "error" &&
                 String.contains?(f["message"], "data mismatch")
             end)
    end

    test "detects corrupted ws method AST" do
      corrupted_ast = %{@sample_method_ast | "statements" => 0, "params" => []}

      exchange =
        put_in(build_full_exchange(), ["structure", "ws_methods"], %{
          "watchTicker" => corrupted_ast
        })

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.ws_methods.watchTicker" && f["severity"] == "error" &&
                 String.contains?(f["message"], "data mismatch")
             end)
    end

    test "detects missing sign_method" do
      # Output has nil sign_method but source has data
      exchange = put_in(build_full_exchange(), ["structure", "sign_method"], nil)

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.sign_method" && f["severity"] == "error"
             end)
    end

    test "detects missing parse methods" do
      # Output has nil but source has methods
      exchange = put_in(build_full_exchange(), ["structure", "parse_methods"], nil)

      findings = Validation.validate_roundtrip(exchange, matching_source_data(), "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.parse_methods" && f["severity"] == "error"
             end)
    end

    test "handles alias exchange with all nil sections" do
      exchange = build_alias_exchange()

      # Source data has nothing for aliasex
      source = %{
        describe: %{},
        load_markets: %{},
        classes: %{},
        methods_rest: %{},
        methods_ws: %{},
        sign_methods: %{},
        handle_errors: %{},
        parse_methods: %{},
        ws_methods: %{},
        overrides: %{}
      }

      findings = Validation.validate_roundtrip(exchange, source, "aliasex")
      assert findings == []
    end

    test "detects class_info method_count mismatch" do
      exchange = build_full_exchange()

      source =
        put_in(matching_source_data(), [:classes, "testex"], [
          %{"type" => "rest", "class_name" => "testex", "method_count" => 99}
        ])

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.class_info.rest" && f["severity"] == "error" &&
                 String.contains?(f["message"], "method_count")
             end)
    end

    test "detects WS class_info method_count mismatch" do
      ws_class = %{
        @sample_class_entry
        | "node_key" => "ws:testex",
          "type" => "ws",
          "method_count" => 10
      }

      exchange = put_in(build_full_exchange(), ["structure", "class_info", "ws"], ws_class)

      source =
        put_in(matching_source_data(), [:classes, "testex"], [
          %{"type" => "rest", "class_name" => "testex", "method_count" => 42},
          %{"type" => "ws", "class_name" => "testex", "method_count" => 99}
        ])

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.class_info.ws" && f["severity"] == "error" &&
                 String.contains?(f["message"], "method_count")
             end)
    end

    test "detects WS method inventory mismatch" do
      ws_sig = %{@sample_method_sig | "name" => "watchTicker"}

      exchange = put_in(build_full_exchange(), ["structure", "methods", "ws"], [ws_sig])

      source =
        put_in(matching_source_data(), [:methods_ws, "testex"], [
          ws_sig,
          %{@sample_method_sig | "name" => "watchOrderBook"}
        ])

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.methods.ws" && f["severity"] == "error" &&
                 String.contains?(f["message"], "missing")
             end)
    end

    test "detects WS override mismatch" do
      ws_override = %{
        "parent_key" => "ws:binance",
        "overridden" => %{},
        "new_methods" => %{},
        "inherited" => []
      }

      exchange =
        put_in(build_full_exchange(), ["structure", "overrides"], %{
          "extends" => "binance",
          "rest" => nil,
          "ws" => ws_override
        })

      source =
        put_in(matching_source_data(), [:overrides, "testex"], [%{"parent_key" => "ws:kraken", "extends" => "binance"}])

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.overrides.ws" && f["severity"] == "error" &&
                 String.contains?(f["message"], "parent_key mismatch")
             end)
    end

    test "detects WS class_info missing from output when source has WS class" do
      # Output has class_info.ws = nil, but source has a WS class entry
      exchange = build_full_exchange()
      # Confirm output WS is nil (from full_structure)
      assert get_in(exchange, ["structure", "class_info", "ws"]) == nil

      ws_class = %{"type" => "ws", "class_name" => "testex", "method_count" => 10}

      source =
        put_in(matching_source_data(), [:classes, "testex"], [
          %{"type" => "rest", "class_name" => "testex", "method_count" => 42},
          ws_class
        ])

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.class_info.ws" && f["severity"] == "error" &&
                 String.contains?(f["message"], "output is null but source has ws class data")
             end)
    end

    test "detects WS-only overrides extends mismatch" do
      # WS override with wrong extends — previously slipped through because only REST was checked
      ws_override = %{
        "parent_key" => "ws:testex",
        "method_count" => 2,
        "new_methods" => %{},
        "inherited" => []
      }

      exchange =
        put_in(build_full_exchange(), ["structure", "overrides"], %{
          "extends" => "exchange",
          "rest" => nil,
          "ws" => ws_override
        })

      # Source has a WS-only override with different extends
      source =
        put_in(matching_source_data(), [:overrides, "testex"], [
          %{"parent_key" => "ws:testex", "extends" => "binance"}
        ])

      findings = Validation.validate_roundtrip(exchange, source, "testex")

      assert Enum.any?(findings, fn f ->
               f["path"] == "structure.overrides" && f["severity"] == "error" &&
                 String.contains?(f["message"], "extends mismatch")
             end)
    end
  end

  # --- Corrupt JSON handling ---

  describe "source data loaders handle corrupt JSON" do
    test "validate_all succeeds even with corrupt per-exchange discovery files" do
      # This test verifies that corrupt JSON in per-exchange files
      # doesn't crash the validation — it's covered by the rescue in
      # read_describe_entry/2 and read_markets_entry/2.
      # The unit-level fix is structural (rescue clause), so we verify
      # the roundtrip logic handles nil entries gracefully.
      exchange = build_full_exchange()

      # Simulate a corrupt describe entry (nil value, as rescue produces)
      source = put_in(matching_source_data(), [:describe, "testex"], nil)
      findings = Validation.validate_roundtrip(exchange, source, "testex")

      # Should produce a finding about missing source, not crash
      assert Enum.any?(findings, fn f ->
               f["path"] == "runtime.describe" && f["severity"] == "warning"
             end)
    end
  end

  # --- build_schema_root/0 ---

  test "build_schema_root returns a compiled JSV root" do
    root = Validation.build_schema_root()
    assert %JSV.Root{} = root
  end
end
