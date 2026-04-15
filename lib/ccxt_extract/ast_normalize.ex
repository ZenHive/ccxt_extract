defmodule CcxtExtract.AstNormalize do
  @moduledoc """
  Normalize OXC 0.7+ AST atoms back to PascalCase strings for stable JSON output.

  `oxc` 0.7 changed AST `:type` node values from PascalCase strings
  (`"BlockStatement"`) to snake_case atoms (`:block_statement`). To keep the
  emitted discovery / output JSON byte-identical with the oxc 0.6 era, AST
  type values are converted back to PascalCase at the serialization boundary.

  `:kind` atoms (`:const`, `:let`, `:init`) are kept lowercase — their atom
  string form matches the pre-existing output convention.
  """

  @doc """
  Recursively walk data and convert `:type`/`"type"` atom values to their
  PascalCase string form. Leaves everything else untouched.
  """
  @spec normalize(term()) :: term()
  def normalize(%_{} = struct), do: struct
  def normalize(%{} = map), do: Map.new(map, &normalize_entry/1)
  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(other), do: other

  defp normalize_entry({k, v}) when k in [:type, "type"] and is_atom(v) and v not in [nil, true, false] do
    {k, atom_to_pascal(v)}
  end

  defp normalize_entry({k, v}), do: {k, normalize(v)}

  @doc """
  Convert a snake_case atom to its PascalCase string form.

      iex> atom_to_pascal(:block_statement)
      "BlockStatement"

      iex> atom_to_pascal(:ts_array_type)
      "TSArrayType"

      iex> atom_to_pascal(:super)
      "Super"
  """
  @spec atom_to_pascal(atom()) :: String.t()
  def atom_to_pascal(atom) do
    case Atom.to_string(atom) do
      "ts_" <> rest -> "TS" <> pascal(rest)
      s -> pascal(s)
    end
  end

  defp pascal(s), do: s |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
end
