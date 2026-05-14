defmodule CcxtExtract.Normalization.ResponseEnvelopesTest do
  @moduledoc """
  Unit tests for `CcxtExtract.Normalization.ResponseEnvelopes`.

  Synthetic AST fixtures only — no file I/O. Corpus-level shape assertions
  live in `test/integration/cached/schema_v4_emit_cached_test.exs`.

  Design: N:1 fetcher→parser — multiple fetchers (fetchTrades, fetchMyTrades)
  can dispatch to the same parser type (trade), each with its own envelope key.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.Normalization.ResponseEnvelopes

  # ---------------------------------------------------------------------------
  # AST builder helpers
  # ---------------------------------------------------------------------------

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

  defp member_expression(object, property_name) do
    %{
      "type" => "MemberExpression",
      "object" => object,
      "property" => identifier(property_name)
    }
  end

  defp this_call(method, args) do
    %{
      "type" => "CallExpression",
      "callee" => member_expression(this_expression(), method),
      "arguments" => args
    }
  end

  defp var_decl(name, init) do
    %{
      "type" => "VariableDeclaration",
      "kind" => "const",
      "declarations" => [
        %{
          "type" => "VariableDeclarator",
          "id" => identifier(name),
          "init" => init
        }
      ]
    }
  end

  defp return_stmt(argument) do
    %{"type" => "ReturnStatement", "argument" => argument}
  end

  # `return this.parseTrades(data_var, market)` — the common pattern
  defp parse_return(parse_fn, first_arg_name) do
    return_stmt(this_call(parse_fn, [identifier(first_arg_name), identifier("market")]))
  end

  # `const data = this.safeList(response, "key", [])` binding
  defp safe_list_binding(var_name, key) do
    var_decl(
      var_name,
      this_call("safeList", [identifier("response"), literal(key), %{"type" => "ArrayExpression", "elements" => []}])
    )
  end

  defp parse_entry(parse_dispatch) do
    %{
      "id" => "testex",
      "parse_methods" => %{},
      "parse_dispatch" => parse_dispatch
    }
  end

  defp fetch_entry(method_name, body_stmts) do
    %{
      "id" => "testex",
      "fetch_methods" => %{
        method_name => %{
          "body" => %{"type" => "BlockStatement", "body" => body_stmts}
        }
      }
    }
  end

  defp multi_fetch_entry(methods_map) do
    entries =
      Map.new(methods_map, fn {name, stmts} ->
        {name, %{"body" => %{"type" => "BlockStatement", "body" => stmts}}}
      end)

    %{"id" => "testex", "fetch_methods" => entries}
  end

  # ---------------------------------------------------------------------------
  # Nil / absent-entry guards
  # ---------------------------------------------------------------------------

  describe "derive/2 — nil / missing entry guards" do
    test "returns nil when parse_methods_entry is nil" do
      assert ResponseEnvelopes.derive(nil, nil) == nil
      assert ResponseEnvelopes.derive(nil, %{}) == nil
    end

    test "returns nil when parse_methods_entry is not a map" do
      assert ResponseEnvelopes.derive("not_a_map", nil) == nil
      assert ResponseEnvelopes.derive(42, nil) == nil
      assert ResponseEnvelopes.derive([], nil) == nil
    end

    test "returns nil when parse_dispatch is absent" do
      entry = %{"id" => "testex", "parse_methods" => %{}}
      assert ResponseEnvelopes.derive(entry, nil) == nil
    end

    test "returns nil when parse_dispatch is empty" do
      entry = parse_entry(%{})
      assert ResponseEnvelopes.derive(entry, nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Top-level shape contract
  # ---------------------------------------------------------------------------

  describe "derive/2 — top-level shape contract" do
    test "returns a map with _unresolved_reason nil when parse_dispatch is non-empty" do
      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", [parse_return("parseTrades", "response")])
      result = ResponseEnvelopes.derive(parse, fetch)

      assert is_map(result)
      assert result["_unresolved_reason"] == nil
    end

    test "all nine parser-type keys are present even when most are nil" do
      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", [parse_return("parseTrades", "response")])
      result = ResponseEnvelopes.derive(parse, fetch)

      for type <- ~w(ticker trade ohlcv order position balance market transaction deposit_address) do
        assert Map.has_key?(result, type), "missing key: #{type}"
      end
    end

    test "parser types with no dispatching fetchers are nil" do
      # Only trade has a fetcher; everything else should be nil.
      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", [parse_return("parseTrades", "response")])
      result = ResponseEnvelopes.derive(parse, fetch)

      for type <- ~w(ticker ohlcv order position balance market transaction deposit_address) do
        assert result[type] == nil, "expected #{type} to be nil"
      end

      assert is_map(result["trade"])
    end
  end

  # ---------------------------------------------------------------------------
  # Direct-response pass-through (key: nil)
  # ---------------------------------------------------------------------------

  describe "derive/2 — direct response pass-through" do
    test "key is null when fetcher passes response directly to parseTrades" do
      # return this.parseTrades(response, market)
      stmts = [parse_return("parseTrades", "response")]
      parse = parse_entry(%{"fetchTrades" => ["parseTrade", "parseTrades"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchTrades"]["key"] == nil
      assert result["trade"]["fetchTrades"]["fallback_keys"] == []
      assert result["trade"]["fetchTrades"]["default"] == nil
    end

    test "key is null when fetcher passes response directly to parseTicker" do
      stmts = [parse_return("parseTicker", "response")]
      parse = parse_entry(%{"fetchTicker" => ["parseTicker"]})
      fetch = fetch_entry("fetchTicker", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["ticker"]["fetchTicker"]["key"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Envelope-key extraction (safeList / safeValue)
  # ---------------------------------------------------------------------------

  describe "derive/2 — safeList/safeValue envelope key extraction" do
    test "extracts key from safeList binding when var is passed to parseTrades" do
      # const data = this.safeList(response, "data", [])
      # return this.parseTrades(data, market)
      stmts = [
        safe_list_binding("data", "data"),
        parse_return("parseTrades", "data")
      ]

      parse = parse_entry(%{"fetchTrades" => ["parseTrade", "parseTrades"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      entry = result["trade"]["fetchTrades"]
      assert entry["key"] == "data"
      assert entry["fallback_keys"] == []
    end

    test "extracts key from safeValue binding" do
      stmts = [
        var_decl(
          "result",
          this_call("safeValue", [
            identifier("response"),
            literal("result"),
            %{"type" => "ObjectExpression", "properties" => []}
          ])
        ),
        parse_return("parseTrade", "result")
      ]

      parse = parse_entry(%{"fetchTrade" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrade", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      entry = result["trade"]["fetchTrade"]
      assert entry["key"] == "result"
    end

    test "extracts key with custom envelope key 'trades'" do
      stmts = [
        safe_list_binding("trades", "trades"),
        parse_return("parseTrades", "trades")
      ]

      parse = parse_entry(%{"fetchMyTrades" => ["parseTrade", "parseTrades"]})
      fetch = fetch_entry("fetchMyTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchMyTrades"]["key"] == "trades"
    end

    test "extracts fallback keys from safeValue2 call" do
      # safeValue2(response, "id", "orderId", nil)
      stmts = [
        var_decl(
          "orders",
          this_call("safeValue2", [
            identifier("response"),
            literal("id"),
            literal("orderId"),
            %{"type" => "Literal", "value" => nil}
          ])
        ),
        parse_return("parseOrders", "orders")
      ]

      parse = parse_entry(%{"fetchOrders" => ["parseOrder", "parseOrders"]})
      fetch = fetch_entry("fetchOrders", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      entry = result["order"]["fetchOrders"]
      assert entry["key"] == "id"
      assert entry["fallback_keys"] == ["orderId"]
    end

    test "extracts default literal (array) from safeList call" do
      stmts = [
        safe_list_binding("data", "rows"),
        parse_return("parseTrades", "data")
      ]

      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchTrades"]["key"] == "rows"
    end
  end

  # ---------------------------------------------------------------------------
  # Unresolved reasons
  # ---------------------------------------------------------------------------

  describe "derive/2 — unresolved reasons" do
    test "no_fetcher_method_body when fetcher name not in fetch_methods" do
      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      # fetch_entry has a DIFFERENT method name
      fetch = fetch_entry("fetchSomethingElse", [parse_return("parseTrades", "data")])
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchTrades"]["_unresolved_reason"] == "no_fetcher_method_body"
    end

    test "no_fetcher_method_body when fetch_methods_entry is nil" do
      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      result = ResponseEnvelopes.derive(parse, nil)

      assert result["trade"]["fetchTrades"]["_unresolved_reason"] == "no_fetcher_method_body"
    end

    test "no_safe_value_call when body has no safeList/safeValue against response and return var is unbound" do
      # The return binds a var that was never bound to safeList(response, ...).
      stmts = [
        var_decl(
          "data",
          this_call("safeList", [identifier("otherObj"), literal("key"), %{"type" => "ArrayExpression", "elements" => []}])
        ),
        parse_return("parseTrades", "data")
      ]

      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      # data is bound to safeList(otherObj, ...) not safeList(response, ...) — no response binding
      assert result["trade"]["fetchTrades"]["_unresolved_reason"] == "no_safe_value_call"
    end

    test "non_literal_key when safeList key is a variable identifier" do
      stmts = [
        var_decl(
          "data",
          this_call("safeList", [
            identifier("response"),
            identifier("keyVar"),
            %{"type" => "ArrayExpression", "elements" => []}
          ])
        ),
        parse_return("parseTrades", "data")
      ]

      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchTrades"]["_unresolved_reason"] == "non_literal_key"
    end

    test "nested_response_unwrap when safeList object is response[property]" do
      # this.safeList(response["nested"], "key", [])
      nested_obj = %{
        "type" => "MemberExpression",
        "object" => identifier("response"),
        "property" => identifier("nested"),
        "computed" => false
      }

      stmts = [
        var_decl(
          "data",
          this_call("safeList", [nested_obj, literal("rows"), %{"type" => "ArrayExpression", "elements" => []}])
        ),
        parse_return("parseTrades", "data")
      ]

      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchTrades"]["_unresolved_reason"] == "nested_response_unwrap"
    end

    test "_unresolved_reason at result root is nil even when individual fetchers are unresolved" do
      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      result = ResponseEnvelopes.derive(parse, nil)

      assert result["_unresolved_reason"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # N:1 fetcher→parser (multiple fetchers per parser type)
  # ---------------------------------------------------------------------------

  describe "derive/2 — N:1 fetcher to parser type" do
    test "multiple fetchers dispatching to same parser type each get their own entry" do
      parse =
        parse_entry(%{
          "fetchTrades" => ["parseTrade", "parseTrades"],
          "fetchMyTrades" => ["parseTrade", "parseTrades"],
          "fetchOrderTrades" => ["parseTrade"]
        })

      fetch =
        multi_fetch_entry(%{
          "fetchTrades" => [parse_return("parseTrades", "response")],
          "fetchMyTrades" => [
            safe_list_binding("trades", "trades"),
            parse_return("parseTrades", "trades")
          ],
          "fetchOrderTrades" => [
            safe_list_binding("data", "data"),
            parse_return("parseTrade", "data")
          ]
        })

      result = ResponseEnvelopes.derive(parse, fetch)
      trade = result["trade"]

      assert is_map(trade)
      assert map_size(trade) == 3

      assert trade["fetchTrades"]["key"] == nil
      assert trade["fetchMyTrades"]["key"] == "trades"
      assert trade["fetchOrderTrades"]["key"] == "data"
    end

    test "two parser types can be populated simultaneously from same parse_dispatch" do
      parse =
        parse_entry(%{
          "fetchTrades" => ["parseTrade"],
          "fetchTicker" => ["parseTicker"]
        })

      fetch =
        multi_fetch_entry(%{
          "fetchTrades" => [safe_list_binding("data", "data"), parse_return("parseTrades", "data")],
          "fetchTicker" => [parse_return("parseTicker", "response")]
        })

      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchTrades"]["key"] == "data"
      assert result["ticker"]["fetchTicker"]["key"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Fallback: first response binding when return var is unbound
  # ---------------------------------------------------------------------------

  describe "derive/2 — fallback to first response binding" do
    test "uses first safeList(response,...) binding when return var not found in bindings" do
      # The fetcher binds `interim = safeList(response, "items", [])` but returns
      # `this.parseTrades(someOtherVar, market)` — fallback to first binding.
      stmts = [
        safe_list_binding("interim", "items"),
        parse_return("parseTrades", "someOtherVar")
      ]

      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      # Falls back to the "interim" → "items" binding since someOtherVar is unbound.
      assert result["trade"]["fetchTrades"]["key"] == "items"
    end

    test "no_safe_value_call when body has NO response bindings at all and return var unbound" do
      # No safeList/safeValue against response anywhere.
      stmts = [
        var_decl("x", literal(42)),
        parse_return("parseTrades", "x")
      ]

      parse = parse_entry(%{"fetchTrades" => ["parseTrade"]})
      fetch = fetch_entry("fetchTrades", stmts)
      result = ResponseEnvelopes.derive(parse, fetch)

      assert result["trade"]["fetchTrades"]["_unresolved_reason"] == "no_safe_value_call"
    end
  end
end
