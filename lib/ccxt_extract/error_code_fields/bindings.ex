defmodule CcxtExtract.ErrorCodeFields.Bindings do
  @moduledoc """
  Shared AST-binding machinery for deriving `error_code_fields` and
  `throw_dispatches` from handleErrors() method AST.

  Two related graphs are collected by walking a method body:

  * **Var bindings** — `%{var_name => %{"object", "field", "field2", "method"}}`
    for every variable that resolves to a `this.safeString`, `this.safeString2`,
    or `this.safeValue` call, either directly or through a chain of simple
    identifier aliases. Consumers use this to resolve Identifier arguments
    (e.g. arg[1] of a throw helper) back to the safe* call that produced them.

  * **Path map** — `%{var_name => [path_segments]}` tracing variables through
    chains of `this.safe*` derivation methods (safeDict, safeList, etc.) back
    to the ultimate source (typically `"response"`). Used to resolve
    `object_path` for a safe* call whose first argument is an opaque local.
  """

  @safe_methods ~w(safeString safeString2 safeValue)

  # All this.safe* methods that derive one object from another
  @derivation_methods ~w(safeDict safeDict2 safeList safeList2 safeValue safeValue2
                         safeString safeString2 safeInteger safeInteger2 safeNumber
                         safeNumber2 safeTimestamp safeTimestamp2 safeBool safeBool2)

  @type resolution_context :: %{
          bindings: %{String.t() => map()},
          initializers: %{String.t() => map()},
          resolved_vars: %{String.t() => String.t()}
        }

  @doc """
  Build a resolution context for a handleErrors() body.

  The context contains:

  * `bindings` — every variable name that resolves to a safe* call record
  * `initializers` — raw `VariableDeclarator.init` expressions keyed by variable
  * `resolved_vars` — canonical direct safe-binding variable for each resolved name
  """
  @spec build_resolution_context(map() | list() | any()) :: resolution_context()
  def build_resolution_context(body) do
    safe_bindings = collect_safe_bindings(body, %{})
    aliases = collect_alias_bindings(body, %{})
    initializers = collect_initializers(body, %{})
    resolved_vars = resolve_bound_vars(safe_bindings, aliases)

    bindings =
      Map.new(resolved_vars, fn {var_name, safe_var_name} ->
        {var_name, Map.fetch!(safe_bindings, safe_var_name)}
      end)

    %{bindings: bindings, initializers: initializers, resolved_vars: resolved_vars}
  end

  @doc """
  Collect all variables that resolve to a safe* call record.

  This includes direct `this.safe*()` initializers and simple identifier aliases
  that ultimately point at one of those direct bindings.
  """
  @spec collect_var_bindings(map() | list() | any()) :: %{String.t() => map()}
  def collect_var_bindings(body) do
    body
    |> build_resolution_context()
    |> Map.get(:bindings)
  end

  @doc """
  Resolve a variable name to the canonical direct safe-binding variable name.
  """
  @spec resolve_bound_var(String.t(), resolution_context()) :: String.t() | nil
  def resolve_bound_var(var_name, %{resolved_vars: resolved_vars}) do
    Map.get(resolved_vars, var_name)
  end

  @doc """
  Resolve the unique safe* lookup referenced by an AST node, or `nil`.

  This follows:

  * direct safe* call expressions
  * identifier aliases (e.g. `errorInfo = message`)
  * variable initializers that wrap a bound identifier (e.g. `feedback = this.id + ' ' + message`)

  If the node references more than one distinct safe* binding, the result is
  `nil` to avoid guessing.
  """
  @spec resolve_lookup(map() | list() | any(), resolution_context(), map()) :: map() | nil
  def resolve_lookup(node, context, path_map) do
    case node |> collect_lookup_candidates(context, MapSet.new()) |> Enum.uniq() do
      [record] -> format_lookup(record, path_map)
      _ -> nil
    end
  end

  @doc """
  Build the derivation path map for a method body. Keys are variable names
  bound to `this.safe*(source, key, ...)` calls; values are the full path from
  the chain root (e.g. `response`) including the key segments as strings.
  """
  @spec build_path_map(map() | list() | any()) :: %{String.t() => [String.t()]}
  def build_path_map(body) do
    bindings = collect_derivation_bindings(body)
    resolve_paths(bindings)
  end

  @doc """
  Resolve an object identifier to a path list via the given path map.

  Returns `nil` when the object is trivially `"response"`, when there is no
  entry in the path map, or when the path map resolves only to `["response"]`.
  Otherwise returns the list of path segments (strings).
  """
  @spec resolve_object_path(String.t() | nil, map()) :: [String.t()] | nil
  def resolve_object_path(nil, _path_map), do: nil
  def resolve_object_path("response", _path_map), do: nil

  def resolve_object_path(object, path_map) do
    case Map.get(path_map, object) do
      nil -> nil
      ["response"] -> nil
      path -> path
    end
  end

  @doc "Extract the name from an `Identifier` node, or `nil`."
  @spec extract_identifier_name(map() | any()) :: String.t() | nil
  def extract_identifier_name(%{"type" => "Identifier", "name" => name}), do: name
  def extract_identifier_name(_), do: nil

  @doc "Extract the `.value` from a `Literal` node, or `nil`."
  @spec extract_literal_value(map() | any()) :: any()
  def extract_literal_value(%{"type" => "Literal", "value" => value}), do: value
  def extract_literal_value(_), do: nil

  # --- Resolution context ---

  defp format_lookup(record, path_map) do
    %{
      "object" => record["object"],
      "object_path" => resolve_object_path(record["object"], path_map),
      "field" => record["field"],
      "field2" => record["field2"],
      "method" => record["method"]
    }
  end

  defp collect_lookup_candidates(%{"type" => "Identifier", "name" => var_name}, context, seen) do
    cond do
      MapSet.member?(seen, var_name) ->
        []

      Map.has_key?(context.bindings, var_name) ->
        [Map.fetch!(context.bindings, var_name)]

      true ->
        case Map.get(context.initializers, var_name) do
          nil -> []
          init -> collect_lookup_candidates(init, context, MapSet.put(seen, var_name))
        end
    end
  end

  defp collect_lookup_candidates(node, context, seen) when is_map(node) do
    case extract_safe_call_record(node) do
      nil -> node |> Map.values() |> Enum.flat_map(&collect_lookup_candidates(&1, context, seen))
      record -> [record]
    end
  end

  defp collect_lookup_candidates(nodes, context, seen) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_lookup_candidates(&1, context, seen))
  end

  defp collect_lookup_candidates(_, _context, _seen), do: []

  defp resolve_bound_vars(safe_bindings, aliases) do
    direct = Map.new(Map.keys(safe_bindings), &{&1, &1})

    alias_resolved =
      aliases
      |> Map.new(fn {var_name, _target} ->
        {var_name, resolve_safe_var(var_name, safe_bindings, aliases, MapSet.new())}
      end)
      |> Enum.reject(fn {_var_name, safe_var_name} -> is_nil(safe_var_name) end)
      |> Map.new()

    Map.merge(direct, alias_resolved)
  end

  defp resolve_safe_var(var_name, safe_bindings, aliases, seen) do
    cond do
      MapSet.member?(seen, var_name) ->
        nil

      Map.has_key?(safe_bindings, var_name) ->
        var_name

      true ->
        case Map.get(aliases, var_name) do
          nil -> nil
          alias_var -> resolve_safe_var(alias_var, safe_bindings, aliases, MapSet.put(seen, var_name))
        end
    end
  end

  # --- Var binding collection ---

  defp collect_safe_bindings(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => var_name}, "init" => init} = node,
         acc
       ) do
    acc =
      case extract_safe_call_record(init) do
        nil -> acc
        record -> Map.put(acc, var_name, record)
      end

    node
    |> Map.drop(["id", "type"])
    |> Map.values()
    |> Enum.reduce(acc, &collect_safe_bindings/2)
  end

  defp collect_safe_bindings(node, acc) when is_map(node) do
    node |> Map.values() |> Enum.reduce(acc, &collect_safe_bindings/2)
  end

  defp collect_safe_bindings(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_safe_bindings/2)
  end

  defp collect_safe_bindings(_, acc), do: acc

  defp collect_alias_bindings(
         %{
           "type" => "VariableDeclarator",
           "id" => %{"type" => "Identifier", "name" => var_name},
           "init" => %{"type" => "Identifier", "name" => alias_var}
         } = node,
         acc
       ) do
    node
    |> Map.drop(["id", "type"])
    |> Map.values()
    |> Enum.reduce(Map.put(acc, var_name, alias_var), &collect_alias_bindings/2)
  end

  defp collect_alias_bindings(node, acc) when is_map(node) do
    node |> Map.values() |> Enum.reduce(acc, &collect_alias_bindings/2)
  end

  defp collect_alias_bindings(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_alias_bindings/2)
  end

  defp collect_alias_bindings(_, acc), do: acc

  defp collect_initializers(
         %{"type" => "VariableDeclarator", "id" => %{"type" => "Identifier", "name" => var_name}, "init" => init} = node,
         acc
       ) do
    node
    |> Map.drop(["id", "type"])
    |> Map.values()
    |> Enum.reduce(Map.put(acc, var_name, init), &collect_initializers/2)
  end

  defp collect_initializers(node, acc) when is_map(node) do
    node |> Map.values() |> Enum.reduce(acc, &collect_initializers/2)
  end

  defp collect_initializers(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_initializers/2)
  end

  defp collect_initializers(_, acc), do: acc

  defp extract_safe_call_record(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => method_name}
         },
         "arguments" => [first_arg | rest_args]
       })
       when method_name in @safe_methods do
    %{
      "object" => extract_identifier_name(first_arg),
      "field" => extract_literal_value(Enum.at(rest_args, 0)),
      "field2" => extract_literal_value(Enum.at(rest_args, 1)),
      "method" => method_name
    }
  end

  defp extract_safe_call_record(_), do: nil

  # --- Path map construction ---

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

  defp resolve_paths(bindings) do
    Map.new(bindings, fn {var_name, _} ->
      {var_name, trace_path(var_name, bindings, [])}
    end)
  end

  defp trace_path(var_name, bindings, seen) do
    cond do
      var_name in seen -> [var_name]
      is_nil(Map.get(bindings, var_name)) -> [var_name]
      true -> extend_path(Map.get(bindings, var_name), bindings, [var_name | seen])
    end
  end

  defp extend_path({source, key}, bindings, seen) do
    parent_path = trace_path(source, bindings, seen)
    if key, do: parent_path ++ [to_string(key)], else: parent_path
  end
end
