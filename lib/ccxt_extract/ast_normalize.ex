defmodule CcxtExtract.AstNormalize do
  @moduledoc """
  Normalize OXC AST atoms back to PascalCase strings and produce
  byte-deterministic JSON via sorted-key encoding.

  ## :type atom rewrite (`normalize/1`)

  `oxc` 0.7 changed AST `:type` node values from PascalCase strings
  (`"BlockStatement"`) to snake_case atoms (`:block_statement`). To
  keep the emitted discovery / output JSON byte-identical with the
  oxc 0.6 era, AST type values are converted back to PascalCase at the
  serialization boundary. `:kind` atoms (`:const`, `:let`, `:init`)
  are kept lowercase — their atom string form matches the pre-existing
  output convention.

  `normalize/1` returns plain Elixir maps. Downstream consumers
  (`SignRecipe.Derive`, `ErrorCodeFields`, `ParseDispatch`, …)
  pattern-match on those maps, so this stage must stay
  shape-compatible with `Map`.

  ## Deterministic emit (`to_encodable/1` — Task 114)

  At the JSON write boundary, every map is recursively wrapped in
  `Jason.OrderedObject` with keys sorted ascending. Without this,
  `Jason.encode!` emits keys in the BEAM's internal map order — flat
  insertion order for ≤32-key maps, hash order for larger maps. Both
  are deterministic per VM but reshuffle across BEAM restarts (per-VM
  hash seed in OTP 26+) and across the 32→33-key crossover. The sort
  makes the on-disk JSON byte-identical regardless of either.

  Atom keys are coerced to their string form before sorting so
  `%{a: 1, "b" => 2}` produces stable output. Structs other than
  `Jason.OrderedObject` pass through unchanged — domain values like
  `DateTime` encode to a fixed string regardless.
  """

  @doc """
  Recursively walk data and convert `:type`/`"type"` atom values to
  their PascalCase string form. Returns plain Elixir maps and lists.
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
  Walk a term and produce a `Jason`-encodable form whose maps emit
  with sorted keys — the canonical form used at every write boundary
  for byte-stable JSON.

  Combines `normalize/1`'s `:type` atom rewrite with the
  `Jason.OrderedObject` wrap, so callers only need a single pass:

      File.write!(path, Jason.encode!(AstNormalize.to_encodable(payload)))

  `Jason.OrderedObject` envelopes already present in the input are
  unwrapped + re-sorted so multi-stage pipelines stay idempotent.
  """
  @spec to_encodable(term()) :: term()
  def to_encodable(%Jason.OrderedObject{values: pairs}), do: wrap_sorted(pairs)

  def to_encodable(%_{} = struct), do: struct
  def to_encodable(%{} = map), do: map |> Enum.map(&normalize_entry/1) |> wrap_sorted()
  def to_encodable(list) when is_list(list), do: Enum.map(list, &to_encodable/1)
  def to_encodable(other), do: other

  defp wrap_sorted(pairs) do
    pairs
    |> Enum.map(fn {k, v} -> {k, to_encodable(v)} end)
    |> Enum.sort_by(&sort_key/1)
    |> Jason.OrderedObject.new()
  end

  # String form is the comparison ground for mixed atom/string keys.
  defp sort_key({k, _v}) when is_atom(k), do: Atom.to_string(k)
  defp sort_key({k, _v}) when is_binary(k), do: k

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
