defmodule CcxtExtract.SignRecipe.CanonicalStringTest do
  @moduledoc """
  Unit tests for `CcxtExtract.SignRecipe.CanonicalString` — the Task 66a
  derivation that populates the per-verb `canonical_string` map.

  Uses synthetic AST fixtures; no file I/O. Corpus-level assertions live in
  `test/integration/cached/sign_recipe_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.SignRecipe.CanonicalString

  # --- AST builder helpers (mirrors derive_test.exs style) ---

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

  defp plus(l, r), do: %{"type" => "BinaryExpression", "operator" => "+", "left" => l, "right" => r}
  defp plus_chain([a, b]), do: plus(a, b)
  defp plus_chain([a, b | rest]), do: plus_chain([plus(a, b) | rest])

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

  defp compound_assign(name, rhs) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "+=",
        "left" => identifier(name),
        "right" => rhs
      }
    }
  end

  defp direct_assign(name, rhs) do
    %{
      "type" => "ExpressionStatement",
      "expression" => %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => identifier(name),
        "right" => rhs
      }
    }
  end

  defp if_method(verb, then_stmts, else_stmts \\ nil) do
    test = %{
      "type" => "BinaryExpression",
      "operator" => "===",
      "left" => identifier("method"),
      "right" => literal(verb)
    }

    consequent = %{"type" => "BlockStatement", "body" => then_stmts}

    alternate =
      if else_stmts, do: %{"type" => "BlockStatement", "body" => else_stmts}

    %{
      "type" => "IfStatement",
      "test" => test,
      "consequent" => consequent,
      "alternate" => alternate
    }
  end

  defp sig_decl(arg) do
    # const signature = this.hmac(this.encode(arg), this.encode(secret), sha256)
    encode = this_call("encode", [arg])
    encode_secret = this_call("encode", [identifier("secret")])

    hmac =
      this_call("hmac", [
        encode,
        encode_secret,
        identifier("sha256")
      ])

    var_decl("signature", hmac)
  end

  # --- Short-circuit behavior ---

  describe "terminal unresolved_reason short-circuit" do
    test "ambiguous_ast returns nil without walking" do
      # Even if body contains a clean chain, don't attempt derivation.
      body = [sig_decl(plus(identifier("timestamp"), identifier("method")))]
      assert is_nil(CanonicalString.derive(body, [], ["signature"], "ambiguous_ast"))
    end

    test "custom_signing_family returns nil" do
      assert is_nil(CanonicalString.derive([], [], ["signature"], "custom_signing_family"))
    end

    test "no_sign_method returns nil" do
      assert is_nil(CanonicalString.derive([], [], ["signature"], "no_sign_method"))
    end
  end

  # --- Direct inline chains (no variable indirection) ---

  describe "inline `+`-chain in this.hmac(this.encode(X), ...)" do
    test "simple timestamp + method + path emits `*` entry" do
      body = [
        sig_decl(plus_chain([identifier("timestamp"), identifier("method"), identifier("path")]))
      ]

      result = CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert result == %{
               "*" => %{
                 "family" => "hmac_simple",
                 "components" => [
                   %{"source" => "timestamp"},
                   %{"source" => "method"},
                   %{"source" => "path"}
                 ],
                 "encoding" => "url_encoded"
               }
             }
    end

    test "timestamp + method + path + query works" do
      body = [
        sig_decl(
          plus_chain([
            identifier("timestamp"),
            identifier("method"),
            identifier("path"),
            identifier("query")
          ])
        )
      ]

      assert %{"*" => %{"components" => comps}} =
               CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert comps == [
               %{"source" => "timestamp"},
               %{"source" => "method"},
               %{"source" => "path"},
               %{"source" => "query"}
             ]
    end

    test "unrecognized identifier aborts branch → nil overall" do
      body = [
        sig_decl(plus_chain([identifier("timestamp"), identifier("mystery_var"), identifier("path")]))
      ]

      assert is_nil(CanonicalString.derive(body, [], ["signature"], "not_yet_derived"))
    end

    test "adjacent string literals merge" do
      body = [
        sig_decl(plus_chain([identifier("timestamp"), literal("?"), literal("signature=")]))
      ]

      assert %{"*" => %{"components" => comps}} =
               CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert comps == [
               %{"source" => "timestamp"},
               %{"source" => "literal", "value" => "?signature="}
             ]
    end

    test "this.apiKey and this.milliseconds() recognized" do
      body = [
        sig_decl(
          plus_chain([
            this_call("milliseconds", []),
            %{
              "type" => "MemberExpression",
              "object" => this_expression(),
              "property" => identifier("apiKey")
            },
            identifier("recvWindow")
          ])
        )
      ]

      assert %{"*" => %{"components" => comps}} =
               CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert comps == [
               %{"source" => "timestamp"},
               %{"source" => "api_key"},
               %{"source" => "recv_window"}
             ]
    end

    test "this.urlencode(...) maps to query source" do
      body = [
        sig_decl(
          plus_chain([
            identifier("timestamp"),
            identifier("method"),
            identifier("path"),
            this_call("urlencode", [identifier("params")])
          ])
        )
      ]

      assert %{"*" => %{"components" => comps}} =
               CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert List.last(comps) == %{"source" => "query"}
    end
  end

  # --- Variable indirection + method-conditional branching ---

  describe "variable with method-conditional += (OKX/Bitget pattern)" do
    # OKX-style shape:
    #   let auth = timestamp + method + path;
    #   if (method === 'GET') { auth += '?' + this.urlencode(query); }
    #   else { body = this.json(params); auth += body; }
    #   signature = this.hmac(this.encode(auth), ...);
    #
    # Expected: GET branch emits hmac_simple, POST branch emits hmac_with_body.
    # The `body = this.json(...)` direct assignment puts `body` into the
    # `reassigned` set, but `@body_names` are exempt from that filter in
    # `classify_piece/2` because the identifier name `body` is itself the
    # canonical HTTP-body source tag in CCXT sign().

    test "GET emits hmac_simple, POST emits hmac_with_body (OKX-shape sign)" do
      init = plus_chain([identifier("timestamp"), identifier("method"), identifier("path")])

      get_branch = [
        compound_assign("auth", plus(literal("?"), this_call("urlencode", [identifier("query")])))
      ]

      post_branch = [
        direct_assign("body", this_call("json", [identifier("params")])),
        compound_assign("auth", identifier("body"))
      ]

      body = [
        var_decl("auth", init),
        if_method("GET", get_branch, post_branch),
        sig_decl(identifier("auth"))
      ]

      result = CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert result == %{
               "GET" => %{
                 "family" => "hmac_simple",
                 "components" => [
                   %{"source" => "timestamp"},
                   %{"source" => "method"},
                   %{"source" => "path"},
                   %{"source" => "literal", "value" => "?"},
                   %{"source" => "query"}
                 ],
                 "encoding" => "url_encoded"
               },
               "POST" => %{
                 "family" => "hmac_with_body",
                 "components" => [
                   %{"source" => "timestamp"},
                   %{"source" => "method"},
                   %{"source" => "path"},
                   %{"source" => "body"}
                 ],
                 "encoding" => "url_encoded"
               }
             }
    end

    test "single non-GET branch with body → POST hmac_with_body only" do
      # Minimal shape: let auth = INIT; if (method === 'POST') { auth += body };
      # No else-branch. Locks in the minimal populating shape for 66b: only
      # POST appears in the per-verb map; GET's implicit init-only canonical
      # is not emitted (pre-existing behavior — see build_verb_entries/2).
      init = plus_chain([identifier("timestamp"), identifier("path")])

      post_branch = [
        direct_assign("body", this_call("json", [identifier("params")])),
        compound_assign("auth", identifier("body"))
      ]

      body = [
        var_decl("auth", init),
        if_method("POST", post_branch),
        sig_decl(identifier("auth"))
      ]

      result = CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert result == %{
               "POST" => %{
                 "family" => "hmac_with_body",
                 "components" => [
                   %{"source" => "timestamp"},
                   %{"source" => "path"},
                   %{"source" => "body"}
                 ],
                 "encoding" => "url_encoded"
               }
             }
    end

    test "only GET branch (no else) emits single GET entry" do
      init = plus_chain([identifier("timestamp"), identifier("method"), identifier("path")])

      get_branch = [
        compound_assign("auth", plus(literal("?"), this_call("urlencode", [identifier("query")])))
      ]

      body = [
        var_decl("auth", init),
        if_method("GET", get_branch),
        sig_decl(identifier("auth"))
      ]

      assert %{"GET" => %{"family" => "hmac_simple"}} =
               CanonicalString.derive(body, [], ["signature"], "not_yet_derived")
    end

    test "both branches hmac_simple → both emitted (Deribit-style uniform)" do
      # Contrived: both branches just append different query params.
      init = plus_chain([identifier("timestamp"), identifier("method"), identifier("path")])

      get_branch = [compound_assign("auth", this_call("urlencode", [identifier("params")]))]
      post_branch = [compound_assign("auth", this_call("rawencode", [identifier("params")]))]

      body = [
        var_decl("auth", init),
        if_method("GET", get_branch, post_branch),
        sig_decl(identifier("auth"))
      ]

      result = CanonicalString.derive(body, [], ["signature"], "not_yet_derived")
      assert result |> Map.keys() |> Enum.sort() == ["GET", "POST"]
      assert get_in(result, ["GET", "family"]) == "hmac_simple"
      assert get_in(result, ["POST", "family"]) == "hmac_simple"
    end

    test "both branches reference body → both emit hmac_with_body" do
      # Contrived shape: both branches append `body` to the auth chain. Under
      # 66a this returned nil (any body-bearing branch was dropped); under 66b
      # both emit hmac_with_body entries side-by-side under GET and POST.
      init = plus_chain([identifier("timestamp"), identifier("method")])
      get_branch = [compound_assign("auth", identifier("body"))]
      post_branch = [compound_assign("auth", identifier("body"))]

      body = [
        var_decl("auth", init),
        if_method("GET", get_branch, post_branch),
        sig_decl(identifier("auth"))
      ]

      result = CanonicalString.derive(body, [], ["signature"], "not_yet_derived")
      assert result |> Map.keys() |> Enum.sort() == ["GET", "POST"]
      assert get_in(result, ["GET", "family"]) == "hmac_with_body"
      assert get_in(result, ["POST", "family"]) == "hmac_with_body"
      assert List.last(get_in(result, ["GET", "components"])) == %{"source" => "body"}
      assert List.last(get_in(result, ["POST", "components"])) == %{"source" => "body"}
    end

    test "unconditional += after method-conditional += preserves source order" do
      # Shape: let auth = INIT; if (method === 'GET') { auth += A; } auth += B;
      # No priority CCXT exchange has this pattern today (verified against
      # okx/bitget/kucoin/gate/kraken/deribit/phemex/coinbase), but
      # `build_verb_entries/2` must interleave '*'-tagged updates with
      # verb-tagged ones at their source positions rather than concatenating
      # blindly. This locks in that invariant so a future exchange with this
      # shape doesn't get a silently misordered canonical string.
      init = plus_chain([identifier("timestamp"), identifier("method")])

      get_branch = [compound_assign("auth", identifier("path"))]
      post_if_append = compound_assign("auth", identifier("query"))

      body = [
        var_decl("auth", init),
        if_method("GET", get_branch),
        post_if_append,
        sig_decl(identifier("auth"))
      ]

      result = CanonicalString.derive(body, [], ["signature"], "not_yet_derived")

      assert %{"GET" => %{"components" => comps}} = result
      assert Enum.map(comps, & &1["source"]) == ["timestamp", "method", "path", "query"]
    end

    test "direct reassignment of tracked variable aborts derivation" do
      # `let auth = X; auth = Y; signature = hmac(encode(auth))`
      # — can't reconstruct reliably, so we bail.
      init = plus_chain([identifier("timestamp"), identifier("method")])

      body = [
        var_decl("auth", init),
        direct_assign("auth", identifier("path")),
        sig_decl(identifier("auth"))
      ]

      assert is_nil(CanonicalString.derive(body, [], ["signature"], "not_yet_derived"))
    end
  end

  # --- Bybit-style (all verbs share shape except body-vs-query suffix) ---

  describe "Bybit-v3/v5 shape with auth_base + per-verb extension" do
    test "GET adds query, POST adds body → GET hmac_simple only" do
      # const auth_base = timestamp + apiKey + recvWindow;
      # if (method === 'GET') { authFull = auth_base + queryEncoded; }
      # else { authFull = auth_base + body; }
      # signature = hmac(encode(authFull), ...)
      #
      # We can't cleanly track `authFull` because it's direct-assigned in
      # both branches. The direct-reassign guard will reject it.
      # This test documents the expected null result — Bybit is intentionally
      # out of 66a scope (and also blocked by ambiguous_ast at crypto_op).
      init = plus_chain([identifier("timestamp"), identifier("api_key"), identifier("recvWindow")])

      body = [
        var_decl("auth_base", init),
        var_decl("authFull", identifier("auth_base")),
        if_method(
          "GET",
          [direct_assign("authFull", plus(identifier("auth_base"), identifier("queryEncoded")))],
          [direct_assign("authFull", plus(identifier("auth_base"), identifier("body")))]
        ),
        sig_decl(identifier("authFull"))
      ]

      assert is_nil(CanonicalString.derive(body, [], ["signature"], "not_yet_derived"))
    end
  end

  # --- Signature-binding narrowing ---

  describe "signature name narrowing" do
    test "only the canonical binding's hmac is considered" do
      # Two hmac calls, one bound to `passphrase` (ancillary) and one to
      # `signature` (canonical). We must use the canonical one's arg.
      ancillary =
        var_decl("passphrase", this_call("hmac", [identifier("noise"), identifier("secret"), identifier("sha256")]))

      canonical = sig_decl(plus_chain([identifier("timestamp"), identifier("method")]))
      body = [ancillary, canonical]

      # sig_names narrows to ["signature"] — the ancillary hmac at
      # `passphrase` is ignored because `passphrase` isn't in sig_names.
      assert %{"*" => %{"components" => [%{"source" => "timestamp"}, %{"source" => "method"}]}} =
               CanonicalString.derive(body, [], ["signature"], "not_yet_derived")
    end

    test "no matching binding → nil" do
      # signature bound, but to something other than this.hmac.
      body = [var_decl("signature", identifier("something_else"))]
      assert is_nil(CanonicalString.derive(body, [], ["signature"], "not_yet_derived"))
    end
  end
end
