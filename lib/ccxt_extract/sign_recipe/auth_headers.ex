defmodule CcxtExtract.SignRecipe.AuthHeaders do
  @moduledoc """
  Task 67 — populate `auth_headers` on every `structure.sign_recipe` record.

  Emits an ordered list of auth-related header entries (excluding the
  signature header itself, which lives in `signature_placement`). Each
  entry has the shape:

    * `%{"name" => K, "source" => S}` for `api_key`, `passphrase`,
      `timestamp`, `recv_window`
    * `%{"name" => K, "source" => "literal", "value" => V}` for literals
      like bybit's `X-BAPI-SIGN-TYPE: "2"` or kucoin's
      `KC-API-KEY-VERSION: "2"`

  The `source` vocabulary is closed by
  `priv/schema/exchange_v4.json#/$defs/SignRecipeAuthHeader`.

  ## Walk strategy

  Scan the `sign()` body for these four shapes (pre-existing patterns
  already used by `Derive.placement_for/2`):

    1. `headers['K'] = RHS` — computed member assignment
    2. `headers.K = RHS` — static member assignment
    3. `headers = { K: RHS, ... }` — ObjectExpression assignment
    4. `const headers = { K: RHS, ... }` — VariableDeclarator

  For each `{key, rhs}` candidate, classify `rhs` against the source
  table in order (first hit wins):

  | Pattern                                          | Emit                               |
  |--------------------------------------------------|------------------------------------|
  | RHS references signature (identifier or call)    | skip entry (already in placement)  |
  | `this.apiKey`                                    | `api_key`                          |
  | `this.password`                                  | `passphrase` (CCXT passphrase slot)|
  | Identifier whose name is a timestamp binding     | `timestamp`                        |
  | `this.safeInteger(this.options, 'recvWindow')`   | `recv_window`                      |
  | `this.options['recvWindow']` (+ optional .toString()) | `recv_window`                 |
  | `this.options.recvWindow`                        | `recv_window`                      |
  | String Literal with no non-literal children      | `literal` + emit `value`           |
  | Anything else                                    | abort — emit `nil` for whole list  |

  `timestamp` names come from `Nonce.timestamp_binding_names/1` so both
  derivations stay in sync.

  ## Well-known non-auth headers are filtered

  `Content-Type`, `Accept`, and `User-Agent` appear in `sign()` bodies of
  many priority exchanges (bybit / binance / gate / coinbaseexchange)
  alongside the auth headers, but they are transport-level concerns, not
  auth. They are filtered from the candidate list at collection time;
  their presence or absence doesn't influence the derivation's success.

  ## `this.options[X]` conditional blocks are skipped

  Kucoin sets optional partner headers inside
  `if (this.options['partner']) { headers['KC-API-PARTNER'] = ... }`.
  Those are opt-in broker integration, not part of the baseline auth set.
  The walker skips IfStatement children whose test matches
  `this.options[X]` or `this.options.X`, so the partner block doesn't
  reach the classifier.

  ## Partial-classification policy

    * Every candidate classifies cleanly → emit the list (may be empty,
      as in deribit / htx where the only header is the signature, or all
      non-signature headers are filtered).
    * Any candidate fails to classify → emit `nil` — consumers can't
      safely construct a request from a partial header set.

  ## Terminal reasons

  Short-circuits to `nil` for `ambiguous_ast`, `custom_signing_family`,
  and `no_sign_method` — identical policy to
  `CanonicalString` and `Nonce`.
  """

  alias CcxtExtract.SignRecipe
  alias CcxtExtract.SignRecipe.ASTHelpers
  alias CcxtExtract.SignRecipe.Nonce
  alias CcxtExtract.SignRecipe.SigRef

  @terminal_reasons SignRecipe.terminal_reasons()

  # NOTE: transport-level headers colocated with auth headers in sign() bodies are
  # filtered at collection time (case-insensitively) so they don't reach the
  # classifier — see the reject below at the candidate-collection site.
  #
  # Known allowlist growth risk: exchanges that add new transport headers
  # (e.g. `x-forwarded-for`, `origin`, `referer`) will cause `:abort` and
  # null out the whole list. When a priority exchange surfaces such a
  # header in sign(), extend this list — don't classify at source level.
  @non_auth_header_names_downcased ~w(content-type accept user-agent)

  @type header :: %{required(String.t()) => String.t()}

  @doc """
  Derive the `auth_headers` list for a sign_recipe, or `nil` if
  derivation can't produce a complete list.
  """
  @spec derive([map()] | term(), [String.t()], [tuple()], String.t() | nil) :: [header()] | nil
  def derive(_body_stmts, _sig_names, _crypto_fps, reason) when reason in @terminal_reasons, do: nil

  def derive(body_stmts, sig_names, crypto_fps, _reason) when is_list(body_stmts) do
    timestamp_names = Nonce.timestamp_binding_names(body_stmts)
    # Reverse-then-Map.new keeps the FIRST declaration of each name (matches
    # JS let-semantics and Nonce's partition_bindings). Enables one-hop
    # Identifier resolution so bindings like `const pp = this.password;` can
    # still classify as passphrase when referenced as a header RHS.
    bindings_map = body_stmts |> ASTHelpers.collect_bindings() |> Enum.reverse() |> Map.new()
    sig_ctx = {sig_names, crypto_fps}

    case classify_all(collect_candidates(body_stmts), sig_ctx, timestamp_names, bindings_map) do
      :abort -> nil
      entries -> entries
    end
  end

  def derive(_, _, _, _), do: nil

  # --- Candidate collection ---

  @spec collect_candidates(term()) :: [{String.t(), map()}]
  defp collect_candidates(%{"type" => "IfStatement", "test" => test} = node) do
    # Skip descending into `if (this.options[X]) { ... }` — those bodies
    # carry opt-in broker/partner headers, not baseline auth.
    if options_predicate?(test) do
      []
    else
      candidates_and_descend(node)
    end
  end

  defp collect_candidates(node) when is_map(node) do
    candidates_and_descend(node)
  end

  defp collect_candidates(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_candidates/1)
  end

  defp collect_candidates(_), do: []

  defp candidates_and_descend(node) do
    own = header_candidates_for(node)
    children = node |> Map.values() |> Enum.flat_map(&collect_candidates/1)
    own ++ children
  end

  # Shape 1: headers['K'] = RHS
  defp header_candidates_for(%{
         "type" => "AssignmentExpression",
         "operator" => "=",
         "left" => %{
           "type" => "MemberExpression",
           "computed" => true,
           "object" => %{"type" => "Identifier", "name" => "headers"},
           "property" => %{"type" => "Literal", "value" => key}
         },
         "right" => rhs
       })
       when is_binary(key) do
    keep_if_auth(key, rhs)
  end

  # Shape 2: headers.K = RHS
  defp header_candidates_for(%{
         "type" => "AssignmentExpression",
         "operator" => "=",
         "left" => %{
           "type" => "MemberExpression",
           "computed" => false,
           "object" => %{"type" => "Identifier", "name" => "headers"},
           "property" => %{"type" => "Identifier", "name" => key}
         },
         "right" => rhs
       })
       when is_binary(key) do
    keep_if_auth(key, rhs)
  end

  # Shape 3: headers = { K: RHS, ... }
  defp header_candidates_for(%{
         "type" => "AssignmentExpression",
         "operator" => "=",
         "left" => %{"type" => "Identifier", "name" => "headers"},
         "right" => %{"type" => "ObjectExpression", "properties" => props}
       })
       when is_list(props) do
    properties_to_candidates(props)
  end

  # Shape 4: const headers = { K: RHS, ... }
  defp header_candidates_for(%{
         "type" => "VariableDeclarator",
         "id" => %{"type" => "Identifier", "name" => "headers"},
         "init" => %{"type" => "ObjectExpression", "properties" => props}
       })
       when is_list(props) do
    properties_to_candidates(props)
  end

  defp header_candidates_for(_), do: []

  defp properties_to_candidates(props) do
    Enum.flat_map(props, fn prop ->
      with {:ok, key} <- ASTHelpers.object_prop_key(prop),
           %{"value" => val} <- prop do
        keep_if_auth(key, val)
      else
        _ -> []
      end
    end)
  end

  defp keep_if_auth(key, rhs) when is_binary(key) do
    if String.downcase(key) in @non_auth_header_names_downcased, do: [], else: [{key, rhs}]
  end

  # --- IfStatement test classifier ---

  # `this.options['X']`
  defp options_predicate?(%{
         "type" => "MemberExpression",
         "computed" => true,
         "object" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "options"}
         },
         "property" => %{"type" => "Literal"}
       }), do: true

  # `this.options.X`
  defp options_predicate?(%{
         "type" => "MemberExpression",
         "computed" => false,
         "object" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "options"}
         },
         "property" => %{"type" => "Identifier"}
       }), do: true

  defp options_predicate?(_), do: false

  # --- Classification ---

  defp classify_all(candidates, sig_ctx, timestamp_names, bindings) do
    candidates
    |> Enum.reduce_while([], fn {key, rhs}, acc ->
      case classify_candidate(key, rhs, sig_ctx, timestamp_names, bindings) do
        :skip_sig -> {:cont, acc}
        {:ok, entry} -> {:cont, [entry | acc]}
        :abort -> {:halt, :abort}
      end
    end)
    |> finalize()
  end

  defp finalize(:abort), do: :abort
  defp finalize(acc) when is_list(acc), do: acc |> Enum.reverse() |> Enum.uniq()

  defp classify_candidate(key, rhs, sig_ctx, timestamp_names, bindings) do
    cond do
      SigRef.has?(rhs, sig_ctx) -> :skip_sig
      api_key_match?(rhs, bindings) -> {:ok, %{"name" => key, "source" => "api_key"}}
      passphrase_match?(rhs, bindings) -> {:ok, %{"name" => key, "source" => "passphrase"}}
      timestamp_ident?(rhs, timestamp_names) -> {:ok, %{"name" => key, "source" => "timestamp"}}
      recv_window_match?(rhs, bindings) -> {:ok, %{"name" => key, "source" => "recv_window"}}
      true -> classify_literal(key, rhs)
    end
  end

  # One-hop binding chain resolution: if RHS is an Identifier, re-check the
  # classifier against its init expression. Catches patterns like
  # `const apiKey = this.apiKey; headers['X-KEY'] = apiKey;` without needing
  # each classifier to know about bindings. Non-Identifier RHS paths through
  # unchanged (resolve_identifier/2 returns nil → classifier returns false).
  defp api_key_match?(rhs, bindings), do: api_key?(rhs) or api_key?(resolve_identifier(rhs, bindings))
  defp passphrase_match?(rhs, bindings), do: passphrase?(rhs) or passphrase?(resolve_identifier(rhs, bindings))
  defp recv_window_match?(rhs, bindings), do: recv_window?(rhs) or recv_window?(resolve_identifier(rhs, bindings))

  defp resolve_identifier(%{"type" => "Identifier", "name" => n}, bindings), do: Map.get(bindings, n)
  defp resolve_identifier(_, _), do: nil

  defp classify_literal(key, %{"type" => "Literal", "value" => v}) when is_binary(v),
    do: {:ok, %{"name" => key, "source" => "literal", "value" => v}}

  defp classify_literal(_, _), do: :abort

  # --- Pattern classifiers ---

  defp api_key?(%{
         "type" => "MemberExpression",
         "object" => %{"type" => "ThisExpression"},
         "property" => %{"type" => "Identifier", "name" => "apiKey"}
       }), do: true

  defp api_key?(_), do: false

  defp passphrase?(%{
         "type" => "MemberExpression",
         "object" => %{"type" => "ThisExpression"},
         "property" => %{"type" => "Identifier", "name" => "password"}
       }), do: true

  defp passphrase?(_), do: false

  defp timestamp_ident?(%{"type" => "Identifier", "name" => n}, timestamp_names), do: n in timestamp_names

  # Occasionally wrapped: `X-BAPI-TIMESTAMP: timestamp.toString()` even though
  # the binding already stringifies. Peel one `.toString()` level.
  defp timestamp_ident?(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => inner,
             "property" => %{"type" => "Identifier", "name" => "toString"}
           },
           "arguments" => []
         },
         timestamp_names
       ), do: timestamp_ident?(inner, timestamp_names)

  defp timestamp_ident?(_, _), do: false

  # this.safeInteger(this.options, 'recvWindow')
  defp recv_window?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "safeInteger"}
         },
         "arguments" => [
           %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "options"}
           },
           %{"type" => "Literal", "value" => "recvWindow"} | _
         ]
       }), do: true

  # this.options['recvWindow']
  defp recv_window?(%{
         "type" => "MemberExpression",
         "computed" => true,
         "object" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "options"}
         },
         "property" => %{"type" => "Literal", "value" => "recvWindow"}
       }), do: true

  # this.options.recvWindow
  defp recv_window?(%{
         "type" => "MemberExpression",
         "computed" => false,
         "object" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "options"}
         },
         "property" => %{"type" => "Identifier", "name" => "recvWindow"}
       }), do: true

  # Bybit wraps recvWindow lookup: `this.options['recvWindow'].toString()`.
  # Peel one `.toString()` level and re-classify.
  defp recv_window?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => inner,
           "property" => %{"type" => "Identifier", "name" => "toString"}
         },
         "arguments" => []
       }), do: recv_window?(inner)

  defp recv_window?(_), do: false
end
