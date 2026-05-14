defmodule CcxtExtract.JsonDiff do
  @moduledoc """
  Shared helpers for byte-level JSON-file comparison with volatile-key
  stripping.

  Generalizes the volatile-strip pattern that `CcxtExtract.FixtureParity`
  uses for signing fixtures (`@volatile_keys ["generated_at"]`) so the
  determinism harness (`mix ccxt_extract.determinism_check`) can apply it
  corpus-wide. Both consumers walk the same shape, drop the same keys at
  every depth, and surface only the differences that survive the strip.

  ## Why "strip-then-byte-diff"

  Byte-level equality is the strongest possible determinism claim — it
  catches map-iteration-order drift, JSON encoder choices, and lurking
  insertion-order quirks that semantic diff (`==`) papers over. But
  timestamps are legitimately non-deterministic and would mask the
  interesting signal. Strip the volatile keys first, re-serialize through
  a stable encoder, then `==` the resulting bytes.
  """

  # Default width of the per-side context window in a `{:diff, _}` result.
  # Overridable via `opts[:context_bytes]` on `diff_files/3` / `diff_terms/3`.
  @default_context_bytes 80

  @doc """
  Default keys stripped before comparison.

  These are the timestamp / wall-clock fields written by individual
  extractors (`extracted_at`, `generated_at`) and validators
  (`checked_at`, `validated_at`, `recorded_at`). Callers can extend the
  set via `strip_volatile/2`.
  """
  @spec default_volatile_keys() :: [String.t()]
  def default_volatile_keys do
    ["extracted_at", "generated_at", "checked_at", "validated_at", "recorded_at"]
  end

  @doc """
  Recursively drop `keys` at every map depth, then walk lists element-wise.

  Non-map / non-list values pass through unchanged.

      iex> CcxtExtract.JsonDiff.strip_volatile(
      ...>   %{"a" => 1, "extracted_at" => "now"}, ["extracted_at"])
      %{"a" => 1}

      iex> CcxtExtract.JsonDiff.strip_volatile(
      ...>   [%{"generated_at" => 1, "v" => 2}], ["generated_at"])
      [%{"v" => 2}]
  """
  @spec strip_volatile(term(), [String.t()]) :: term()
  def strip_volatile(value, keys \\ default_volatile_keys())

  def strip_volatile(map, keys) when is_map(map) do
    map
    |> Map.drop(keys)
    |> Map.new(fn {k, v} -> {k, strip_volatile(v, keys)} end)
  end

  def strip_volatile(list, keys) when is_list(list) do
    Enum.map(list, &strip_volatile(&1, keys))
  end

  def strip_volatile(other, _keys), do: other

  @doc """
  Compare two JSON files byte-for-byte after stripping volatile keys and
  re-encoding through a stable, key-sorted encoder.

  Returns `:equal` when the canonical bytes match, or
  `{:diff, %{byte: pos, a_context: ..., b_context: ...}}` with a context
  window around the first divergent byte. The window width is
  `opts[:context_bytes]` (default #{@default_context_bytes}).

  The re-encode pass closes a footgun: two files that decode to equal
  Elixir terms but were written with different map-iteration orders are
  byte-unequal on disk. After `strip_volatile/2` and a sorted-key
  re-encode they're guaranteed equal-or-meaningful.

  Returns `{:error, reason}` if either file is unreadable or not valid
  JSON.
  """
  @spec diff_files(Path.t(), Path.t(), keyword()) ::
          :equal
          | {:diff, %{byte: non_neg_integer(), a_context: String.t(), b_context: String.t()}}
          | {:error, {:read, Path.t(), term()} | {:decode, Path.t(), term()}}
  def diff_files(path_a, path_b, opts \\ []) do
    keys = Keyword.get(opts, :strip_keys, default_volatile_keys())
    ctx_bytes = Keyword.get(opts, :context_bytes, @default_context_bytes)

    with {:ok, a} <- canonical_bytes(path_a, keys),
         {:ok, b} <- canonical_bytes(path_b, keys) do
      if a == b, do: :equal, else: {:diff, byte_diff_context(a, b, ctx_bytes)}
    end
  end

  @doc """
  Compare two JSON-decoded terms via the same strip + canonical-encode
  pipeline used by `diff_files/3`. Useful when callers already hold
  decoded terms (e.g. tests) and want to skip the disk round-trip.
  """
  @spec diff_terms(term(), term(), keyword()) :: :equal | {:diff, map()}
  def diff_terms(a, b, opts \\ []) do
    keys = Keyword.get(opts, :strip_keys, default_volatile_keys())
    ctx_bytes = Keyword.get(opts, :context_bytes, @default_context_bytes)
    a_bytes = a |> strip_volatile(keys) |> canonical_encode()
    b_bytes = b |> strip_volatile(keys) |> canonical_encode()
    if a_bytes == b_bytes, do: :equal, else: {:diff, byte_diff_context(a_bytes, b_bytes, ctx_bytes)}
  end

  @doc """
  Encode `term` with sorted map keys at every depth.

  Wraps each map in a `Jason.OrderedObject` so Jason emits keys in the
  list order, not BEAM hash order. Strings are sorted ascending. This
  is the canonical form used by both `diff_files/3` and `diff_terms/3`.
  """
  @spec canonical_encode(term()) :: binary()
  def canonical_encode(term) do
    term |> sort_keys() |> Jason.encode!()
  end

  @spec sort_keys(term()) :: term()
  defp sort_keys(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end)
      |> Enum.sort_by(&elem(&1, 0))

    Jason.OrderedObject.new(pairs)
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other

  @spec canonical_bytes(Path.t(), [String.t()]) ::
          {:ok, binary()} | {:error, {:decode | :read, Path.t(), term()}}
  defp canonical_bytes(path, keys) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} -> {:ok, decoded |> strip_volatile(keys) |> canonical_encode()}
          {:error, reason} -> {:error, {:decode, path, reason}}
        end

      {:error, reason} ->
        {:error, {:read, path, reason}}
    end
  end

  # First-divergent-byte locator with `ctx_bytes`-wide context windows on
  # each side for human-readable reporting. Returns position in bytes
  # (0-indexed).
  @spec byte_diff_context(binary(), binary(), pos_integer()) ::
          %{byte: non_neg_integer(), a_context: String.t(), b_context: String.t()}
  defp byte_diff_context(a, b, ctx_bytes) do
    pos = first_diff_position(a, b, 0)
    %{byte: pos, a_context: context(a, pos, ctx_bytes), b_context: context(b, pos, ctx_bytes)}
  end

  @spec first_diff_position(binary(), binary(), non_neg_integer()) :: non_neg_integer()
  defp first_diff_position(a, b, i) when byte_size(a) == i and byte_size(b) == i, do: i

  defp first_diff_position(a, b, i) do
    case {a, b} do
      {<<_::binary-size(i), x, _::binary>>, <<_::binary-size(i), y, _::binary>>} when x == y ->
        first_diff_position(a, b, i + 1)

      _ ->
        i
    end
  end

  @spec context(binary(), non_neg_integer(), pos_integer()) :: String.t()
  defp context(bytes, pos, width) do
    start = max(0, pos - div(width, 2))
    len = min(width, byte_size(bytes) - start)
    binary_part(bytes, start, len)
  end
end
