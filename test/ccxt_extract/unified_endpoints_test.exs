defmodule CcxtExtract.UnifiedEndpointsTest do
  @moduledoc """
  Tests for UnifiedEndpoints extraction from exchange TypeScript files.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.UnifiedEndpoints

  # --- AST Helpers ---

  # Build a minimal class AST wrapped in ExportDefaultDeclaration
  defp build_class_ast(class_name, methods) do
    %{
      body: [
        %{
          type: :export_default_declaration,
          declaration: %{
            type: :class_declaration,
            id: %{name: class_name},
            superClass: nil,
            body: %{body: methods}
          }
        }
      ]
    }
  end

  # Build a MethodDefinition whose body contains the given statements
  defp method_with_body(method_name, statements, opts \\ []) do
    %{
      type: :method_definition,
      key: %{name: method_name},
      value: %{
        type: :function_expression,
        async: Keyword.get(opts, :async, true),
        params: [],
        body: %{body: statements}
      }
    }
  end

  # AST node for this.<name>(args...) — used to build method body fixtures
  defp this_call(method_name, args \\ []) do
    %{
      type: :call_expression,
      callee: %{
        type: :member_expression,
        object: %{type: :this_expression},
        property: %{type: :identifier, name: method_name}
      },
      arguments: args
    }
  end

  defp build_class_ast(class_name, parent_name, methods) do
    %{
      body: [
        %{
          type: :export_default_declaration,
          declaration: %{
            type: :class_declaration,
            id: %{name: class_name},
            superClass: %{type: :identifier, name: parent_name},
            body: %{body: methods}
          }
        }
      ]
    }
  end

  # AST node for super.<name>(args...) — used for super delegation fixtures
  defp super_call(method_name, args \\ []) do
    %{
      type: :call_expression,
      callee: %{
        type: :member_expression,
        object: %{type: :super},
        property: %{type: :identifier, name: method_name}
      },
      arguments: args
    }
  end

  defp identifier(name), do: %{type: :identifier, name: name}

  # Wrap an expression in a return-await statement (typical pattern)
  defp return_await(expr) do
    %{
      type: :return_statement,
      argument: %{
        type: :await_expression,
        argument: expr
      }
    }
  end

  describe "extract_from_ast/2" do
    test "single unified method with one interface call" do
      stmt = return_await(this_call("publicGetV5MarketTickers", [identifier("params")]))

      ast = build_class_ast("bybit", [method_with_body("fetchTicker", [stmt])])
      result = UnifiedEndpoints.extract_from_ast(ast, "bybit.ts")

      assert result["id"] == "bybit"
      assert result["unified_endpoint_count"] == 1
      assert result["unified_endpoints"]["fetchTicker"] == ["publicGetV5MarketTickers"]
    end

    test "unified method with multiple interface calls (branching)" do
      # Simulates if/else branches calling different endpoints
      call1 = this_call("privateGetV5SpotCrossMarginTradeAccount")
      call2 = this_call("privateGetV5AccountWalletBalance")

      if_stmt = %{
        type: :if_statement,
        test: identifier("isMargin"),
        consequent: %{
          type: :block_statement,
          body: [return_await(call1)]
        },
        alternate: %{
          type: :block_statement,
          body: [return_await(call2)]
        }
      }

      ast = build_class_ast("bybit", [method_with_body("fetchBalance", [if_stmt])])
      result = UnifiedEndpoints.extract_from_ast(ast, "bybit.ts")

      assert result["unified_endpoint_count"] == 2

      assert result["unified_endpoints"]["fetchBalance"] == [
               "privateGetV5AccountWalletBalance",
               "privateGetV5SpotCrossMarginTradeAccount"
             ]
    end

    test "non-unified method is ignored" do
      stmt = return_await(this_call("publicGetV5MarketTickers"))

      ast =
        build_class_ast("test", [
          method_with_body("parseTicker", [stmt]),
          method_with_body("handleMessage", [stmt])
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      assert result["unified_endpoints"] == %{}
      assert result["unified_endpoint_count"] == 0
    end

    test "nested interface call inside if block is found" do
      nested_call = this_call("privatePostV5OrderCreate")

      if_stmt = %{
        type: :if_statement,
        test: identifier("isStop"),
        consequent: %{
          type: :block_statement,
          body: [
            %{
              type: :expression_statement,
              expression: %{
                type: :assignment_expression,
                right: %{type: :await_expression, argument: nested_call}
              }
            }
          ]
        },
        alternate: nil
      }

      ast = build_class_ast("test", [method_with_body("createOrder", [if_stmt])])
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      assert result["unified_endpoints"]["createOrder"] == ["privatePostV5OrderCreate"]
    end

    test "no interface calls returns empty — method omitted from output" do
      stmt = return_await(this_call("someHelperMethod"))

      ast = build_class_ast("test", [method_with_body("fetchTicker", [stmt])])
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # fetchTicker found but no interface calls → not in output map
      assert result["unified_endpoints"] == %{}
      assert result["unified_endpoint_count"] == 0
    end

    test "no exported class returns nil" do
      ast = %{body: [%{type: :import_declaration, source: %{value: "foo"}}]}
      assert UnifiedEndpoints.extract_from_ast(ast, "foo.ts") == nil
    end

    test "sync method with unified prefix is still captured" do
      stmt = return_await(this_call("publicGetTicker"))

      ast = build_class_ast("test", [method_with_body("fetchTicker", [stmt], async: false)])
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      assert result["unified_endpoints"]["fetchTicker"] == ["publicGetTicker"]
    end

    test "duplicate interface calls are deduplicated" do
      call = this_call("publicGetV5MarketTickers")

      if_stmt = %{
        type: :if_statement,
        test: identifier("retry"),
        consequent: %{type: :block_statement, body: [return_await(call)]},
        alternate: %{type: :block_statement, body: [return_await(call)]}
      }

      ast = build_class_ast("test", [method_with_body("fetchTicker", [if_stmt])])
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # Should deduplicate to single entry
      assert result["unified_endpoints"]["fetchTicker"] == ["publicGetV5MarketTickers"]
      assert result["unified_endpoint_count"] == 1
    end

    test "multiple unified methods each with their own endpoints" do
      ticker_stmt = return_await(this_call("publicGetMarketTicker"))
      balance_stmt = return_await(this_call("privateGetAccountBalance"))

      ast =
        build_class_ast("okx", [
          method_with_body("fetchTicker", [ticker_stmt]),
          method_with_body("fetchBalance", [balance_stmt])
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "okx.ts")

      assert result["unified_endpoint_count"] == 2
      assert result["unified_endpoints"]["fetchTicker"] == ["publicGetMarketTicker"]
      assert result["unified_endpoints"]["fetchBalance"] == ["privateGetAccountBalance"]
    end

    test "all unified prefixes are recognized" do
      prefixes =
        ~w(fetch create cancel edit withdraw transfer setLeverage addMargin reduceMargin borrowMargin repayMargin closePosition)

      methods =
        Enum.map(prefixes, fn name ->
          method_with_body(name, [return_await(this_call("privatePostEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- prefixes do
        assert Map.has_key?(result["unified_endpoints"], name),
               "Expected #{name} to be recognized as unified method"
      end
    end

    test "helper methods with Request/Helper/Params suffix are excluded" do
      # createOrderRequest, fetchAccountHelper, etc. are internal helpers, not unified API
      helpers = ~w(createOrderRequest fetchAccountHelper fetchTickersHelper editSpotOrderRequest)

      methods =
        Enum.map(helpers, fn name ->
          method_with_body(name, [return_await(this_call("privatePostEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- helpers do
        refute Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a helper and should NOT be captured as unified method"
      end

      assert result["unified_endpoint_count"] == 0
    end

    test "dispatch helper suffixes are excluded (FromCache, Supplement, Default, WithMethod)" do
      # Internal routing methods that start with unified prefixes but are not unified API
      helpers =
        ~w(fetchMarketsFromCache fetchCurrenciesFromCache fetchDepositAddressSupplement fetchOrderDefault fetchOrdersWithMethod)

      methods =
        Enum.map(helpers, fn name ->
          method_with_body(name, [return_await(this_call("privateGetEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- helpers do
        refute Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a dispatch helper and should NOT be captured as unified method"
      end

      assert result["unified_endpoint_count"] == 0
    end

    test "FromAPI/FromRest source-qualified helpers are excluded" do
      # Internal methods that fetch from a specific source — not unified API
      helpers = ~w(fetchMarketsFromAPI fetchMarketsFromRest)

      methods =
        Enum.map(helpers, fn name ->
          method_with_body(name, [return_await(this_call("publicGetEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- helpers do
        refute Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a source-qualified helper and should NOT be captured as unified method"
      end

      assert result["unified_endpoint_count"] == 0
    end

    test "known non-unified methods are excluded by name" do
      # Exchange-specific methods that escape pattern-based detection
      non_unified = ~w(fetchNonce fetchLatestBlockHeight fetchDydxAccount fetchHip3Markets)

      methods =
        Enum.map(non_unified, fn name ->
          method_with_body(name, [return_await(this_call("publicGetEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- non_unified do
        refute Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a known non-unified method and should NOT be captured"
      end

      assert result["unified_endpoint_count"] == 0
    end

    test "By* methods with unified prefixes are real unified methods, not helpers" do
      # These are legitimate public API methods — fetchOrdersByStatus, fetchCurrencyById, etc.
      real_methods = ~w(fetchOrdersByStatus fetchCurrencyById fetchMarketsByType fetchSpotOrdersByStates)

      methods =
        Enum.map(real_methods, fn name ->
          method_with_body(name, [return_await(this_call("privateGetEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- real_methods do
        assert Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a real unified method and should be captured"
      end
    end

    test "versioned internal dispatch methods are excluded (V1/V2/V3, numeric)" do
      # Exchange-specific version wrappers, not unified API
      versioned = ~w(fetchTickerV1 fetchTickerV2 fetchTickerV3 fetchTicker2 fetchAccountsV2 fetchTickersV3)

      methods =
        Enum.map(versioned, fn name ->
          method_with_body(name, [return_await(this_call("publicGetEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- versioned do
        refute Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a versioned variant and should NOT be captured as unified method"
      end

      assert result["unified_endpoint_count"] == 0
    end

    test "non-unified setters are excluded, unified setters are included" do
      # Exchange-specific setters should be excluded
      excluded_setters = ~w(setUserAbstraction setAgentAbstraction setRef setContractLeverage)
      # Unified CCXT setters should be included
      included_setters = ~w(setLeverage setMarginMode setPositionMode setMargin)

      all_methods =
        Enum.map(excluded_setters ++ included_setters, fn name ->
          method_with_body(name, [return_await(this_call("privatePostEndpoint"))])
        end)

      ast = build_class_ast("test", all_methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- excluded_setters do
        refute Map.has_key?(result["unified_endpoints"], name),
               "#{name} is an exchange-specific setter and should NOT be captured"
      end

      for name <- included_setters do
        assert Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a unified setter and SHOULD be captured"
      end
    end

    test "isPostOnly and handlePostOnly are not captured as interface calls" do
      # These contain "Post" but are helper functions, not transport methods
      stmt =
        return_await(
          this_call("publicGetTicker", [
            this_call("isPostOnly"),
            this_call("handlePostOnly")
          ])
        )

      ast = build_class_ast("test", [method_with_body("fetchTicker", [stmt])])
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # Only publicGetTicker should be captured, not isPostOnly or handlePostOnly
      assert result["unified_endpoints"]["fetchTicker"] == ["publicGetTicker"]
    end

    test "compound By* methods with unified prefixes are real unified methods" do
      # These are legitimate public API methods — ByIds, ByNetwork, etc.
      real_methods =
        ~w(fetchOrdersByIds fetchLedgerEntriesByIds fetchDepositAddressesByNetwork fetchMarketsByTypeAndSubType fetchOrdersByState)

      methods =
        Enum.map(real_methods, fn name ->
          method_with_body(name, [return_await(this_call("privateGetEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- real_methods do
        assert Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a real unified method and should be captured"
      end
    end

    test "Default variant methods are excluded (fetchDefaultMarkets)" do
      # Regression: fetchDefaultMarkets leaked into the fixture as a unified method
      helpers = ~w(fetchDefaultMarkets createDefaultOrder fetchDefaultCurrencies)

      methods =
        Enum.map(helpers, fn name ->
          method_with_body(name, [return_await(this_call("publicGetEndpoint"))])
        end)

      ast = build_class_ast("test", methods)
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      for name <- helpers do
        refute Map.has_key?(result["unified_endpoints"], name),
               "#{name} is a Default variant and should NOT be captured as unified method"
      end
    end

    test "delegation: unified method calling helper resolves to helper's interface calls" do
      # Regression: fetchMarkets → this.fetchDefaultMarkets() → interface calls
      # fetchMarkets has no direct interface calls, only delegates to helper
      unified_body = [return_await(this_call("fetchDefaultMarkets", [identifier("params")]))]

      helper_body = [return_await(this_call("publicGetV5MarketInstrumentsInfo", [identifier("params")]))]

      ast =
        build_class_ast("test", [
          method_with_body("fetchMarkets", unified_body),
          method_with_body("fetchDefaultMarkets", helper_body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # fetchMarkets should resolve through delegation to the helper's interface call
      assert result["unified_endpoints"]["fetchMarkets"] == ["publicGetV5MarketInstrumentsInfo"]

      # fetchDefaultMarkets itself should NOT appear (excluded by Default pattern)
      refute Map.has_key?(result["unified_endpoints"], "fetchDefaultMarkets")
    end

    test "delegation: unified method with multiple delegate targets" do
      # htx pattern: fetchMarkets → multiple this.fetchMarketsByTypeAndSubType() calls
      unified_body = [
        %{
          type: :expression_statement,
          expression:
            this_call("fetchMarketsByTypeAndSubType", [
              %{type: :literal, value: "spot"}
            ])
        },
        %{
          type: :expression_statement,
          expression:
            this_call("fetchMarketsByTypeAndSubType", [
              %{type: :literal, value: "swap"}
            ])
        }
      ]

      helper_body = [
        return_await(this_call("publicGetV2SettingCommonSymbols", [identifier("params")]))
      ]

      ast =
        build_class_ast("test", [
          method_with_body("fetchMarkets", unified_body),
          method_with_body("fetchMarketsByTypeAndSubType", helper_body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      assert result["unified_endpoints"]["fetchMarkets"] == ["publicGetV2SettingCommonSymbols"]
      # fetchMarketsByTypeAndSubType is now correctly recognized as a real unified method
      assert result["unified_endpoints"]["fetchMarketsByTypeAndSubType"] == ["publicGetV2SettingCommonSymbols"]
    end

    test "delegation: merges direct and delegated interface calls" do
      # When a unified method has both direct interface calls AND delegates,
      # both should be captured — e.g., fetchBalance calls privateGetBalance
      # directly for one market type and delegates to loadBalance for another.
      body = [
        return_await(this_call("publicGetTicker")),
        %{type: :expression_statement, expression: this_call("someHelper")}
      ]

      helper_body = [return_await(this_call("privateGetOtherEndpoint"))]

      ast =
        build_class_ast("test", [
          method_with_body("fetchTicker", body),
          method_with_body("someHelper", helper_body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # Should have BOTH direct and delegated interface calls
      assert result["unified_endpoints"]["fetchTicker"] == ["privateGetOtherEndpoint", "publicGetTicker"]
    end

    test "this.extend() calls are not captured as interface methods" do
      # this.extend(request, params) is common — should NOT match (no HTTP verb)
      extend_call = this_call("extend", [identifier("request"), identifier("params")])

      interface_call =
        this_call("publicGetTicker", [
          %{type: :call_expression, callee: extend_call.callee, arguments: extend_call.arguments}
        ])

      stmt = return_await(interface_call)

      ast = build_class_ast("test", [method_with_body("fetchTicker", [stmt])])
      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # Only the interface call, not extend
      assert result["unified_endpoints"]["fetchTicker"] == ["publicGetTicker"]
    end

    test "delegation: multi-hop resolution follows helper chains" do
      # fetchOpenOrders → fetchOrdersByStatus → privateGetOrders
      body = [%{type: :expression_statement, expression: this_call("fetchOrdersByStatus")}]
      hop1_body = [%{type: :expression_statement, expression: this_call("fetchOrdersSinglePage")}]
      hop2_body = [return_await(this_call("privateGetOrders"))]

      ast =
        build_class_ast("test", [
          method_with_body("fetchOpenOrders", body),
          method_with_body("fetchOrdersByStatus", hop1_body),
          method_with_body("fetchOrdersSinglePage", hop2_body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      assert result["unified_endpoints"]["fetchOpenOrders"] == ["privateGetOrders"]
    end

    test "delegation: cycle protection prevents infinite loops" do
      # methodA → methodB → methodA (mutual recursion)
      body_a = [%{type: :expression_statement, expression: this_call("helperB")}]
      body_b = [%{type: :expression_statement, expression: this_call("helperA")}]

      # helperA also calls an interface method to verify we still get results
      body_a = body_a ++ [return_await(this_call("publicGetTicker"))]

      ast =
        build_class_ast("test", [
          method_with_body("fetchTicker", body_a),
          method_with_body("helperA", body_a),
          method_with_body("helperB", body_b)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # Should resolve without infinite loop, capturing the interface call
      assert "publicGetTicker" in result["unified_endpoints"]["fetchTicker"]
    end

    test "delegation: depth limit stops at max hops" do
      # Chain of 5 hops — should stop at depth 3 and miss the deepest call
      body0 = [%{type: :expression_statement, expression: this_call("hop1")}]
      body1 = [%{type: :expression_statement, expression: this_call("hop2")}]
      body2 = [%{type: :expression_statement, expression: this_call("hop3")}]
      body3 = [%{type: :expression_statement, expression: this_call("hop4")}]
      body4 = [return_await(this_call("privateGetDeepEndpoint"))]

      ast =
        build_class_ast("test", [
          method_with_body("fetchDeep", body0),
          method_with_body("hop1", body1),
          method_with_body("hop2", body2),
          method_with_body("hop3", body3),
          method_with_body("hop4", body4)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # 4 hops exceeds max depth of 3, so deepest call is not reached
      refute Map.has_key?(result["unified_endpoints"], "fetchDeep")
    end
  end

  describe "super.*() delegation" do
    setup do
      # Simulate base Exchange methods that delegate back via this.*
      # createOrderWithTakeProfitAndStopLoss calls this.createOrder()
      # fetchDepositAddress calls this.fetchDepositAddresses() and this.fetchDepositAddressesByNetwork()
      base_methods = %{
        "createOrderWithTakeProfitAndStopLoss" =>
          method_with_body("createOrderWithTakeProfitAndStopLoss", [
            return_await(this_call("createOrder", [identifier("symbol")]))
          ]),
        "fetchDepositAddress" =>
          method_with_body("fetchDepositAddress", [
            %{
              type: :if_statement,
              test: identifier("hasFetchDepositAddresses"),
              consequent: %{
                type: :block_statement,
                body: [return_await(this_call("fetchDepositAddresses", [identifier("code")]))]
              },
              alternate: %{
                type: :block_statement,
                body: [
                  return_await(this_call("fetchDepositAddressesByNetwork", [identifier("code")]))
                ]
              }
            }
          ])
      }

      Process.put(:base_method_index, base_methods)
      on_exit(fn -> Process.delete(:base_method_index) end)
      :ok
    end

    test "super call resolves through base method's this.* calls to child's interface methods" do
      # coincatch pattern: super.createOrderWithTakeProfitAndStopLoss() → base calls this.createOrder()
      # → child's createOrder → transport endpoints
      unified_body = [return_await(super_call("createOrderWithTakeProfitAndStopLoss"))]

      create_body = [
        return_await(this_call("privateMixPostV1PlanPlaceOrder")),
        return_await(this_call("privateMixPostV1OrdersPlace"))
      ]

      ast =
        build_class_ast("coincatch", "Exchange", [
          method_with_body("createOrderWithTakeProfitAndStopLoss", unified_body),
          method_with_body("createOrder", create_body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "coincatch.ts")

      assert "privateMixPostV1OrdersPlace" in result["unified_endpoints"]["createOrderWithTakeProfitAndStopLoss"]
      assert "privateMixPostV1PlanPlaceOrder" in result["unified_endpoints"]["createOrderWithTakeProfitAndStopLoss"]
    end

    test "super call with branching base method resolves both branches" do
      # kucoin pattern: super.fetchDepositAddress() → base branches to
      # this.fetchDepositAddresses() OR this.fetchDepositAddressesByNetwork()
      unified_body = [return_await(super_call("fetchDepositAddress"))]

      fetch_addrs_body = [return_await(this_call("privateGetDepositAddresses"))]
      fetch_by_network_body = [return_await(this_call("privateGetDepositAddressByNetwork"))]

      ast =
        build_class_ast("kucoin", "Exchange", [
          method_with_body("fetchDepositAddress", unified_body),
          method_with_body("fetchDepositAddresses", fetch_addrs_body),
          method_with_body("fetchDepositAddressesByNetwork", fetch_by_network_body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "kucoin.ts")

      calls = result["unified_endpoints"]["fetchDepositAddress"]
      assert "privateGetDepositAddresses" in calls
      assert "privateGetDepositAddressByNetwork" in calls
    end

    test "mixed this.* and super.*() calls merge correctly" do
      # Method has both direct this.* interface calls and super.* delegation
      body = [
        return_await(this_call("privatePostDirectEndpoint")),
        return_await(super_call("createOrderWithTakeProfitAndStopLoss"))
      ]

      create_body = [return_await(this_call("privatePostCreateOrder"))]

      ast =
        build_class_ast("test", "Exchange", [
          method_with_body("createOrderWithTakeProfitAndStopLoss", body),
          method_with_body("createOrder", create_body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      calls = result["unified_endpoints"]["createOrderWithTakeProfitAndStopLoss"]
      assert "privatePostDirectEndpoint" in calls
      assert "privatePostCreateOrder" in calls
    end

    test "super call to unknown base method is gracefully ignored" do
      body = [return_await(super_call("fetchSomethingNew"))]

      ast =
        build_class_ast("test", "Exchange", [
          method_with_body("fetchSomethingNew", body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # No base method found → no transport calls → method omitted from output
      refute Map.has_key?(result["unified_endpoints"], "fetchSomethingNew")
    end

    test "super resolution works without base index loaded" do
      # Clear the base index to simulate missing Exchange.ts
      Process.delete(:base_method_index)

      body = [return_await(super_call("createOrderWithTakeProfitAndStopLoss"))]

      ast =
        build_class_ast("test", "Exchange", [
          method_with_body("createOrderWithTakeProfitAndStopLoss", body)
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      # Should not crash — just produces no endpoints for this method
      refute Map.has_key?(result["unified_endpoints"], "createOrderWithTakeProfitAndStopLoss")
    end

    test "parent_class is included in extraction output" do
      ast =
        build_class_ast("coincatch", "Exchange", [
          method_with_body("fetchTicker", [return_await(this_call("publicGetTicker"))])
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "coincatch.ts")

      assert result["parent_class"] == "Exchange"
    end

    test "parent_class is nil when no superClass" do
      ast =
        build_class_ast("test", [
          method_with_body("fetchTicker", [return_await(this_call("publicGetTicker"))])
        ])

      result = UnifiedEndpoints.extract_from_ast(ast, "test.ts")

      assert result["parent_class"] == nil
    end
  end

  describe "parse_file/1" do
    @tag :extraction
    test "parses bybit and finds expected unified endpoint mappings" do
      path = Path.join(CcxtExtract.Paths.ts_src(), "bybit.ts")

      if File.exists?(path) do
        assert {:ok, result} = UnifiedEndpoints.parse_file(path)
        assert result["id"] == "bybit"
        assert result["unified_endpoint_count"] > 0

        # bybit fetchTicker should call publicGetV5MarketTickers
        assert "publicGetV5MarketTickers" in result["unified_endpoints"]["fetchTicker"]

        # bybit fetchBalance should have multiple interface calls
        balance_calls = result["unified_endpoints"]["fetchBalance"]
        assert length(balance_calls) >= 2
      else
        flunk("CCXT source not found at #{path}. Run `mix ccxt_extract.setup` first.")
      end
    end

    @tag :extraction
    test "parses kucoin and resolves super.*() delegation for fetchDepositAddress" do
      path = Path.join(CcxtExtract.Paths.ts_src(), "kucoin.ts")

      if File.exists?(path) do
        assert {:ok, result} = UnifiedEndpoints.parse_file(path)
        assert result["id"] == "kucoin"
        assert result["parent_class"] == "Exchange"

        calls = result["unified_endpoints"]["fetchDepositAddress"] || []

        # The utaPrivate* endpoint is reached only via super.fetchDepositAddress
        # (kucoin uta branch) → base Exchange.fetchDepositAddress delegates via
        # this.fetchDepositAddressesByNetwork (polymorphic to child's impl)
        assert "utaPrivateGetAssetDepositAddress" in calls
      else
        flunk("CCXT source not found at #{path}. Run `mix ccxt_extract.setup` first.")
      end
    end
  end

  describe "extract/0" do
    @tag :extraction
    test "extracts unified endpoints from all exchange files" do
      {:ok, exchanges, stats} = UnifiedEndpoints.extract()

      assert exchanges != []
      assert stats.errors == []

      # All entries have required keys
      for exchange <- exchanges do
        assert is_binary(exchange["id"])
        assert is_binary(exchange["file"])
        assert is_integer(exchange["unified_endpoint_count"])
        assert is_map(exchange["unified_endpoints"])
      end

      # Most exchanges should have unified endpoints
      with_endpoints = Enum.count(exchanges, &(&1["unified_endpoint_count"] > 0))
      assert with_endpoints >= 80
    end

    @tag :extraction
    test "tier 1 exchanges all have fetchTicker and fetchBalance mappings" do
      {:ok, exchanges, _stats} = UnifiedEndpoints.extract()

      for id <- ~w(binance bybit okx) do
        exchange = Enum.find(exchanges, &(&1["id"] == id))
        assert exchange, "#{id} should exist in extracted exchanges"
        assert exchange["unified_endpoint_count"] > 0, "#{id} should have unified endpoints"

        assert Map.has_key?(exchange["unified_endpoints"], "fetchTicker"),
               "#{id} should have fetchTicker mapping"

        assert Map.has_key?(exchange["unified_endpoints"], "fetchBalance"),
               "#{id} should have fetchBalance mapping"
      end
    end

    @tag :extraction
    test "binance fetchBalance has multiple interface calls (market type branching)" do
      {:ok, exchanges, _stats} = UnifiedEndpoints.extract()

      binance = Enum.find(exchanges, &(&1["id"] == "binance"))
      assert binance, "binance should exist"

      balance_calls = binance["unified_endpoints"]["fetchBalance"]
      assert length(balance_calls) >= 3, "binance fetchBalance should branch to multiple endpoints"
    end
  end
end
