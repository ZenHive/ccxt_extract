defmodule CcxtExtract.SignRecipe.CanonicalString do
  @moduledoc """
  Task 66a — populate `canonical_string` on every `structure.sign_recipe`
  record as a **per-verb map** of hmac_simple entries.

  # Patch count: 0/3. First patch migrates to priv/overrides/.
  # See ROADMAP.md § Phase 10 "Three-Strikes Rule".

  ## Scope

  For each authenticated section whose sign() builds a plain
  HMAC-over-concatenated-string without referencing the request body,
  emit `%{verb_key => %{family, components, encoding}}` where:

    * `verb_key` — `"GET"`/`"POST"`/`"PUT"`/`"DELETE"`/`"PATCH"` when the
      sign() method branches on `method === 'X'`, or the sentinel `"*"`
      when the canonical string is uniform across all verbs.
    * `family` — always `"hmac_simple"` here. HMAC-with-body entries are
      Task 66b's scope; 66a skips any branch whose `+`-chain references
      `body` / `this.json(...)`.
    * `components` — ordered list of `%{source, value?}` where
      `source ∈ timestamp|api_key|recv_window|method|path|query|body|literal`.
    * `encoding` — currently always `"url_encoded"` (the default for
      `+`-chain concatenation of urlencoded query blobs). `"raw"` and
      `"json"` are reserved for later tasks.

  Returns `nil` when no verb yields a clean hmac_simple decomposition.

  ## Honesty Rule

    * Exchanges whose `crypto_op` is already null with
      `unresolved_reason ∈ {"ambiguous_ast", "custom_signing_family",
      "no_sign_method"}` get `canonical_string: nil` — the ambiguity /
      custom-family tag at the recipe level covers the whole record.
    * Exchanges that use unrepresentable patterns (nested `this.hash`
      pre-transforms, `Array.join` separators, merged-query-via-extend,
      hostname components, random nonce components not in the schema
      vocabulary) get `canonical_string: nil` silently — the null value
      plus `unresolved_reason: "not_yet_derived"` at the recipe level is
      the truthful "Phase 10 hasn't fully landed here yet" signal.

  ## Strategy

  1. **Find the primary HMAC call** — the `this.hmac(arg1, arg2, algo, ...)`
     whose result is bound to the canonical `signature` / `sig` / `sign`
     identifier (already narrowed by `Derive.collect_signature_bindings/2`).

  2. **Peel and resolve `arg1`.** If `arg1 = this.encode(X)`, strip the
     encode wrapper; then if `X` is an `Identifier`, trace the variable's
     declaration + compound-assignment chain.

  3. **Walk verb branches.** Compound-assignments (`auth += '?' + urlencode(q)`)
     inside `IfStatement` whose `test` is `method === 'X'` / `'X' === method`
     emit a per-verb extension to the base chain. The else-branch of a
     single-verb test flips to its complement (GET ↔ POST by convention —
     CCXT sign() methods almost universally branch GET-vs-everything-else).

  4. **Classify each branch's `+`-chain.** Each AST piece maps to one of
     the eight component sources in the schema vocabulary. Consecutive
     literals merge. Any unrecognized piece aborts the branch (null it).
     Any branch containing a `body` component is 66b's scope and gets
     dropped (not nulled — dropped from the per-verb map, so other verbs
     can still ship).

  5. **Emit the per-verb map.** At least one verb must survive; otherwise
     `canonical_string` stays `nil`.

  ## What 66a does NOT attempt (truthful deferrals)

    * `Array.join(\"\\n\")` — Gate's `payloadArray.join`, Deribit's
      newline-separated chain, HTX's `[method, hostname, path, query].join`.
      Requires a `encoding: \"delimited\"` mode plus separator-awareness;
      unlocks Task 66e.
    * `this.hash(encode(body))` pre-transforms — Kraken (binaryConcat +
      SHA256 of nonce+body before HMAC), Gate (SHA512 of body as a
      component). Requires a nested-op component source; unlocks Task 66e.
    * `this.extend({timestamp: ...}, params)` merged-query patterns —
      Binance, HTX legacy. The HMAC input is one urlencode'd blob whose
      semantic decomposition (timestamp + api_key + params) is lost in
      the final `CallExpression`. Requires a merged-query analysis pass;
      unlocks Task 66f.
    * RSA/HMAC conditional branches by key-format (Binance, Bybit). These
      already emit `crypto_op: nil` + `unresolved_reason: \"ambiguous_ast\"`
      at Task 65 — we respect that tag and skip canonical_string derivation
      entirely. Unlocks Task 66f.
  """

  @type verb_key :: String.t()
  @type component :: %{required(String.t()) => term()}
  @type canonical_record :: %{required(String.t()) => term()}

  @verb_keys ~w(GET POST PUT DELETE PATCH)

  # Reasons that short-circuit derivation — the recipe as a whole is already
  # tagged terminal at Task 65, so no canonical_string is possible.
  @terminal_reasons ~w(ambiguous_ast custom_signing_family no_sign_method)

  @doc """
  Derive the per-verb `canonical_string` map from a sign() method body
  and the Task 65 intermediate state.

    * `body_stmts` — the flat list from `sign_method["body"]["body"]`.
    * `crypto_calls` — `[{algo, call_node}, ...]` from
      `Derive.collect_crypto_calls/1`. Used only to confirm the HMAC call
      exists and to correlate signature bindings.
    * `signature_names` — `[String.t()]` from
      `Derive.collect_signature_bindings/2`. The binding whose init is
      our primary HMAC call lives under one of these names.
    * `unresolved_reason` — the recipe-level reason computed by
      `Derive.compute_unresolved_reason/2`. Short-circuits on terminal
      reasons (ambiguous_ast / custom_signing_family / no_sign_method).

  Returns `%{verb_key => record}` with at least one entry, or `nil`.
  """
  @spec derive([map()], [{term(), map()}], [String.t()], String.t() | nil) :: map() | nil
  def derive(_body_stmts, _crypto_calls, _signature_names, reason) when reason in @terminal_reasons, do: nil

  def derive(body_stmts, _crypto_calls, signature_names, _reason) when is_list(body_stmts) do
    with hmac_call when not is_nil(hmac_call) <- find_primary_hmac(body_stmts, signature_names),
         [_ | _] = verb_branches <- resolve_arg(hmac_call, body_stmts) do
      # Names directly reassigned somewhere in the body. Any piece referencing
      # these is dynamic per code path — treat as unclassifiable. This is what
      # keeps kucoin's `let endpart = ''` (overwritten to `this.json(query)` for
      # POST/PUT) and coinbaseexchange's `let payload = ''` (overwritten to
      # body for non-GET) from masquerading as a stable literal/path tag.
      reassigned = reassigned_names(body_stmts)

      # Bindings map used to substitute local-const identifiers during
      # piece classification (e.g. OKX's `const urlencodedQuery = '?' + urlencode(query)`).
      # Reassigned names and the signature bindings themselves are excluded.
      bindings = bindings_map(body_stmts, signature_names, reassigned)

      entries =
        verb_branches
        |> Enum.map(&classify_branch(&1, bindings, reassigned))
        |> Enum.reject(&is_nil/1)

      case entries do
        [] -> nil
        _ -> Map.new(entries)
      end
    else
      _ -> nil
    end
  end

  def derive(_, _, _, _), do: nil

  # Build a %{name => init_expr} map for local-const substitution at classify
  # time. Excludes:
  #   * signature bindings (those wrap this.hmac and must not be substituted
  #     back into the canonical-string)
  #   * names with any direct reassignment (`NAME = ...`) elsewhere in the
  #     body — their initial value does not represent the value at hmac
  #     time, so expanding would produce a wrong canonical string for at
  #     least one verb
  @spec bindings_map([map()], [String.t()], [String.t()]) :: map()
  defp bindings_map(body_stmts, signature_names, reassigned) do
    body_stmts
    |> collect_bindings()
    |> Enum.reject(fn {name, _init} ->
      name in signature_names or name in reassigned
    end)
    |> Map.new()
  end

  # Collect the set of identifier names that appear as the LHS of a direct
  # assignment (`NAME = RHS`, operator "=") anywhere in the body. These
  # names are dynamic — their value at hmac-time depends on code path — and
  # must not be substituted or classified as stable-source identifiers.
  # Plain list rather than MapSet — the set is small (<20 names per sign())
  # and Dialyzer's opaque-type enforcement on MapSet adds noise without
  # any measurable benefit at this size.
  @spec reassigned_names([map()]) :: [String.t()]
  defp reassigned_names(body_stmts) do
    body_stmts
    |> collect_reassignments([])
    |> Enum.uniq()
  end

  defp collect_reassignments(node, acc) when is_map(node) do
    acc =
      case node do
        %{
          "type" => "AssignmentExpression",
          "operator" => "=",
          "left" => %{"type" => "Identifier", "name" => name}
        } ->
          [name | acc]

        _ ->
          acc
      end

    Enum.reduce(Map.values(node), acc, &collect_reassignments/2)
  end

  defp collect_reassignments(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_reassignments/2)
  end

  defp collect_reassignments(_, acc), do: acc

  # --- HMAC call location ---

  # The primary HMAC call is the one whose result is bound to one of the
  # canonical signature names (already narrowed by Task 65). We walk the body
  # for VariableDeclarator nodes with matching names and return the init expr
  # if it's a this.hmac(...) call.
  defp find_primary_hmac(body_stmts, signature_names) do
    body_stmts
    |> collect_bindings()
    |> Enum.find_value(fn {name, init} ->
      if name in signature_names and hmac_call?(init), do: init
    end)
  end

  defp hmac_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "hmac"}
         }
       }), do: true

  defp hmac_call?(_), do: false

  # --- Argument resolution ---

  # hmac_call.arguments[0] is the canonical-string expression. Peel
  # `this.encode(...)` and dispatch on shape.
  defp resolve_arg(%{"arguments" => [arg | _]}, body_stmts) do
    resolve_expr(peel_encode(arg), body_stmts)
  end

  defp resolve_arg(_, _), do: nil

  # `this.encode(x)` → `x`; other → unchanged.
  defp peel_encode(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "encode"}
         },
         "arguments" => [inner | _]
       }), do: inner

  defp peel_encode(other), do: other

  # Identifier — trace the variable's declaration + reassignments.
  defp resolve_expr(%{"type" => "Identifier", "name" => name}, body_stmts) do
    trace_variable(name, body_stmts)
  end

  # Direct inline `+`-chain — emit single "*" entry.
  defp resolve_expr(expr, _body_stmts) do
    [{"*", flatten_plus_chain(expr)}]
  end

  # Trace `let NAME = ...` + all `NAME += ...` assignments. Returns list of
  # `{verb, pieces_ast_list}` or nil if the variable can't be cleanly tracked
  # (e.g. direct reassignment via `NAME = ...` in the middle).
  defp trace_variable(name, body_stmts) do
    with %{} = init <- find_initial_init(body_stmts, name),
         false <- any_direct_reassign_after_init?(body_stmts, name) do
      init_pieces = flatten_plus_chain(init)
      updates = collect_compound_assigns(body_stmts, name)
      build_verb_entries(init_pieces, updates)
    else
      _ -> nil
    end
  end

  # Find the first `VariableDeclarator` for `name` with a non-nil init.
  defp find_initial_init(node, name) do
    find_var_decl_init(node, name)
  end

  defp find_var_decl_init(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => n}, "init" => init},
         n
       )
       when not is_nil(init), do: init

  defp find_var_decl_init(node, name) when is_map(node) do
    Enum.find_value(Map.values(node), &find_var_decl_init(&1, name))
  end

  defp find_var_decl_init(nodes, name) when is_list(nodes) do
    Enum.find_value(nodes, &find_var_decl_init(&1, name))
  end

  defp find_var_decl_init(_, _), do: nil

  # Reject tracking when there's a direct `NAME = RHS` (operator "=") somewhere
  # beyond the initial VariableDeclarator — that means the chain is broken and
  # we can't reliably reconstruct.
  defp any_direct_reassign_after_init?(node, name) when is_map(node) do
    case node do
      %{
        "type" => "AssignmentExpression",
        "operator" => "=",
        "left" => %{"type" => "Identifier", "name" => ^name}
      } ->
        true

      _ ->
        Enum.any?(Map.values(node), &any_direct_reassign_after_init?(&1, name))
    end
  end

  defp any_direct_reassign_after_init?(nodes, name) when is_list(nodes) do
    Enum.any?(nodes, &any_direct_reassign_after_init?(&1, name))
  end

  defp any_direct_reassign_after_init?(_, _), do: false

  # Walk the tree collecting `{verb_ctx, appended_pieces}` entries for every
  # `+=` assignment to `name`. Verb context comes from the nearest enclosing
  # `IfStatement` whose test is `method === 'X'` (or cousin forms).
  defp collect_compound_assigns(body, name) do
    body
    |> walk_verb_ctx(name, "*", [])
    |> Enum.reverse()
  end

  defp walk_verb_ctx(%{"type" => "IfStatement"} = node, name, verb_ctx, acc) do
    %{"test" => test, "consequent" => cons, "alternate" => alt} = node

    case extract_method_verb(test) do
      nil ->
        # Not a method-conditional — recurse into children with same verb_ctx.
        recurse_children(node, name, verb_ctx, acc)

      {verb, negated?} ->
        {then_verb, else_verb} =
          if negated?, do: {flip_verb(verb), verb}, else: {verb, flip_verb(verb)}

        acc = walk_verb_ctx(cons, name, then_verb, acc)
        if alt, do: walk_verb_ctx(alt, name, else_verb, acc), else: acc
    end
  end

  defp walk_verb_ctx(
         %{
           "type" => "AssignmentExpression",
           "operator" => "+=",
           "left" => %{"type" => "Identifier", "name" => name},
           "right" => rhs
         } = node,
         name,
         verb_ctx,
         acc
       ) do
    acc = [{verb_ctx, flatten_plus_chain(rhs)} | acc]
    recurse_children(node, name, verb_ctx, acc)
  end

  defp walk_verb_ctx(node, name, verb_ctx, acc) when is_map(node) do
    recurse_children(node, name, verb_ctx, acc)
  end

  defp walk_verb_ctx(nodes, name, verb_ctx, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, fn n, a -> walk_verb_ctx(n, name, verb_ctx, a) end)
  end

  defp walk_verb_ctx(_, _, _, acc), do: acc

  defp recurse_children(node, name, verb_ctx, acc) when is_map(node) do
    Enum.reduce(Map.values(node), acc, fn child, a ->
      walk_verb_ctx(child, name, verb_ctx, a)
    end)
  end

  # `method === 'GET'` / `'GET' === method` / `method !== 'POST'` etc.
  defp extract_method_verb(%{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right})
       when op in ["===", "==", "!==", "!="] do
    negated? = op in ["!==", "!="]

    case {left, right} do
      {%{"type" => "Identifier", "name" => "method"}, %{"type" => "Literal", "value" => v}}
      when is_binary(v) ->
        verb = normalize_verb(v)
        if verb, do: {verb, negated?}

      {%{"type" => "Literal", "value" => v}, %{"type" => "Identifier", "name" => "method"}}
      when is_binary(v) ->
        verb = normalize_verb(v)
        if verb, do: {verb, negated?}

      _ ->
        nil
    end
  end

  defp extract_method_verb(_), do: nil

  defp normalize_verb(v) when is_binary(v) do
    upcase = String.upcase(v)
    if upcase in @verb_keys, do: upcase
  end

  # CCXT sign() methods almost universally branch GET-vs-everything-else; the
  # else-branch of a `method === 'GET'` test is treated as "POST" (the dominant
  # non-GET verb). We accept one misclassification: PUT/DELETE/PATCH endpoints
  # share the "POST" key. This is safe for 66a specifically because the
  # else-branch almost always contains `body` and is dropped from the hmac_simple
  # result anyway — TODO(Task 66b): populate it cleanly once HMAC-with-body
  # derivation distinguishes the individual non-GET verbs.
  defp flip_verb("GET"), do: "POST"
  defp flip_verb("POST"), do: "GET"
  defp flip_verb(_), do: nil

  # Combine init pieces with verb-tagged compound-assignment pieces while
  # preserving source order. `updates` is a list of `{verb_tag, pieces}` in
  # source order (collect_compound_assigns reverses the prepend-accumulator).
  # For each distinct verb observed, we include every "*"-tagged update AND
  # that verb's own updates at their original positions — so a `*` update
  # that appears BEFORE a verb-tagged one in source lands before it in the
  # emitted component list, and likewise for a `*` update that appears AFTER.
  # This matters when a sign() body interleaves unconditional appends with
  # method-conditional appends (dormant on every priority exchange today but
  # produces silently wrong canonical strings under the old group-and-concat
  # composition — see Task 66a review).
  defp build_verb_entries(init_pieces, updates) do
    verbs_seen =
      updates
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [nil, "*"]))

    case verbs_seen do
      [] ->
        all = Enum.flat_map(updates, fn {_verb, pieces} -> pieces end)
        [{"*", init_pieces ++ all}]

      verbs ->
        Enum.map(verbs, fn verb -> {verb, init_pieces ++ pieces_for_verb(updates, verb)} end)
    end
  end

  # Every `*`-tagged update plus this verb's own updates, in source order.
  defp pieces_for_verb(updates, verb) do
    updates
    |> Enum.filter(fn {tag, _} -> tag == "*" or tag == verb end)
    |> Enum.flat_map(fn {_tag, pieces} -> pieces end)
  end

  # --- Branch classification ---

  @spec classify_branch({verb_key(), [map()]}, map(), [String.t()]) ::
          {verb_key(), canonical_record()} | nil
  defp classify_branch({verb, pieces}, bindings, reassigned) do
    case classify_pieces(pieces, bindings, reassigned) do
      :abort ->
        nil

      components ->
        if Enum.any?(components, &body_component?/1) do
          # hmac_with_body — Task 66b's scope.
          nil
        else
          {verb,
           %{
             "family" => "hmac_simple",
             "components" => components,
             "encoding" => "url_encoded"
           }}
        end
    end
  end

  defp body_component?(%{"source" => "body"}), do: true
  defp body_component?(_), do: false

  # Max depth for Identifier → binding substitution during classification.
  # Guards against pathological recursion where `const a = b; const b = a`.
  @substitution_depth 3

  # Returns a component list or the atom :abort if any piece is unrecognized
  # or references a reassigned identifier (dynamic source — honest null).
  @spec classify_pieces([map()], map(), [String.t()]) :: [component()] | :abort
  defp classify_pieces(pieces, bindings, reassigned) do
    # First pass: expand any Identifier whose name is in bindings by
    # substituting the init expression and re-flattening. Capped recursion.
    expanded = Enum.flat_map(pieces, &expand_piece(&1, bindings, 0))

    results = Enum.map(expanded, &classify_piece(&1, reassigned))

    if Enum.any?(results, &(&1 == :skip)) do
      :abort
    else
      results
      |> Enum.map(fn {:ok, c} -> c end)
      |> merge_consecutive_literals()
    end
  end

  # Substitute Identifier → bound init (recursively, capped). Everything else
  # passes through unchanged; returns a flat list of pieces.
  defp expand_piece(_node, _bindings, depth) when depth >= @substitution_depth, do: []

  # Known identifier names by their semantic role. Declared before
  # `expand_piece/3` so we can use `known_identifier?/1` to short-circuit
  # substitution on names that already classify cleanly without peeking
  # into their local-const binding.
  # Note: `nonce` / `nonceString` are NOT in @timestamp_names. A wall-clock
  # timestamp and a per-request nonce are semantically distinct (Deribit
  # canonicalizes both), but the schema's component source vocabulary only
  # has `timestamp`. Tagging nonce as timestamp would produce a consumer-
  # ambiguous recipe (two `timestamp` sources in a row with no way to know
  # which is which). Task 66e is tracked to add `source: "nonce"`.
  @timestamp_names ~w(timestamp timestampString ts)
  @method_names ~w(method methodUpper)
  @path_names ~w(path requestPath endpoint url request savedPath signaturePath payload)
  @query_names ~w(query queryString queryEncoded rawQueryString)
  @body_names ~w(body bodyPayload)
  @recv_window_names ~w(recvWindow recv_window recvWindowString)
  @known_names @timestamp_names ++
                 @method_names ++
                 @path_names ++ @query_names ++ @body_names ++ @recv_window_names

  defp expand_piece(%{"type" => "Identifier", "name" => n} = node, bindings, depth) do
    # Already a known name — classify it directly rather than peeking into
    # its binding. Peeking often reveals nested this.implodeParams(...)
    # or this.version-style pieces we can't classify; meanwhile the name
    # itself ("request", "path", "query") has a clean source tag. This is
    # the load-bearing semantic abstraction — consumers care about
    # "source: path", not about how `path` was computed upstream.
    if n in @known_names do
      [node]
    else
      case Map.get(bindings, n) do
        nil ->
          [node]

        init ->
          init
          |> flatten_plus_chain()
          |> Enum.flat_map(&expand_piece(&1, bindings, depth + 1))
      end
    end
  end

  defp expand_piece(node, _bindings, _depth), do: [node]

  # Merge adjacent literal components (e.g. `'&' + 'signature='` → `&signature=`).
  defp merge_consecutive_literals([]), do: []

  defp merge_consecutive_literals([
         %{"source" => "literal", "value" => v1} = a,
         %{"source" => "literal", "value" => v2} | rest
       ])
       when is_binary(v1) and is_binary(v2) do
    merge_consecutive_literals([Map.put(a, "value", v1 <> v2) | rest])
  end

  defp merge_consecutive_literals([h | t]), do: [h | merge_consecutive_literals(t)]

  # --- Piece classification ---
  #
  # classify_piece/2 takes `reassigned` (list of dynamically-reassigned
  # identifier names) and returns either `{:ok, component}` or `:skip`.
  # An Identifier whose name is in `reassigned` returns `:skip` regardless
  # of how well it matches the known-name tables — its value at hmac-time
  # is dynamic and any stable source tag would be a lie.

  @spec classify_piece(map(), [String.t()]) :: {:ok, component()} | :skip
  defp classify_piece(%{"type" => "Identifier", "name" => n}, reassigned) do
    cond do
      n in reassigned -> :skip
      n in @timestamp_names -> {:ok, %{"source" => "timestamp"}}
      n in @method_names -> {:ok, %{"source" => "method"}}
      n in @path_names -> {:ok, %{"source" => "path"}}
      n in @query_names -> {:ok, %{"source" => "query"}}
      n in @body_names -> {:ok, %{"source" => "body"}}
      n in @recv_window_names -> {:ok, %{"source" => "recv_window"}}
      true -> :skip
    end
  end

  # this.apiKey (property access, not call)
  defp classify_piece(
         %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "apiKey"}
         },
         _reassigned
       ), do: {:ok, %{"source" => "api_key"}}

  # this.milliseconds() / this.iso8601(...) / this.urlencode(...) / this.json(...)
  defp classify_piece(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => fn_name}
           }
         },
         _reassigned
       ) do
    cond do
      fn_name in ~w(milliseconds seconds microseconds nanoseconds iso8601 nonce numberToString) ->
        {:ok, %{"source" => "timestamp"}}

      fn_name in ~w(urlencode rawencode urlencodeNested urlencodeWithArrayRepeat) ->
        {:ok, %{"source" => "query"}}

      fn_name == "json" ->
        {:ok, %{"source" => "body"}}

      true ->
        :skip
    end
  end

  # method.toUpperCase() / method.toLowerCase()
  defp classify_piece(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "Identifier", "name" => "method"},
             "property" => %{"type" => "Identifier", "name" => fn_name}
           }
         },
         _reassigned
       )
       when fn_name in ["toUpperCase", "toLowerCase"], do: {:ok, %{"source" => "method"}}

  # String literal
  defp classify_piece(%{"type" => "Literal", "value" => v}, _reassigned) when is_binary(v),
    do: {:ok, %{"source" => "literal", "value" => v}}

  defp classify_piece(_, _reassigned), do: :skip

  # --- Generic AST helpers (local to 66a; Derive has parallel versions
  # we intentionally don't import to keep modules decoupled) ---

  # Walk the tree collecting `{name, init_expr}` pairs from every
  # `VariableDeclarator` with non-nil init. Duplicate names keep the first
  # (innermost-first traversal is fine — we only use it for signature-binding
  # lookup and initial-init lookup, both of which want the canonical binding).
  defp collect_bindings(node) when is_map(node) do
    own =
      case node do
        %{"type" => "VariableDeclaration", "declarations" => decls} when is_list(decls) ->
          Enum.flat_map(decls, fn
            %{
              "type" => "VariableDeclarator",
              "id" => %{"type" => "Identifier", "name" => name},
              "init" => init
            }
            when not is_nil(init) ->
              [{name, init}]

            _ ->
              []
          end)

        _ ->
          []
      end

    children = node |> Map.values() |> Enum.flat_map(&collect_bindings/1)
    own ++ children
  end

  defp collect_bindings(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_bindings/1)
  defp collect_bindings(_), do: []

  defp flatten_plus_chain(%{"type" => "BinaryExpression", "operator" => "+", "left" => l, "right" => r}) do
    flatten_plus_chain(l) ++ flatten_plus_chain(r)
  end

  defp flatten_plus_chain(node), do: [node]
end
