defmodule CcxtExtract.RequestShape.BodyEncoding do
  @moduledoc """
  Task 71 — populate `body_encoding` + `content_type` on every
  `structure.request_shape` record by scanning the `sign()` AST
  for `body = ...` assignments and `Content-Type` header
  declarations.

  # Patch count: 0/3. First patch migrates to priv/overrides/.
  # See ROADMAP.md § Phase 11 "Three-Strikes Rule".

  ## Output shape

      %{
        body_encoding: "json" | "form_urlencoded" | "query_string" | "none" | nil,
        content_type: String.t() | nil,
        reason: String.t() | nil
      }

  Returned as a map by `derive/1`; the caller (the Derive
  orchestrator) merges the body fields into the per-section record
  and surfaces `reason` (when non-nil) on the parent
  `unresolved_reason` slot.

  ## Body-assignment AST shapes recognized

  CCXT's sign() builds the body via one of:

    * `body = this.json(query)` /
      `body = this.json({...})`                            → `"json"`
    * `body = this.urlencode(...)` /
      `body = this.urlencodeNested(...)` /
      `body = this.urlencodeWithArrayRepeat(...)`           → `"form_urlencoded"`
    * `body = this.rawencode(...)`                         → `"form_urlencoded"`
      (used by a handful of exchanges; same wire encoding as
      `urlencode` minus key sorting — Content-Type is identical.)
    * No `body = ...` assignment anywhere in sign()         → `"none"`

  When sign() ALSO sets up a `?key=value` query string AND there is
  no body assignment, the encoding stays `"none"` — query strings
  flow through `path_template` / placeholder substitution, not body
  encoding. `"query_string"` is reserved for exotic exchanges that
  send the query string in the body without urlencoding the keys —
  none surfaced on the priority-tier scan today, so it's a forward-
  compatibility slot in the closed vocabulary.

  ## Verb-conditional bodies (binance pattern)

  Some sign() methods set `body = X` inside an `if (method === 'POST')`
  branch. The walker collects every body assignment regardless of
  which `IfStatement` body it lives in. If every assignment maps to
  the SAME encoding (or `"none"`-equivalent paths via the no-body
  branch), we emit that encoding. If the set is mixed (e.g.
  `json` AND `urlencode`) AND we can't determine which verb owns
  which from the surrounding `IfStatement.test`, we emit
  `body_encoding: nil` plus `unresolved_reason: "ambiguous_body"`.

  ## Content-Type detection

  Two paths:

    1. Walk the body for `headers` assignments / property values
       that match a `Content-Type` key (case-insensitive). Pick the
       Literal value if all matches agree.
    2. Fall back to the canonical Content-Type for the derived
       encoding (`json` → `application/json`, `form_urlencoded` →
       `application/x-www-form-urlencoded`).

  When `body_encoding == "none"`, `content_type` is `nil` (no body
  to send → no Content-Type to declare).
  """

  alias CcxtExtract.RequestShape

  @type result :: %{
          required(:body_encoding) => String.t() | nil,
          required(:content_type) => String.t() | nil,
          required(:reason) => String.t() | nil
        }

  @json_methods ~w(json)
  @urlencode_methods ~w(urlencode urlencodeNested urlencodeWithArrayRepeat rawencode)

  @doc """
  Derive a `%{body_encoding, content_type, reason}` map from a
  sign() body AST.

  `body_stmts` is the list under `sign_method["body"]["body"]`, or
  `nil` when there's no sign(). The reason is a closed-vocabulary
  tag (`"ambiguous_body"`, `"no_sign_method"`) or `nil` when
  derivation succeeded; the orchestrator decides whether to surface
  the reason on the parent record's `unresolved_reason` slot.
  """
  @spec derive([map()] | nil) :: result()
  def derive(nil), do: %{body_encoding: nil, content_type: nil, reason: "no_sign_method"}

  def derive(body_stmts) when is_list(body_stmts) do
    encodings =
      body_stmts
      |> collect_body_encoders([])
      |> Enum.uniq()

    case classify_encoding(encodings) do
      {:ok, encoding} ->
        content_type = pick_content_type(body_stmts, encoding)
        %{body_encoding: encoding, content_type: content_type, reason: nil}

      {:error, reason} ->
        %{body_encoding: nil, content_type: nil, reason: reason}
    end
  end

  def derive(_), do: %{body_encoding: nil, content_type: nil, reason: "no_sign_method"}

  # --- Body encoder collection ---

  # Walks the AST, returning the encoder family for every
  # `body = this.X(...)` assignment seen anywhere in the tree.
  defp collect_body_encoders(node, acc) when is_map(node) do
    acc =
      case body_assignment_encoder(node) do
        nil -> acc
        encoder -> [encoder | acc]
      end

    Enum.reduce(Map.values(node), acc, &collect_body_encoders/2)
  end

  defp collect_body_encoders(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_body_encoders/2)
  end

  defp collect_body_encoders(_, acc), do: acc

  # Match `body = this.<encoder>(...)` / `body = '<literal>'` /
  # `body = identifier`. Returns `:json | :form_urlencoded | :empty | :unknown | nil`.
  # `nil` means "this node isn't a body assignment" (don't classify).
  defp body_assignment_encoder(%{
         "type" => "AssignmentExpression",
         "operator" => "=",
         "left" => %{"type" => "Identifier", "name" => "body"},
         "right" => rhs
       }) do
    classify_body_rhs(rhs)
  end

  defp body_assignment_encoder(%{
         "type" => "VariableDeclarator",
         "id" => %{"type" => "Identifier", "name" => "body"},
         "init" => init
       })
       when not is_nil(init) do
    classify_body_rhs(init)
  end

  defp body_assignment_encoder(_), do: nil

  defp classify_body_rhs(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => name}
         }
       }) do
    cond do
      name in @json_methods -> :json
      name in @urlencode_methods -> :form_urlencoded
      true -> :unknown
    end
  end

  # `body = '<empty literal>'` = no body content (acts like none).
  defp classify_body_rhs(%{"type" => "Literal", "value" => ""}), do: :empty

  # Other literals (`body = 'fixed-string'`) are too rare to model;
  # tag as unknown so the orchestrator can decide whether to abort
  # or fall back.
  defp classify_body_rhs(%{"type" => "Literal"}), do: :unknown

  # `body = someIdent` — could be a previously assigned encoder
  # result. Conservative: treat as unknown.
  defp classify_body_rhs(%{"type" => "Identifier"}), do: :unknown

  # `body = cond ? this.json(...) : this.urlencode(...)` —
  # walk both branches, both must match.
  defp classify_body_rhs(%{"type" => "ConditionalExpression", "consequent" => c, "alternate" => a}) do
    case {classify_body_rhs(c), classify_body_rhs(a)} do
      {same, same} -> same
      {:empty, other} -> other
      {other, :empty} -> other
      _ -> :unknown
    end
  end

  defp classify_body_rhs(_), do: :unknown

  # Reduce a deduped encoder list to a single encoding string. Drops
  # `:empty` (covered by no-body fallback) and rejects mixed sets.
  defp classify_encoding(encoders) do
    real = Enum.reject(encoders, &(&1 == :empty))

    case real do
      [] -> {:ok, "none"}
      [:json] -> {:ok, "json"}
      [:form_urlencoded] -> {:ok, "form_urlencoded"}
      [:unknown] -> {:error, "ambiguous_body"}
      _multiple -> {:error, "ambiguous_body"}
    end
  end

  # --- Content-Type detection ---

  # Walk the body for `'Content-Type'` Property nodes / member
  # assignments and collect their string-literal values. If every
  # observation agrees on a single literal, return it; otherwise
  # fall back to the canonical Content-Type for the encoding.
  #
  # Hard short-circuit for `"none"`: when there is no body to send,
  # there is no Content-Type to declare. Honors the moduledoc
  # contract on line 67 even if sign() initializes a header literal
  # (e.g. as a default for a sibling code path) but never actually
  # assigns `body = ...`.
  defp pick_content_type(_body_stmts, "none"), do: nil

  defp pick_content_type(body_stmts, encoding) do
    case unique_content_type_literal(body_stmts) do
      {:ok, value} -> value
      :ambiguous -> RequestShape.content_type_for(encoding)
      :none -> RequestShape.content_type_for(encoding)
    end
  end

  defp unique_content_type_literal(body_stmts) do
    body_stmts
    |> collect_content_type_literals([])
    |> Enum.uniq()
    |> case do
      [] -> :none
      [single] -> {:ok, single}
      _ -> :ambiguous
    end
  end

  defp collect_content_type_literals(node, acc) when is_map(node) do
    acc =
      case extract_content_type_value(node) do
        nil -> acc
        value -> [value | acc]
      end

    Enum.reduce(Map.values(node), acc, &collect_content_type_literals/2)
  end

  defp collect_content_type_literals(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_content_type_literals/2)
  end

  defp collect_content_type_literals(_, acc), do: acc

  # `{ 'Content-Type': 'application/json' }` — Property node with
  # string-literal key + string-literal value.
  defp extract_content_type_value(%{
         "type" => "Property",
         "key" => key,
         "value" => %{"type" => "Literal", "value" => value}
       })
       when is_binary(value) do
    if content_type_key?(key), do: value
  end

  # `headers['Content-Type'] = 'application/json'` — member-access
  # assignment with string-literal key.
  defp extract_content_type_value(%{
         "type" => "AssignmentExpression",
         "operator" => "=",
         "left" => %{
           "type" => "MemberExpression",
           "computed" => true,
           "object" => %{"type" => "Identifier", "name" => "headers"},
           "property" => %{"type" => "Literal", "value" => key}
         },
         "right" => %{"type" => "Literal", "value" => value}
       })
       when is_binary(key) and is_binary(value) do
    if String.downcase(key) == "content-type", do: value
  end

  # `headers.ContentType = 'application/json'` — non-computed member
  # access. Rare; cover for completeness.
  defp extract_content_type_value(%{
         "type" => "AssignmentExpression",
         "operator" => "=",
         "left" => %{
           "type" => "MemberExpression",
           "computed" => false,
           "object" => %{"type" => "Identifier", "name" => "headers"},
           "property" => %{"type" => "Identifier", "name" => name}
         },
         "right" => %{"type" => "Literal", "value" => value}
       })
       when is_binary(name) and is_binary(value) do
    if String.downcase(name) in ["contenttype", "content-type"], do: value
  end

  defp extract_content_type_value(_), do: nil

  defp content_type_key?(%{"type" => "Literal", "value" => value}) when is_binary(value) do
    String.downcase(value) == "content-type"
  end

  # JS identifiers can't contain hyphens, so an `Identifier` node
  # with name `"Content-Type"` is impossible. The shorthand object-
  # literal property `{ ContentType: "..." }` is the realistic case;
  # match on the hyphen-stripped form (mirrors the
  # `headers.ContentType` member-access path above).
  defp content_type_key?(%{"type" => "Identifier", "name" => name}) when is_binary(name) do
    String.downcase(name) == "contenttype"
  end

  defp content_type_key?(_), do: false
end
