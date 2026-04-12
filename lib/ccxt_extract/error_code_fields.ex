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

  alias CcxtExtract.ErrorCodeFields.Bindings

  @safe_methods ~w(safeString safeString2 safeValue)

  # CCXT helper semantics (base/Exchange.ts):
  #   throwExactlyMatchedException(exact, string, message) — `string in exact`
  #     → arg[1] is an exact lookup key (error code).
  #   throwBroadlyMatchedException(broad, string, message) — `string.indexOf(key) >= 0`
  #     → arg[1] is the message text scanned for substrings.
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
    path_map = Bindings.build_path_map(body)
    resolution_context = Bindings.build_resolution_context(body)
    {safe_calls, var_bindings} = collect_with_bindings(body)
    usage = analyze_usage(body, var_bindings, resolution_context)

    Enum.map(safe_calls, fn entry ->
      var_name = entry["_var_name"]
      roles = Map.get(usage, {:roles, var_name}, [])
      sentinels = Map.get(usage, {:sentinels, var_name}, nil)
      object_path = Bindings.resolve_object_path(entry["object"], path_map)

      entry
      |> Map.delete("_var_name")
      |> Map.put("object_path", object_path)
      |> Map.put("roles", Enum.sort(Enum.uniq(roles)))
      |> Map.put("sentinel_values", format_sentinels(roles, sentinels))
    end)
  end

  def derive(_), do: nil

  # --- Pass 1: Collect safe* calls with variable bindings ---

  defp collect_with_bindings(body) do
    calls = collect_safe_calls(body, nil)
    var_set = calls |> Enum.map(& &1["_var_name"]) |> Enum.reject(&is_nil/1) |> Map.new(&{&1, true})
    {calls, var_set}
  end

  defp collect_safe_calls(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => var_name}, "init" => init} = node,
         _parent_var
       ) do
    own = extract_if_safe_call(init, var_name)
    init_children = collect_children(init, nil)

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

  defp collect_children(node, parent_var) when is_map(node) do
    node |> Map.values() |> Enum.flat_map(&collect_safe_calls(&1, parent_var))
  end

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
    %{
      "object" => Bindings.extract_identifier_name(first_arg),
      "field" => Bindings.extract_literal_value(Enum.at(rest_args, 0)),
      "method" => method_name,
      "field2" => Bindings.extract_literal_value(Enum.at(rest_args, 1)),
      "_var_name" => var_name
    }
  end

  defp extract_if_safe_call(_, _var_name), do: nil

  # --- Pass 2: Analyze usage patterns ---

  defp analyze_usage(body, var_bindings, resolution_context) do
    if var_bindings == %{}, do: %{}, else: scan_usage(body, var_bindings, resolution_context, %{})
  end

  defp scan_usage(node, vars, resolution_context, acc) when is_map(node) do
    acc = detect_throw_usage(node, vars, resolution_context, acc)
    acc = detect_sentinel_usage(node, vars, resolution_context, acc)

    node
    |> Map.values()
    |> Enum.reduce(acc, &scan_usage(&1, vars, resolution_context, &2))
  end

  defp scan_usage(nodes, vars, resolution_context, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &scan_usage(&1, vars, resolution_context, &2))
  end

  defp scan_usage(_, _vars, _resolution_context, acc), do: acc

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
         resolution_context,
         acc
       ) do
    case {Map.get(@throw_role_map, method_name), rest_args} do
      {nil, _} ->
        acc

      {roles, [%{"type" => "Identifier", "name" => var_name} | _]} when is_list(roles) ->
        case Bindings.resolve_bound_var(var_name, resolution_context) do
          nil -> acc
          resolved_var_name -> append_roles(acc, vars, resolved_var_name, roles)
        end

      _ ->
        acc
    end
  end

  defp detect_throw_usage(_, _vars, _resolution_context, acc), do: acc

  defp append_roles(acc, vars, var_name, roles) do
    if Map.has_key?(vars, var_name) do
      Enum.reduce(roles, acc, fn role, inner ->
        Map.update(inner, {:roles, var_name}, [role], &[role | &1])
      end)
    else
      acc
    end
  end

  defp detect_sentinel_usage(
         %{"type" => "BinaryExpression", "operator" => op, "left" => left, "right" => right},
         _vars,
         resolution_context,
         acc
       )
       when op in ["===", "!=="] do
    case resolve_sentinel_pair(left, right, resolution_context) do
      {var_name, value} ->
        sentinel = %{"value" => value, "operator" => op}

        acc
        |> Map.update({:roles, var_name}, ["status_sentinel"], &["status_sentinel" | &1])
        |> Map.update({:sentinels, var_name}, [sentinel], &[sentinel | &1])

      nil ->
        acc
    end
  end

  defp detect_sentinel_usage(_, _vars, _resolution_context, acc), do: acc

  defp resolve_sentinel_pair(
         %{"type" => "Identifier", "name" => var_name},
         %{"type" => "Literal", "value" => value},
         resolution_context
       )
       when not is_nil(value) do
    case Bindings.resolve_bound_var(var_name, resolution_context) do
      nil -> nil
      resolved_var_name -> {resolved_var_name, to_string(value)}
    end
  end

  defp resolve_sentinel_pair(
         %{"type" => "Literal", "value" => value},
         %{"type" => "Identifier", "name" => var_name},
         resolution_context
       )
       when not is_nil(value) do
    case Bindings.resolve_bound_var(var_name, resolution_context) do
      nil -> nil
      resolved_var_name -> {resolved_var_name, to_string(value)}
    end
  end

  defp resolve_sentinel_pair(_, _, _), do: nil

  defp format_sentinels(roles, sentinels) do
    if "status_sentinel" in roles do
      (sentinels || [])
      |> Enum.uniq_by(&{&1["value"], &1["operator"]})
      |> Enum.sort_by(& &1["value"])
    end
  end
end
