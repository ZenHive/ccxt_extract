defmodule CcxtExtract.ErrorCodeFields do
  @moduledoc """
  Derive error code field names and their roles from the handleErrors() method AST.

  Two-pass analysis:

  **Pass 1** — Walk the handleErrors() AST collecting all `this.safeString()`,
  `this.safeString2()`, and `this.safeValue()` calls. When a call is the `init`
  of a `VariableDeclarator`, record the variable name binding.

  **Pass 2** — Scan the full function body for usage patterns that classify each
  field's role:

  - `"error_code"` — variable passed to `this.throwExactlyMatchedException()`
  - `"error_message"` — variable passed to `this.throwBroadlyMatchedException()`
  - `"status_sentinel"` — variable compared against literals via `===` or `!==`

  A single field can have multiple roles (e.g., Binance's `code` is both
  `error_code` and `status_sentinel`).

  ## Usage

      CcxtExtract.ErrorCodeFields.derive(method_ast)
      #=> [%{"object" => "response", "field" => "code", "method" => "safeString",
      #       "field2" => nil, "roles" => ["error_code", "status_sentinel"],
      #       "sentinel_values" => ["0", "200"]}, ...]
  """

  @safe_methods ~w(safeString safeString2 safeValue)

  @throw_role_map %{
    "throwExactlyMatchedException" => "error_code",
    "throwBroadlyMatchedException" => "error_message"
  }

  @doc """
  Derive error code field references and their roles from a handleErrors() method AST.

  Returns a list of safe* call records with role classification, or nil if the
  method AST is nil. Returns an empty list if no safe* calls are found.
  """
  @spec derive(map() | nil) :: [map()] | nil
  def derive(nil), do: nil

  def derive(%{"body" => body}) when is_map(body) do
    # Pass 1: collect safe* calls with variable bindings
    {safe_calls, var_bindings} = collect_with_bindings(body)

    # Pass 2: analyze how bound variables are used
    usage = analyze_usage(body, var_bindings)

    # Merge roles and sentinel values into each entry
    Enum.map(safe_calls, fn entry ->
      var_name = entry["_var_name"]
      roles = Map.get(usage, {:roles, var_name}, [])
      sentinels = Map.get(usage, {:sentinels, var_name}, nil)

      entry
      |> Map.delete("_var_name")
      |> Map.put("roles", Enum.sort(Enum.uniq(roles)))
      |> Map.put("sentinel_values", if("status_sentinel" in roles, do: Enum.sort(Enum.uniq(sentinels || []))))
    end)
  end

  def derive(_), do: nil

  # --- Pass 1: Collect safe* calls with variable bindings ---

  # Walks the AST collecting safe* calls. When a safe* call is the init of a
  # VariableDeclarator, records the variable name on the entry as "_var_name".
  # Returns {safe_calls, var_bindings} where var_bindings maps var_name to true.
  defp collect_with_bindings(body) do
    calls = collect_safe_calls(body, nil)
    var_names = calls |> Enum.map(& &1["_var_name"]) |> Enum.reject(&is_nil/1) |> MapSet.new()
    {calls, var_names}
  end

  # Walk with parent context to detect VariableDeclarator wrapping
  defp collect_safe_calls(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => var_name}, "init" => init} = node,
         _parent_var
       ) do
    # Check if init is directly a safe* call
    own = extract_if_safe_call(init, var_name)

    # Also recurse into the init for nested safe* calls (rare but possible)
    init_children = collect_children(init, nil)

    # Recurse remaining children (not init, already handled)
    other_children =
      node
      |> Map.drop(["init", "id", "type"])
      |> Map.values()
      |> Enum.flat_map(&collect_safe_calls(&1, nil))

    case own do
      nil -> init_children ++ other_children
      record -> [record | init_children ++ other_children]
    end
  end

  defp collect_safe_calls(node, parent_var) when is_map(node) do
    own = extract_if_safe_call(node, parent_var)
    children = collect_children(node, nil)

    case own do
      nil -> children
      record -> [record | children]
    end
  end

  defp collect_safe_calls(nodes, parent_var) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_safe_calls(&1, parent_var))
  end

  defp collect_safe_calls(_, _parent_var), do: []

  # Collect children of a node (all map values)
  defp collect_children(node, parent_var) when is_map(node) do
    node |> Map.values() |> Enum.flat_map(&collect_safe_calls(&1, parent_var))
  end

  # Check if a node is a this.safe*(obj, field, ...) CallExpression
  defp extract_if_safe_call(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => method_name}
           },
           "arguments" => [first_arg | rest_args]
         },
         var_name
       )
       when method_name in @safe_methods do
    object = extract_identifier_name(first_arg)
    field = extract_literal_value(Enum.at(rest_args, 0))
    field2 = extract_literal_value(Enum.at(rest_args, 1))

    %{
      "object" => object,
      "field" => field,
      "method" => method_name,
      "field2" => field2,
      "_var_name" => var_name
    }
  end

  defp extract_if_safe_call(_, _var_name), do: nil

  # --- Pass 2: Analyze usage patterns ---

  # Scans the full AST body for throw* calls and === / !== comparisons
  # involving variables that were bound to safe* calls.
  # Returns %{{:roles, var_name} => [role, ...], {:sentinels, var_name} => [value, ...]}
  defp analyze_usage(_body, var_bindings) when var_bindings == %MapSet{} do
    %{}
  end

  defp analyze_usage(body, var_bindings) do
    scan_usage(body, var_bindings, %{})
  end

  defp scan_usage(node, vars, acc) when is_map(node) do
    # Check for throw*MatchedException calls
    acc = detect_throw_usage(node, vars, acc)

    # Check for === / !== comparisons
    acc = detect_sentinel_usage(node, vars, acc)

    # Recurse into children
    node
    |> Map.values()
    |> Enum.reduce(acc, &scan_usage(&1, vars, &2))
  end

  defp scan_usage(nodes, vars, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &scan_usage(&1, vars, &2))
  end

  defp scan_usage(_, _vars, acc), do: acc

  # Detect: this.throwExactlyMatchedException(_, variable, _)
  #     or: this.throwBroadlyMatchedException(_, variable, _)
  defp detect_throw_usage(
         %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => method_name}
           },
           "arguments" => [_first | rest_args]
         },
         vars,
         acc
       ) do
    case {Map.get(@throw_role_map, method_name), rest_args} do
      {nil, _} ->
        acc

      {role, [%{"type" => "Identifier", "name" => var_name} | _]} when is_binary(role) ->
        if MapSet.member?(vars, var_name) do
          Map.update(acc, {:roles, var_name}, [role], &[role | &1])
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp detect_throw_usage(_, _vars, acc), do: acc

  # Detect: variable === literal  or  literal === variable
  #         variable !== literal  or  literal !== variable
  defp detect_sentinel_usage(
         %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right},
         vars,
         acc
       )
       when op in ["===", "!=="] do
    case resolve_sentinel_pair(left, right, vars) do
      {var_name, value} ->
        acc
        |> Map.update({:roles, var_name}, ["status_sentinel"], &["status_sentinel" | &1])
        |> Map.update({:sentinels, var_name}, [value], &[value | &1])

      nil ->
        acc
    end
  end

  defp detect_sentinel_usage(_, _vars, acc), do: acc

  # Try both orderings: var op literal, or literal op var
  defp resolve_sentinel_pair(
         %{"type" => "Identifier", "name" => var_name},
         %{"type" => "Literal", "value" => value},
         vars
       )
       when not is_nil(value) do
    if MapSet.member?(vars, var_name), do: {var_name, to_string(value)}
  end

  defp resolve_sentinel_pair(
         %{"type" => "Literal", "value" => value},
         %{"type" => "Identifier", "name" => var_name},
         vars
       )
       when not is_nil(value) do
    if MapSet.member?(vars, var_name), do: {var_name, to_string(value)}
  end

  defp resolve_sentinel_pair(_, _, _), do: nil

  # --- Shared helpers ---

  defp extract_identifier_name(%{"type" => "Identifier", "name" => name}), do: name
  defp extract_identifier_name(_), do: nil

  defp extract_literal_value(%{"type" => "Literal", "value" => value}), do: value
  defp extract_literal_value(_), do: nil
end
