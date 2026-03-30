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

  describe "missing entry tracking" do
    @tag :tmp_dir
    test "tracks missing per-exchange describe file", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      # No describe/fakex.json exists — should be tracked
      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert "describe/fakex.json" in stats.missing_entries
    end

    @tag :tmp_dir
    test "tracks missing per-exchange load_markets file", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: ["fakex"]
      )

      # No load_markets/fakex.json exists — should be tracked
      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert "load_markets/fakex.json" in stats.missing_entries
    end

    @tag :tmp_dir
    test "does not track exchanges absent from manifest", %{tmp_dir: tmp_dir} do
      # Manifest lists only "fakex", but "other" exists in exchanges.json
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: [],
        extra_exchanges: [%{"id" => "other", "name" => "Other", "alias" => true}]
      )

      # Write the describe file for fakex so it's NOT missing
      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{"describe" => %{"id" => "fakex"}})

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      # "other" is not in any manifest — should NOT appear in missing_entries
      refute Enum.any?(stats.missing_entries, &String.contains?(&1, "other"))
      assert stats.missing_entries == []
    end

    @tag :tmp_dir
    test "successful file reads produce empty missing_entries", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: ["fakex"]
      )

      # Write both per-exchange files
      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{"describe" => %{"id" => "fakex"}})

      write_json(Path.join(tmp_dir, "load_markets/fakex.json"), %{
        "market_count" => 1,
        "markets" => %{"BTC/USDT" => %{}}
      })

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert stats.missing_entries == []
    end
  end

  # --- Fixture Helpers ---

  # Writes the minimum set of discovery files so the pipeline doesn't raise
  # on missing_files. Per-exchange files are intentionally omitted for testing.
  defp write_minimal_fixtures(dir, opts) do
    describe_exchanges = Keyword.get(opts, :describe_exchanges, [])
    markets_succeeded = Keyword.get(opts, :markets_succeeded, [])
    extra_exchanges = Keyword.get(opts, :extra_exchanges, [])

    base_exchange = %{
      "id" => "fakex",
      "name" => "Fake Exchange",
      "certified" => false,
      "pro" => false,
      "version" => nil,
      "country" => [],
      "alias" => false,
      "referral" => nil
    }

    all_exchanges = [base_exchange | extra_exchanges]

    # Global files (required to avoid missing_files raise)
    write_json(Path.join(dir, "exchanges.json"), %{"exchanges" => all_exchanges})

    write_json(Path.join(dir, "class_hierarchy.json"), %{"classes" => []})

    empty_global = %{"exchanges" => []}
    write_json(Path.join(dir, "methods_rest.json"), empty_global)
    write_json(Path.join(dir, "methods_ws.json"), empty_global)
    write_json(Path.join(dir, "sign_methods.json"), empty_global)
    write_json(Path.join(dir, "handle_errors.json"), empty_global)
    write_json(Path.join(dir, "parse_methods.json"), empty_global)
    write_json(Path.join(dir, "ws_methods.json"), empty_global)
    write_json(Path.join(dir, "overrides.json"), empty_global)

    # Manifests for per-exchange loaders
    File.mkdir_p!(Path.join(dir, "describe"))
    write_json(Path.join(dir, "describe/_manifest.json"), %{"exchanges" => describe_exchanges})

    File.mkdir_p!(Path.join(dir, "load_markets"))

    write_json(Path.join(dir, "load_markets/_manifest.json"), %{
      "succeeded" => markets_succeeded,
      "failed" => []
    })
  end

  defp write_json(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
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

    test "overrides with wrong shape fails validation" do
      # Old flat shape should fail — missing required keys extends/rest/ws
      bad_overrides = %{
        "parent_key" => "rest:parentex",
        "overridden" => %{},
        "new_methods" => %{},
        "inherited" => []
      }

      exchange = build_with_overrides(bad_overrides)
      assert {:error, reasons} = Schema.validate(exchange)
      assert Enum.any?(reasons, &String.contains?(&1, "missing required keys"))
    end

    test "overrides with string new_methods fails validation" do
      bad_overrides = %{
        "extends" => "parentex",
        "rest" => %{
          "parent_key" => "rest:parentex",
          "overridden" => %{},
          "new_methods" => "not a map",
          "inherited" => []
        },
        "ws" => nil
      }

      exchange = build_with_overrides(bad_overrides)
      assert {:error, reasons} = Schema.validate(exchange)
      assert Enum.any?(reasons, &String.contains?(&1, "new_methods"))
    end

    test "overrides with string inherited fails validation" do
      bad_overrides = %{
        "extends" => "parentex",
        "rest" => %{
          "parent_key" => "rest:parentex",
          "overridden" => %{},
          "new_methods" => %{},
          "inherited" => "not a list"
        },
        "ws" => nil
      }

      exchange = build_with_overrides(bad_overrides)
      assert {:error, reasons} = Schema.validate(exchange)
      assert Enum.any?(reasons, &String.contains?(&1, "inherited"))
    end

    test "overrides with nil overridden/new_methods fails validation" do
      bad_overrides = %{
        "extends" => "parentex",
        "rest" => %{
          "parent_key" => "rest:parentex",
          "overridden" => nil,
          "new_methods" => nil,
          "inherited" => []
        },
        "ws" => nil
      }

      exchange = build_with_overrides(bad_overrides)
      assert {:error, reasons} = Schema.validate(exchange)
      assert Enum.any?(reasons, &String.contains?(&1, "overridden"))
      assert Enum.any?(reasons, &String.contains?(&1, "new_methods"))
    end

    test "overrides with non-string extends fails validation" do
      bad_overrides = %{
        "extends" => 42,
        "rest" => nil,
        "ws" => nil
      }

      exchange = build_with_overrides(bad_overrides)
      assert {:error, reasons} = Schema.validate(exchange)
      assert Enum.any?(reasons, &String.contains?(&1, "extends"))
    end

    test "overrides with non-string parent_key fails validation" do
      bad_overrides = %{
        "extends" => "parentex",
        "rest" => %{
          "parent_key" => 123,
          "overridden" => %{},
          "new_methods" => %{},
          "inherited" => []
        },
        "ws" => nil
      }

      exchange = build_with_overrides(bad_overrides)
      assert {:error, reasons} = Schema.validate(exchange)
      assert Enum.any?(reasons, &String.contains?(&1, "parent_key"))
    end

    test "overrides with non-string inherited elements fails validation" do
      bad_overrides = %{
        "extends" => "parentex",
        "rest" => %{
          "parent_key" => "rest:parentex",
          "overridden" => %{},
          "new_methods" => %{},
          "inherited" => ["fetchTicker", 123, :atom_val]
        },
        "ws" => nil
      }

      exchange = build_with_overrides(bad_overrides)
      assert {:error, reasons} = Schema.validate(exchange)
      assert Enum.any?(reasons, &String.contains?(&1, "non-string elements"))
    end
  end

  describe "corrupt entry detection" do
    @tag :tmp_dir
    test "corrupt describe file tracked in corrupt_entries", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      # Write invalid JSON to the describe file
      File.write!(Path.join(tmp_dir, "describe/fakex.json"), "{not valid json")

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert stats.corrupt_entries != []
      assert Enum.any?(stats.corrupt_entries, &String.contains?(&1, "fakex"))
      # Should NOT appear in missing_entries
      refute Enum.any?(stats.missing_entries, &String.contains?(&1, "fakex"))
    end

    @tag :tmp_dir
    test "corrupt load_markets file tracked in corrupt_entries", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: ["fakex"]
      )

      # Write invalid JSON to the load_markets file
      File.write!(Path.join(tmp_dir, "load_markets/fakex.json"), "<<<corrupt>>>")

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert stats.corrupt_entries != []
      assert Enum.any?(stats.corrupt_entries, &String.contains?(&1, "fakex"))
      refute Enum.any?(stats.missing_entries, &String.contains?(&1, "fakex"))
    end

    @tag :tmp_dir
    test "corrupt global file raises", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      # Corrupt a global file
      File.write!(Path.join(tmp_dir, "class_hierarchy.json"), "not json")

      assert_raise RuntimeError, ~r/Corrupt discovery artifact/, fn ->
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )
      end
    end

    @tag :tmp_dir
    test "describe manifest with non-string IDs raises as corrupt", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      # Overwrite describe manifest with non-string IDs
      File.write!(
        Path.join(tmp_dir, "describe/_manifest.json"),
        Jason.encode!(%{"exchanges" => [123, "valid", nil]})
      )

      assert_raise RuntimeError, ~r/non-string IDs/, fn ->
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )
      end
    end

    @tag :tmp_dir
    test "load_markets manifest with non-string IDs raises as corrupt", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      # Overwrite load_markets manifest with non-string IDs
      File.write!(
        Path.join(tmp_dir, "load_markets/_manifest.json"),
        Jason.encode!(%{"succeeded" => [123, true], "failed" => []})
      )

      assert_raise RuntimeError, ~r/non-string IDs/, fn ->
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )
      end
    end

    @tag :tmp_dir
    test "malformed describe manifest raises as corrupt artifact", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      # Overwrite describe manifest with valid JSON that lacks "exchanges" key
      File.write!(Path.join(tmp_dir, "describe/_manifest.json"), Jason.encode!(%{}))

      assert_raise RuntimeError, ~r/Corrupt discovery artifact/, fn ->
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )
      end
    end
  end

  # --- Helpers ---

  # Builds a full exchange map with custom overrides for validation testing
  defp build_with_overrides(overrides_value) do
    data = full_data()
    meta = full_meta()
    result = Pipeline.build_exchange_data(meta, data, @schema_opts)
    put_in(result, ["structure", "overrides"], overrides_value)
  end
end
