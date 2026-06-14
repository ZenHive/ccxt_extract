defmodule CcxtExtract.SignRecipe.PreSignTransforms do
  @moduledoc """
  Task 68 — populate `pre_sign_transforms` on every `structure.sign_recipe`
  record, closing the sixth (and final) derivation field introduced by the
  Task 64 scaffold.

  Emits an ordered list of encoding / normalization operations applied to
  the signature, body, or canonical_string during `sign()`. Each entry has
  the shape:

      %{"op" => op, "target" => target}

  where the vocabularies are closed by
  `priv/schema/exchange_v4.json#/$defs/SignRecipePreSignTransform`:

    * `op`     ∈ `"hex_encode"` | `"base64_encode"` | `"lowercase"`
                 | `"url_encode"` | `"json_encode"`
    * `target` ∈ `"signature"` | `"body"` | `"canonical_string"`

  ## Why this field exists

  `crypto_op`'s schema only carries `algo` (e.g. `"hmac_sha256"`) — there
  is no digest field. Consumers therefore cannot tell whether
  `this.hmac(auth, secret, sha256, 'base64')` produces a hex or base64
  signature without walking the AST. That encoding lives here as
  `{op: "base64_encode", target: "signature"}`.

  ## Detection strategy

  Three detector passes, in order:

    1. **Digest** — for every `this.hmac(_, _, algo, digest?)` call whose
       result is bound to (or directly placed as) the signature, inspect
       the 4th argument (default is hex when absent). Unique digest across
       sig-producing calls → emit `{hex_encode|base64_encode, signature}`.
       Disagreement across calls → skip the entry (honest: the later
       `sign_recipe_honesty_valid` invariant + a null
       `pre_sign_transforms` tells the consumer to consult the raw AST).
    2. **Body encoding** — `body = this.json(...)` or
       `body = JSON.stringify(...)` reassignment where `body` is
       subsequently consumed by a crypto call (directly OR through a
       single-hop alias) → `{json_encode, body}`. Direct catches
       `this.hmac(body, …)`. **1-hop alias** catches the okx/bitfinex
       shape — `body = this.json(query); auth += body; this.hmac(auth, …)`
       (or the same with `const auth = … + body` concat) — by following
       identifiers referenced in crypto-call args back through their local
       declarator/reassignment RHS one level. Multi-hop chains are
       intentionally out of scope for Phase 10 and tracked under
       Maintenance Backlog Task 128. If body is JSON-encoded but never
       reaches a crypto call, that's a request-preparation artifact and
       belongs in the Phase 11 request-building contract, not here.
    3. **Post-signature** — `CallExpression`s whose arguments transitively
       reference the signature (via `SigRef.has?/2`):
         * `this.urlencode({K: sig})` or `this.urlencode({K: sig, …})` → `{url_encode, signature}`
         * `this.encodeURIComponent(sig)` / bare `encodeURIComponent(sig)` → `{url_encode, signature}`
         * `sig.toLowerCase()` (MemberCall no-args) → `{lowercase, signature}`
       Deduplicated — a single htx sign() produces one url_encode entry
       even when two code paths invoke the wrapper.

  ## Honest empty

  Returns `[]` when derivation ran but found nothing actionable — for
  example a parseable sign() body that contains no crypto call and no
  recognizable transforms. `[]` counts as populated (non-nil) for the
  `sign_recipe_honesty_valid` biconditional, which is what we want: a
  sign() that legitimately has no transforms should not block the flip.

  Returns `nil` only on terminal `unresolved_reason` short-circuit
  (`ambiguous_ast` / `custom_signing_family` / `no_sign_method`) — the
  recipe-level tag already tells the truthful story, so no transforms
  derivation will help.

  ## Reuse contract

  Takes `sig_names` + `crypto_fps` so the post-signature detector can
  answer "does this sub-AST transitively reference the signature?" via
  `SigRef.has?/2` — the same machinery Task 65's placement detection
  uses. No new infrastructure.
  """

  alias CcxtExtract.SignRecipe
  alias CcxtExtract.SignRecipe.ASTHelpers
  alias CcxtExtract.SignRecipe.SigRef

  @terminal_reasons SignRecipe.terminal_reasons()

  @type transform :: %{required(String.t()) => String.t()}

  @doc """
  Derive the `pre_sign_transforms` list for a sign_recipe, or `nil` on
  terminal short-circuit.
  """
  @spec derive([map()] | term(), [String.t()], [tuple()], String.t() | nil) :: [transform()] | nil
  def derive(_body_stmts, _sig_names, _crypto_fps, reason) when reason in @terminal_reasons, do: nil

  def derive(body_stmts, sig_names, crypto_fps, _reason) when is_list(body_stmts) do
    sig_ctx = {sig_names, crypto_fps}

    digest_transforms(body_stmts, sig_ctx) ++
      body_encoding_transforms(body_stmts, sig_ctx) ++
      post_signature_transforms(body_stmts, sig_ctx)
  end

  def derive(_, _, _, _), do: nil

  # --- Digest detection (primary) ---------------------------------------------

  # Walk the body for signature-producing hmac calls and extract their 4th
  # argument (the digest). A call is "signature-producing" if its fingerprint
  # is in crypto_fps AND either:
  #   (a) it is bound to an identifier in sig_names (canonical binding), OR
  #   (b) no sig_names exist but the call is directly placed via e.g.
  #       headers['X-SIGN'] = this.hmac(...) (phemex-style inline).
  # If all surviving calls agree on digest → emit; disagreement → skip.
  defp digest_transforms(body_stmts, {sig_names, crypto_fps}) do
    sig_hmac_calls = collect_signature_hmac_calls(body_stmts, sig_names, crypto_fps)

    sig_hmac_calls
    |> Enum.map(&digest_op_for/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [single_op] -> [%{"op" => single_op, "target" => "signature"}]
      # Zero matches OR disagreement across sig-producing calls → honest
      # "don't emit a digest entry". Other transforms still emit.
      _ -> []
    end
  end

  # Collect hmac CallExpression nodes whose byte-fingerprint is in crypto_fps
  # AND which are bound to a name in sig_names (or used inline when sig_names
  # is empty).
  @spec collect_signature_hmac_calls([map()], [String.t()], [tuple()]) :: [map()]
  defp collect_signature_hmac_calls(body_stmts, sig_names, crypto_fps) do
    all_hmac = collect_hmac_calls(body_stmts)

    sig_bound =
      body_stmts
      |> ASTHelpers.collect_bindings()
      |> Enum.filter(fn {name, init} ->
        name in sig_names and SigRef.fingerprint(init) in crypto_fps and hmac_call?(init)
      end)
      |> Enum.map(fn {_name, init} -> init end)

    if sig_bound == [] do
      # Inline (no binding) case: fall back to every hmac call in crypto_fps.
      # Handles phemex-style `headers['X-SIGN'] = this.hmac(...)` and similar.
      Enum.filter(all_hmac, fn node -> SigRef.fingerprint(node) in crypto_fps end)
    else
      sig_bound
    end
  end

  # Walk AST collecting `this.hmac(...)` CallExpression nodes. Distinct from
  # Derive.collect_crypto_calls/1 (private, also collects ed25519/rsa/etc.) —
  # digest detection is hmac-specific.
  defp collect_hmac_calls(node), do: walk_collect(node, &hmac_call?/1)

  defp hmac_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "hmac"}
         }
       }), do: true

  defp hmac_call?(_), do: false

  # Extract the digest op from an hmac CallExpression's 4th argument.
  # Default (3 or fewer args) is `"hex_encode"` per CCXT's defaultHmacBase`hex`.
  defp digest_op_for(%{"type" => "CallExpression", "arguments" => args}) do
    case Enum.at(args, 3) do
      nil ->
        "hex_encode"

      %{"type" => "Literal", "value" => "hex"} ->
        "hex_encode"

      %{"type" => "Literal", "value" => "base64"} ->
        "base64_encode"

      # Non-literal digest (Identifier, MemberExpression) — honestly skip.
      # TODO: resolve non-literal digest identifiers (Identifier /
      # MemberExpression) through local bindings. Until a priority
      # exchange surfaces that pattern, skipping is the honest answer
      # under the Three-Strikes Rule.
      _ ->
        nil
    end
  end

  defp digest_op_for(_), do: nil

  # --- Body encoding detection ------------------------------------------------

  # Look for `body = this.json(...)` / `body = JSON.stringify(...)` bindings or
  # reassignments where the resulting `body` identifier is subsequently
  # referenced by a crypto call (meaning the JSON-encoded body enters the
  # signed payload). Emits `{json_encode, body}` at most once even if multiple
  # reassignments exist.
  defp body_encoding_transforms(body_stmts, {_sig_names, crypto_fps}) do
    has_body_json = has_body_json_encoding?(body_stmts)
    body_referenced_by_crypto = body_reached_by_crypto?(body_stmts, crypto_fps)

    if has_body_json and body_referenced_by_crypto do
      [%{"op" => "json_encode", "target" => "body"}]
    else
      []
    end
  end

  # `const body = this.json(...)` | `body = this.json(...)` | `= JSON.stringify(...)`.
  defp has_body_json_encoding?(node) when is_map(node) do
    case node do
      %{
        "type" => "VariableDeclarator",
        "id" => %{"type" => "Identifier", "name" => "body"},
        "init" => init
      }
      when not is_nil(init) ->
        json_encoder_call?(init) or descend_body_json(node)

      %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => %{"type" => "Identifier", "name" => "body"},
        "right" => rhs
      } ->
        json_encoder_call?(rhs) or descend_body_json(node)

      _ ->
        descend_body_json(node)
    end
  end

  defp has_body_json_encoding?(nodes) when is_list(nodes), do: Enum.any?(nodes, &has_body_json_encoding?/1)

  defp has_body_json_encoding?(_), do: false

  # descend_body_json/1 is only ever reached from has_body_json_encoding?/1's
  # `is_map(node)` branch — the guard is redundant but kept for local
  # defensibility. No catch-all clause: dialyzer proved it's unreachable.
  defp descend_body_json(node) when is_map(node), do: node |> Map.values() |> Enum.any?(&has_body_json_encoding?/1)

  # this.json(...) — CCXT's canonical body JSON-encoder.
  defp json_encoder_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "json"}
         }
       }), do: true

  # JSON.stringify(...) — raw JS fallback.
  defp json_encoder_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "Identifier", "name" => "JSON"},
           "property" => %{"type" => "Identifier", "name" => "stringify"}
         }
       }), do: true

  defp json_encoder_call?(_), do: false

  # Is there a crypto call (by fingerprint) that *reaches* the `body`
  # identifier — either directly in its args or one alias-hop away?
  #
  # 1-hop covers the okx pattern:
  #   body = this.json(query); auth += body; this.hmac(this.encode(auth), …)
  # Here the crypto call references `auth`, not `body`. We follow `auth`'s
  # local bindings/reassignments one level and check if any of them
  # reference `body` (or `this.json(...)` directly, since some sign() bodies
  # build the JSON directly into the alias without a separate `body =` step).
  #
  # Bounded to a single hop on purpose — broader concat-chain resolution
  # (multi-hop, fixed-point) is tracked under Maintenance Backlog Task 128.
  defp body_reached_by_crypto?(body_stmts, crypto_fps) do
    body_stmts
    |> collect_all_calls()
    |> Enum.any?(fn node ->
      SigRef.fingerprint(node) in crypto_fps and crypto_call_reaches_body?(node, body_stmts)
    end)
  end

  defp crypto_call_reaches_body?(crypto_call, body_stmts) do
    has_body_ident?(crypto_call) or
      crypto_call
      |> identifier_names_in()
      |> Enum.any?(&name_alias_reaches_body?(&1, body_stmts))
  end

  # An identifier `name` reaches body if any of its 1-hop bindings/
  # reassignments contain `body` or `this.json(...)` somewhere in the RHS.
  defp name_alias_reaches_body?("body", _body_stmts), do: true

  defp name_alias_reaches_body?(name, body_stmts) do
    body_stmts
    |> assignments_to(name)
    |> Enum.any?(&references_body_or_json?/1)
  end

  # Collect every RHS expression that gets assigned to `name`, whether by
  # `let/const/var name = …` (VariableDeclarator) or by `name = …` /
  # `name += …` / etc. (AssignmentExpression). One-pass walk; result order
  # is depth-first pre-order over the AST map's values.
  defp assignments_to(node, name) when is_map(node) do
    own =
      case node do
        %{
          "type" => "VariableDeclarator",
          "id" => %{"type" => "Identifier", "name" => ^name},
          "init" => init
        }
        when not is_nil(init) ->
          [init]

        %{
          "type" => "AssignmentExpression",
          "left" => %{"type" => "Identifier", "name" => ^name},
          "right" => rhs
        } ->
          [rhs]

        _ ->
          []
      end

    children = node |> Map.values() |> Enum.flat_map(&assignments_to(&1, name))
    own ++ children
  end

  defp assignments_to(nodes, name) when is_list(nodes), do: Enum.flat_map(nodes, &assignments_to(&1, name))

  defp assignments_to(_, _), do: []

  # Does this AST term contain a `body` identifier or a JSON-encoder call
  # (this.json(...) / JSON.stringify(...)) anywhere in its tree?
  defp references_body_or_json?(node) do
    walk_any(node, fn n ->
      match?(%{"type" => "Identifier", "name" => "body"}, n) or json_encoder_call?(n)
    end)
  end

  # All identifier names referenced anywhere in this AST term (including
  # nested calls, member expressions, etc.). De-duplication is the caller's
  # responsibility.
  defp identifier_names_in(node) do
    node
    |> walk_collect(fn n -> match?(%{"type" => "Identifier", "name" => name} when is_binary(name), n) end)
    |> Enum.map(&Map.get(&1, "name"))
  end

  defp collect_all_calls(node), do: walk_collect(node, &(Map.get(&1, "type") == "CallExpression"))

  defp has_body_ident?(node), do: walk_any(node, &match?(%{"type" => "Identifier", "name" => "body"}, &1))

  # --- Generic AST walkers ----------------------------------------------------
  #
  # Half a dozen detectors above answer the same two questions over the AST
  # (depth-first, no zipper, JSON-decoded maps with string keys):
  #
  #   * "Does any descendant satisfy this predicate?"  → walk_any/2
  #   * "Collect every descendant that satisfies this predicate"  → walk_collect/2
  #
  # Predicates only ever see *maps* — list and leaf nodes are dispatched by
  # the walker itself. Helpers like `assignments_to/2` keep direct recursion
  # because their match→extract logic is heterogeneous (declarator → init,
  # assignment → right) and doesn't fit a uniform "node-or-not" predicate.
  @spec walk_any(term(), (map() -> boolean())) :: boolean()
  defp walk_any(node, pred) when is_map(node) do
    pred.(node) or node |> Map.values() |> Enum.any?(&walk_any(&1, pred))
  end

  defp walk_any(nodes, pred) when is_list(nodes), do: Enum.any?(nodes, &walk_any(&1, pred))

  defp walk_any(_, _), do: false

  @spec walk_collect(term(), (map() -> boolean())) :: [map()]
  defp walk_collect(node, pred) when is_map(node) do
    own = if pred.(node), do: [node], else: []
    children = node |> Map.values() |> Enum.flat_map(&walk_collect(&1, pred))
    own ++ children
  end

  defp walk_collect(nodes, pred) when is_list(nodes), do: Enum.flat_map(nodes, &walk_collect(&1, pred))

  defp walk_collect(_, _), do: []

  # --- Post-signature transforms ----------------------------------------------

  # Walk body for CallExpressions whose arguments transitively reference the
  # signature. Emit the matching transform for each recognized wrapper, then
  # dedup so a single wrapper shape produces one entry regardless of how many
  # times it appears.
  defp post_signature_transforms(body_stmts, sig_ctx) do
    body_stmts
    |> collect_post_sig_transforms(sig_ctx)
    |> Enum.uniq()
  end

  defp collect_post_sig_transforms(node, sig_ctx) when is_map(node) do
    own = node |> post_sig_transform_for(sig_ctx) |> List.wrap()
    children = node |> Map.values() |> Enum.flat_map(&collect_post_sig_transforms(&1, sig_ctx))
    own ++ children
  end

  defp collect_post_sig_transforms(nodes, sig_ctx) when is_list(nodes),
    do: Enum.flat_map(nodes, &collect_post_sig_transforms(&1, sig_ctx))

  defp collect_post_sig_transforms(_, _), do: []

  # this.urlencode({K: sig, ...}) — htx-style signature goes into URL query.
  defp post_sig_transform_for(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "urlencode"}
           },
           "arguments" => [%{"type" => "ObjectExpression", "properties" => props} | _]
         },
         sig_ctx
       )
       when is_list(props) do
    if Enum.any?(props, fn p -> SigRef.has?(Map.get(p, "value"), sig_ctx) end),
      do: %{"op" => "url_encode", "target" => "signature"}
  end

  # this.encodeURIComponent(<sig-expr>) — binance RSA/EdDSA-style.
  defp post_sig_transform_for(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "encodeURIComponent"}
           },
           "arguments" => [arg | _]
         },
         sig_ctx
       ) do
    if SigRef.has?(arg, sig_ctx),
      do: %{"op" => "url_encode", "target" => "signature"}
  end

  # Bare-callee encodeURIComponent(<sig-expr>) — global form.
  defp post_sig_transform_for(
         %{
           "type" => "CallExpression",
           "callee" => %{"type" => "Identifier", "name" => "encodeURIComponent"},
           "arguments" => [arg | _]
         },
         sig_ctx
       ) do
    if SigRef.has?(arg, sig_ctx),
      do: %{"op" => "url_encode", "target" => "signature"}
  end

  # sig.toLowerCase() — direct method call on a sig identifier.
  defp post_sig_transform_for(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => inner,
             "property" => %{"type" => "Identifier", "name" => "toLowerCase"}
           },
           "arguments" => []
         },
         sig_ctx
       ) do
    if SigRef.has?(inner, sig_ctx),
      do: %{"op" => "lowercase", "target" => "signature"}
  end

  defp post_sig_transform_for(_, _), do: nil
end
