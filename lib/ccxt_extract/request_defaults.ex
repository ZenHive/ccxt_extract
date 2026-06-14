defmodule CcxtExtract.RequestDefaults do
  @moduledoc """
  Extract per-method default request body from CCXT exchange TypeScript files.

  CCXT exchanges that POST to a type-discriminated endpoint (hyperliquid's
  `publicPostInfo`, dydx v4's POST helpers, etc.) build a literal JSON body
  inside each method like:

      async fetchTime(params = {}) {
        const request: Dict = { 'type': 'exchangeStatus' };
        return await this.publicPostInfo(this.extend(request, params));
      }

  The spec correctly maps `fetchTime -> publicPostInfo`, but the literal
  `{ 'type': 'exchangeStatus' }` lives in the method body and was previously
  lost during extraction — consumers had to walk the AST themselves or hit
  the empty-body bug described at the head of ROADMAP Task 73c.

  This module walks each class method body looking for `this.<httpVerb>()`
  call expressions, then traces the first argument back to a literal
  `ObjectExpression` via three resolution tiers:

    1. **Direct literal** — `this.call({'k': 'v'})`
    2. **`this.extend` unwrap** — `this.call(this.extend(X, params))` recurses with `X`
    3. **`const`-trace** — `const request = { ... }; this.call(request)` (or extend-wrapped)
       traces the identifier back to its declarator init, provided there is
       exactly one declaration of that name in the method body

  Each extracted property is classified per the Honesty Rule:

    * `kind: "literal"` — value is a primitive (string, number, boolean, nil)
      or a fully-literal nested object/array; `reason` is `nil`
    * `kind: "unresolved"` — value is a non-literal expression; `reason` is
      a closed-vocabulary tag (see `@reasons`)

  ## Output shape

  Per exchange, a map `method_name -> %{key -> entry}` where each `entry`
  is `%{"value" => term(), "kind" => "literal" | "unresolved", "reason" => String.t() | nil}`.

  A method is emitted iff the walker finds at least one HTTP call site with
  a resolvable literal body containing at least one property. Methods with
  no HTTP calls, pure delegation, or multiple divergent literal bodies are
  silently skipped (not present in the output map).

  ## Scope (v1)

    * Conditional mutation (`if (...) request[k] = v`) is not tracked —
      declared properties are extracted, mutated additions are ignored.
    * Spread elements inside an ObjectExpression are silently dropped.
    * Only single-declarator resolution: if a variable is declared twice
      within the method body, OR if any `x = ...` reassignment or `x++`
      update targets the identifier anywhere in the method body (including
      nested blocks), the arg is treated as unresolved. This keeps the
      Honesty Rule — a declarator's init value can't be asserted as the
      shipped body when a later reassignment invisibly replaces it
      (ndax.signIn is the canonical case).

  The "Three-Strikes escalation for Task 73c" note in ROADMAP.md (Phase 11
  section) anticipates that if the derivation is patched three times for
  richer shapes, we migrate to a bounded mechanics-AST subtree rather than
  stretching the walker further.

  ## Usage

      {:ok, exchanges, stats} = CcxtExtract.RequestDefaults.extract()
      CcxtExtract.RequestDefaults.write!(exchanges)
  """

  use CcxtExtract.OXCExtractor, output_file: "request_defaults.json"

  # Interface-method name pattern — same as CcxtExtract.UnifiedEndpoints.
  # CCXT auto-generates interface method names with an embedded HTTP verb
  # (publicGetV5MarketTickers, privatePostInfo, etc.). A method-body call
  # whose name matches this pattern is treated as an HTTP call site.
  @http_verb_pattern ~r/(Get|Post|Put|Delete|Patch)/

  # Prefixes that contain an HTTP verb but are NOT interface methods —
  # isPostOnly, handlePost*, etc. Exclude them the same way UnifiedEndpoints does.
  @non_interface_prefixes ~w(is handle)

  # Closed vocabulary for `kind: "unresolved"` reason tags — listed here as
  # a reading aid; the schema file `priv/schema/exchange_v4.json` is the
  # authoritative enum (RequestDefaultsEntry.reason). Producer is
  # `classify_property_value/1` below.
  #   conditional_value     — ternary or logical expression
  #   identifier_reference  — variable or member-access read
  #   dynamic_construction  — call, binary, template literal, partially-literal object/array
  #   computed_key          — property key was a computed `[expr]`
  #   spread_elaboration    — reserved for future spread tracking (not emitted today)

  @impl true
  def source_dir, do: CcxtExtract.Paths.ts_src()

  @impl true
  def extract_from_ast(ast, filename) do
    export = Enum.find(ast.body, &(&1.type == :export_default_declaration))

    if export && export.declaration && Map.get(export.declaration, :body) do
      class = export.declaration
      class_name = if class.id, do: class.id.name, else: Path.rootname(filename)
      id = class_name

      request_defaults =
        class.body.body
        |> Enum.filter(&(&1.type == :method_definition))
        |> Enum.map(&extract_method_defaults/1)
        |> Enum.reject(fn {_name, body} -> body == :skip end)
        |> Map.new()

      resolvable = count_entries(request_defaults, "literal")
      unresolved = count_entries(request_defaults, "unresolved")

      %{
        "id" => id,
        "class_name" => class_name,
        "file" => filename,
        "request_defaults_method_count" => map_size(request_defaults),
        "request_defaults_resolvable_count" => resolvable,
        "request_defaults_unresolved_count" => unresolved,
        "request_defaults" => request_defaults
      }
    end
  end

  @impl true
  def write_stats(exchanges) do
    %{
      "with_request_defaults" => Enum.count(exchanges, &(&1["request_defaults_method_count"] > 0)),
      "total_methods" => sum_field(exchanges, "request_defaults_method_count"),
      "total_resolvable" => sum_field(exchanges, "request_defaults_resolvable_count"),
      "total_unresolved" => sum_field(exchanges, "request_defaults_unresolved_count")
    }
  end

  defp sum_field(exchanges, field), do: Enum.sum(Enum.map(exchanges, & &1[field]))

  defp count_entries(request_defaults, kind) do
    Enum.sum(
      Enum.map(request_defaults, fn {_method, body} ->
        Enum.count(body, fn {_k, entry} -> entry["kind"] == kind end)
      end)
    )
  end

  # --- Per-method extraction ---

  # For a method, find its HTTP call sites and resolve the first one (or
  # collapse multiple identical ones) to a literal body. Returns
  # {method_name, body_map} or {method_name, :skip}.
  defp extract_method_defaults(%{type: :method_definition, key: %{name: name}, value: %{body: %{body: stmts}}} = method) do
    body =
      method
      |> find_http_calls(stmts)
      |> resolve_call_sites(stmts)

    {name, body}
  end

  defp extract_method_defaults(%{key: %{name: name}}), do: {name, :skip}

  # Catch-all: method_definition with a non-identifier key (string-literal
  # method name, computed key, getter/setter without a name field). Returning
  # a sentinel tuple keeps the downstream `reject body == :skip` pipeline
  # simple; `:__non_identifier__` never collides with real method names.
  defp extract_method_defaults(_), do: {:__non_identifier__, :skip}

  defp resolve_call_sites([], _stmts), do: :skip

  defp resolve_call_sites([call], stmts), do: resolve_single_call(call, stmts)

  defp resolve_call_sites(calls, stmts) do
    results = Enum.map(calls, &resolve_single_call(&1, stmts))
    distinct = Enum.uniq(results)

    case distinct do
      [single] -> single
      _ -> :skip
    end
  end

  defp resolve_single_call(%{arguments: []}, _stmts), do: :skip

  defp resolve_single_call(%{arguments: [arg | _]}, stmts) do
    case resolve_arg_to_object(arg, stmts) do
      {:ok, obj_node} ->
        case extract_object_expression(obj_node) do
          body when map_size(body) > 0 -> body
          _ -> :skip
        end

      :skip ->
        :skip
    end
  end

  # --- Resolution tiers ---

  # Tier 1: direct ObjectExpression literal
  defp resolve_arg_to_object(%{type: :object_expression} = node, _stmts), do: {:ok, node}

  # Tier 2: this.extend(X, _) — unwrap and recurse with X
  defp resolve_arg_to_object(
         %{
           type: :call_expression,
           callee: %{
             type: :member_expression,
             object: %{type: :this_expression},
             property: %{type: :identifier, name: "extend"}
           },
           arguments: [inner | _]
         },
         stmts
       ) do
    resolve_arg_to_object(inner, stmts)
  end

  # Tier 3: Identifier — trace to sole const/let declarator and recurse on its
  # init. This keeps `const request = {...}` working via tier 1 AND picks up
  # `const request = this.extend({...}, params)` via tier 2 without a new
  # resolution strategy (mirror of the existing tiers). Any other init shape
  # (another identifier, a non-extend call, conditional, etc.) falls through
  # to `:skip` via the catch-all clause below.
  #
  # Honesty Rule: before trusting the declarator, scan the whole method body
  # for reassignments (`request = ...`) or update expressions (`request++`)
  # to the same name. A reassigned identifier means the declarator's init
  # isn't the value that flows into the HTTP call — emit `:skip` so the
  # method drops out rather than asserting a stale literal.
  defp resolve_arg_to_object(%{type: :identifier, name: var_name}, stmts) do
    if any_assignment_to?(stmts, var_name) do
      :skip
    else
      case collect_declarators(stmts, var_name) do
        [%{init: init}] when not is_nil(init) -> resolve_arg_to_object(init, stmts)
        _ -> :skip
      end
    end
  end

  defp resolve_arg_to_object(_, _), do: :skip

  # Walk top-level statements (not nested inside conditionals) collecting
  # VariableDeclarator nodes whose id.name matches var_name. v1 does not
  # descend into nested blocks — declarations inside if/try/for are treated
  # as non-extractable (they rarely produce the simple const-literal pattern
  # the walker targets).
  defp collect_declarators(stmts, var_name) when is_list(stmts) do
    Enum.flat_map(stmts, fn
      %{type: :variable_declaration, declarations: decls} ->
        Enum.filter(decls, fn
          %{id: %{type: :identifier, name: ^var_name}} -> true
          _ -> false
        end)

      _ ->
        []
    end)
  end

  defp collect_declarators(_, _), do: []

  # Return true when any assignment_expression whose LHS is the identifier
  # `var_name`, OR any update_expression (`x++`, `x--`) whose argument is
  # that identifier, appears anywhere in the method body — including nested
  # blocks (if/else/try/for). Used by tier-3 identifier resolution and by
  # computed-member method-name resolution to force `:skip` when the traced
  # binding is not effectively-const.
  defp any_assignment_to?(nodes, var_name) when is_list(nodes) do
    Enum.any?(nodes, &any_assignment_to?(&1, var_name))
  end

  defp any_assignment_to?(%{type: :assignment_expression, left: %{type: :identifier, name: name}}, var_name)
       when name == var_name, do: true

  defp any_assignment_to?(%{type: :update_expression, argument: %{type: :identifier, name: name}}, var_name)
       when name == var_name, do: true

  defp any_assignment_to?(node, var_name) when is_map(node) do
    node |> Map.values() |> Enum.any?(&any_assignment_to?(&1, var_name))
  end

  defp any_assignment_to?(_, _), do: false

  # --- HTTP call detection ---

  # Collect every `this.<identifier>()` / `this[x]()` CallExpression node
  # anywhere in the method body, then filter to those whose (possibly
  # computed) callee name resolves to an HTTP-verb-matching string.
  defp find_http_calls(method, stmts) do
    method
    |> collect_this_call_nodes()
    |> Enum.filter(&interface_method_call?(&1, stmts))
  end

  defp collect_this_call_nodes(
         %{
           type: :call_expression,
           callee: %{type: :member_expression, object: %{type: :this_expression}, property: %{type: :identifier}}
         } = node
       ) do
    [node | walk_children(node, &collect_this_call_nodes/1)]
  end

  defp collect_this_call_nodes(node) when is_map(node) do
    walk_children(node, &collect_this_call_nodes/1)
  end

  defp collect_this_call_nodes(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_this_call_nodes/1)
  end

  defp collect_this_call_nodes(_), do: []

  defp walk_children(node, fun) when is_map(node) do
    node |> Map.values() |> Enum.flat_map(fun)
  end

  # Non-computed: this.method(...) — check callee.property.name directly.
  defp interface_method_call?(
         %{callee: %{type: :member_expression, computed: false, property: %{type: :identifier, name: name}}},
         _stmts
       ), do: verb_match?(name)

  # Computed: this[x](...) — trace x through the same sole-declarator mechanism
  # as tier 3, but for a string-literal init rather than an object_expression.
  # Mirrors the v1 tier-3 constraint: single declaration, literal init.
  defp interface_method_call?(
         %{callee: %{type: :member_expression, computed: true, property: %{type: :identifier, name: var_name}}},
         stmts
       ) do
    case resolve_identifier_to_string(var_name, stmts) do
      {:ok, resolved} -> verb_match?(resolved)
      :skip -> false
    end
  end

  # Older AST shapes may omit :computed; fall back to the original name match.
  defp interface_method_call?(%{callee: %{property: %{name: name}}}, _stmts), do: verb_match?(name)

  defp interface_method_call?(_, _), do: false

  defp verb_match?(name) when is_binary(name) do
    Regex.match?(@http_verb_pattern, name) and
      not Enum.any?(@non_interface_prefixes, &String.starts_with?(name, &1))
  end

  defp verb_match?(_), do: false

  defp resolve_identifier_to_string(var_name, stmts) do
    if any_assignment_to?(stmts, var_name) do
      :skip
    else
      case collect_declarators(stmts, var_name) do
        [%{init: %{type: type, value: v}}] when type in [:literal, :string_literal] and is_binary(v) ->
          {:ok, v}

        _ ->
          :skip
      end
    end
  end

  # --- ObjectExpression extraction ---

  @doc """
  Convert an `ObjectExpression` AST node to a `%{key => entry}` map where each
  entry is `%{"value" => term(), "kind" => "literal" | "unresolved", "reason" => String.t() | nil}`.

  Exposed for testing; normal callers go through `extract_from_ast/2`.
  """
  @spec extract_object_expression(map()) :: %{String.t() => map()}
  def extract_object_expression(%{type: :object_expression, properties: properties}) do
    properties
    |> Enum.map(&extract_property/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  def extract_object_expression(_), do: %{}

  # Regular object property — both :object_property (OXC TS) and :property (stock ESTree)
  defp extract_property(%{type: type, key: key_node, value: value_node} = prop)
       when type in [:object_property, :property] do
    computed? = Map.get(prop, :computed, false)

    if computed? do
      unresolved_key_entry("computed_key")
    else
      case property_key(key_node) do
        nil -> nil
        key -> {key, classify_property_value(value_node)}
      end
    end
  end

  # Spread element — v1 drops silently (see Honesty-Rule note in @moduledoc)
  defp extract_property(%{type: :spread_element}), do: nil

  defp extract_property(_), do: nil

  # Synthesize a pseudo-key entry for computed keys so the consumer sees that
  # SOMETHING unresolved exists at this position. The key itself is opaque.
  defp unresolved_key_entry(reason) do
    {"_computed", unresolved_entry(reason)}
  end

  # Property key extraction: Identifier.name or Literal/StringLiteral.value.
  # Returns nil for keys we can't render as a string map key.
  defp property_key(%{type: :identifier, name: n}) when is_binary(n), do: n
  defp property_key(%{type: :literal, value: v}) when is_binary(v), do: v
  defp property_key(%{type: :literal, value: v}) when is_number(v), do: to_string(v)
  defp property_key(%{type: :string_literal, value: v}) when is_binary(v), do: v
  defp property_key(%{type: :numeric_literal, value: v}) when is_number(v), do: to_string(v)
  defp property_key(_), do: nil

  @doc """
  Classify a property-value AST node as a `%{"value" => _, "kind" => _, "reason" => _}` entry.

  Exposed for testing; normal callers go through `extract_from_ast/2`.
  """
  @spec classify_property_value(map()) :: map()
  def classify_property_value(%{type: :literal, value: v})
      when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v) do
    literal_entry(v)
  end

  # OXC emits variant literal types for TS in some positions
  def classify_property_value(%{type: :string_literal, value: v}) when is_binary(v), do: literal_entry(v)

  def classify_property_value(%{type: :numeric_literal, value: v}) when is_number(v), do: literal_entry(v)

  def classify_property_value(%{type: :boolean_literal, value: v}) when is_boolean(v), do: literal_entry(v)

  def classify_property_value(%{type: :null_literal}), do: literal_entry(nil)

  # Negative numeric literal: `UnaryExpression { operator: "-", argument: Literal(n) }`
  def classify_property_value(%{type: :unary_expression, operator: "-", argument: %{value: v}}) when is_number(v),
    do: literal_entry(-v)

  # `undefined` keyword is an Identifier in ESTree
  def classify_property_value(%{type: :identifier, name: "undefined"}), do: literal_entry(nil)

  # Non-literal expressions — tag with closed-vocabulary reason
  def classify_property_value(%{type: :conditional_expression}), do: unresolved_entry("conditional_value")

  def classify_property_value(%{type: :logical_expression}), do: unresolved_entry("conditional_value")

  def classify_property_value(%{type: :identifier}), do: unresolved_entry("identifier_reference")

  def classify_property_value(%{type: :member_expression}), do: unresolved_entry("identifier_reference")

  def classify_property_value(%{type: :call_expression}), do: unresolved_entry("dynamic_construction")

  def classify_property_value(%{type: :binary_expression}), do: unresolved_entry("dynamic_construction")

  def classify_property_value(%{type: :template_literal}), do: unresolved_entry("dynamic_construction")

  # Nested ObjectExpression. Fully-literal nested objects collapse into a plain
  # map value with `kind: "literal"`; any non-literal child forces the whole
  # entry to `kind: "unresolved"` with `value: nil` (Honesty Rule — the schema,
  # docstring, and CHANGELOG all require `value` to be null when unresolved).
  def classify_property_value(%{type: :object_expression} = node) do
    nested = extract_object_expression(node)

    if all_literal?(nested) do
      nested_value = Map.new(nested, fn {k, entry} -> {k, entry["value"]} end)
      literal_entry(nested_value)
    else
      unresolved_entry("dynamic_construction")
    end
  end

  # ArrayExpression — literal iff every element is literal
  def classify_property_value(%{type: :array_expression, elements: els}) do
    entries = Enum.map(els, &classify_property_value/1)

    if Enum.all?(entries, &(&1["kind"] == "literal")) do
      literal_entry(Enum.map(entries, & &1["value"]))
    else
      unresolved_entry("dynamic_construction")
    end
  end

  def classify_property_value(_), do: unresolved_entry("dynamic_construction")

  defp all_literal?(body) when is_map(body) do
    Enum.all?(body, fn {_k, entry} -> entry["kind"] == "literal" end)
  end

  defp literal_entry(value) do
    %{"value" => value, "kind" => "literal", "reason" => nil}
  end

  defp unresolved_entry(reason) do
    %{"value" => nil, "kind" => "unresolved", "reason" => reason}
  end
end
