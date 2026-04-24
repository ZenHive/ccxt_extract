defmodule CcxtExtract.SignRecipe.Derive do
  @moduledoc """
  Orchestrator for `structure.sign_recipe` derivation. Populates every
  field except `pre_sign_transforms` (Task 68 territory).

  # Patch count: 0/3. First patch migrates to priv/overrides/.
  # See ROADMAP.md § Phase 10 "Three-Strikes Rule".

  ## Scope

    * `crypto_op` — HMAC algorithm / Ed25519 / RSA / custom. (Task 65)
    * `signature_placement` — where the signature attaches (header /
      query / body) and under which key. (Task 65)
    * `canonical_string` — per-verb map of HMAC-input decompositions.
      (Tasks 66a + 66b, delegated to `CanonicalString.derive/4`)
    * `auth_headers` — ordered list of non-signature auth headers the
      consumer attaches. (Task 67, delegated to `AuthHeaders.derive/4`)
    * `nonce` — timestamp / nonce `{source, format}` classification.
      (Task 67, delegated to `Nonce.derive/2`)

  `pre_sign_transforms` stays `null` — Task 68 populates it.
  `unresolved_reason` stays `"not_yet_derived"` while any derivation
  field remains null; Task 69 flips it to `nil` when everything is filled.

  ## Strategy

  Most exchanges route every authenticated section through the same signing
  code path inside `sign()` — differences between sections live at
  canonical-string level, not at crypto-op / placement level. So this module
  scans the entire sign() body once, determines a single
  `(crypto_op, signature_placement)` contract, and stamps it onto every
  entry in `authenticated_sections`. Per-section divergence at the crypto
  level (if it ever surfaces on a priority exchange) belongs in an override,
  not here.

  ### Crypto op detection

  Match order (first hit wins):

    1. `this.hmac(_, _, <Identifier>, _?)` where `Identifier.name` is
       `"sha256"`, `"sha512"`, or `"sha384"` → `{algo: "hmac_sha*"}`.
    2. Bare-callee `eddsa(_, _, ed25519)` → `{algo: "ed25519"}`.
    3. Bare-callee `rsa(...)` → `{algo: "rsa"}`.
    4. Bare-callee `jwt(...)` → `{algo: "custom", reason: "jwt signing (deferred)"}`.

  If multiple mutually-distinct crypto calls appear (e.g. binance's
  RSA/EdDSA/HMAC conditional branch) → emit `crypto_op: nil` +
  `unresolved_reason: "ambiguous_ast"`.

  If no crypto call is found → emit `crypto_op: nil` +
  `unresolved_reason: "custom_signing_family"` (hyperliquid-style signing
  lives entirely outside `sign()`).

  ### Signature placement detection

  Phase A finds identifiers bound to crypto results (`const signature =
  this.hmac(...)`).

  Phase B scans the body for assignments that consume any such identifier:

    * `headers['K'] = <sig>` or `headers = { 'K': <sig> }`   → header `K`.
    * `query += '&K=' + <sig>` / `'K=' + <sig>` in a `+` chain → query `K`.
    * `body = this.json({..., 'K': <sig>})` or `this.urlencode(...)` → body `K`.

  All detected placements must agree on `(location, key)` for a value to be
  emitted; otherwise `signature_placement` stays `nil` (placement can still
  succeed even when `crypto_op` is ambiguous — the conditional branches in
  binance/coinbase all land the signature in the same query key/header).
  """

  alias CcxtExtract.SignRecipe
  alias CcxtExtract.SignRecipe.ASTHelpers
  alias CcxtExtract.SignRecipe.AuthHeaders
  alias CcxtExtract.SignRecipe.CanonicalString
  alias CcxtExtract.SignRecipe.Nonce
  alias CcxtExtract.SignRecipe.SigRef

  @type derive_note :: nil | String.t()

  @doc """
  Build the `section_name => recipe` map from a sign() method AST and the
  derived `authenticated_sections` list.

  `sign_method` is a MethodAST map (see `CcxtExtract.MethodAST`) or `nil`.
  `auth_sections` is a sorted list of section name strings, `nil`, or `[]`.

  Returns `%{}` when there is nothing to emit. Otherwise returns one
  populated `SignRecipe` record per authenticated section; every section
  shares the same `crypto_op` + `signature_placement` because those
  quantities are determined globally for the sign() method, not
  per-section.
  """
  @spec derive(map() | nil, [String.t()] | nil) :: SignRecipe.recipe_map()
  def derive(_sign_method, nil), do: %{}
  def derive(_sign_method, []), do: %{}
  def derive(nil, auth_sections), do: no_sign_method_recipe(auth_sections)

  def derive(%{"body" => %{"body" => body_stmts}}, auth_sections) when is_list(body_stmts) and is_list(auth_sections) do
    crypto_calls = collect_crypto_calls(body_stmts)
    {crypto_op, crypto_note} = classify_crypto_op(crypto_calls)

    sig_names = collect_signature_bindings(crypto_calls, body_stmts)
    crypto_fps = Enum.map(crypto_calls, fn {_algo, node} -> SigRef.fingerprint(node) end)
    signature_placement = detect_placement(body_stmts, {sig_names, crypto_fps})

    unresolved = compute_unresolved_reason(crypto_op, crypto_note)
    canonical_string = CanonicalString.derive(body_stmts, crypto_calls, sig_names, unresolved)
    auth_headers = AuthHeaders.derive(body_stmts, sig_names, crypto_fps, unresolved)
    nonce = Nonce.derive(body_stmts, unresolved)

    record =
      SignRecipe.null_recipe()
      |> Map.put("crypto_op", crypto_op)
      |> Map.put("signature_placement", signature_placement)
      |> Map.put("canonical_string", canonical_string)
      |> Map.put("auth_headers", auth_headers)
      |> Map.put("nonce", nonce)
      |> Map.put("unresolved_reason", unresolved)

    Map.new(auth_sections, fn section -> {section, record} end)
  end

  def derive(_sign_method, auth_sections), do: no_sign_method_recipe(auth_sections)

  # Sign method present but unparseable shape, OR auth sections present but
  # sign_method absent — Honesty-Rule: tag as such.
  defp no_sign_method_recipe(auth_sections) when is_list(auth_sections) do
    record = Map.put(SignRecipe.null_recipe(), "unresolved_reason", "no_sign_method")
    Map.new(auth_sections, fn section -> {section, record} end)
  end

  defp no_sign_method_recipe(_), do: %{}

  # --- Crypto op detection ---------------------------------------------------

  # Walk the AST collecting CallExpressions that look like crypto invocations.
  # Returns a list of `{algo, call_node}` tuples.
  @spec collect_crypto_calls(term()) :: [{String.t() | :custom_jwt, map()}]
  defp collect_crypto_calls(node) when is_map(node) do
    own =
      case classify_call(node) do
        nil -> []
        algo -> [{algo, node}]
      end

    children =
      node
      |> Map.values()
      |> Enum.flat_map(&collect_crypto_calls/1)

    own ++ children
  end

  defp collect_crypto_calls(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_crypto_calls/1)
  end

  defp collect_crypto_calls(_), do: []

  # `this.hmac(_, _, sha256 | sha512 | sha384, _?)` — HMAC family.
  defp classify_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "hmac"}
         },
         "arguments" => [_, _, %{"type" => "Identifier", "name" => algo_ident} | _]
       }) do
    case algo_ident do
      "sha256" -> "hmac_sha256"
      "sha512" -> "hmac_sha512"
      "sha384" -> "hmac_sha384"
      _ -> nil
    end
  end

  # Bare-callee `eddsa(...)` — Ed25519.
  defp classify_call(%{"type" => "CallExpression", "callee" => %{"type" => "Identifier", "name" => "eddsa"}}),
    do: "ed25519"

  # Bare-callee `rsa(...)`.
  defp classify_call(%{"type" => "CallExpression", "callee" => %{"type" => "Identifier", "name" => "rsa"}}), do: "rsa"

  # TODO(Task 66d): Bare-callee `ecdsa(...)` — currently "custom" (EIP-712
  # style). Revisit under 10-exotic if a priority exchange surfaces it.
  defp classify_call(%{"type" => "CallExpression", "callee" => %{"type" => "Identifier", "name" => "ecdsa"}}),
    do: :custom_ecdsa

  # TODO(Task 66c): Bare-callee `jwt(...)` — deferred to 10-exotic.
  defp classify_call(%{"type" => "CallExpression", "callee" => %{"type" => "Identifier", "name" => "jwt"}}),
    do: :custom_jwt

  defp classify_call(_), do: nil

  # Turn the collected call list into a `{crypto_op_map | nil, note}`:
  #   note is `nil` on success, `"ambiguous"` on multi-algo, `"absent"` when
  #   no crypto call was found, or `"custom"` for jwt-only / ecdsa-only.
  @spec classify_crypto_op([{String.t() | atom(), map()}]) ::
          {map() | nil, derive_note()}
  defp classify_crypto_op([]), do: {nil, "absent"}

  defp classify_crypto_op(calls) do
    algos =
      calls
      |> Enum.map(fn {a, _} -> a end)
      |> Enum.uniq()

    case algos do
      [algo] when algo in ["hmac_sha256", "hmac_sha512", "hmac_sha384", "ed25519", "rsa"] ->
        {%{"algo" => algo}, nil}

      [:custom_jwt] ->
        {%{"algo" => "custom", "reason" => "jwt signing (deferred to Task 66c)"}, "custom"}

      [:custom_ecdsa] ->
        {%{"algo" => "custom", "reason" => "ecdsa signing inside sign() (deferred)"}, "custom"}

      _ ->
        {nil, "ambiguous"}
    end
  end

  # A non-null unresolved_reason means the recipe as a whole is terminal for
  # Task 65's scope (no later task will turn this into a complete record).
  # When Task 65 merely fills two of six fields (crypto_op + placement are
  # populated, others still null), we leave "not_yet_derived" in place —
  # Tasks 66a/66b/67/68 will flip individual nulls; Task 69 sets
  # unresolved_reason to nil when all six are populated.
  defp compute_unresolved_reason(_crypto_op, "absent"), do: "custom_signing_family"
  defp compute_unresolved_reason(_crypto_op, "ambiguous"), do: "ambiguous_ast"
  defp compute_unresolved_reason(_crypto_op, "custom"), do: "custom_signing_family"
  defp compute_unresolved_reason(_crypto_op, nil), do: "not_yet_derived"

  # --- Signature placement detection ----------------------------------------

  # Find every `const/let/var NAME = <crypto_call>` binding where the init
  # expression is one of the crypto calls we already classified. If any of
  # those bindings uses the canonical CCXT name (`signature` / `sig` /
  # `sign`), narrow to just those — this avoids false placements on
  # secondary bindings (e.g. kucoin's `passphrase = this.hmac(...)` and
  # `partnerSignature = this.hmac(...)` alongside the real `signature`
  # binding). Returns a list of identifier names.
  @spec collect_signature_bindings([{term(), map()}], list()) :: [String.t()]
  defp collect_signature_bindings(crypto_calls, body_stmts) do
    call_fingerprints = Enum.map(crypto_calls, fn {_algo, node} -> SigRef.fingerprint(node) end)

    crypto_bound =
      body_stmts
      |> ASTHelpers.collect_bindings()
      |> Enum.filter(fn {_name, init} -> SigRef.fingerprint(init) in call_fingerprints end)
      |> Enum.map(fn {name, _init} -> name end)
      |> Enum.uniq()

    canonical = Enum.filter(crypto_bound, &canonical_signature_name?/1)

    case canonical do
      [] -> crypto_bound
      names -> names
    end
  end

  @canonical_signature_names ~w(signature sig sign)

  defp canonical_signature_name?(name) when is_binary(name), do: name in @canonical_signature_names

  defp canonical_signature_name?(_), do: false

  # Scan the body for assignments of `sig_names` members into headers, query,
  # or body. Returns a single placement map or nil if nothing conclusive.
  @spec detect_placement(list(), {[String.t()], [tuple()]}) :: map() | nil
  defp detect_placement(body_stmts, {names, fps} = sig_ctx) do
    if names == [] and fps == [] do
      nil
    else
      placements =
        body_stmts
        |> collect_placements(sig_ctx)
        |> Enum.uniq()

      case placements do
        [single] -> single
        _ -> nil
      end
    end
  end

  # Walk the tree, emit `%{"location" => _, "key" => _}` on every placement hit.
  defp collect_placements(node, sig_names) when is_map(node) do
    own = placement_for(node, sig_names)

    children =
      node
      |> Map.values()
      |> Enum.flat_map(&collect_placements(&1, sig_names))

    List.wrap(own) ++ children
  end

  defp collect_placements(nodes, sig_names) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_placements(&1, sig_names))
  end

  defp collect_placements(_, _), do: []

  # `headers['K'] = <any RHS containing sig>` — computed member assignment.
  # The key is the Literal on the LHS; the RHS may be a direct Identifier,
  # a `'prefix=' + sig + ',...'` chain, or anything that transitively
  # references one of the signature identifiers.
  defp placement_for(
         %{
           "type" => "AssignmentExpression",
           "operator" => "=",
           "left" => %{
             "type" => "MemberExpression",
             "computed" => true,
             "object" => %{"type" => "Identifier", "name" => "headers"},
             "property" => %{"type" => "Literal", "value" => key}
           },
           "right" => rhs
         },
         sig_names
       )
       when is_binary(key) do
    if SigRef.has?(rhs, sig_names),
      do: %{"location" => "header", "key" => key}
  end

  # `headers.K = <any RHS containing sig>` — static member assignment.
  defp placement_for(
         %{
           "type" => "AssignmentExpression",
           "operator" => "=",
           "left" => %{
             "type" => "MemberExpression",
             "computed" => false,
             "object" => %{"type" => "Identifier", "name" => "headers"},
             "property" => %{"type" => "Identifier", "name" => key}
           },
           "right" => rhs
         },
         sig_names
       )
       when is_binary(key) do
    if SigRef.has?(rhs, sig_names),
      do: %{"location" => "header", "key" => key}
  end

  # `headers = { 'K': <value containing sig>, ... }` (ObjectExpression on RHS,
  # property value may be Identifier, BinaryExpression chain, etc).
  # Also handles `headers = cond ? A : B` by recursing into both branches
  # and returning any agreeing placement.
  defp placement_for(
         %{
           "type" => "AssignmentExpression",
           "operator" => "=",
           "left" => %{"type" => "Identifier", "name" => "headers"},
           "right" => rhs
         },
         sig_names
       ) do
    rhs_header_placement(rhs, sig_names)
  end

  # `const headers = { 'K': <value containing sig>, ... }` — variable init.
  defp placement_for(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => "headers"}, "init" => init},
         sig_names
       )
       when not is_nil(init) do
    rhs_header_placement(init, sig_names)
  end

  # `query = <chain>` / `query += <chain>` / `url = <chain>` / `url += <chain>`.
  # Walk the RHS chain looking for `"K="` literals adjacent to sig refs.
  defp placement_for(
         %{
           "type" => "AssignmentExpression",
           "operator" => op,
           "left" => %{"type" => "Identifier", "name" => target},
           "right" => rhs
         },
         sig_names
       )
       when op in ["=", "+="] and target in ["query", "url"] do
    chain_query_placement(rhs, sig_names)
  end

  # `body = this.json({..., 'K': signature})` / `this.urlencode(...)`.
  defp placement_for(
         %{
           "type" => "AssignmentExpression",
           "operator" => "=",
           "left" => %{"type" => "Identifier", "name" => "body"},
           "right" => %{
             "type" => "CallExpression",
             "callee" => %{
               "type" => "MemberExpression",
               "object" => %{"type" => "ThisExpression"},
               "property" => %{"type" => "Identifier", "name" => encoder}
             },
             "arguments" => [%{"type" => "ObjectExpression", "properties" => props} | _]
           }
         },
         sig_names
       )
       when encoder in ["json", "urlencode"] and is_list(props) do
    find_prop_with_sig(props, sig_names, "body")
  end

  defp placement_for(_, _), do: nil

  # Recurse through ObjectExpression / ConditionalExpression to find a
  # header property whose value transitively references the signature.
  defp rhs_header_placement(%{"type" => "ObjectExpression", "properties" => props}, sig_names) when is_list(props) do
    find_prop_with_sig(props, sig_names, "header")
  end

  defp rhs_header_placement(%{"type" => "ConditionalExpression", "consequent" => c, "alternate" => a}, sig_names) do
    rhs_header_placement(c, sig_names) || rhs_header_placement(a, sig_names)
  end

  defp rhs_header_placement(_, _), do: nil

  # Scan ObjectExpression properties for the first whose value references one
  # of the signature identifiers. Returns `%{"location" => location, "key"
  # => K}` or nil. `location` is "header" or "body" depending on caller.
  defp find_prop_with_sig(props, sig_names, location) when is_list(props) do
    Enum.find_value(props, &prop_with_sig(&1, sig_names, location))
  end

  defp prop_with_sig(%{"type" => "Property", "value" => val} = p, sig_names, location) do
    with {:ok, key} <- ASTHelpers.object_prop_key(p),
         true <- SigRef.has?(val, sig_names) do
      %{"location" => location, "key" => key}
    else
      _ -> nil
    end
  end

  defp prop_with_sig(_, _, _), do: nil

  # Walk a `+` chain and return the first query placement formed by a
  # `"K="`-style literal next to a sig reference anywhere in the chain.
  # Only called from `query = ...` / `query += ...` assignment contexts,
  # so header-value chains like deribit's Authorization don't reach here.
  defp chain_query_placement(rhs, sig_names) do
    pieces = ASTHelpers.flatten_plus_chain(rhs)

    if Enum.any?(pieces, &SigRef.has?(&1, sig_names)),
      do: Enum.find_value(pieces, &query_key_placement/1)
  end

  defp query_key_placement(%{"type" => "Literal", "value" => v}) when is_binary(v) do
    case parse_query_key(v) do
      {:ok, key} -> %{"location" => "query", "key" => key}
      :error -> nil
    end
  end

  defp query_key_placement(_), do: nil

  # "signature=" / "&signature=" / "?signature=" → {"ok", "signature"}.
  # A literal that is ONLY "&" or "?" is not a key-carrier → :error.
  defp parse_query_key(v) when is_binary(v) do
    trimmed = v |> String.trim_leading("&") |> String.trim_leading("?")

    case String.split(trimmed, "=", parts: 2) do
      [key, ""] when key != "" -> {:ok, key}
      _ -> :error
    end
  end
end
