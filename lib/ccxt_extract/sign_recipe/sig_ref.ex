defmodule CcxtExtract.SignRecipe.SigRef do
  @moduledoc """
  Signature-reference detection helpers shared across the sign-recipe
  derivation pipeline.

  Consumers: `Derive` (placement detection) and `AuthHeaders` (skip
  entries whose RHS is itself the signature). Both need to answer the
  same question — "does this sub-AST transitively reference the
  signature?" — and both use the same `{names, fps}` sig_ctx tuple:

    * `names` — identifier names bound to crypto calls (e.g. `"signature"`).
    * `fps`   — byte-offset fingerprints of the crypto-call nodes themselves,
      used to detect inline references like `headers['X-SIGN'] =
      this.hmac(...)` that skip an intermediate binding (phemex pattern).

  The fingerprint tuple is deliberately narrow to the SignRecipe pipeline
  — it is NOT a generic AST utility. That's why this module lives next
  to the pipeline, not in `ASTHelpers`.
  """

  @typedoc "`{names, fingerprints}` — the signature context passed through derivation."
  @type sig_ctx :: {[String.t()], [tuple()]}

  @doc """
  Return `true` if `node` transitively references the signature.

  Matches two shapes:

    * an `Identifier` whose name is in `names` (canonical binding case), OR
    * a `CallExpression` whose byte-range matches a known crypto call
      (inline reference case — headers written directly with `this.hmac(...)`
      before any binding).

  Recurses through maps and lists.
  """
  @spec has?(term(), sig_ctx()) :: boolean()
  def has?(%{"type" => "Identifier", "name" => n}, {names, _fps}), do: n in names

  def has?(%{"type" => "CallExpression"} = node, {_names, fps} = sig_ctx) do
    fingerprint(node) in fps or Enum.any?(Map.values(node), &has?(&1, sig_ctx))
  end

  def has?(node, sig_ctx) when is_map(node) do
    Enum.any?(Map.values(node), &has?(&1, sig_ctx))
  end

  def has?(nodes, sig_ctx) when is_list(nodes) do
    Enum.any?(nodes, &has?(&1, sig_ctx))
  end

  def has?(_, _), do: false

  @doc """
  Byte-offset fingerprint for a `CallExpression` node.

  Two call-expression nodes are "the same node" iff their `start` and
  `end` offsets match (plus the fact that they're both CallExpressions).
  Avoids structural equality on large AST maps when crypto-call identity
  matters.
  """
  @spec fingerprint(term()) :: tuple() | :__not_a_call__
  def fingerprint(%{"type" => "CallExpression", "start" => s, "end" => e}), do: {s, e}
  def fingerprint(_), do: :__not_a_call__
end
