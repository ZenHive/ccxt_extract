defmodule CcxtExtract.AuthenticatedSections do
  @moduledoc """
  Derive API section names proven to require authentication via
  `checkRequiredCredentials()` gates in the sign() method AST.

  # Patch count: 3/3. Future AST shapes go to priv/overrides/, not new strategies.
  # See CLAUDE.md "Three-Strikes Derivation Rule".

  ## Strategies (locked at 3)

  1. **Direct equality** — `api === 'X'` in the IfStatement test:
     ```typescript
     if (api === 'private' || api === 'sapi') { this.checkRequiredCredentials(); }
     ```

  2. **Array-indexed** — `api[N] === 'X'` for tuple-like api params
     (coinbase, bitget, gate).

  3. **Variable binding** — `const isPrivate = api === 'private'; if (isPrivate) {...}`.

  ## Completeness pass (not a new strategy)

  **Alternate-branch inversion** — when the IfStatement's consequent has NO
  `checkRequiredCredentials()` but the alternate block calls it unconditionally,
  the test values identify the *non-auth* sections; the authenticated set is
  `api_keys -- test_values`. This is a completeness fix to the existing
  IfStatement visitor, not a new extraction strategy — it uses the same
  `collect_api_values/2` machinery.

      if (api === 'public') { ... }
      else { this.checkRequiredCredentials(); ... }

  Requires `api_keys` (from `describe.api`) to compute the complement.

  ## Nested sub-section expansion (post-derivation)

  After the sign-AST scan yields a flat list of section names, walk
  `describe.api` one level deeper: for every top-level `<parent>` whose
  sub-tree is a map, if any `<child>` key in that sub-tree is an exact
  match for one of the already-derived section names, emit
  `<parent>.<child>` alongside the flat names. This covers
  htx/huobi-style schemas where authenticated endpoints nest under
  container keys (`contract.private`, `spot.private`) that a flat scan
  would miss. The child-name check is set-membership against the
  already-derived names, not a regex over a name class — a child key
  the sign AST never identified as authenticated is never added
  (even if it spells the same shape, e.g. `privateV3`). See
  `expand_nested/2`.

  ## What goes to overrides instead

  - `api.startsWith('private')` (grvt) — prefix matching
  - `inArray(api, [...])` (was poloniex; now covered via inversion)
  - sign() with no `checkRequiredCredentials()` gate (lighter, p2b, hyperliquid, paradex)

  Overrides live in `priv/overrides/<exchange>.json` with `authenticated_sections`,
  `reason`, and `verified_against` fields. Applied by the pipeline after derivation.

  Returns `nil` when the sign() method AST is absent.
  """

  @doc """
  Derive authenticated section names from a sign() method AST.

  `api` is the full `describe.api` map (or `nil`). Its top-level keys feed
  alternate-branch inversion; its nested sub-trees feed one-level-deep
  expansion (`<parent>.<child>` paths). If `nil`, both passes are skipped
  and only the direct/indexed/binding patterns on the sign AST are used.

  Returns a sorted, deduplicated list of section name strings, or `nil` if
  the method AST is nil.
  """
  @spec derive(map() | nil, map() | nil) :: [String.t()] | nil
  def derive(sign_method, api \\ nil)

  def derive(nil, _api), do: nil

  def derive(%{"body" => %{"body" => body_stmts}}, api) when is_list(body_stmts) do
    api_keys = if is_map(api), do: Map.keys(api)
    bindings = resolve_variable_bindings(body_stmts)
    ctx = %{bindings: bindings, api_keys: api_keys}

    raw_names =
      body_stmts
      |> collect_from_if_statements(ctx)
      |> Enum.uniq()

    raw_names
    |> expand_nested(api)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def derive(_, _), do: nil

  # Post-derivation: for every top-level <parent> in describe.api whose
  # sub-tree is a map, emit "<parent>.<child>" for every child key whose
  # name matches a derived section name. Returns names ++ dotted paths.
  # When api is not a map, returns names unchanged.
  defp expand_nested(names, api) when is_map(api) and is_list(names) do
    name_set = MapSet.new(names)

    dotted =
      Enum.flat_map(api, fn
        {parent, subtree} when is_map(subtree) and is_binary(parent) ->
          subtree
          |> Map.keys()
          |> Enum.filter(&MapSet.member?(name_set, &1))
          |> Enum.map(&"#{parent}.#{&1}")

        _ ->
          []
      end)

    names ++ dotted
  end

  defp expand_nested(names, _api), do: names

  # Scan top-level VariableDeclarations for `api === 'sectionName'` bindings.
  defp resolve_variable_bindings(body_stmts) do
    Enum.reduce(body_stmts, %{}, fn stmt, acc ->
      case stmt do
        %{"type" => "VariableDeclaration", "declarations" => declarations} ->
          Enum.reduce(declarations, acc, &extract_api_binding/2)

        _ ->
          acc
      end
    end)
  end

  defp extract_api_binding(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => var_name}, "init" => init},
         acc
       ) do
    case extract_api_equals(init) do
      {:ok, section} -> Map.put(acc, var_name, section)
      :skip -> acc
    end
  end

  defp extract_api_binding(_, acc), do: acc

  defp extract_api_equals(%{
         "type" => "BinaryExpression",
         "operator" => "===",
         "left" => %{"type" => "Identifier", "name" => "api"},
         "right" => %{"type" => "Literal", "value" => value}
       })
       when is_binary(value) do
    {:ok, value}
  end

  defp extract_api_equals(%{
         "type" => "BinaryExpression",
         "operator" => "===",
         "left" => %{
           "type" => "MemberExpression",
           "computed" => true,
           "object" => %{"type" => "Identifier", "name" => "api"}
         },
         "right" => %{"type" => "Literal", "value" => value}
       })
       when is_binary(value) do
    {:ok, value}
  end

  defp extract_api_equals(%{"type" => "ParenthesizedExpression", "expression" => inner}) do
    extract_api_equals(inner)
  end

  defp extract_api_equals(_), do: :skip

  defp collect_from_if_statements(nodes, ctx) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_from_if_statements(&1, ctx))
  end

  defp collect_from_if_statements(%{"type" => "IfStatement"} = node, ctx) do
    # Flatten else-if chain: [{:branch, test, conseq}, ..., {:final, else_block_or_nil}]
    chain = flatten_if_chain(node)

    {own, nested_nodes} = process_if_chain(chain, ctx)

    nested =
      Enum.flat_map(nested_nodes, fn n -> collect_nested_ifs(n, ctx) end)

    own ++ nested
  end

  defp collect_from_if_statements(%{} = node, ctx) do
    node
    |> Map.values()
    |> Enum.flat_map(fn
      v when is_map(v) -> collect_from_if_statements(v, ctx)
      v when is_list(v) -> collect_from_if_statements(v, ctx)
      _ -> []
    end)
  end

  defp collect_from_if_statements(_, _ctx), do: []

  defp collect_nested_ifs(%{"type" => "BlockStatement", "body" => stmts}, ctx) when is_list(stmts) do
    collect_from_if_statements(stmts, ctx)
  end

  defp collect_nested_ifs(_, _), do: []

  defp flatten_if_chain(%{"type" => "IfStatement"} = node) do
    test = Map.get(node, "test", %{})
    consequent = Map.get(node, "consequent", %{})
    alternate = Map.get(node, "alternate")

    rest =
      case alternate do
        %{"type" => "IfStatement"} = nested -> flatten_if_chain(nested)
        nil -> [{:final, nil}]
        block -> [{:final, block}]
      end

    [{:branch, test, consequent} | rest]
  end

  defp process_if_chain(chain, ctx) do
    initial = %{own: [], non_auth: [], nested: []}
    result = Enum.reduce(chain, initial, &step_if_chain(&1, &2, ctx))
    {result.own, result.nested}
  end

  defp step_if_chain({:branch, test, consequent}, acc, ctx) do
    values = collect_api_values(test, ctx.bindings)

    if has_check_required_credentials?(consequent) do
      %{acc | own: acc.own ++ values, nested: [consequent | acc.nested]}
    else
      %{acc | non_auth: acc.non_auth ++ values, nested: [consequent | acc.nested]}
    end
  end

  defp step_if_chain({:final, nil}, acc, _ctx), do: acc

  defp step_if_chain({:final, block}, acc, ctx) do
    auth = final_else_auth(block, acc.non_auth, ctx)
    %{acc | own: acc.own ++ auth, nested: [block | acc.nested]}
  end

  defp final_else_auth(block, non_auth, %{api_keys: api_keys}) when is_list(api_keys) and non_auth != [] do
    if alternate_unconditional_check?(block), do: api_keys -- non_auth, else: []
  end

  defp final_else_auth(_block, _non_auth, _ctx), do: []

  # Strict: alternate is a BlockStatement with a top-level checkRequiredCredentials().
  # Avoids false positives from nested conditional auth.
  defp alternate_unconditional_check?(%{"type" => "BlockStatement", "body" => stmts}) when is_list(stmts) do
    Enum.any?(stmts, &top_level_check_call?/1)
  end

  defp alternate_unconditional_check?(_), do: false

  defp top_level_check_call?(%{"type" => "ExpressionStatement", "expression" => expr}) do
    check_call?(expr)
  end

  defp top_level_check_call?(_), do: false

  defp check_call?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "checkRequiredCredentials"}
         }
       }), do: true

  defp check_call?(_), do: false

  defp has_check_required_credentials?(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "checkRequiredCredentials"}
         }
       }), do: true

  defp has_check_required_credentials?(node) when is_map(node) do
    Enum.any?(Map.values(node), &has_check_required_credentials?/1)
  end

  defp has_check_required_credentials?(nodes) when is_list(nodes) do
    Enum.any?(nodes, &has_check_required_credentials?/1)
  end

  defp has_check_required_credentials?(_), do: false

  defp collect_api_values(
         %{
           "type" => "BinaryExpression",
           "operator" => "===",
           "left" => %{"type" => "Identifier", "name" => "api"},
           "right" => %{"type" => "Literal", "value" => value}
         },
         _bindings
       )
       when is_binary(value) do
    [value]
  end

  defp collect_api_values(
         %{
           "type" => "BinaryExpression",
           "operator" => "===",
           "left" => %{
             "type" => "MemberExpression",
             "computed" => true,
             "object" => %{"type" => "Identifier", "name" => "api"}
           },
           "right" => %{"type" => "Literal", "value" => value}
         },
         _bindings
       )
       when is_binary(value) do
    [value]
  end

  defp collect_api_values(%{"type" => "Identifier", "name" => name}, bindings) do
    case Map.get(bindings, name) do
      nil -> []
      section -> [section]
    end
  end

  defp collect_api_values(%{"type" => "LogicalExpression", "left" => left, "right" => right}, bindings) do
    collect_api_values(left, bindings) ++ collect_api_values(right, bindings)
  end

  defp collect_api_values(%{"type" => "ParenthesizedExpression", "expression" => inner}, bindings) do
    collect_api_values(inner, bindings)
  end

  defp collect_api_values(_, _bindings), do: []
end
