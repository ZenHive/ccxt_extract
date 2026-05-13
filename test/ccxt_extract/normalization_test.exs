defmodule CcxtExtract.NormalizationTest do
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization

  @sample_method_ast %{
    "async" => false,
    "params" => [
      %{"name" => "trade", "type" => "Dict"},
      %{"name" => "market", "type" => "Market"}
    ],
    "return_type" => "Trade",
    "statements" => 19,
    "body" => %{
      "type" => "BlockStatement",
      "start" => 100,
      "end" => 500,
      "body" => [%{"type" => "ReturnStatement", "argument" => nil}]
    }
  }

  @sample_entry %{
    "id" => "binance",
    "class_name" => "binance",
    "file" => "ts/src/binance.ts",
    "parse_method_count" => 2,
    "parse_methods" => %{
      "parseTrade" => @sample_method_ast,
      "parseTicker" => %{
        "async" => true,
        "params" => [%{"name" => "ticker", "type" => "Dict"}],
        "return_type" => nil,
        "statements" => 5,
        "body" => %{"type" => "BlockStatement", "body" => []}
      }
    }
  }

  describe "build/2 — parse_methods_digest" do
    test "projects every parse_method into a compact digest record" do
      result = Normalization.build(@sample_entry)

      digest = result["parse_methods_digest"]
      assert digest |> Map.keys() |> Enum.sort() == ["parseTicker", "parseTrade"]

      trade = digest["parseTrade"]

      assert trade["params"] == [
               %{"name" => "trade", "type" => "Dict"},
               %{"name" => "market", "type" => "Market"}
             ]

      assert trade["return_type"] == "Trade"
      assert trade["async"] == false
      assert trade["statement_count"] == 19
      refute Map.has_key?(trade, "body"), "digest must NOT include AST body (Hex 128MB cap)"

      ticker = digest["parseTicker"]
      assert ticker["async"] == true
      assert ticker["return_type"] == nil
      assert ticker["statement_count"] == 5
    end

    test "empty digest when entry is nil (alias exchange / no own parse_methods)" do
      assert Normalization.build(nil)["parse_methods_digest"] == %{}
    end

    test "empty digest when entry has empty parse_methods" do
      entry = %{"id" => "x", "parse_methods" => %{}}
      assert Normalization.build(entry)["parse_methods_digest"] == %{}
    end

    test "empty digest when parse_methods key missing" do
      entry = %{"id" => "x"}
      assert Normalization.build(entry)["parse_methods_digest"] == %{}
    end

    test "missing fields default to safe values" do
      entry = %{
        "id" => "skinny",
        "parse_methods" => %{
          "parseFoo" => %{"body" => %{"type" => "BlockStatement", "body" => []}}
        }
      }

      foo = Normalization.build(entry)["parse_methods_digest"]["parseFoo"]
      assert foo["params"] == []
      assert foo["return_type"] == nil
      assert foo["async"] == false
      assert foo["statement_count"] == 0
    end

    test "non-map entry returns empty digest" do
      assert Normalization.build("not a map")["parse_methods_digest"] == %{}
      assert Normalization.build(42)["parse_methods_digest"] == %{}
    end
  end

  describe "build/2 — field_maps and response_envelopes scaffolds" do
    test "field_maps carries every parser type plus _unresolved_reason" do
      result = Normalization.build(nil)
      field_maps = result["field_maps"]

      for type <- Normalization.parser_types() do
        assert Map.fetch!(field_maps, type) == nil,
               "field_maps.#{type} should be null in the Task 129 scaffold"
      end

      assert field_maps["_unresolved_reason"] == "not_yet_derived"
    end

    test "response_envelopes carries the same shape as field_maps" do
      result = Normalization.build(nil)

      assert result["response_envelopes"] |> Map.keys() |> Enum.sort() ==
               result["field_maps"] |> Map.keys() |> Enum.sort()

      for type <- Normalization.parser_types() do
        assert result["response_envelopes"][type] == nil
      end

      assert result["response_envelopes"]["_unresolved_reason"] == "not_yet_derived"
    end

    test "stub_record/0 returns the canonical scaffold shape" do
      stub = Normalization.stub_record()

      expected_keys = Enum.sort(Normalization.parser_types() ++ ["_unresolved_reason"])
      assert stub |> Map.keys() |> Enum.sort() == expected_keys
      assert stub["_unresolved_reason"] == "not_yet_derived"
    end

    test "Task 78: ohlcv slot populates when a parseOHLCV entry is supplied" do
      # Synthetic minimal parseOHLCV: timestamp + 5 OHLC slots, no volume —
      # exercises the wiring without depending on the real corpus. Validates
      # that build/2 routes the entry into OHLCV.derive while leaving the
      # other 8 parser-type slots null and the carrier reason unchanged.
      ohlcv_ast = %{
        "async" => false,
        "params" => [],
        "return_type" => nil,
        "statements" => 1,
        "body" => %{
          "type" => "BlockStatement",
          "body" => [
            %{
              "type" => "ReturnStatement",
              "argument" => %{
                "type" => "ArrayExpression",
                "elements" =>
                  Enum.map(0..4, fn idx ->
                    method = if idx == 0, do: "safeInteger", else: "safeNumber"

                    %{
                      "type" => "CallExpression",
                      "callee" => %{
                        "type" => "MemberExpression",
                        "object" => %{"type" => "ThisExpression"},
                        "property" => %{"type" => "Identifier", "name" => method}
                      },
                      "arguments" => [
                        %{"type" => "Identifier", "name" => "ohlcv"},
                        %{"type" => "Literal", "value" => idx}
                      ]
                    }
                  end)
              }
            }
          ]
        }
      }

      entry = %{"parse_methods" => %{"parseOHLCV" => ohlcv_ast}}
      result = Normalization.build(entry)
      field_maps = result["field_maps"]

      assert is_map(field_maps["ohlcv"]), "Task 78: ohlcv slot populates"
      assert [branch] = field_maps["ohlcv"]["branches"]
      assert branch["guard"]["kind"] == "always"
      assert branch["field_map"]["timestamp"]["coercion"] == "safeInteger"

      # Other 8 parser-type slots stay nil
      for type <- Normalization.parser_types() -- ["ohlcv"] do
        assert field_maps[type] == nil, "non-ohlcv slot #{type} should still be nil"
      end

      # Carrier-level reason stays "not_yet_derived" until all 9 types populate
      assert field_maps["_unresolved_reason"] == "not_yet_derived"
    end

    test "Task 74: ticker slot populates when a parseTicker entry is supplied" do
      # Synthetic minimal parseTicker: timestamp from a binding + one inline
      # price field. Validates wiring into field_maps_record/1 without
      # depending on the real corpus.
      identifier = fn name -> %{"type" => "Identifier", "name" => name} end
      literal = fn v -> %{"type" => "Literal", "value" => v} end

      this_call = fn method, args ->
        %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => method}
          },
          "arguments" => args
        }
      end

      var_decl = fn name, init ->
        %{
          "type" => "VariableDeclaration",
          "kind" => "const",
          "declarations" => [
            %{"type" => "VariableDeclarator", "id" => identifier.(name), "init" => init}
          ]
        }
      end

      timestamp_binding =
        var_decl.("timestamp", this_call.("safeInteger", [identifier.("ticker"), literal.("time")]))

      safe_ticker_ret = %{
        "type" => "ReturnStatement",
        "argument" =>
          this_call.("safeTicker", [
            %{
              "type" => "ObjectExpression",
              "properties" => [
                %{"key" => identifier.("timestamp"), "value" => identifier.("timestamp")},
                %{
                  "key" => identifier.("high"),
                  "value" => this_call.("safeString", [identifier.("ticker"), literal.("highPrice")])
                }
              ]
            },
            identifier.("market")
          ])
      }

      entry = %{
        "parse_methods" => %{
          "parseTicker" => %{
            "body" => %{"type" => "BlockStatement", "body" => [timestamp_binding, safe_ticker_ret]}
          }
        }
      }

      result = Normalization.build(entry)
      field_maps = result["field_maps"]

      assert is_map(field_maps["ticker"]), "ticker slot must populate"
      assert field_maps["ticker"]["field_map"]["timestamp"]["coercion"] == "safeInteger"
      assert field_maps["ticker"]["field_map"]["timestamp"]["format"] == "ms"
      assert field_maps["ticker"]["field_map"]["high"]["key"] == "highPrice"

      # Other parser-type slots (excluding ohlcv which stays nil with no parseOHLCV) stay nil
      for type <- Normalization.parser_types() -- ["ticker", "ohlcv"] do
        assert field_maps[type] == nil, "non-ticker slot #{type} should still be nil"
      end

      assert field_maps["_unresolved_reason"] == "not_yet_derived"
    end

    test "Task 76: trade slot populates when a parseTrade entry is supplied" do
      # Synthetic minimal parseTrade: identifier-binding-resolved scalar + inline
      # safeString-on-id, exercising the full Trade.derive wiring path through
      # field_maps_record/1.
      identifier = fn name -> %{"type" => "Identifier", "name" => name} end
      literal = fn v -> %{"type" => "Literal", "value" => v} end

      this_call = fn method, args ->
        %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => method}
          },
          "arguments" => args
        }
      end

      var_decl = fn name, init ->
        %{
          "type" => "VariableDeclaration",
          "kind" => "const",
          "declarations" => [
            %{"type" => "VariableDeclarator", "id" => identifier.(name), "init" => init}
          ]
        }
      end

      timestamp_binding =
        var_decl.("timestamp", this_call.("safeInteger", [identifier.("trade"), literal.("ts")]))

      safe_trade_ret = %{
        "type" => "ReturnStatement",
        "argument" =>
          this_call.("safeTrade", [
            %{
              "type" => "ObjectExpression",
              "properties" => [
                %{"key" => identifier.("timestamp"), "value" => identifier.("timestamp")},
                %{
                  "key" => identifier.("id"),
                  "value" => this_call.("safeString", [identifier.("trade"), literal.("tradeId")])
                },
                %{
                  "key" => identifier.("side"),
                  "value" => this_call.("safeStringLower", [identifier.("trade"), literal.("side")])
                }
              ]
            },
            identifier.("market")
          ])
      }

      # Pair the parseTrade entry with a stub parseTicker so the wiring test
      # also confirms the two slots populate INDEPENDENTLY (Task 76 doesn't
      # regress Task 74's ticker derivation).
      ticker_ret = %{
        "type" => "ReturnStatement",
        "argument" =>
          this_call.("safeTicker", [
            %{
              "type" => "ObjectExpression",
              "properties" => [
                %{
                  "key" => identifier.("high"),
                  "value" => this_call.("safeString", [identifier.("ticker"), literal.("highPrice")])
                }
              ]
            },
            identifier.("market")
          ])
      }

      entry = %{
        "parse_methods" => %{
          "parseTrade" => %{
            "body" => %{"type" => "BlockStatement", "body" => [timestamp_binding, safe_trade_ret]}
          },
          "parseTicker" => %{
            "body" => %{"type" => "BlockStatement", "body" => [ticker_ret]}
          }
        }
      }

      result = Normalization.build(entry)
      field_maps = result["field_maps"]

      assert is_map(field_maps["trade"]), "trade slot must populate"
      assert field_maps["trade"]["_unresolved_reason"] == nil
      assert field_maps["trade"]["field_map"]["timestamp"]["coercion"] == "safeInteger"
      assert field_maps["trade"]["field_map"]["timestamp"]["format"] == "ms"
      assert field_maps["trade"]["field_map"]["id"]["key"] == "tradeId"
      assert field_maps["trade"]["field_map"]["side"]["coercion"] == "safeStringLower"

      # ticker independently populates (Task 74 wiring unbroken)
      assert is_map(field_maps["ticker"]), "ticker slot must also populate independently"
      assert field_maps["ticker"]["field_map"]["high"]["key"] == "highPrice"

      # Other parser-type slots stay nil
      for type <- Normalization.parser_types() -- ["trade", "ticker", "ohlcv"] do
        assert field_maps[type] == nil, "non-trade/ticker slot #{type} should still be nil"
      end

      assert field_maps["_unresolved_reason"] == "not_yet_derived"
    end

    test "Task 75: order slot populates when a parseOrder entry is supplied" do
      identifier = fn name -> %{"type" => "Identifier", "name" => name} end
      literal = fn v -> %{"type" => "Literal", "value" => v} end

      this_call = fn method, args ->
        %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => method}
          },
          "arguments" => args
        }
      end

      safe_order_ret = %{
        "type" => "ReturnStatement",
        "argument" =>
          this_call.("safeOrder", [
            %{
              "type" => "ObjectExpression",
              "properties" => [
                %{
                  "key" => identifier.("id"),
                  "value" => this_call.("safeString", [identifier.("order"), literal.("orderId")])
                },
                %{
                  "key" => identifier.("timestamp"),
                  "value" => this_call.("safeInteger", [identifier.("order"), literal.("ts")])
                },
                %{
                  "key" => identifier.("side"),
                  "value" => this_call.("safeStringLower", [identifier.("order"), literal.("side")])
                }
              ]
            },
            identifier.("market")
          ])
      }

      entry = %{
        "parse_methods" => %{
          "parseOrder" => %{
            "body" => %{"type" => "BlockStatement", "body" => [safe_order_ret]}
          }
        }
      }

      result = Normalization.build(entry)
      field_maps = result["field_maps"]

      assert is_map(field_maps["order"]), "order slot must populate"
      assert field_maps["order"]["_unresolved_reason"] == nil
      assert field_maps["order"]["field_map"]["id"]["key"] == "orderId"
      assert field_maps["order"]["field_map"]["timestamp"]["coercion"] == "safeInteger"
      assert field_maps["order"]["field_map"]["timestamp"]["format"] == "ms"
      assert field_maps["order"]["field_map"]["side"]["coercion"] == "safeStringLower"

      # Other parser-type slots stay nil
      for type <- Normalization.parser_types() -- ["order", "ohlcv"] do
        assert field_maps[type] == nil, "non-order slot #{type} should still be nil"
      end

      assert field_maps["_unresolved_reason"] == "not_yet_derived"
    end

    test "Task 80: position slot populates when a parsePosition entry is supplied" do
      identifier = fn name -> %{"type" => "Identifier", "name" => name} end
      literal = fn v -> %{"type" => "Literal", "value" => v} end

      this_call = fn method, args ->
        %{
          "type" => "CallExpression",
          "callee" => %{
            "type" => "MemberExpression",
            "object" => %{"type" => "ThisExpression"},
            "property" => %{"type" => "Identifier", "name" => method}
          },
          "arguments" => args
        }
      end

      safe_position_ret = %{
        "type" => "ReturnStatement",
        "argument" =>
          this_call.("safePosition", [
            %{
              "type" => "ObjectExpression",
              "properties" => [
                %{
                  "key" => identifier.("id"),
                  "value" => this_call.("safeString", [identifier.("pos"), literal.("posId")])
                },
                %{
                  "key" => identifier.("entryPrice"),
                  "value" => this_call.("safeNumber", [identifier.("pos"), literal.("entryPrice")])
                },
                %{
                  "key" => identifier.("side"),
                  "value" => this_call.("safeString", [identifier.("pos"), literal.("side")])
                }
              ]
            },
            identifier.("market")
          ])
      }

      entry = %{
        "parse_methods" => %{
          "parsePosition" => %{
            "body" => %{"type" => "BlockStatement", "body" => [safe_position_ret]}
          }
        }
      }

      result = Normalization.build(entry)
      field_maps = result["field_maps"]

      assert is_map(field_maps["position"]), "position slot must populate"
      assert field_maps["position"]["_unresolved_reason"] == nil
      assert field_maps["position"]["field_map"]["id"]["key"] == "posId"
      assert field_maps["position"]["field_map"]["entryPrice"]["key"] == "entryPrice"
      assert field_maps["position"]["field_map"]["side"]["coercion"] == "safeString"
      assert field_maps["position"]["field_map"]["side"]["enum_map"] == nil

      # Other parser-type slots stay nil
      for type <- Normalization.parser_types() -- ["position", "ohlcv"] do
        assert field_maps[type] == nil, "non-position slot #{type} should still be nil"
      end

      assert field_maps["_unresolved_reason"] == "not_yet_derived"
    end
  end

  describe "build/2 — round-trip + shape" do
    test "every output has the three required top-level keys" do
      for entry <- [nil, %{}, @sample_entry, %{"parse_methods" => %{}}] do
        result = Normalization.build(entry)

        assert result |> Map.keys() |> Enum.sort() == Enum.sort(Normalization.required_keys())
      end
    end

    test "every digest record has the four required fields, in valid types" do
      result = Normalization.build(@sample_entry)

      for {_name, record} <- result["parse_methods_digest"] do
        assert record |> Map.keys() |> Enum.sort() == Enum.sort(Normalization.digest_record_keys())
        assert is_list(record["params"])
        assert record["return_type"] == nil or is_binary(record["return_type"])
        assert is_boolean(record["async"])
        assert is_integer(record["statement_count"]) and record["statement_count"] >= 0
      end
    end

    test "round-trip: digest preserves method-name set from the inventory" do
      inventory = @sample_entry["parse_methods"] |> Map.keys() |> Enum.sort()
      digest_keys = Normalization.build(@sample_entry)["parse_methods_digest"] |> Map.keys() |> Enum.sort()

      assert inventory == digest_keys
    end

    test "stub_record_keys/0 includes every parser_type and _unresolved_reason" do
      assert Enum.sort(Normalization.stub_record_keys()) ==
               Enum.sort(Normalization.parser_types() ++ ["_unresolved_reason"])
    end
  end

  describe "non-conforming param shapes (defensive)" do
    test "missing param name defaults to empty string with nil type" do
      entry = %{
        "parse_methods" => %{
          "parseFoo" => %{"params" => [%{"type" => "Dict"}], "statements" => 1}
        }
      }

      foo = Normalization.build(entry)["parse_methods_digest"]["parseFoo"]
      assert foo["params"] == [%{"name" => "", "type" => nil}]
    end

    test "non-list params resolves to []" do
      entry = %{
        "parse_methods" => %{
          "parseFoo" => %{"params" => "weird", "statements" => 1}
        }
      }

      assert Normalization.build(entry)["parse_methods_digest"]["parseFoo"]["params"] == []
    end

    test "negative or non-integer statements coerced to 0" do
      entry = %{
        "parse_methods" => %{
          "parseA" => %{"statements" => -1},
          "parseB" => %{"statements" => "twelve"}
        }
      }

      digest = Normalization.build(entry)["parse_methods_digest"]
      assert digest["parseA"]["statement_count"] == 0
      assert digest["parseB"]["statement_count"] == 0
    end

    test "non-map MethodAST falls back to a safe-defaults record" do
      # Defensive: if a discovery file has a non-map under a parse_method
      # key (corrupt fixture), the digest still emits one record per key
      # rather than blowing up the whole pipeline.
      entry = %{"parse_methods" => %{"parseFoo" => "garbage"}}

      assert Normalization.build(entry)["parse_methods_digest"]["parseFoo"] ==
               %{"params" => [], "return_type" => nil, "async" => false, "statement_count" => 0}
    end
  end
end
