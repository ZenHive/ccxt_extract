defmodule CcxtExtract.SignRecipe.Nonce do
  @moduledoc """
  Task 67 — populate `nonce` on every `structure.sign_recipe` record.

  Detects the canonical timestamp / nonce binding in the `sign()` body and
  classifies it as `{source, format}` where:

    * `source` ∈ `timestamp_ms` | `timestamp_sec` | `timestamp_us` |
      `timestamp_ns` | `monotonic` | `exchange_supplied`
    * `format` ∈ `integer` | `iso8601` | `hex` | `string`

  The `SignRecipeNonce` schema (`priv/schema/exchange_v3.json#/$defs`)
  defines the closed vocabulary. This module only emits classifications
  that land inside that vocabulary.

  ## Strategy

    1. Collect every `VariableDeclarator{id: Identifier(name), init}` whose
       `name` matches a recognized timestamp-binding name
       (`timestamp`, `nonce`, `ts`, `expires`, `deadline`, `now`,
       `timestampString`).
    2. For each binding, classify the init expression against the known
       shape table (see `classify_init/2`). Identifier references inside
       wrapper shapes (`.toString()`, `this.iso8601(<x>)`,
       `this.parseToInt(<x> / 1000)`) resolve through the local
       `%{name => init}` map up to `@max_ident_depth` levels — this is
       what makes gate's chain
       (`timestampString → timestamp → parseToInt(nonce / 1000) → this.nonce()`)
       classify as `{timestamp_sec, string}`.
    3. Keep only **terminal** timestamp bindings — those whose name is not
       referenced by another whitelisted binding's init. For gate this
       picks `timestampString` (the actual wire value) over the
       intermediate `nonce` and `timestamp` bindings. For deribit, where
       `timestamp` and `nonce` are both bound to `this.nonce().toString()`
       without cross-reference, both stay terminal and produce the same
       classification (deduped to one).
    4. If exactly one unique classification survives, emit it. Disagreement
       across terminal bindings → `nil` (honest "can't pick one").
    5. Terminal-reason exchanges (ambiguous_ast / custom_signing_family /
       no_sign_method) short-circuit to `nil` — the recipe-level tag
       already tells the truthful story.

  ## Reuse contract

  `timestamp_binding_names/1` is a public helper used by
  `CcxtExtract.SignRecipe.AuthHeaders` to decide when a header value of
  the form `<identifier>` should be tagged `source: "timestamp"`. It
  returns EVERY whitelisted binding whose init chain-classifies — not
  just the terminal one — because AuthHeaders only needs a membership
  test, and exchanges like gate reference intermediate bindings in
  headers (`'Timestamp': timestampString` — terminal — is common, but a
  future exchange might reference the intermediate `timestamp` too).
  """

  alias CcxtExtract.SignRecipe.ASTHelpers

  # Same short-circuit set as CanonicalString — a recipe already tagged
  # terminal at Task 65 will never have a meaningful nonce classification
  # no matter what shape its body happens to have. Single source of truth
  # lives in `CcxtExtract.SignRecipe.terminal_reasons/0`.
  @terminal_reasons CcxtExtract.SignRecipe.terminal_reasons()

  # Identifier names exchanges actually bind the canonical timestamp to.
  # Expanded during Phase 1 exploration; priority exchanges use
  # `timestamp` (okx, bybit, kucoin, gate, bitget, binance) or `nonce`
  # (coinbaseexchange, bitfinex) or `deadline` / `now` (lighter-style).
  @timestamp_names ~w(timestamp nonce ts expires deadline now timestampString)

  # Max depth for Identifier → binding substitution inside classify. Caps
  # at 4 levels: gate's real chain is 3 (timestampString → timestamp →
  # parseToInt arg → nonce), so 4 gives one level of headroom. Prevents
  # infinite recursion on pathological `const a = b; const b = a` shapes.
  @max_ident_depth 4

  @type classification :: %{required(String.t()) => String.t()}

  @doc """
  Derive the `%{"source" => _, "format" => _}` classification for a
  recipe, or `nil` if the body has no recognizable timestamp binding or
  the recipe is already tagged terminal at Task 65.
  """
  @spec derive([map()] | term(), String.t() | nil) :: classification() | nil
  def derive(_body_stmts, reason) when reason in @terminal_reasons, do: nil

  def derive(body_stmts, _reason) when is_list(body_stmts) do
    {timestamp_bindings, bindings_map} = partition_bindings(body_stmts)

    timestamp_bindings
    |> terminal_only()
    |> Enum.map(fn {_name, init} -> classify_init(init, bindings_map) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [single] -> single
      # Zero matches OR disagreement between terminal bindings → honest nil.
      _ -> nil
    end
  end

  def derive(_, _), do: nil

  @doc """
  Return the identifier names in `body_stmts` whose binding init
  chain-classifies as a recognized timestamp producer. Used by
  `AuthHeaders.derive/4` to tag header values whose RHS is a bare
  identifier reference to one of these bindings.
  """
  @spec timestamp_binding_names([map()] | term()) :: [String.t()]
  def timestamp_binding_names(body_stmts) when is_list(body_stmts) do
    {timestamp_bindings, bindings_map} = partition_bindings(body_stmts)

    timestamp_bindings
    |> Enum.filter(fn {_name, init} -> not is_nil(classify_init(init, bindings_map)) end)
    |> Enum.map(fn {name, _init} -> name end)
    |> Enum.uniq()
  end

  def timestamp_binding_names(_), do: []

  # Split the body's bindings into "those with a timestamp-whitelisted
  # name" and a full `%{name => init}` map used for identifier resolution
  # during classification. Bindings with duplicate names keep the first.
  defp partition_bindings(body_stmts) do
    all = ASTHelpers.collect_bindings(body_stmts)
    map = all |> Enum.reverse() |> Map.new()
    timestamps = Enum.filter(all, fn {name, _} -> name in @timestamp_names end)
    {timestamps, map}
  end

  # Filter out timestamp-whitelisted bindings whose name is referenced in
  # another timestamp-whitelisted binding's init. The survivors are the
  # "terminal" bindings — the ones most likely to be the actual wire
  # value the consumer sees. For gate: `timestampString` survives,
  # `nonce` and `timestamp` are filtered as intermediate.
  defp terminal_only(timestamp_bindings) do
    Enum.reject(timestamp_bindings, fn {name, _init} ->
      Enum.any?(timestamp_bindings, fn {other_name, other_init} ->
        other_name != name and references_name?(other_init, name)
      end)
    end)
  end

  defp references_name?(%{"type" => "Identifier", "name" => n}, n), do: true

  defp references_name?(node, name) when is_map(node) do
    Enum.any?(Map.values(node), &references_name?(&1, name))
  end

  defp references_name?(nodes, name) when is_list(nodes) do
    Enum.any?(nodes, &references_name?(&1, name))
  end

  defp references_name?(_, _), do: false

  # --- Init expression classifier with bindings resolution ---
  #
  # Each clause handles one CCXT idiom. Wrapper clauses (`toString`,
  # `iso8601`, `ymdhms`, `parseToInt`, `seconds() + offset`) recursively
  # classify an inner sub-expression and thread bindings + a
  # monotonically-decreasing depth through. Identifier references
  # resolve through `bindings` until depth runs out.

  defp classify_init(node, bindings), do: classify_init(node, bindings, @max_ident_depth)

  # Identifier → look up in bindings and recurse with decremented depth.
  # The depth guard ONLY bites here: leaf classifiers (this.nonce etc.)
  # must work at any depth — what we're guarding against is pathological
  # `const a = b; const b = a` cycles chasing forever, not legitimate
  # deep chains resolving to a concrete leaf.
  defp classify_init(%{"type" => "Identifier", "name" => _n}, _bindings, depth) when depth <= 0, do: nil

  defp classify_init(%{"type" => "Identifier", "name" => n}, bindings, depth) do
    case Map.get(bindings, n) do
      nil -> nil
      init -> classify_init(init, bindings, depth - 1)
    end
  end

  # this.nonce() — CCXT base defines nonce() as milliseconds()
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "nonce"}
           },
           "arguments" => []
         },
         _bindings,
         _depth
       ),
       do: %{"source" => "timestamp_ms", "format" => "integer"}

  # this.milliseconds()
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "milliseconds"}
           },
           "arguments" => []
         },
         _bindings,
         _depth
       ),
       do: %{"source" => "timestamp_ms", "format" => "integer"}

  # this.seconds()
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "seconds"}
           },
           "arguments" => []
         },
         _bindings,
         _depth
       ),
       do: %{"source" => "timestamp_sec", "format" => "integer"}

  # this.microseconds()
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "microseconds"}
           },
           "arguments" => []
         },
         _bindings,
         _depth
       ),
       do: %{"source" => "timestamp_us", "format" => "integer"}

  # this.nanoseconds()
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "nanoseconds"}
           },
           "arguments" => []
         },
         _bindings,
         _depth
       ),
       do: %{"source" => "timestamp_ns", "format" => "integer"}

  # Date.now() — raw JS global, returns milliseconds. Priority exchanges use
  # `this.nonce()` via CCXT's base, but exchanges with custom sign() overrides
  # (bitmex-style) may reach for the plain global directly.
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "Identifier", "name" => "Date"},
             "property" => %{"type" => "Identifier", "name" => "now"}
           },
           "arguments" => []
         },
         _bindings,
         _depth
       ),
       do: %{"source" => "timestamp_ms", "format" => "integer"}

  # x.toString() — flip an integer-format classification to string.
  # Preserves the source; drops the classification if inner doesn't match.
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => inner,
             "property" => %{"type" => "Identifier", "name" => "toString"}
           },
           "arguments" => []
         },
         bindings,
         depth
       ) do
    case classify_init(inner, bindings, depth - 1) do
      %{"source" => source, "format" => "integer"} ->
        %{"source" => source, "format" => "string"}

      # Nested non-integer classifications (iso8601, already string) pass
      # through unchanged — .toString() on a string is a no-op.
      other ->
        other
    end
  end

  # this.iso8601(<inner>) / this.ymdhms(<inner>, ...) — format → iso8601.
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => fn_name}
           },
           "arguments" => [inner | _]
         },
         bindings,
         depth
       )
       when fn_name in ["iso8601", "ymdhms"] do
    case classify_init(inner, bindings, depth - 1) do
      %{"source" => source} -> %{"source" => source, "format" => "iso8601"}
      nil -> nil
    end
  end

  # this.parseToInt(<timestamp_ms expr> / 1000) — gate-style sec conversion.
  defp classify_init(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => "parseToInt"}
           },
           "arguments" => [
             %{
               "type" => "BinaryExpression",
               "operator" => "/",
               "left" => ms_expr,
               "right" => %{"type" => "Literal", "value" => divisor}
             }
             | _
           ]
         },
         bindings,
         depth
       )
       when divisor == 1000 do
    case classify_init(ms_expr, bindings, depth - 1) do
      %{"source" => "timestamp_ms"} -> %{"source" => "timestamp_sec", "format" => "integer"}
      _ -> nil
    end
  end

  # <timestamp> + <offset> — lighter-style deadline, or ms-based drift
  # correction (`this.milliseconds() + this.options['timeDifference']`).
  # Classification inherited from the left operand; right is ignored.
  # Widened beyond timestamp_sec to cover timestamp_ms callsites.
  defp classify_init(%{"type" => "BinaryExpression", "operator" => "+", "left" => left}, bindings, depth) do
    case classify_init(left, bindings, depth - 1) do
      %{"source" => source} = c when source in ["timestamp_ms", "timestamp_sec"] -> c
      _ -> nil
    end
  end

  defp classify_init(_, _, _), do: nil
end
