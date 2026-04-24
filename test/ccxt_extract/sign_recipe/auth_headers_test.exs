defmodule CcxtExtract.SignRecipe.AuthHeadersTest do
  @moduledoc """
  Unit tests for `CcxtExtract.SignRecipe.AuthHeaders` — the Task 67
  derivation that emits the ordered list of non-signature auth headers a
  consumer must attach.

  Uses synthetic AST fixtures; no file I/O. Corpus-level assertions live
  in `test/integration/cached/sign_recipe_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.SignRecipe.AuthHeaders

  # --- AST builder helpers ---

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

  defp unique_offset, do: System.unique_integer([:positive, :monotonic])

  defp this_call(method, args) do
    s = unique_offset()

    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => this_expression(),
        "property" => identifier(method)
      },
      "arguments" => args,
      "start" => s,
      "end" => s + 1_000_000
    }
  end

  defp method_call(receiver, method, args) do
    s = unique_offset()

    %{
      "type" => "CallExpression",
      "callee" => %{
        "type" => "MemberExpression",
        "object" => receiver,
        "property" => identifier(method)
      },
      "arguments" => args,
      "start" => s,
      "end" => s + 1_000_000
    }
  end

  defp this_member(property_name) do
    %{
      "type" => "MemberExpression",
      "object" => this_expression(),
      "property" => identifier(property_name)
    }
  end

  defp this_options_computed(key) do
    %{
      "type" => "MemberExpression",
      "computed" => true,
      "object" => this_member("options"),
      "property" => literal(key)
    }
  end

  defp this_options_dot(key) do
    %{
      "type" => "MemberExpression",
      "computed" => false,
      "object" => this_member("options"),
      "property" => identifier(key)
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

  defp assign_computed_header(key, rhs) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => %{
          "type" => "MemberExpression",
          "computed" => true,
          "object" => identifier("headers"),
          "property" => literal(key)
        },
        "right" => rhs
      }
    }
  end

  defp assign_static_header(key, rhs) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => %{
          "type" => "MemberExpression",
          "computed" => false,
          "object" => identifier("headers"),
          "property" => identifier(key)
        },
        "right" => rhs
      }
    }
  end

  defp object_expression(pairs) do
    props =
      Enum.map(pairs, fn {key, val} ->
        %{
          "type" => "Property",
          "key" => literal(key),
          "value" => val
        }
      end)

    %{"type" => "ObjectExpression", "properties" => props}
  end

  defp assign_headers_object(pairs) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => identifier("headers"),
        "right" => object_expression(pairs)
      }
    }
  end

  defp if_stmt(test, body_stmts) do
    %{
      "type" => "IfStatement",
      "test" => test,
      "consequent" => %{"type" => "BlockStatement", "body" => body_stmts},
      "alternate" => nil
    }
  end

  # --- Terminal-reason short-circuit ---

  describe "terminal unresolved_reason short-circuit" do
    test "ambiguous_ast returns nil without walking" do
      body = [assign_computed_header("X-API-KEY", this_member("apiKey"))]
      assert is_nil(AuthHeaders.derive(body, [], [], "ambiguous_ast"))
    end

    test "custom_signing_family returns nil" do
      body = [assign_computed_header("X-API-KEY", this_member("apiKey"))]
      assert is_nil(AuthHeaders.derive(body, [], [], "custom_signing_family"))
    end

    test "no_sign_method returns nil" do
      assert is_nil(AuthHeaders.derive([], [], [], "no_sign_method"))
    end
  end

  # --- Input-shape tolerance ---

  describe "non-list input" do
    test "nil body returns nil" do
      assert is_nil(AuthHeaders.derive(nil, [], [], "not_yet_derived"))
    end

    test "empty body returns empty list (no headers to attach)" do
      # Zero candidates classifies successfully as []. This is the
      # truthful answer for htx-style exchanges where all auth is in the
      # query string — the consumer has zero extra headers to attach.
      assert AuthHeaders.derive([], [], [], "not_yet_derived") == []
    end
  end

  # --- Individual source classifiers ---

  describe "source: api_key" do
    test "headers['X-MBX-APIKEY'] = this.apiKey" do
      body = [assign_computed_header("X-MBX-APIKEY", this_member("apiKey"))]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-MBX-APIKEY", "source" => "api_key"}
             ]
    end

    test "api_key via binding chain: `const k = this.apiKey; headers[K] = k;`" do
      body = [
        var_decl("k", this_member("apiKey")),
        assign_computed_header("X-API-KEY", identifier("k"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-API-KEY", "source" => "api_key"}
             ]
    end
  end

  describe "source: passphrase" do
    test "headers['OK-ACCESS-PASSPHRASE'] = this.password" do
      body = [assign_computed_header("OK-ACCESS-PASSPHRASE", this_member("password"))]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "OK-ACCESS-PASSPHRASE", "source" => "passphrase"}
             ]
    end

    test "passphrase via binding chain: `const pp = this.password; headers[K] = pp;`" do
      # Some exchanges rebind this.password into a local variable (often
      # because the raw value is normalized or trimmed). One-hop resolution
      # through the bindings map recognizes the indirection.
      body = [
        var_decl("pp", this_member("password")),
        assign_computed_header("OK-ACCESS-PASSPHRASE", identifier("pp"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "OK-ACCESS-PASSPHRASE", "source" => "passphrase"}
             ]
    end
  end

  describe "source: timestamp" do
    test "identifier bound to this.milliseconds() tagged timestamp" do
      body = [
        var_decl("timestamp", this_call("milliseconds", [])),
        assign_computed_header("X-BAPI-TIMESTAMP", identifier("timestamp"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-BAPI-TIMESTAMP", "source" => "timestamp"}
             ]
    end

    test "timestamp.toString() wrapper still resolves to timestamp" do
      body = [
        var_decl("timestamp", this_call("milliseconds", [])),
        assign_computed_header("X-SOMETHING-TIMESTAMP", method_call(identifier("timestamp"), "toString", []))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-SOMETHING-TIMESTAMP", "source" => "timestamp"}
             ]
    end

    test "identifier whose binding init isn't a timestamp → not tagged timestamp (aborts)" do
      # The identifier name `timestamp` matches Nonce's whitelist, BUT its
      # init (`something_opaque`) doesn't classify — so it's not a recognized
      # timestamp binding. The header value `timestamp` falls through every
      # other classifier (not a Literal, not `this.apiKey` etc) → abort.
      body = [
        var_decl("timestamp", identifier("something_opaque")),
        assign_computed_header("X-TIMESTAMP", identifier("timestamp"))
      ]

      assert is_nil(AuthHeaders.derive(body, [], [], "not_yet_derived"))
    end

    test "coinbaseexchange pattern: binding named `nonce` acts as timestamp" do
      body = [
        var_decl("nonce", this_call("seconds", [])),
        assign_computed_header("CB-ACCESS-TIMESTAMP", identifier("nonce"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "CB-ACCESS-TIMESTAMP", "source" => "timestamp"}
             ]
    end
  end

  describe "source: recv_window" do
    test "this.safeInteger(this.options, 'recvWindow')" do
      rhs =
        this_call("safeInteger", [
          this_member("options"),
          literal("recvWindow")
        ])

      body = [assign_computed_header("X-BAPI-RECV-WINDOW", rhs)]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-BAPI-RECV-WINDOW", "source" => "recv_window"}
             ]
    end

    test "this.options['recvWindow']" do
      body = [assign_computed_header("X-BAPI-RECV-WINDOW", this_options_computed("recvWindow"))]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-BAPI-RECV-WINDOW", "source" => "recv_window"}
             ]
    end

    test "this.options.recvWindow" do
      body = [assign_computed_header("X-BAPI-RECV-WINDOW", this_options_dot("recvWindow"))]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-BAPI-RECV-WINDOW", "source" => "recv_window"}
             ]
    end

    test "this.options['recvWindow'].toString() — bybit actual pattern" do
      rhs = method_call(this_options_computed("recvWindow"), "toString", [])
      body = [assign_computed_header("X-BAPI-RECV-WINDOW", rhs)]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-BAPI-RECV-WINDOW", "source" => "recv_window"}
             ]
    end

    test "recv_window via binding chain: `const rw = this.options['recvWindow']; headers[K] = rw;`" do
      body = [
        var_decl("rw", this_options_computed("recvWindow")),
        assign_computed_header("X-BAPI-RECV-WINDOW", identifier("rw"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-BAPI-RECV-WINDOW", "source" => "recv_window"}
             ]
    end
  end

  describe "source: literal" do
    test "literal string value emits literal + value" do
      body = [assign_computed_header("KC-API-KEY-VERSION", literal("2"))]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "KC-API-KEY-VERSION", "source" => "literal", "value" => "2"}
             ]
    end

    test "bybit X-BAPI-SIGN-TYPE literal" do
      body = [assign_computed_header("X-BAPI-SIGN-TYPE", literal("2"))]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-BAPI-SIGN-TYPE", "source" => "literal", "value" => "2"}
             ]
    end
  end

  # --- Signature-exclusion ---

  describe "signature header is excluded" do
    test "RHS that is the signature identifier is dropped" do
      body = [
        assign_computed_header("OK-ACCESS-KEY", this_member("apiKey")),
        assign_computed_header("OK-ACCESS-SIGN", identifier("signature"))
      ]

      result = AuthHeaders.derive(body, ["signature"], [], "not_yet_derived")
      assert result == [%{"name" => "OK-ACCESS-KEY", "source" => "api_key"}]
    end

    test "RHS containing signature in a + chain is dropped (deribit-style compound)" do
      # Authorization: 'deri-hmac-sha256 id=' + apiKey + ',sig=' + signature
      compound = %{
        "type" => "BinaryExpression",
        "operator" => "+",
        "left" => literal("deri-hmac-sha256 sig="),
        "right" => identifier("signature")
      }

      body = [assign_computed_header("Authorization", compound)]

      result = AuthHeaders.derive(body, ["signature"], [], "not_yet_derived")
      assert result == []
    end
  end

  # --- Filtering of well-known non-auth headers ---

  describe "non-auth headers filtered" do
    test "Content-Type literal in ObjectExpression is filtered" do
      body = [
        assign_headers_object([
          {"X-MBX-APIKEY", this_member("apiKey")},
          {"Content-Type", literal("application/json")}
        ])
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-MBX-APIKEY", "source" => "api_key"}
             ]
    end

    test "Accept header is filtered" do
      body = [
        assign_headers_object([
          {"X-API-KEY", this_member("apiKey")},
          {"Accept", literal("application/json")}
        ])
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-API-KEY", "source" => "api_key"}
             ]
    end

    test "User-Agent computed assignment is filtered" do
      body = [
        assign_computed_header("X-API-KEY", this_member("apiKey")),
        assign_computed_header("User-Agent", literal("ccxt/1.0"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-API-KEY", "source" => "api_key"}
             ]
    end
  end

  # --- Optional-features IfStatement skip ---

  describe "this.options[X] conditional blocks skipped" do
    test "kucoin partner block not classified" do
      # Outer: baseline headers. Inner (inside `if (this.options['partner'])`):
      # KC-API-PARTNER headers that use unrecognized `this.safeString(...)`
      # RHS. If we descended, the baseline derivation would abort. Skipping
      # the if-block keeps the baseline clean.
      partner_inside = [
        assign_computed_header("KC-API-PARTNER", this_call("safeString", [this_member("options"), literal("partner")]))
      ]

      body = [
        assign_headers_object([
          {"KC-API-KEY", this_member("apiKey")},
          {"KC-API-KEY-VERSION", literal("2")}
        ]),
        if_stmt(this_options_computed("partner"), partner_inside)
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "KC-API-KEY", "source" => "api_key"},
               %{"name" => "KC-API-KEY-VERSION", "source" => "literal", "value" => "2"}
             ]
    end

    test "non-options IfStatement is descended normally" do
      # `if (api === 'private') { headers = {...}; }` — baseline case
      # wrapped in an api-dispatch guard. MUST descend.
      method_eq = %{
        "type" => "BinaryExpression",
        "operator" => "===",
        "left" => identifier("api"),
        "right" => literal("private")
      }

      body = [
        if_stmt(method_eq, [
          assign_headers_object([
            {"X-API-KEY", this_member("apiKey")}
          ])
        ])
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-API-KEY", "source" => "api_key"}
             ]
    end
  end

  # --- Partial-classification policy ---

  describe "unclassified header aborts list" do
    test "opaque RHS on one header → nil overall" do
      body = [
        assign_computed_header("X-API-KEY", this_member("apiKey")),
        assign_computed_header("X-MYSTERY", identifier("some_unrecognized_thing"))
      ]

      assert is_nil(AuthHeaders.derive(body, [], [], "not_yet_derived"))
    end
  end

  # --- ObjectExpression shape (OKX / Coinbase Exchange pattern) ---

  describe "headers = { K: V, ... } assignment shape" do
    test "OKX-style full object assignment emits sources in order" do
      body = [
        var_decl("timestamp", this_call("iso8601", [this_call("milliseconds", [])])),
        assign_headers_object([
          {"OK-ACCESS-KEY", this_member("apiKey")},
          {"OK-ACCESS-SIGN", identifier("signature")},
          {"OK-ACCESS-TIMESTAMP", identifier("timestamp")},
          {"OK-ACCESS-PASSPHRASE", this_member("password")},
          {"Content-Type", literal("application/json")}
        ])
      ]

      result = AuthHeaders.derive(body, ["signature"], [], "not_yet_derived")

      assert result == [
               %{"name" => "OK-ACCESS-KEY", "source" => "api_key"},
               %{"name" => "OK-ACCESS-TIMESTAMP", "source" => "timestamp"},
               %{"name" => "OK-ACCESS-PASSPHRASE", "source" => "passphrase"}
             ]
    end
  end

  describe "const headers = { K: V, ... } VariableDeclarator shape" do
    test "recognized as a candidate source" do
      body = [
        var_decl("headers", object_expression([{"X-API-KEY", this_member("apiKey")}]))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-API-KEY", "source" => "api_key"}
             ]
    end
  end

  # --- Static member assignment (headers.K = RHS) ---

  describe "headers.K = RHS (static member) assignment shape" do
    test "recognized alongside computed form" do
      body = [
        assign_static_header("Authorization", this_member("apiKey"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "Authorization", "source" => "api_key"}
             ]
    end
  end

  # --- Deduplication ---

  describe "duplicate header assignments collapse" do
    test "same {name, source} listed twice emits once" do
      # An exchange might set `headers['X-KEY'] = this.apiKey` inside both
      # branches of an if/else. Both surface as candidates, classify the
      # same, and dedupe.
      body = [
        assign_computed_header("X-API-KEY", this_member("apiKey")),
        assign_computed_header("X-API-KEY", this_member("apiKey"))
      ]

      assert AuthHeaders.derive(body, [], [], "not_yet_derived") == [
               %{"name" => "X-API-KEY", "source" => "api_key"}
             ]
    end
  end
end
