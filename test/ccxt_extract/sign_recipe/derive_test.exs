defmodule CcxtExtract.SignRecipe.DeriveTest do
  @moduledoc """
  Unit tests for `CcxtExtract.SignRecipe.Derive` — the Task 65 derivation
  that populates `crypto_op` and `signature_placement` from the sign()
  AST.

  Uses synthetic AST fixtures; no file I/O. Corpus-level assertions live
  in `test/integration/cached/sign_recipe_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.SignRecipe
  alias CcxtExtract.SignRecipe.Derive

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

  defp bare_call(fn_name, args) do
    s = unique_offset()

    %{
      "type" => "CallExpression",
      "callee" => identifier(fn_name),
      "arguments" => args,
      "start" => s,
      "end" => s + 1_000_000
    }
  end

  defp hmac_call(algo_ident_name) do
    this_call("hmac", [
      this_call("encode", [identifier("query")]),
      this_call("encode", [identifier("secret")]),
      identifier(algo_ident_name)
    ])
  end

  defp var(name, init) do
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

  defp assign_header(key, value_node) do
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
        "right" => value_node
      }
    }
  end

  defp assign_query_plus(key_prefix, sig_ident) do
    # query += '&KEY=' + signature
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "+=",
        "left" => identifier("query"),
        "right" => %{
          "type" => "BinaryExpression",
          "operator" => "+",
          "left" => literal(key_prefix),
          "right" => sig_ident
        }
      }
    }
  end

  defp assign_body_json(sig_key, sig_ident) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => identifier("body"),
        "right" =>
          this_call("json", [
            %{
              "type" => "ObjectExpression",
              "properties" => [
                %{
                  "type" => "Property",
                  "key" => literal(sig_key),
                  "value" => sig_ident
                }
              ]
            }
          ])
      }
    }
  end

  defp method_ast(statements) do
    %{
      "async" => false,
      "params" => [],
      "return_type" => nil,
      "statements" => length(statements),
      "body" => %{"type" => "BlockStatement", "body" => statements}
    }
  end

  # --- Null / empty input ---

  describe "derive/2 — null inputs" do
    test "returns %{} when auth_sections is nil" do
      assert Derive.derive(method_ast([]), nil) == %{}
    end

    test "returns %{} when auth_sections is []" do
      assert Derive.derive(method_ast([]), []) == %{}
    end

    test "returns no_sign_method record for each section when sign_method is nil" do
      result = Derive.derive(nil, ["private"])

      assert %{"private" => record} = result
      assert record["crypto_op"] == nil
      assert record["signature_placement"] == nil
      assert record["unresolved_reason"] == "no_sign_method"
    end

    test "returns no_sign_method record when sign_method has unparseable shape" do
      result = Derive.derive(%{"body" => "not a block"}, ["private"])

      assert %{"private" => record} = result
      assert record["unresolved_reason"] == "no_sign_method"
    end
  end

  # --- HMAC families ---

  describe "derive/2 — HMAC crypto ops" do
    test "detects hmac_sha256 via this.hmac(_, _, sha256)" do
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature"))
        ])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"] == %{"algo" => "hmac_sha256"}
    end

    test "detects hmac_sha512" do
      ast =
        method_ast([
          var("sig", hmac_call("sha512")),
          assign_header("X-SIGN", identifier("sig"))
        ])

      assert %{"private" => %{"crypto_op" => %{"algo" => "hmac_sha512"}}} =
               Derive.derive(ast, ["private"])
    end

    test "detects hmac_sha384" do
      ast =
        method_ast([
          var("sig", hmac_call("sha384")),
          assign_header("X-SIGN", identifier("sig"))
        ])

      assert %{"private" => %{"crypto_op" => %{"algo" => "hmac_sha384"}}} =
               Derive.derive(ast, ["private"])
    end

    test "unknown hmac algorithm identifier leaves crypto_op nil with custom_signing_family" do
      ast = method_ast([var("sig", hmac_call("md5"))])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"] == nil
      # md5 doesn't match any known algo ident — treated as no crypto call
      assert record["unresolved_reason"] == "custom_signing_family"
    end
  end

  # --- Ed25519 / RSA / JWT ---

  describe "derive/2 — non-HMAC crypto ops" do
    test "detects ed25519 via bare eddsa(...) call" do
      ast =
        method_ast([
          var("sig", bare_call("eddsa", [identifier("q"), identifier("s"), identifier("ed25519")])),
          assign_header("X-SIGN", identifier("sig"))
        ])

      assert %{"private" => %{"crypto_op" => %{"algo" => "ed25519"}}} =
               Derive.derive(ast, ["private"])
    end

    test "detects rsa via bare rsa(...) call" do
      ast =
        method_ast([
          var("sig", bare_call("rsa", [identifier("q"), identifier("s"), identifier("sha256")])),
          assign_header("X-SIGN", identifier("sig"))
        ])

      assert %{"private" => %{"crypto_op" => %{"algo" => "rsa"}}} =
               Derive.derive(ast, ["private"])
    end

    test "jwt call emits custom algo with deferred reason" do
      ast =
        method_ast([
          var("token", bare_call("jwt", [identifier("req"), identifier("key")])),
          assign_header("Authorization", identifier("token"))
        ])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"]["algo"] == "custom"
      assert record["crypto_op"]["reason"] =~ "jwt"
      assert record["unresolved_reason"] == "custom_signing_family"
    end
  end

  # --- Multi-algo ambiguity ---

  describe "derive/2 — ambiguous multi-algo" do
    test "multiple distinct crypto calls emit nil crypto_op + ambiguous_ast" do
      # Mimics binance: RSA / EdDSA / HMAC conditional branches all present.
      ast =
        method_ast([
          var("sig1", bare_call("rsa", [identifier("q"), identifier("s"), identifier("sha256")])),
          var("sig2", bare_call("eddsa", [identifier("q"), identifier("s"), identifier("ed25519")])),
          var("sig3", hmac_call("sha256")),
          assign_query_plus("&signature=", identifier("sig3"))
        ])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"] == nil
      assert record["unresolved_reason"] == "ambiguous_ast"
    end

    test "two hmac calls with same algo are not ambiguous" do
      # Some exchanges use this.hmac twice — once for passphrase encoding,
      # once for the signature. Both return the same algo, so no ambiguity.
      ast =
        method_ast([
          var("passphrase", hmac_call("sha256")),
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature"))
        ])

      assert %{"private" => %{"crypto_op" => %{"algo" => "hmac_sha256"}}} =
               Derive.derive(ast, ["private"])
    end
  end

  # --- Custom signing family (no crypto call) ---

  describe "derive/2 — custom signing family" do
    test "sign() with no crypto call at all" do
      # Hyperliquid-style: sign() just builds url/body; ECDSA signing lives
      # elsewhere.
      ast =
        method_ast([
          %{
            "type" => "ExpressionStatement",
            "expression" => %{
              "type" => "AssignmentExpression",
              "operator" => "=",
              "left" => identifier("url"),
              "right" => literal("https://api.example.com")
            }
          }
        ])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"] == nil
      assert record["signature_placement"] == nil
      assert record["unresolved_reason"] == "custom_signing_family"
    end
  end

  # --- Signature placement ---

  describe "derive/2 — signature_placement detection" do
    test "header via computed member assignment `headers['X-BAPI-SIGN'] = signature`" do
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-BAPI-SIGN", identifier("signature"))
        ])

      assert %{"private" => %{"signature_placement" => placement}} =
               Derive.derive(ast, ["private"])

      assert placement == %{"location" => "header", "key" => "X-BAPI-SIGN"}
    end

    test "query via `+ '&signature=' + signature` chain" do
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_query_plus("&signature=", identifier("signature"))
        ])

      assert %{"private" => %{"signature_placement" => placement}} =
               Derive.derive(ast, ["private"])

      assert placement == %{"location" => "query", "key" => "signature"}
    end

    test "body via `body = this.json({'sign': signature})`" do
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_body_json("sign", identifier("signature"))
        ])

      assert %{"private" => %{"signature_placement" => placement}} =
               Derive.derive(ast, ["private"])

      assert placement == %{"location" => "body", "key" => "sign"}
    end

    test "inline use (no signature binding) emits nil placement" do
      # Rare: crypto call result passed directly into a return/call without
      # ever being bound to an identifier. Still leaves crypto_op intact.
      ast =
        method_ast([
          %{
            "type" => "ExpressionStatement",
            "expression" =>
              this_call("urlencode", [
                %{
                  "type" => "ObjectExpression",
                  "properties" => [
                    %{
                      "type" => "Property",
                      "key" => literal("sig"),
                      "value" => hmac_call("sha256")
                    }
                  ]
                }
              ])
          }
        ])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"] == %{"algo" => "hmac_sha256"}
      # No binding was created, so we can't track the signature to a
      # placement.
      assert record["signature_placement"] == nil
    end

    test "inline header placement via `headers['K'] = this.hmac(...)` (no binding, phemex-style)" do
      # Phemex: crypto call is the RHS of a header assignment with no
      # intermediate `const signature = ...` binding. Detection falls
      # through the fingerprint-based branch of has_sig_ref?/2.
      ast =
        method_ast([
          assign_header("x-phemex-request-signature", hmac_call("sha256"))
        ])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"] == %{"algo" => "hmac_sha256"}

      assert record["signature_placement"] ==
               %{"location" => "header", "key" => "x-phemex-request-signature"}
    end

    test "conflicting placements across branches emit nil" do
      # Some branches put signature in header, others in query. Without
      # per-section attribution, we can't pick one, so we emit nil rather
      # than guess.
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature")),
          assign_query_plus("&sig=", identifier("signature"))
        ])

      assert %{"private" => %{"signature_placement" => nil}} =
               Derive.derive(ast, ["private"])
    end

    test "ambiguous crypto but agreed placement still emits placement" do
      # Binance-style: RSA+HMAC branches both land in the query with the
      # same key. crypto_op stays nil, signature_placement survives.
      ast =
        method_ast([
          var("sig", bare_call("rsa", [identifier("q"), identifier("s"), identifier("sha256")])),
          var("hmacSig", hmac_call("sha256")),
          assign_query_plus("&signature=", identifier("sig")),
          assign_query_plus("&signature=", identifier("hmacSig"))
        ])

      assert %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["crypto_op"] == nil
      assert record["unresolved_reason"] == "ambiguous_ast"
      assert record["signature_placement"] == %{"location" => "query", "key" => "signature"}
    end
  end

  # --- Multi-section replication ---

  describe "derive/2 — section replication" do
    test "same crypto_op + placement stamped on every authenticated section" do
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature"))
        ])

      result = Derive.derive(ast, ["private", "sapi", "fapiPrivate"])

      assert result |> Map.keys() |> Enum.sort() == ["fapiPrivate", "private", "sapi"]

      for {_section, record} <- result do
        assert record["crypto_op"] == %{"algo" => "hmac_sha256"}
        assert record["signature_placement"] == %{"location" => "header", "key" => "X-SIGN"}
      end
    end
  end

  # --- Output shape invariants ---

  describe "derive/2 — record shape" do
    test "every emitted record has the eight required keys" do
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature"))
        ])

      result = Derive.derive(ast, ["private"])

      for {_section, record} <- result do
        assert record |> Map.keys() |> Enum.sort() == Enum.sort(SignRecipe.required_keys())
      end
    end

    test "populated recipe leaves Task 68 field null" do
      # Tasks 65 / 66a / 66b / 67 combined populate crypto_op,
      # signature_placement, canonical_string, auth_headers, nonce.
      # The minimal body below has only the signature header assignment
      # — so auth_headers comes out as `[]` (signature is excluded; no
      # other auth headers) rather than nil, and the canonical string is
      # nil (CanonicalString needs an hmac + encoded chain to classify).
      # Nonce is nil because there is no timestamp binding.
      # pre_sign_transforms is the only field that remains wholly null
      # until Task 68.
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature"))
        ])

      %{"private" => record} = Derive.derive(ast, ["private"])

      assert record["auth_headers"] == []
      assert record["canonical_string"] == nil
      assert record["nonce"] == nil
      assert record["pre_sign_transforms"] == nil
    end

    test "auth_headers and nonce populate end-to-end for a Bybit-shaped body" do
      # Full shape: timestamp binding + headers ObjectExpression with
      # api_key, timestamp, recv_window, literal sign-type, and the
      # signature entry that must be excluded.
      rw = %{
        "type" => "CallExpression",
        "callee" => %{
          "type" => "MemberExpression",
          "object" => %{
            "type" => "MemberExpression",
            "computed" => true,
            "object" => %{
              "type" => "MemberExpression",
              "object" => this_expression(),
              "property" => identifier("options")
            },
            "property" => literal("recvWindow")
          },
          "property" => identifier("toString")
        },
        "arguments" => [],
        "start" => System.unique_integer([:positive, :monotonic]),
        "end" => System.unique_integer([:positive, :monotonic]) + 1_000_000
      }

      ast =
        method_ast([
          var("timestamp", this_call("nonce", [])),
          var("signature", hmac_call("sha256")),
          %{
            "type" => "ExpressionStatement",
            "expression" => %{
              "type" => "AssignmentExpression",
              "operator" => "=",
              "left" => identifier("headers"),
              "right" => %{
                "type" => "ObjectExpression",
                "properties" => [
                  %{
                    "type" => "Property",
                    "key" => literal("Content-Type"),
                    "value" => literal("application/json")
                  },
                  %{
                    "type" => "Property",
                    "key" => literal("X-BAPI-API-KEY"),
                    "value" => %{
                      "type" => "MemberExpression",
                      "object" => this_expression(),
                      "property" => identifier("apiKey")
                    }
                  },
                  %{
                    "type" => "Property",
                    "key" => literal("X-BAPI-TIMESTAMP"),
                    "value" => identifier("timestamp")
                  },
                  %{
                    "type" => "Property",
                    "key" => literal("X-BAPI-SIGN"),
                    "value" => identifier("signature")
                  },
                  %{
                    "type" => "Property",
                    "key" => literal("X-BAPI-SIGN-TYPE"),
                    "value" => literal("2")
                  },
                  %{
                    "type" => "Property",
                    "key" => literal("X-BAPI-RECV-WINDOW"),
                    "value" => rw
                  }
                ]
              }
            }
          }
        ])

      %{"private" => record} = Derive.derive(ast, ["private"])

      assert record["auth_headers"] == [
               %{"name" => "X-BAPI-API-KEY", "source" => "api_key"},
               %{"name" => "X-BAPI-TIMESTAMP", "source" => "timestamp"},
               %{"name" => "X-BAPI-SIGN-TYPE", "source" => "literal", "value" => "2"},
               %{"name" => "X-BAPI-RECV-WINDOW", "source" => "recv_window"}
             ]

      assert record["nonce"] == %{"source" => "timestamp_ms", "format" => "integer"}
    end

    test "terminal unresolved_reason leaves auth_headers and nonce null" do
      # Hyperliquid-shape: no crypto call in sign(), so Task 65 tags
      # unresolved_reason as custom_signing_family. Task 67 must respect
      # that tag and emit null for auth_headers and nonce — anything else
      # would break the Honesty Rule.
      ast =
        method_ast([
          %{
            "type" => "ExpressionStatement",
            "expression" => %{
              "type" => "AssignmentExpression",
              "operator" => "=",
              "left" => identifier("url"),
              "right" => literal("https://api.example.com")
            }
          }
        ])

      %{"private" => record} = Derive.derive(ast, ["private"])

      assert record["unresolved_reason"] == "custom_signing_family"
      assert record["auth_headers"] == nil
      assert record["nonce"] == nil
    end

    test "patch_count starts at 0" do
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature"))
        ])

      %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["patch_count"] == 0
    end

    test "unresolved_reason stays 'not_yet_derived' when crypto_op+placement populated" do
      # Task 65 only fills 2 of 6 derivation fields. The other four are
      # still null, so unresolved_reason must remain 'not_yet_derived'
      # until Task 69 flips it.
      ast =
        method_ast([
          var("signature", hmac_call("sha256")),
          assign_header("X-SIGN", identifier("signature"))
        ])

      %{"private" => record} = Derive.derive(ast, ["private"])
      assert record["unresolved_reason"] == "not_yet_derived"
    end
  end
end
