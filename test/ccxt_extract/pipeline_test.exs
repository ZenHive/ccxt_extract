defmodule CcxtExtract.PipelineTest do
  @moduledoc """
  Unit tests for Pipeline pure functions.
  Uses synthetic data — no file I/O, no QuickBEAM/OXC.
  """
  # async: false — many `@tag :tmp_dir` cases; parallel pool races rm_rf!/nested dirs (:eexist).
  use ExUnit.Case, async: false

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

  # handleErrors-specific AST with safe* calls for error_code_fields derivation
  @sample_handle_errors_ast %{
    "async" => false,
    "params" => [%{"name" => "httpCode", "type" => "int"}],
    "return_type" => nil,
    "statements" => 4,
    "body" => %{
      "type" => "BlockStatement",
      "start" => 100,
      "end" => 500,
      "body" => [
        %{
          "type" => "VariableDeclaration",
          "declarations" => [
            %{
              "type" => "VariableDeclarator",
              "id" => %{"type" => "Identifier", "name" => "code"},
              "init" => %{
                "type" => "CallExpression",
                "callee" => %{
                  "type" => "MemberExpression",
                  "object" => %{"type" => "ThisExpression"},
                  "property" => %{"type" => "Identifier", "name" => "safeString"}
                },
                "arguments" => [
                  %{"type" => "Identifier", "name" => "response"},
                  %{"type" => "Literal", "value" => "code"}
                ]
              }
            }
          ]
        },
        %{
          "type" => "VariableDeclaration",
          "declarations" => [
            %{
              "type" => "VariableDeclarator",
              "id" => %{"type" => "Identifier", "name" => "msg"},
              "init" => %{
                "type" => "CallExpression",
                "callee" => %{
                  "type" => "MemberExpression",
                  "object" => %{"type" => "ThisExpression"},
                  "property" => %{"type" => "Identifier", "name" => "safeString"}
                },
                "arguments" => [
                  %{"type" => "Identifier", "name" => "response"},
                  %{"type" => "Literal", "value" => "msg"}
                ]
              }
            }
          ]
        },
        # throwExactlyMatchedException(exceptions, code, feedback)
        %{
          "type" => "ExpressionStatement",
          "expression" => %{
            "type" => "CallExpression",
            "callee" => %{
              "type" => "MemberExpression",
              "object" => %{"type" => "ThisExpression"},
              "property" => %{"type" => "Identifier", "name" => "throwExactlyMatchedException"}
            },
            "arguments" => [
              %{"type" => "Identifier", "name" => "exceptions"},
              %{"type" => "Identifier", "name" => "code"},
              %{"type" => "Identifier", "name" => "feedback"}
            ]
          }
        },
        # throwBroadlyMatchedException(exceptions, msg, feedback)
        %{
          "type" => "ExpressionStatement",
          "expression" => %{
            "type" => "CallExpression",
            "callee" => %{
              "type" => "MemberExpression",
              "object" => %{"type" => "ThisExpression"},
              "property" => %{"type" => "Identifier", "name" => "throwBroadlyMatchedException"}
            },
            "arguments" => [
              %{"type" => "Identifier", "name" => "exceptions"},
              %{"type" => "Identifier", "name" => "msg"},
              %{"type" => "Identifier", "name" => "feedback"}
            ]
          }
        }
      ]
    }
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
          "handle_errors" => @sample_handle_errors_ast,
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
      interface_signatures: %{
        "testex" => %{
          "id" => "testex",
          "interface_signatures" => %{
            "publicGetTicker" => %{
              "name" => "publicGetTicker",
              "params" => [%{"name" => "params", "type" => "typeliteral"}],
              "return_type" => "Promise<implicitReturnType>"
            },
            "privateGetAccount" => %{
              "name" => "privateGetAccount",
              "params" => [%{"name" => "params", "type" => "typeliteral"}],
              "return_type" => "Promise<implicitReturnType>"
            }
          },
          "interface_signature_count" => 2
        }
      },
      pagination: %{
        "testex" => %{
          "id" => "testex",
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
          "pagination_count" => 1
        }
      },
      unified_endpoints: %{
        "testex" => %{
          "id" => "testex",
          "unified_endpoints" => %{
            "fetchTicker" => ["publicGetTicker"],
            "fetchBalance" => ["privateGetAccount"]
          },
          "unified_endpoint_count" => 2
        }
      },
      request_defaults: %{},
      url_templates: %{
        "testex" => %{
          "id" => "testex",
          "url_templates" => %{
            "public" => %{
              "api_param" => "public",
              "http_method" => "GET",
              "sample_path" => "ticker",
              "resolved_url" => "https://api.testex.com/api/v1/ticker",
              "url_prefix" => "https://api.testex.com/api/v1/"
            }
          }
        }
      },
      request_headers: %{
        "testex" => %{
          "id" => "testex",
          "request_headers" => %{
            "user_agent" => "Mozilla/5.0 (TestEx)",
            "default_headers" => %{"X-Test-Header" => "ccxt"}
          }
        }
      },
      overrides: %{},
      error_class_hierarchy: %{
        "tree" => %{"BaseError" => %{"ExchangeError" => %{}}},
        "flat_parents" => %{"BaseError" => nil, "ExchangeError" => "BaseError"},
        "ancestors" => %{"BaseError" => [], "ExchangeError" => ["BaseError"]}
      },
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
      interface_signatures: %{},
      pagination: %{},
      unified_endpoints: %{},
      request_defaults: %{},
      url_templates: %{},
      request_headers: %{},
      overrides: %{},
      error_class_hierarchy: nil,
      missing_files: []
    }
  end

  describe "build_exchange_data/3" do
    test "assembles full exchange with all layers" do
      result = Pipeline.build_exchange_data(full_meta(), full_data(), @schema_opts)

      assert result["schema_version"] == Schema.schema_version()
      assert result["ccxt_version"] == "4.5.45"
      assert result["exchange"]["id"] == "testex"
      assert result["exchange"]["pro"] == true

      # v4 raw section (was runtime)
      assert result["raw"]["describe"]["has"]["fetchTicker"] == true
      assert is_map(result["markets"]["symbols_index"])
      assert is_map(result["markets"]["patterns"])

      # v4 raw/auth sections (was structure)
      assert result["raw"]["class_info"]["rest"]["node_key"] == "rest:testex"
      assert result["raw"]["class_info"]["ws"]["node_key"] == "ws:testex"
      assert result["raw"]["method_inventory"]["rest"] == [@method_sig]
      assert result["raw"]["method_inventory"]["ws"] == [@method_sig]
      assert result["auth"]["sign_method"]["statements"] == 12
      refute Map.has_key?(result, "structure")
      refute Map.has_key?(result, "runtime")
      assert result["endpoints"]["interfaces"]["publicGetTicker"]["name"] == "publicGetTicker"

      # Pagination — now under endpoints
      assert result["endpoints"]["pagination"]["fetchTrades"] == [
               %{
                 "strategy" => "dynamic",
                 "max_entries_per_request" => 1000,
                 "containing_method" => "fetchTrades",
                 "target_method" => "fetchTrades"
               }
             ]
    end

    test "assembles alias exchange with nil layers when no parent in class hierarchy" do
      result = Pipeline.build_exchange_data(alias_meta(), empty_data(), @schema_opts)

      assert result["exchange"]["alias"] == true
      assert result["raw"]["describe"] == nil
      assert result["markets"]["symbols_index"] == nil
      assert result["markets"]["patterns"] == nil
      assert result["raw"]["class_info"] == nil
      assert result["raw"]["method_inventory"] == nil
      assert result["auth"]["sign_method"] == nil
      assert result["errors"]["handle_errors"] == nil
      refute Map.has_key?(result, "runtime")
      refute Map.has_key?(result, "structure")
      assert result["endpoints"]["interfaces"] == nil
      assert result["endpoints"]["pagination"] == nil
      assert result["raw"]["overrides_meta"] == nil
    end

    test "resolves alias exchange runtime data from parent" do
      parent_describe = %{"id" => "testex", "has" => %{"fetchTicker" => true}}
      parent_markets = %{"market_count" => 50, "markets" => %{"BTC/USDT" => %{"active" => true}}}

      # Alias has no own describe/markets but has class hierarchy pointing to parent
      alias_class = %{
        "node_key" => "rest:aliasex",
        "class_name" => "aliasex",
        "type" => "rest",
        "extends_resolved" => "testex",
        "parent_key" => "rest:testex",
        "file" => "aliasex.ts",
        "method_count" => 1,
        "methods" => ["describe"],
        "method_details" => []
      }

      data = %{
        empty_data()
        | describe: %{"testex" => parent_describe},
          load_markets: %{"testex" => parent_markets},
          classes: %{"aliasex" => [alias_class]}
      }

      result = Pipeline.build_exchange_data(alias_meta(), data, @schema_opts)

      assert result["raw"]["describe"] == parent_describe
      # runtime.markets no longer emitted; symbols_index derived from the same source.
      assert result["markets"]["symbols_index"] == %{"BTC/USDT" => %{"spot" => false, "swap" => false}}
      assert is_map(result["markets"]["patterns"])
    end

    test "resolves authenticated_sections from parent's sign() when child doesn't override" do
      # Child `aliasex` has its own describe.api (so api_keys are from the child)
      # but no own sign_methods entry — pipeline must walk the extends chain back
      # to `testex` and derive authenticated_sections from the parent's sign() AST.
      parent_sign =
        %{
          "async" => false,
          "params" => [%{"name" => "path", "type" => "string"}],
          "return_type" => nil,
          "statements" => 3,
          "body" => %{
            "type" => "BlockStatement",
            "body" => [
              %{
                "type" => "IfStatement",
                "test" => %{
                  "type" => "BinaryExpression",
                  "operator" => "===",
                  "left" => %{"type" => "Identifier", "name" => "api"},
                  "right" => %{"type" => "Literal", "value" => "private"}
                },
                "consequent" => %{
                  "type" => "BlockStatement",
                  "body" => [
                    %{
                      "type" => "ExpressionStatement",
                      "expression" => %{
                        "type" => "CallExpression",
                        "callee" => %{
                          "type" => "MemberExpression",
                          "object" => %{"type" => "ThisExpression"},
                          "property" => %{
                            "type" => "Identifier",
                            "name" => "checkRequiredCredentials"
                          }
                        },
                        "arguments" => []
                      }
                    }
                  ]
                },
                "alternate" => nil
              }
            ]
          }
        }

      alias_class = %{
        "node_key" => "rest:aliasex",
        "class_name" => "aliasex",
        "type" => "rest",
        "extends_resolved" => "testex",
        "parent_key" => "rest:testex",
        "file" => "aliasex.ts",
        "method_count" => 0,
        "methods" => [],
        "method_details" => []
      }

      data = %{
        empty_data()
        | describe: %{"aliasex" => %{"id" => "aliasex", "api" => %{"public" => %{}, "private" => %{}}}},
          classes: %{"aliasex" => [alias_class]},
          sign_methods: %{"testex" => parent_sign}
      }

      result = Pipeline.build_exchange_data(alias_meta(), data, @schema_opts)

      # Child has no own sign_method — it is resolved from parent only for
      # derivation purposes, not re-emitted as the child's own AST.
      assert result["auth"]["sign_method"] == nil
      assert result["auth"]["authenticated_sections"] == ["private"]
    end

    test "renames handle_errors fields correctly" do
      result = Pipeline.build_exchange_data(full_meta(), full_data(), @schema_opts)
      he = result["errors"]["handle_errors"]

      # "handle_errors" from extraction → "method" in schema
      assert he["method"]["statements"] == 4
      assert he["exceptions"]["broad"]["error"] == "ExchangeError"
      assert he["http_exceptions"]["429"] == "RateLimitExceeded"

      # error_code_fields derived from method AST with role classification
      assert is_list(he["error_code_fields"])
      assert length(he["error_code_fields"]) == 2

      code_entry = Enum.find(he["error_code_fields"], &(&1["field"] == "code"))
      msg_entry = Enum.find(he["error_code_fields"], &(&1["field"] == "msg"))

      assert code_entry["roles"] == ["error_code"]
      assert code_entry["sentinel_values"] == nil

      assert msg_entry["roles"] == ["error_message"]
      assert msg_entry["sentinel_values"] == nil

      assert is_list(he["throw_dispatches"])
      assert length(he["throw_dispatches"]) == 2
      assert Enum.all?(he["throw_dispatches"], &Map.has_key?(&1, "message_lookup"))

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

      assert result["errors"]["handle_errors"] == nil
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
      ov = result["raw"]["overrides_meta"]

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
      ov = result["raw"]["overrides_meta"]

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
      ci = result["raw"]["class_info"]

      assert ci["rest"]["type"] == "rest"
      assert ci["ws"]["type"] == "ws"
    end

    test "class_info ws is nil when no ws class exists" do
      data = %{full_data() | classes: %{"testex" => [@rest_class]}}
      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)

      assert result["raw"]["class_info"]["rest"]["type"] == "rest"
      assert result["raw"]["class_info"]["ws"] == nil
    end

    test "parse_methods is nil when empty map" do
      data = %{
        full_data()
        | parse_methods: %{
            "testex" => %{"id" => "testex", "parse_methods" => %{}, "parse_method_count" => 0}
          }
      }

      # In v4 parse_methods go into normalization.parse_methods_digest; nil digest means empty
      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      assert result["normalization"]["parse_methods_digest"] == %{}
    end

    test "ws_methods is not emitted in v4 output (pruned since schema 3.0.0 / Task 117)" do
      data = %{
        full_data()
        | ws_methods: %{
            "testex" => %{"id" => "testex", "ws_methods" => %{}, "ws_method_count" => 0}
          }
      }

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)

      # ws_methods are pruned from the emitted schema since 3.0.0
      # (Task 117). v4 has no ws_methods key at top level, and `raw`
      # carries method_inventory (REST only) — never ws_methods.
      refute Map.has_key?(result, "ws_methods")
      refute Map.has_key?(result["raw"] || %{}, "ws_methods")
    end

    test "unified_endpoints filters out method names not in interface_signatures" do
      # Simulate leaked helper methods: ethGetAddressFromPrivateKey contains "Get"
      # but is not a real interface method
      data = %{
        full_data()
        | unified_endpoints: %{
            "testex" => %{
              "id" => "testex",
              "unified_endpoints" => %{
                "fetchTicker" => ["publicGetTicker", "ethGetAddressFromPrivateKey"],
                "createOrder" => ["parseOrderTypeTimeInForceAndPostOnly"]
              },
              "unified_endpoint_count" => 3
            }
          }
      }

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      ue = result["endpoints"]["unified"]

      # publicGetTicker is in interface_signatures — kept
      assert ue["fetchTicker"] == ["publicGetTicker"]

      # ethGetAddressFromPrivateKey is NOT in interface_signatures — removed
      refute "ethGetAddressFromPrivateKey" in (ue["fetchTicker"] || [])

      # createOrder had only leaked methods — entire entry removed
      refute Map.has_key?(ue, "createOrder")
    end

    test "unified_endpoints passes through unfiltered when no interface_signatures exist" do
      data = %{
        full_data()
        | interface_signatures: %{},
          unified_endpoints: %{
            "testex" => %{
              "id" => "testex",
              "unified_endpoints" => %{
                "fetchTicker" => ["publicGetTicker", "someHelper"]
              },
              "unified_endpoint_count" => 2
            }
          }
      }

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      ue = result["endpoints"]["unified"]

      # No signatures to filter against — all endpoints preserved
      assert ue["fetchTicker"] == ["publicGetTicker", "someHelper"]
    end

    test "unified_endpoints is nil when all endpoints are filtered out" do
      data = %{
        full_data()
        | unified_endpoints: %{
            "testex" => %{
              "id" => "testex",
              "unified_endpoints" => %{
                "fetchTicker" => ["nonExistentMethod"]
              },
              "unified_endpoint_count" => 1
            }
          }
      }

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      assert result["endpoints"]["unified"] == nil
    end

    test "drop_disabled_endpoints removes methods the child sets has: false" do
      # Pattern A: parent declares fetchOrders in `has`, child flips it to false.
      # Child still pattern-matches a `fetchOrders` binding via prefix, but contract
      # says the endpoint is unavailable — it must not appear in unified_endpoints.
      sig = %{
        "name" => "stub",
        "params" => [%{"name" => "params", "type" => "typeliteral"}],
        "return_type" => "Promise<implicitReturnType>"
      }

      data = %{
        full_data()
        | describe: %{
            "testex" => %{
              "id" => "testex",
              "has" => %{"fetchTicker" => true, "fetchOrders" => false}
            }
          },
          unified_endpoints: %{
            "testex" => %{
              "id" => "testex",
              "unified_endpoints" => %{
                "fetchTicker" => ["publicGetTicker"],
                "fetchOrders" => ["privateGetOrders"]
              },
              "unified_endpoint_count" => 2
            }
          },
          interface_signatures: %{
            "testex" => %{
              "id" => "testex",
              "interface_signatures" => %{
                "publicGetTicker" => sig,
                "privateGetOrders" => sig
              }
            }
          }
      }

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      ue = result["endpoints"]["unified"]

      assert ue["fetchTicker"] == ["publicGetTicker"]
      refute Map.has_key?(ue, "fetchOrders")
    end

    test "restrict_to_canonical_vocab drops methods outside the CCXT has-key vocabulary" do
      # Pattern B: fetchSpotMarkets is an internal routing helper — never appears
      # as a `has` key in CCXT. The canonical_has_keys MapSet is the union of
      # every `has` key across the corpus; methods outside it are not unified.
      sig = %{
        "name" => "stub",
        "params" => [%{"name" => "params", "type" => "typeliteral"}],
        "return_type" => "Promise<implicitReturnType>"
      }

      data =
        full_data()
        |> Map.put(:canonical_has_keys, MapSet.new(["fetchTicker", "fetchOrders"]))
        |> Map.put(:unified_endpoints, %{
          "testex" => %{
            "id" => "testex",
            "unified_endpoints" => %{
              "fetchTicker" => ["publicGetTicker"],
              "fetchSpotMarkets" => ["publicGetSpotMarkets"]
            },
            "unified_endpoint_count" => 2
          }
        })
        |> Map.put(:interface_signatures, %{
          "testex" => %{
            "id" => "testex",
            "interface_signatures" => %{
              "publicGetTicker" => sig,
              "publicGetSpotMarkets" => sig
            }
          }
        })

      result = Pipeline.build_exchange_data(full_meta(), data, @schema_opts)
      ue = result["endpoints"]["unified"]

      assert ue["fetchTicker"] == ["publicGetTicker"]
      refute Map.has_key?(ue, "fetchSpotMarkets")
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
      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "fakex",
        "describe" => %{"id" => "fakex"}
      })

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
      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "fakex",
        "describe" => %{"id" => "fakex"}
      })

      write_json(Path.join(tmp_dir, "load_markets/fakex.json"), %{
        "id" => "fakex",
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
      assert stats.orphan_entries == []
      assert stats.id_mismatch_entries == []
    end
  end

  describe "id mismatch detection" do
    @tag :tmp_dir
    test "tracks describe file with mismatched top-level id", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "otherex",
        "describe" => %{"id" => "otherex"}
      })

      {:ok, exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert Enum.any?(stats.id_mismatch_entries, fn entry ->
               String.contains?(entry, "describe/fakex.json") and
                 String.contains?(entry, "expected id")
             end)

      assert hd(exchanges)["runtime"]["describe"] == nil
      assert stats.missing_entries == []
      assert stats.corrupt_entries == []
    end

    @tag :tmp_dir
    test "tracks describe file with mismatched nested describe.id", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "fakex",
        "describe" => %{"id" => "otherex"}
      })

      {:ok, exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert Enum.any?(stats.id_mismatch_entries, fn entry ->
               String.contains?(entry, "describe/fakex.json") and
                 String.contains?(entry, "describe.id")
             end)

      assert hd(exchanges)["runtime"]["describe"] == nil
      assert stats.missing_entries == []
      assert stats.corrupt_entries == []
    end

    @tag :tmp_dir
    test "tracks load_markets file with mismatched top-level id", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: ["fakex"]
      )

      write_json(Path.join(tmp_dir, "load_markets/fakex.json"), %{
        "id" => "otherex",
        "market_count" => 1,
        "markets" => %{"BTC/USDT" => %{}}
      })

      {:ok, exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert Enum.any?(stats.id_mismatch_entries, fn entry ->
               String.contains?(entry, "load_markets/fakex.json") and
                 String.contains?(entry, "expected id")
             end)

      assert hd(exchanges)["runtime"]["markets"] == nil
      assert stats.missing_entries == []
      assert stats.corrupt_entries == []
    end
  end

  describe "orphan entry detection" do
    @tag :tmp_dir
    test "tracks orphan describe file absent from manifest", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      write_json(Path.join(tmp_dir, "describe/rogue.json"), %{
        "id" => "rogue",
        "describe" => %{"id" => "rogue"}
      })

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert "describe/rogue.json" in stats.orphan_entries
      assert stats.missing_entries == []
      assert stats.id_mismatch_entries == []
    end

    @tag :tmp_dir
    test "tracks orphan load_markets file absent from manifest", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      write_json(Path.join(tmp_dir, "load_markets/rogue.json"), %{
        "id" => "rogue",
        "market_count" => 1,
        "markets" => %{"BTC/USDT" => %{}}
      })

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert "load_markets/rogue.json" in stats.orphan_entries
      assert stats.missing_entries == []
      assert stats.id_mismatch_entries == []
    end

    @tag :tmp_dir
    test "tracks orphan ids in global discovery files", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      write_json(Path.join(tmp_dir, "methods_rest.json"), %{
        "exchanges" => [
          %{"id" => "fakex", "methods" => []},
          %{"id" => "rogue", "methods" => []}
        ]
      })

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert Enum.any?(stats.orphan_entries, fn entry ->
               String.contains?(entry, "methods_rest.json") and String.contains?(entry, "rogue")
             end)
    end
  end

  describe "global entry corruption tracking" do
    @tag :tmp_dir
    test "tracks corrupt methods_rest entry instead of silently treating it as null", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir, describe_exchanges: [], markets_succeeded: [])
      write_json(Path.join(tmp_dir, "methods_rest.json"), %{"exchanges" => [%{"id" => "fakex", "methods" => nil}]})

      {:ok, exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert Enum.any?(stats.corrupt_entries, fn entry ->
               String.contains?(entry, "methods_rest.json") and String.contains?(entry, "invalid methods")
             end)

      assert hd(exchanges)["structure"]["methods"] == nil
      assert stats.validation_errors == []
    end

    @tag :tmp_dir
    test "tracks corrupt handle_errors entry with missing method key", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir, describe_exchanges: [], markets_succeeded: [])

      write_json(Path.join(tmp_dir, "handle_errors.json"), %{
        "exchanges" => [
          %{
            "id" => "fakex",
            "exceptions" => %{"broad" => %{}, "exact" => %{}},
            "http_exceptions" => %{}
          }
        ]
      })

      {:ok, exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert Enum.any?(stats.corrupt_entries, fn entry ->
               String.contains?(entry, "handle_errors.json") and
                 String.contains?(entry, "missing required handle_errors key")
             end)

      assert hd(exchanges)["structure"]["handle_errors"] == nil
      assert stats.validation_errors == []
    end

    @tag :tmp_dir
    test "tracks corrupt parse_methods entry with non-map payload", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir, describe_exchanges: [], markets_succeeded: [])

      write_json(Path.join(tmp_dir, "parse_methods.json"), %{
        "exchanges" => [
          %{
            "id" => "fakex",
            "parse_methods" => nil,
            "parse_method_count" => 0
          }
        ]
      })

      {:ok, exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert Enum.any?(stats.corrupt_entries, fn entry ->
               String.contains?(entry, "parse_methods.json") and String.contains?(entry, "invalid parse_methods")
             end)

      assert hd(exchanges)["structure"]["parse_methods"] == nil
      assert stats.validation_errors == []
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

    write_json(Path.join(dir, "error_class_hierarchy.json"), %{
      "tree" => %{"BaseError" => %{}},
      "flat_parents" => %{"BaseError" => nil},
      "ancestors" => %{"BaseError" => []}
    })

    empty_global = %{"exchanges" => []}
    write_json(Path.join(dir, "methods_rest.json"), empty_global)
    write_json(Path.join(dir, "methods_ws.json"), empty_global)
    write_json(Path.join(dir, "sign_methods.json"), empty_global)
    write_json(Path.join(dir, "handle_errors.json"), empty_global)
    write_json(Path.join(dir, "parse_methods.json"), empty_global)
    write_json(Path.join(dir, "ws_methods.json"), empty_global)
    write_json(Path.join(dir, "interface_signatures.json"), empty_global)
    write_json(Path.join(dir, "pagination.json"), empty_global)
    write_json(Path.join(dir, "unified_endpoints.json"), empty_global)
    write_json(Path.join(dir, "request_defaults.json"), empty_global)
    write_json(Path.join(dir, "url_templates.json"), empty_global)
    write_json(Path.join(dir, "request_headers.json"), empty_global)
    write_json(Path.join(dir, "rate_limit_buckets.json"), empty_global)
    write_json(Path.join(dir, "rate_limit_costs.json"), empty_global)
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
      assert :ok = Schema.validate_v4(result)
    end

    test "alias exchange passes schema validation" do
      result = Pipeline.build_exchange_data(alias_meta(), empty_data(), @schema_opts)
      assert :ok = Schema.validate_v4(result)
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
      assert :ok = Schema.validate_v4(result)
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

    @tag :tmp_dir
    test "unified_endpoints entry missing unified_endpoints key tracked as corrupt", %{
      tmp_dir: tmp_dir
    } do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      # Write entry with id but missing required "unified_endpoints" key
      File.write!(
        Path.join(tmp_dir, "unified_endpoints.json"),
        Jason.encode!(%{"exchanges" => [%{"id" => "fakex"}]})
      )

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert stats.corrupt_entries != []

      assert Enum.any?(
               stats.corrupt_entries,
               &String.contains?(&1, "unified_endpoints")
             )
    end

    @tag :tmp_dir
    test "unified_endpoints entry with non-map endpoints tracked as corrupt", %{
      tmp_dir: tmp_dir
    } do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      # Write entry with unified_endpoints as a string instead of map
      File.write!(
        Path.join(tmp_dir, "unified_endpoints.json"),
        Jason.encode!(%{
          "exchanges" => [%{"id" => "fakex", "unified_endpoints" => "not a map"}]
        })
      )

      {:ok, _exchanges, stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      assert stats.corrupt_entries != []

      assert Enum.any?(
               stats.corrupt_entries,
               &String.contains?(&1, "unified_endpoints")
             )
    end
  end

  describe "write!/2" do
    @tag :tmp_dir
    test "copies exchange_v4.json into the output directory", %{tmp_dir: tmp_dir} do
      Pipeline.write!([full_exchange()], tmp_dir)

      schema_path = Path.join(tmp_dir, "exchange_v4.json")
      assert File.exists?(schema_path)
      assert schema_path |> File.read!() |> Jason.decode!() |> is_map()
      assert File.read!(schema_path) == File.read!(CcxtExtract.Paths.priv("schema/exchange_v4.json"))
    end

    @tag :tmp_dir
    test "removes stale exchange files and refreshes schema and manifest", %{tmp_dir: tmp_dir} do
      stale_exchange_path = Path.join(tmp_dir, "staleex.json")
      stale_manifest_path = Path.join(tmp_dir, "_manifest.json")
      stale_schema_path = Path.join(tmp_dir, "exchange_v4.json")

      File.write!(stale_exchange_path, Jason.encode!(%{"exchange" => %{"id" => "staleex"}}))
      File.write!(stale_manifest_path, Jason.encode!(%{"exchange_count" => 0, "exchanges" => []}))
      File.write!(stale_schema_path, ~s({"stale":true}))

      exchange = full_exchange()
      Pipeline.write!([exchange], tmp_dir)

      refute File.exists?(stale_exchange_path)

      manifest = stale_manifest_path |> File.read!() |> Jason.decode!()
      assert manifest["exchange_count"] == 1
      assert manifest["exchanges"] == ["testex"]

      assert File.read!(stale_schema_path) == File.read!(CcxtExtract.Paths.priv("schema/exchange_v4.json"))
    end
  end

  describe "write!/3 with discoveries_dir" do
    @tag :tmp_dir
    test "copies _base_methods.json from custom discoveries_dir", %{tmp_dir: tmp_dir} do
      discoveries_dir = Path.join(tmp_dir, "discoveries")
      output_dir = Path.join(tmp_dir, "output")
      File.mkdir_p!(discoveries_dir)

      base_methods = %{"methods" => %{"safeCurrencyCode" => %{"type" => "method"}}}
      File.write!(Path.join(discoveries_dir, "_base_methods.json"), Jason.encode!(base_methods))

      Pipeline.write!([full_exchange()], output_dir, discoveries_dir: discoveries_dir)

      target = Path.join(output_dir, "_base_methods.json")
      assert File.exists?(target)
      assert Jason.decode!(File.read!(target)) == base_methods
    end

    @tag :tmp_dir
    test "removes stale _base_methods.json when source is absent", %{tmp_dir: tmp_dir} do
      discoveries_dir = Path.join(tmp_dir, "discoveries")
      output_dir = Path.join(tmp_dir, "output")
      File.mkdir_p!(discoveries_dir)
      File.mkdir_p!(output_dir)

      # Simulate a previous run that copied _base_methods.json
      stale_target = Path.join(output_dir, "_base_methods.json")
      File.write!(stale_target, Jason.encode!(%{"stale" => true}))
      assert File.exists?(stale_target)

      # Run write! without a source _base_methods.json
      Pipeline.write!([full_exchange()], output_dir, discoveries_dir: discoveries_dir)

      refute File.exists?(stale_target)
    end

    @tag :tmp_dir
    test "no error when neither source nor stale target exists", %{tmp_dir: tmp_dir} do
      discoveries_dir = Path.join(tmp_dir, "discoveries")
      output_dir = Path.join(tmp_dir, "output")
      File.mkdir_p!(discoveries_dir)

      Pipeline.write!([full_exchange()], output_dir, discoveries_dir: discoveries_dir)

      refute File.exists?(Path.join(output_dir, "_base_methods.json"))
    end
  end

  describe "manifest version fields" do
    @tag :tmp_dir
    test "manifest includes source_git_sha from version_info", %{tmp_dir: tmp_dir} do
      version_info = %{
        "npm_version" => "4.5.45",
        "source_version" => "4.5.45",
        "source_git_sha" => "abc1234def5678",
        "recorded_at" => "2026-04-03T00:00:00Z"
      }

      Pipeline.write!([full_exchange()], tmp_dir, version_info: version_info)

      manifest = tmp_dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["ccxt_version"] == "4.5.45"
      assert manifest["source_git_sha"] == "abc1234def5678"
      assert manifest["schema_version"] == Schema.schema_version()
    end

    @tag :tmp_dir
    test "manifest ccxt_version falls back to exchange data when version_info missing", %{
      tmp_dir: tmp_dir
    } do
      Pipeline.write!([full_exchange()], tmp_dir, version_info: %{})

      manifest = tmp_dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["ccxt_version"] == "4.5.45"
      assert is_nil(manifest["source_git_sha"])
    end

    @tag :tmp_dir
    test "manifest ccxt_version matches exchange data, not version_info on disk", %{
      tmp_dir: tmp_dir
    } do
      # Simulate exchanges built with an override version that differs from version_info.
      # Manifest must agree with the exchanges (source of truth), not the version file.
      override_opts = [ccxt_version: "OVERRIDE-1.2.3", extracted_at: "2026-04-03T00:00:00Z"]
      exchange = Pipeline.build_exchange_data(full_meta(), full_data(), override_opts)

      version_info = %{"npm_version" => "4.5.45", "source_git_sha" => "abc1234"}
      Pipeline.write!([exchange], tmp_dir, version_info: version_info)

      manifest = tmp_dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["ccxt_version"] == "OVERRIDE-1.2.3"
      assert manifest["source_git_sha"] == "abc1234"
    end
  end

  # --- Helpers ---

  defp full_exchange do
    Pipeline.build_exchange_data(full_meta(), full_data(), @schema_opts)
  end

  describe "scope filtering and manifest tier_scope" do
    @tag :tmp_dir
    test "extract/1 with :all returns every manifest exchange", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: ["fakex"],
        extra_exchanges: [%{"id" => "otherx", "name" => "Other", "alias" => false}]
      )

      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{"id" => "fakex", "describe" => %{"id" => "fakex"}})
      write_json(Path.join(tmp_dir, "describe/otherx.json"), %{"id" => "otherx", "describe" => %{"id" => "otherx"}})

      write_json(Path.join(tmp_dir, "load_markets/fakex.json"), %{"id" => "fakex", "market_count" => 0, "markets" => %{}})

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z",
          scope: :all
        )

      ids = Enum.map(exchanges, & &1["exchange"]["id"])
      assert Enum.sort(ids) == ["fakex", "otherx"]
    end

    @tag :tmp_dir
    test "extract/1 filters to the MapSet scope", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: ["fakex"],
        extra_exchanges: [%{"id" => "otherx", "name" => "Other", "alias" => false}]
      )

      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{"id" => "fakex", "describe" => %{"id" => "fakex"}})
      write_json(Path.join(tmp_dir, "describe/otherx.json"), %{"id" => "otherx", "describe" => %{"id" => "otherx"}})

      write_json(Path.join(tmp_dir, "load_markets/fakex.json"), %{"id" => "fakex", "market_count" => 0, "markets" => %{}})

      {:ok, exchanges, _stats} =
        Pipeline.extract(
          discoveries_dir: tmp_dir,
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z",
          scope: MapSet.new(["fakex"])
        )

      ids = Enum.map(exchanges, & &1["exchange"]["id"])
      assert ids == ["fakex"]
    end

    @tag :tmp_dir
    test "write!/3 stamps tier_scope into manifest and prunes stale files", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      File.mkdir_p!(output_dir)

      # Simulate a prior extract that left leftover files behind.
      File.write!(Path.join(output_dir, "stale.json"), "{}")
      File.write!(Path.join(output_dir, "_kept.json"), "{}")
      File.write!(Path.join(output_dir, "exchange_v3.json"), "{}")

      # Discoveries dir just needs the schema + base methods copy targets.
      discoveries_dir = Path.join(tmp_dir, "discoveries")
      File.mkdir_p!(discoveries_dir)
      write_json(Path.join(discoveries_dir, "_base_methods.json"), %{"count" => 0, "methods" => []})

      exchange =
        Pipeline.build_exchange_data(
          %{
            "id" => "fakex",
            "name" => "Fake",
            "alias" => false,
            "pro" => false,
            "certified" => false,
            "version" => nil,
            "country" => [],
            "referral" => nil
          },
          %{
            describe: %{},
            load_markets: %{},
            classes: %{},
            methods_rest: %{},
            methods_ws: %{},
            sign_methods: %{},
            handle_errors: %{},
            parse_methods: %{},
            ws_methods: %{},
            interface_signatures: %{},
            pagination: %{},
            unified_endpoints: %{},
            request_defaults: %{},
            url_templates: %{},
            request_headers: %{},
            overrides: %{},
            error_class_hierarchy: nil,
            missing_files: []
          },
          ccxt_version: "4.5.45",
          extracted_at: "2026-03-30T12:00:00Z"
        )

      Pipeline.write!([exchange], output_dir,
        tier_scope: ["tier1", "exchange:fakex"],
        discoveries_dir: discoveries_dir
      )

      manifest = output_dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["tier_scope"] == ["tier1", "exchange:fakex"]
      assert manifest["exchanges"] == ["fakex"]

      refute File.exists?(Path.join(output_dir, "stale.json"))
      assert File.exists?(Path.join(output_dir, "_kept.json"))
      assert File.exists?(Path.join(output_dir, "exchange_v4.json"))
      assert File.exists?(Path.join(output_dir, "fakex.json"))
    end

    @tag :tmp_dir
    test "write!/3 defaults tier_scope to \"all\" when option omitted", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "out")
      File.mkdir_p!(output_dir)

      discoveries_dir = Path.join(tmp_dir, "discoveries")
      File.mkdir_p!(discoveries_dir)
      write_json(Path.join(discoveries_dir, "_base_methods.json"), %{"count" => 0, "methods" => []})

      Pipeline.write!([], output_dir, discoveries_dir: discoveries_dir)

      manifest = output_dir |> Path.join("_manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["tier_scope"] == "all"
    end
  end
end
