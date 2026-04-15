defmodule CcxtExtract.Scope do
  @moduledoc """
  Unified scope resolution for CCXT extraction tasks.

  Composes `CcxtExtract.Tiers` (tier membership with family inheritance)
  with explicit `--exchange` IDs and an `--all` escape hatch to produce
  a single `{exchanges, label}` view every mix task can share.

  Scope selectors:

    * `:tier1 | :tier2 | :tier3 | :dex` — expands to tier members
      (roots + variants/aliases) via `Tiers.members_for_tier/1`
    * `:exchange` — explicit exchange IDs. Accepts repeated
      (`OptionParser` `:keep`) string values, comma-split values,
      and list values (for programmatic callers).
    * `:all` — entire universe. Conflicts with any narrowing flag.

  No scope flags means the same thing as `:all`: the full universe.
  """

  alias CcxtExtract.Tiers

  @tier_keys [:tier1, :tier2, :tier3, :dex]
  @min_jaro_similarity 0.7
  @max_suggestions 3

  @type scope_label :: :all | {:scoped, String.t()}
  @type suggestions :: %{String.t() => [String.t()]}
  @type manifest_value :: String.t() | [String.t()]

  @type resolve_result ::
          {:ok, [String.t()], scope_label}
          | {:error, {:unknown_exchange, [String.t()], suggestions}}
          | {:error, {:all_with_narrowing, [atom()]}}

  @doc """
  Resolves scope selectors against a caller-supplied universe.

  `opts` is the parsed keyword list from `OptionParser`. `universe`
  is the full list of known exchange IDs (typically loaded from
  `priv/discoveries/exchanges.json`).

  Returns:

    * `{:ok, exchanges, :all}` when no narrowing flags are set or
      `--all` is explicit.
    * `{:ok, exchanges, {:scoped, label}}` for any narrowed scope.
      `exchanges` is sorted-unique; `label` is e.g.
      `"TIER 1 + DEX + binance (11)"`.
    * `{:error, {:unknown_exchange, bad_ids, suggestions}}` when any
      `--exchange` ID isn't in the universe. `suggestions` maps each
      bad ID to up to three fuzzy matches (Jaro ≥ 0.7).
    * `{:error, {:all_with_narrowing, conflicting_keys}}` when
      `--all` is combined with any narrowing flag.

  Tier-derived IDs are silently intersected with `universe` — tier
  members not present in the caller's universe are dropped without
  error. Explicit `--exchange` IDs still fail loud on mismatch
  (that's the typo-detection surface). The label's count reflects
  the post-intersection size.
  """
  @spec resolve(keyword(), [String.t()]) :: resolve_result
  def resolve(opts, universe) do
    explicit = parse_exchange_opts(opts)
    narrowing = narrowing_keys(opts, explicit)

    cond do
      opts[:all] && narrowing != [] -> {:error, {:all_with_narrowing, narrowing}}
      opts[:all] -> {:ok, universe, :all}
      narrowing == [] -> {:ok, universe, :all}
      true -> validate_and_build(opts, explicit, universe)
    end
  end

  defp narrowing_keys(opts, explicit) do
    active_tiers = Enum.filter(@tier_keys, fn k -> opts[k] end)
    active_tiers ++ if(explicit == [], do: [], else: [:exchange])
  end

  defp validate_and_build(opts, explicit, universe) do
    universe_set = MapSet.new(universe)
    unknowns = Enum.reject(explicit, &MapSet.member?(universe_set, &1))

    if unknowns == [] do
      {tier_ids, tier_label_raw} = Tiers.collect_tier_exchanges(opts)
      scoped_tier_ids = Enum.filter(tier_ids, &MapSet.member?(universe_set, &1))
      ids = (scoped_tier_ids ++ explicit) |> Enum.uniq() |> Enum.sort()
      label = build_label(tier_label_raw, explicit, length(ids))
      {:ok, ids, {:scoped, label}}
    else
      suggestions = Map.new(unknowns, fn id -> {id, fuzzy_suggest(id, universe)} end)
      {:error, {:unknown_exchange, unknowns, suggestions}}
    end
  end

  defp parse_exchange_opts(opts) do
    opts
    |> Keyword.get_values(:exchange)
    |> Enum.flat_map(&normalize_exchange_value/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_exchange_value(value) when is_list(value), do: Enum.flat_map(value, &normalize_exchange_value/1)

  defp normalize_exchange_value(value) when is_binary(value), do: String.split(value, ",")

  defp fuzzy_suggest(id, universe) do
    universe
    |> Enum.map(fn candidate -> {candidate, String.jaro_distance(id, candidate)} end)
    |> Enum.filter(fn {_c, d} -> d >= @min_jaro_similarity end)
    |> Enum.sort_by(fn {_c, d} -> -d end)
    |> Enum.take(@max_suggestions)
    |> Enum.map(fn {c, _d} -> c end)
  end

  defp build_label(tier_label_raw, explicit, total_count) do
    segments =
      [strip_count_suffix(tier_label_raw), Enum.join(explicit, ", ")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" + ")

    "#{segments} (#{total_count})"
  end

  defp strip_count_suffix(label), do: Regex.replace(~r/\s*\(\d+\)$/, label, "")

  @doc """
  Renders the active scope as a JSON-friendly manifest value.

  Returns `"all"` when no narrowing flags are set (or `--all` is explicit),
  otherwise a sorted, canonicalized list:

      iex> CcxtExtract.Scope.to_manifest_value([])
      "all"
      iex> CcxtExtract.Scope.to_manifest_value(all: true)
      "all"
      iex> CcxtExtract.Scope.to_manifest_value(tier1: true, dex: true)
      ["tier1", "dex"]
      iex> CcxtExtract.Scope.to_manifest_value(exchange: "binance,deribit")
      ["exchange:binance", "exchange:deribit"]
      iex> CcxtExtract.Scope.to_manifest_value(tier1: true, exchange: "hyperliquid")
      ["tier1", "exchange:hyperliquid"]

  Tier entries preserve the canonical tier1/tier2/tier3/dex order; explicit
  exchange entries are sorted alphabetically and prefixed with `exchange:`.
  """
  @spec to_manifest_value(keyword()) :: manifest_value
  def to_manifest_value(opts) do
    active_tiers = Enum.filter(@tier_keys, &Keyword.get(opts, &1))
    explicit = parse_exchange_opts(opts)

    cond do
      opts[:all] -> "all"
      active_tiers == [] and explicit == [] -> "all"
      true -> Enum.map(active_tiers, &Atom.to_string/1) ++ Enum.map(Enum.sort(explicit), &"exchange:#{&1}")
    end
  end
end
