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

  # CCXT helper semantics (base/Exchange.ts):
  #   throwExactlyMatchedException(exact, string, message) — `string in exact` → arg[1] is an exact lookup key (error code).
  #   throwBroadlyMatchedException(broad, string, message) — `string.indexOf(key) >= 0` → arg[1] is the message text scanned for substrings.
  # A field that flows through both helpers in the same handleErrors() naturally accumulates both roles.
  @throw_role_map %{
    "throwExactlyMatchedException" => ["error_code"],
    "throwBroadlyMatchedException" => ["error_message"]
  }

  @doc """
  Derive error code field references and their roles from a handleErrors() method AST.

  Returns a list of safe* call records with role classification, or nil if the
  method AST is nil. Returns an empty list if no safe* calls are found.
  """
  @spec derive(map() | nil) :: [map()] | nil
  def derive(nil), do: nil

  def derive(%{"body" => body}) when is_map(body) do
    # Pass 0: build variable derivation path map
    path_map = build_path_map(body)

    # Pass 1: collect safe* calls with variable bindings
    {safe_calls, var_bindings} = collect_with_bindings(body)

    # Pass 2: analyze how bound variables are used
    usage = analyze_usage(body, var_bindings)

    # Merge roles, sentinel values, and object paths into each entry
    Enum.map(safe_calls, fn entry ->
      var_name = entry["_var_name"]
      roles = Map.get(usage, {:roles, var_name}, [])
      sentinels = Map.get(usage, {:sentinels, var_name}, nil)
      object_path = resolve_object_path(entry["object"], path_map)

      entry
      |> Map.delete("_var_name")
      |> Map.put("object_path", object_path)
      |> Map.put("roles", Enum.sort(Enum.uniq(roles)))
      |> Map.put("sentinel_values", format_sentinels(roles, sentinels))
    end)
  end

  def derive(_), do: nil

  # --- Pass 1: Collect safe* calls with variable bindings ---

  # Walks the AST collecting safe* calls. When a safe* call is the init of a
  # VariableDeclarator, records the variable name on the entry as "_var_name".
  # Returns {safe_calls, var_bindings} where var_bindings maps var_name to true.
  defp collect_with_bindings(body) do
    calls = collect_safe_calls(body, nil)
    var_set = calls |> Enum.map(& &1["_var_name"]) |> Enum.reject(&is_nil/1) |> Map.new(&{&1, true})
    {calls, var_set}
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
  defp analyze_usage(body, var_bindings) do
    if var_bindings == %{}, do: %{}, else: scan_usage(body, var_bindings, %{})
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

      {roles, [%{"type" => "Identifier", "name" => var_name} | _]} when is_list(roles) ->
        append_roles(acc, vars, var_name, roles)

      _ ->
        acc
    end
  end

  defp detect_throw_usage(_, _vars, acc), do: acc

  # Appends multiple roles for a variable if it's in the bound set
  defp append_roles(acc, vars, var_name, roles) do
    if Map.has_key?(vars, var_name) do
      Enum.reduce(roles, acc, fn role, inner ->
        Map.update(inner, {:roles, var_name}, [role], &[role | &1])
      end)
    else
      acc
    end
  end

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
        sentinel = %{"value" => value, "operator" => op}

        acc
        |> Map.update({:roles, var_name}, ["status_sentinel"], &["status_sentinel" | &1])
        |> Map.update({:sentinels, var_name}, [sentinel], &[sentinel | &1])

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
    if Map.has_key?(vars, var_name), do: {var_name, to_string(value)}
  end

  defp resolve_sentinel_pair(
         %{"type" => "Literal", "value" => value},
         %{"type" => "Identifier", "name" => var_name},
         vars
       )
       when not is_nil(value) do
    if Map.has_key?(vars, var_name), do: {var_name, to_string(value)}
  end

  defp resolve_sentinel_pair(_, _, _), do: nil

  # --- Pass 0: Build variable derivation path map ---

  # All this.safe* methods that derive objects from other objects
  @derivation_methods ~w(safeDict safeDict2 safeList safeList2 safeValue safeValue2
                         safeString safeString2 safeInteger safeInteger2 safeNumber
                         safeNumber2 safeTimestamp safeTimestamp2 safeBool safeBool2)

  # Walks the AST collecting VariableDeclarator → this.safe*(obj, key) bindings.
  # Returns %{var_name => [path_segments]} where path traces back to "response".
  defp build_path_map(body) do
    bindings = collect_derivation_bindings(body)
    resolve_paths(bindings)
  end

  # Collect raw bindings: %{var_name => {source_var, key}}
  defp collect_derivation_bindings(node) when is_map(node) do
    own = extract_derivation_binding(node)

    children =
      node
      |> Map.values()
      |> Enum.reduce(%{}, fn child, acc -> Map.merge(acc, collect_derivation_bindings(child)) end)

    Map.merge(children, own)
  end

  defp collect_derivation_bindings(nodes) when is_list(nodes) do
    Enum.reduce(nodes, %{}, fn node, acc -> Map.merge(acc, collect_derivation_bindings(node)) end)
  end

  defp collect_derivation_bindings(_), do: %{}

  # Extract a single binding from a VariableDeclarator with a this.safe*() init
  defp extract_derivation_binding(%{
         "type" => "VariableDeclarator",
         "id" => %{"type" => "Identifier", "name" => var_name},
         "init" => %{
           "type" => "CallExpression",
           "callee" => %{
             "type" => "MemberExpression",
             "object" => %{"type" => "ThisExpression"},
             "property" => %{"type" => "Identifier", "name" => method_name}
           },
           "arguments" => [first_arg | rest_args]
         }
       })
       when method_name in @derivation_methods do
    source = extract_identifier_name(first_arg)
    key = extract_literal_value(Enum.at(rest_args, 0))
    if source, do: %{var_name => {source, key}}, else: %{}
  end

  defp extract_derivation_binding(_), do: %{}

  # Resolve raw bindings into full paths by following chains
  defp resolve_paths(bindings) do
    Map.new(bindings, fn {var_name, _} ->
      {var_name, trace_path(var_name, bindings, [])}
    end)
  end

  # Trace a variable back through its derivation chain to build the full path
  defp trace_path(var_name, bindings, seen) do
    if var_name in seen do
      # Cycle detected — return what we have
      [var_name]
    else
      case Map.get(bindings, var_name) do
        nil ->
          # Terminal — this is either "response" or an untracked parameter
          [var_name]

        {source, key} ->
          parent_path = trace_path(source, bindings, [var_name | seen])
          if key, do: parent_path ++ [to_string(key)], else: parent_path
      end
    end
  end

  # Resolve object_path for an entry: null if trivially "response", path otherwise
  defp resolve_object_path(nil, _path_map), do: nil
  defp resolve_object_path("response", _path_map), do: nil

  defp resolve_object_path(object, path_map) do
    case Map.get(path_map, object) do
      nil -> nil
      ["response"] -> nil
      path -> path
    end
  end

  # --- Shared helpers ---

  # Formats sentinel_values: null if no sentinel role, sorted by value otherwise
  defp format_sentinels(roles, sentinels) do
    if "status_sentinel" in roles do
      (sentinels || [])
      |> Enum.uniq_by(&{&1["value"], &1["operator"]})
      |> Enum.sort_by(& &1["value"])
    end
  end

  defp extract_identifier_name(%{"type" => "Identifier", "name" => name}), do: name
  defp extract_identifier_name(_), do: nil

  defp extract_literal_value(%{"type" => "Literal", "value" => value}), do: value
  defp extract_literal_value(_), do: nil
end
