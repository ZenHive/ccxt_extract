defmodule CcxtExtract.ThrowDispatches do
  @moduledoc """
  Derive structural `throw_dispatches` entries from a handleErrors() method AST.

  Each `this.throwExactlyMatchedException(exceptionsMap, lookupVar, message)` or
  `this.throwBroadlyMatchedException(...)` call in the method body becomes one
  entry. The entry records:

  * `helper` — which throw helper was called
  * `exceptions_source` — normalized tag for arg[0]
    (`exceptions`, `exceptions.exact`, `exceptions.broad`, `by_url.exact`,
    `by_url.broad`, or `other`)
  * `exceptions_source_raw` — string rendering of arg[0] (anti-rot hatch: when
    the normalizer can't classify a shape, consumers still see the original
    source expression)
  * `lookup` — the resolved safe* binding for arg[1] (same shape as an
    `error_code_fields` entry minus `roles`/`sentinel_values`, plus `method`),
    or `nil` when arg[1] isn't a bound Identifier
  * `message_lookup` — the unique resolved safe* binding referenced anywhere in
    arg[2], or `nil` when the message expression does not point at a single
    bound lookup value
  """

  alias CcxtExtract.ErrorCodeFields.Bindings

  @throw_helpers ~w(throwExactlyMatchedException throwBroadlyMatchedException)

  @doc """
  Derive a list of `ThrowDispatchEntry` maps from a handleErrors() method AST.

  Returns `nil` when the input is nil or not a `%{"body" => _}` map. Returns an
  empty list when no throw dispatches are found.
  """
  @spec derive(map() | nil) :: [map()] | nil
  def derive(nil), do: nil

  def derive(%{"body" => body}) when is_map(body) do
    resolution_context = Bindings.build_resolution_context(body)
    path_map = Bindings.build_path_map(body)

    body
    |> collect_throw_calls()
    |> Enum.map(&build_entry(&1, resolution_context, path_map))
  end

  def derive(_), do: nil

  # --- Collect throw helper calls ---

  defp collect_throw_calls(node) when is_map(node) do
    own =
      case match_throw_call(node) do
        nil -> []
        call -> [call]
      end

    children = node |> Map.values() |> Enum.flat_map(&collect_throw_calls/1)
    own ++ children
  end

  defp collect_throw_calls(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_throw_calls/1)
  end

  defp collect_throw_calls(_), do: []

  defp match_throw_call(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => helper}
         },
         "arguments" => args
       })
       when helper in @throw_helpers do
    %{
      helper: helper,
      exceptions_arg: Enum.at(args, 0),
      lookup_arg: Enum.at(args, 1),
      message_arg: Enum.at(args, 2)
    }
  end

  defp match_throw_call(_), do: nil

  # --- Build output entry ---

  defp build_entry(
         %{helper: helper, exceptions_arg: ex_arg, lookup_arg: lookup_arg, message_arg: message_arg},
         resolution_context,
         path_map
       ) do
    %{
      "helper" => helper,
      "exceptions_source" => classify_exceptions_source(ex_arg),
      "exceptions_source_raw" => render_ast(ex_arg),
      "lookup" => Bindings.resolve_lookup(lookup_arg, resolution_context, path_map),
      "message_lookup" => Bindings.resolve_lookup(message_arg, resolution_context, path_map)
    }
  end

  # --- Exceptions source normalization ---

  # this.exceptions
  defp classify_exceptions_source(%{
         "type" => "MemberExpression",
         "object" => %{"type" => "ThisExpression"},
         "property" => prop,
         "computed" => computed
       }) do
    case extract_key(prop, computed) do
      "exceptions" -> "exceptions"
      _ -> "other"
    end
  end

  # this.exceptions['exact'] or this.exceptions.exact
  defp classify_exceptions_source(%{
         "type" => "MemberExpression",
         "object" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "exceptions"}
         },
         "property" => prop,
         "computed" => computed
       }) do
    case extract_key(prop, computed) do
      "exact" -> "exceptions.exact"
      "broad" -> "exceptions.broad"
      _ -> "other"
    end
  end

  # this.getExceptionsByUrl(url, 'exact' | 'broad')
  defp classify_exceptions_source(%{
         "type" => "CallExpression",
         "callee" => %{
           "type" => "MemberExpression",
           "object" => %{"type" => "ThisExpression"},
           "property" => %{"type" => "Identifier", "name" => "getExceptionsByUrl"}
         },
         "arguments" => args
       }) do
    case Enum.at(args, 1) do
      %{"type" => "Literal", "value" => "exact"} -> "by_url.exact"
      %{"type" => "Literal", "value" => "broad"} -> "by_url.broad"
      _ -> "other"
    end
  end

  defp classify_exceptions_source(_), do: "other"

  defp extract_key(%{"type" => "Literal", "value" => v}, true) when is_binary(v), do: v
  defp extract_key(%{"type" => "Identifier", "name" => n}, false), do: n
  defp extract_key(_, _), do: nil

  # --- AST string renderer ---

  defp render_ast(%{"type" => "ThisExpression"}), do: "this"
  defp render_ast(%{"type" => "Identifier", "name" => name}), do: name

  defp render_ast(%{"type" => "Literal", "value" => v}) when is_binary(v), do: "'#{v}'"
  defp render_ast(%{"type" => "Literal", "value" => v}) when is_nil(v), do: "null"
  defp render_ast(%{"type" => "Literal", "value" => v}), do: to_string(v)

  defp render_ast(%{"type" => "MemberExpression", "object" => obj, "property" => prop, "computed" => computed}) do
    obj_str = render_ast(obj)

    if computed do
      "#{obj_str}[#{render_ast(prop)}]"
    else
      "#{obj_str}.#{render_ast(prop)}"
    end
  end

  defp render_ast(%{"type" => "CallExpression", "callee" => callee, "arguments" => args}) do
    args_str = Enum.map_join(args, ", ", &render_ast/1)
    "#{render_ast(callee)}(#{args_str})"
  end

  defp render_ast(%{"type" => type}), do: "<#{type}>"
  defp render_ast(_), do: "<unknown>"
end
