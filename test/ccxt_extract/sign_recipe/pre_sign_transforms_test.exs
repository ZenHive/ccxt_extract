defmodule CcxtExtract.SignRecipe.PreSignTransformsTest do
  @moduledoc """
  Unit tests for `CcxtExtract.SignRecipe.PreSignTransforms` — the Task 68
  derivation that closes the sixth (and final) sign-recipe derivation
  field, emitting ordered hex/base64/lowercase/url/json encoding
  transforms applied to signature, body, or canonical_string.

  Uses synthetic AST fixtures; no file I/O. Corpus-level assertions live
  in `test/integration/cached/sign_recipe_cached_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.SignRecipe.PreSignTransforms
  alias CcxtExtract.SignRecipe.SigRef

  # --- AST builder helpers ---
  #
  # The `start`/`end` byte offsets matter because `SigRef.fingerprint/1`
  # uses them to identify crypto-call nodes across derivation stages.
  # Every CallExpression needs a unique range or two distinct calls collide
  # in the crypto_fps list.

  defp unique_offset, do: System.unique_integer([:positive, :monotonic])

  defp identifier(name), do: %{"type" => "Identifier", "name" => name}
  defp literal(value), do: %{"type" => "Literal", "value" => value}
  defp this_expression, do: %{"type" => "ThisExpression"}

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

  defp bare_call(name, args) do
    s = unique_offset()

    %{
      "type" => "CallExpression",
      "callee" => identifier(name),
      "arguments" => args,
      "start" => s,
      "end" => s + 1_000_000
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

  defp assign(target_name, rhs) do
    %{
      "type" => "AssignmentExpression",
      "operator" => "=",
      "left" => identifier(target_name),
      "right" => rhs
    }
  end

  defp op_assign(target_name, operator, rhs) do
    %{
      "type" => "AssignmentExpression",
      "operator" => operator,
      "left" => identifier(target_name),
      "right" => rhs
    }
  end

  defp property(key, value) do
    %{
      "type" => "Property",
      "key" => %{"type" => "Literal", "value" => key},
      "value" => value
    }
  end

  defp object_expression(properties) do
    %{"type" => "ObjectExpression", "properties" => properties}
  end

  # An `this.hmac(data, secret, sha256, digest?)` call — digest arg optional.
  defp hmac_call(digest_opt) do
    args =
      [identifier("auth"), identifier("secret"), identifier("sha256")] ++
        case digest_opt do
          nil -> []
          digest -> [literal(digest)]
        end

    this_call("hmac", args)
  end

  # Build the `sig_ctx` tuple (sig_names + crypto_fps) from a sign-binding
  # declarator. Caller passes the binding's init node; we fingerprint it and
  # return the {names, fps} pair.
  defp sig_ctx(sig_name, hmac_init) do
    {[sig_name], [SigRef.fingerprint(hmac_init)]}
  end

  # --- Terminal-reason short-circuit ---

  describe "terminal unresolved_reason short-circuit" do
    test "ambiguous_ast returns nil" do
      assert is_nil(PreSignTransforms.derive([], [], [], "ambiguous_ast"))
    end

    test "custom_signing_family returns nil" do
      assert is_nil(PreSignTransforms.derive([], [], [], "custom_signing_family"))
    end

    test "no_sign_method returns nil" do
      assert is_nil(PreSignTransforms.derive([], [], [], "no_sign_method"))
    end
  end

  # --- Null / empty input ---

  describe "empty or non-list input" do
    test "empty body and no sig context → []" do
      assert PreSignTransforms.derive([], [], [], "not_yet_derived") == []
    end

    test "non-list body returns nil" do
      assert is_nil(PreSignTransforms.derive(%{"some" => "map"}, [], [], "not_yet_derived"))
    end
  end

  # --- Digest detection: hex vs base64 ---

  describe "digest detection" do
    test "base64 digest (okx pattern): this.hmac(auth, secret, sha256, 'base64') bound to signature" do
      hmac = hmac_call("base64")
      body = [var_decl("signature", hmac)]
      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert result == [%{"op" => "base64_encode", "target" => "signature"}]
    end

    test "hex digest (bybit V5 pattern): this.hmac(auth, secret, sha256, 'hex') bound to signature" do
      hmac = hmac_call("hex")
      body = [var_decl("signature", hmac)]
      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert result == [%{"op" => "hex_encode", "target" => "signature"}]
    end

    test "default digest (deribit/bitfinex pattern): 3-arg this.hmac defaults to hex" do
      hmac = hmac_call(nil)
      body = [var_decl("signature", hmac)]
      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert result == [%{"op" => "hex_encode", "target" => "signature"}]
    end

    test "multiple sig-producing hmac calls with uniform digest → single entry" do
      hmac_a = hmac_call("base64")
      hmac_b = hmac_call("base64")

      body = [
        var_decl("signature", hmac_a),
        var_decl("sig", hmac_b)
      ]

      sig_names = ["signature", "sig"]
      crypto_fps = [SigRef.fingerprint(hmac_a), SigRef.fingerprint(hmac_b)]

      result = PreSignTransforms.derive(body, sig_names, crypto_fps, "not_yet_derived")

      assert result == [%{"op" => "base64_encode", "target" => "signature"}]
    end

    test "multiple sig-producing hmac calls with disagreeing digest → no digest entry" do
      hmac_a = hmac_call("base64")
      hmac_b = hmac_call("hex")

      body = [
        var_decl("signature", hmac_a),
        var_decl("sig", hmac_b)
      ]

      sig_names = ["signature", "sig"]
      crypto_fps = [SigRef.fingerprint(hmac_a), SigRef.fingerprint(hmac_b)]

      # Honest empty list: no uniform digest could be derived. Other
      # detectors (body, post-sig) still emit if they find something.
      result = PreSignTransforms.derive(body, sig_names, crypto_fps, "not_yet_derived")

      assert result == []
    end

    test "sig_names empty but crypto_fps matches (phemex-style inline placement)" do
      hmac = hmac_call("base64")

      # headers['X-SIGN'] = this.hmac(...) — no intermediate binding.
      assign_stmt = %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => %{
          "type" => "MemberExpression",
          "computed" => true,
          "object" => identifier("headers"),
          "property" => literal("X-SIGN")
        },
        "right" => hmac
      }

      body = [assign_stmt]
      crypto_fps = [SigRef.fingerprint(hmac)]

      result = PreSignTransforms.derive(body, [], crypto_fps, "not_yet_derived")

      assert result == [%{"op" => "base64_encode", "target" => "signature"}]
    end

    test "non-literal digest (Identifier) is skipped honestly" do
      # this.hmac(auth, secret, sha256, digestVar) — can't resolve without
      # chasing bindings; Task 68 skips under Three-Strikes Rule.
      args = [identifier("auth"), identifier("secret"), identifier("sha256"), identifier("digestVar")]
      hmac = this_call("hmac", args)

      body = [var_decl("signature", hmac)]
      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      # No digest entry — but also no other transforms → []
      assert result == []
    end

    test "hmac call not bound to signature name → ignored (kucoin passphrase hmac)" do
      # kucoin's sign() has `passphrase = this.hmac(...)` AND `signature =
      # this.hmac(...)`. Only the signature-bound one produces the digest
      # we emit; the passphrase hmac is out of scope for pre_sign_transforms.
      hmac_passphrase = hmac_call("base64")
      hmac_sig = hmac_call("base64")

      body = [
        var_decl("passphrase", hmac_passphrase),
        var_decl("signature", hmac_sig)
      ]

      # Only signature is in sig_names (matches Derive.collect_signature_bindings
      # narrowing behavior).
      sig_names = ["signature"]
      crypto_fps = [SigRef.fingerprint(hmac_passphrase), SigRef.fingerprint(hmac_sig)]

      result = PreSignTransforms.derive(body, sig_names, crypto_fps, "not_yet_derived")

      assert result == [%{"op" => "base64_encode", "target" => "signature"}]
    end
  end

  # --- Body encoding detection ---

  describe "body = this.json(...) + crypto uses body" do
    test "body is JSON-encoded AND referenced by crypto call → json_encode entry" do
      hmac_on_body =
        this_call("hmac", [
          identifier("body"),
          identifier("secret"),
          identifier("sha256"),
          literal("base64")
        ])

      body = [
        assign("body", this_call("json", [identifier("params")])),
        var_decl("signature", hmac_on_body)
      ]

      ctx = sig_ctx("signature", hmac_on_body)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      # Ordering: digest first (signature), then body encoding.
      assert %{"op" => "json_encode", "target" => "body"} in result
      assert %{"op" => "base64_encode", "target" => "signature"} in result
    end

    test "body is JSON-encoded but not referenced by crypto → no json_encode entry" do
      # Body is prepared for the REQUEST, not for signing. Phase 11 scope,
      # not Phase 10.
      hmac_on_auth = hmac_call("base64")

      body = [
        assign("body", this_call("json", [identifier("params")])),
        var_decl("signature", hmac_on_auth)
      ]

      ctx = sig_ctx("signature", hmac_on_auth)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      refute %{"op" => "json_encode", "target" => "body"} in result
    end

    test "JSON.stringify variant (raw JS fallback)" do
      json_stringify =
        method_call(identifier("JSON"), "stringify", [identifier("params")])

      hmac_on_body =
        this_call("hmac", [
          identifier("body"),
          identifier("secret"),
          identifier("sha256"),
          literal("hex")
        ])

      body = [
        var_decl("body", json_stringify),
        var_decl("signature", hmac_on_body)
      ]

      ctx = sig_ctx("signature", hmac_on_body)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert %{"op" => "json_encode", "target" => "body"} in result
    end

    test "1-hop alias: body flows through auth via `auth += body` (okx pattern)" do
      # okx.private:
      #   body = this.json(query);
      #   auth += body;
      #   const signature = this.hmac(this.encode(auth), ..., 'base64');
      # The crypto call references `auth`, not `body`. The 1-hop tracer must
      # follow auth's reassignment chain to find the json-encoded body.
      hmac_on_auth =
        this_call("hmac", [
          this_call("encode", [identifier("auth")]),
          identifier("secret"),
          identifier("sha256"),
          literal("base64")
        ])

      body = [
        # let auth = timestamp + method + request;  (no body yet)
        var_decl("auth", literal("seed")),
        # body = this.json(query)
        assign("body", this_call("json", [identifier("query")])),
        # auth += body  ← 1-hop alias linking auth to body
        op_assign("auth", "+=", identifier("body")),
        # const signature = this.hmac(this.encode(auth), ..., 'base64');
        var_decl("signature", hmac_on_auth)
      ]

      ctx = sig_ctx("signature", hmac_on_auth)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert %{"op" => "json_encode", "target" => "body"} in result
      assert %{"op" => "base64_encode", "target" => "signature"} in result
    end

    test "1-hop alias does NOT fire when alias chain never touches body" do
      # auth concats only timestamp + method + request — no body alias.
      hmac_on_auth = hmac_call("base64")

      body = [
        var_decl("auth", literal("seed")),
        op_assign("auth", "+=", identifier("path")),
        # body is JSON-encoded but never enters auth.
        assign("body", this_call("json", [identifier("query")])),
        var_decl("signature", hmac_on_auth)
      ]

      ctx = sig_ctx("signature", hmac_on_auth)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      refute %{"op" => "json_encode", "target" => "body"} in result
    end
  end

  # --- Post-signature transforms ---

  describe "post-signature transforms" do
    test "this.urlencode({K: signature}) → url_encode on signature (htx pattern)" do
      hmac = hmac_call("base64")

      url_encode_call =
        this_call("urlencode", [
          object_expression([property("Signature", identifier("signature"))])
        ])

      body = [
        var_decl("signature", hmac),
        assign("url", url_encode_call)
      ]

      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert %{"op" => "url_encode", "target" => "signature"} in result
      # Digest should still emit.
      assert %{"op" => "base64_encode", "target" => "signature"} in result
    end

    test "this.encodeURIComponent(signature) → url_encode on signature (binance RSA/EdDSA)" do
      hmac = hmac_call(nil)

      encode_call =
        this_call("encodeURIComponent", [identifier("signature")])

      body = [
        var_decl("signature", hmac),
        assign("query", encode_call)
      ]

      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert %{"op" => "url_encode", "target" => "signature"} in result
    end

    test "bare-callee encodeURIComponent(signature) variant" do
      hmac = hmac_call(nil)
      encode_call = bare_call("encodeURIComponent", [identifier("signature")])

      body = [
        var_decl("signature", hmac),
        assign("query", encode_call)
      ]

      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert %{"op" => "url_encode", "target" => "signature"} in result
    end

    test "signature.toLowerCase() → lowercase on signature" do
      hmac = hmac_call(nil)

      lowercase_call =
        method_call(identifier("signature"), "toLowerCase", [])

      body = [
        var_decl("signature", hmac),
        assign("sigLower", lowercase_call)
      ]

      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert %{"op" => "lowercase", "target" => "signature"} in result
    end

    test "duplicate post-sig wrappers deduplicate to one entry" do
      hmac = hmac_call(nil)

      url_a =
        this_call("urlencode", [
          object_expression([property("Signature", identifier("signature"))])
        ])

      url_b =
        this_call("urlencode", [
          object_expression([property("Sign", identifier("signature"))])
        ])

      body = [
        var_decl("signature", hmac),
        assign("urlA", url_a),
        assign("urlB", url_b)
      ]

      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      # Both url_encode entries dedup because both have {op: url_encode, target: signature}.
      url_encode_entries =
        Enum.filter(result, fn t -> t["op"] == "url_encode" end)

      assert length(url_encode_entries) == 1
    end

    test "wrapper on non-sig identifier → no post-sig transform" do
      hmac = hmac_call(nil)

      # encodeURIComponent(something) where `something` is not a sig.
      encode_other = this_call("encodeURIComponent", [identifier("notASignature")])

      body = [
        var_decl("signature", hmac),
        assign("x", encode_other)
      ]

      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      refute Enum.any?(result, fn t -> t["op"] == "url_encode" end)
    end
  end

  # --- Composition: multi-transform recipes ---

  describe "composed recipes" do
    test "htx-style full stack: base64 digest + url_encode wrap" do
      hmac = hmac_call("base64")

      url_encode_call =
        this_call("urlencode", [
          object_expression([property("Signature", identifier("signature"))])
        ])

      body = [
        var_decl("signature", hmac),
        assign("url", url_encode_call)
      ]

      ctx = sig_ctx("signature", hmac)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      assert result == [
               %{"op" => "base64_encode", "target" => "signature"},
               %{"op" => "url_encode", "target" => "signature"}
             ]
    end

    test "kucoin-style: json_encode body + base64 digest" do
      hmac_on_body =
        this_call("hmac", [
          identifier("body"),
          identifier("secret"),
          identifier("sha256"),
          literal("base64")
        ])

      body = [
        assign("body", this_call("json", [identifier("params")])),
        var_decl("signature", hmac_on_body)
      ]

      ctx = sig_ctx("signature", hmac_on_body)

      result = PreSignTransforms.derive(body, elem(ctx, 0), elem(ctx, 1), "not_yet_derived")

      # Digest ordering is by pipeline: digest first, then body, then post-sig.
      assert result == [
               %{"op" => "base64_encode", "target" => "signature"},
               %{"op" => "json_encode", "target" => "body"}
             ]
    end
  end
end
