defmodule CcxtExtract.Tiers do
  @moduledoc """
  Priority-tier classification for CCXT exchanges.

  Tier membership has two layers:

    * **Roots** — hand-curated in `priv/priority_tiers.json`. These are the
      canonical per-tier exchange lists this project commits to deriving
      recipes for. Stable, intentional, edited by humans.

    * **Members** — roots **plus** any CCXT class that inherits from a
      root via `priv/discoveries/class_hierarchy.json`. Variants
      (`binance` → `binanceus`, `binancecoinm`, `binanceusdm`; `okx` →
      `okxus`, `myokx`; `kucoin` → `kucoinfutures`) and aliases
      (`htx` → `huobi`; `coinbase` → `coinbaseadvanced`) inherit their root's tier.

  Inheritance is **provable** from the class graph, not guessed — this
  respects the Honesty Rule. The four member buckets are:

    * `:tier1` — must-have priority (roots: binance, bybit, okx, deribit)
    * `:tier2` — intentionally empty; the staging bucket for re-adding
      exchanges in matching family groups (see `priv/priority_tiers.json`
      `_notes` and CLAUDE.md § "Tier-based scoping")
    * `:tier3` — explicitly deprioritized; supported but tasks defer until
      a real consumer surfaces a need
    * `:dex` — priority DEX track (roots: hyperliquid, derive)

  Anything not in any member set is `:unclassified`. Raw extraction still
  runs for every CCXT exchange regardless of tier — this module only
  governs which exchanges are in-scope for **derivation** and
  `--tier*`-scoped commands.

  Loaded at compile time via `@external_resource` so editing either
  `priv/priority_tiers.json` or `priv/discoveries/class_hierarchy.json`
  triggers a recompile.
  """

  @priority_tiers_path "priv/priority_tiers.json"
  @class_hierarchy_path "priv/discoveries/class_hierarchy.json"
  @external_resource @priority_tiers_path
  @external_resource @class_hierarchy_path

  tiers_data = @priority_tiers_path |> File.read!() |> JSON.decode!()

  @tier1_exchanges Map.fetch!(tiers_data, "tier1")
  @tier2_exchanges Map.fetch!(tiers_data, "tier2")
  @tier3_exchanges Map.fetch!(tiers_data, "tier3")
  @dex_exchanges Map.fetch!(tiers_data, "dex")

  # Build a REST-only parent map so variants resolve to their family root.
  # WS entries would introduce self-loops (ws:<id> "extends" rest:<id>).
  if !File.exists?(@class_hierarchy_path) do
    Mix.raise("""
    #{@class_hierarchy_path} not found. This file is compile-time load-bearing
    and is the one priv/discoveries/ entry that remains tracked in git.

    Fresh clone? Run `mix setup`.
    Regenerating after deletion? Run `mix ccxt_extract.classes`.
    """)
  end

  parent_map =
    @class_hierarchy_path
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("classes")
    |> Enum.filter(&(&1["type"] == "rest"))
    |> Map.new(fn class -> {class["id"], class["extends_resolved"]} end)

  # Walks the parent chain to a root. Cycle/self-loop/depth-exhaustion all
  # degrade to "this id is its own root" — callers then classify it via
  # exact match against the root list (yielding `:unclassified` when the
  # id is not a curated root).
  resolve_root = fn id, self, depth ->
    parent = Map.get(parent_map, id)

    cond do
      depth == 0 -> id
      is_nil(parent) -> id
      parent == "Exchange" -> id
      parent == id -> id
      true -> self.(parent, self, depth - 1)
    end
  end

  expand = fn roots ->
    roots_set = MapSet.new(roots)

    variants =
      for {id, _parent} <- parent_map,
          not MapSet.member?(roots_set, id),
          MapSet.member?(roots_set, resolve_root.(id, resolve_root, 8)),
          do: id

    (roots ++ variants) |> Enum.uniq() |> Enum.sort()
  end

  @tier1_members expand.(@tier1_exchanges)
  @tier2_members expand.(@tier2_exchanges)
  @tier3_members expand.(@tier3_exchanges)
  @dex_members expand.(@dex_exchanges)

  @tier_member_map Enum.reduce(
                     [
                       {:tier1, @tier1_members},
                       {:tier2, @tier2_members},
                       {:tier3, @tier3_members},
                       {:dex, @dex_members}
                     ],
                     %{},
                     fn {tier, members}, acc ->
                       Enum.reduce(members, acc, &Map.put(&2, &1, tier))
                     end
                   )

  @doc "Returns Priority Tier 1 **roots** (hand-curated, does not include variants)."
  @spec tier1_exchanges() :: [String.t()]
  def tier1_exchanges, do: @tier1_exchanges

  @doc "Returns Priority Tier 2 **roots** (hand-curated, does not include variants)."
  @spec tier2_exchanges() :: [String.t()]
  def tier2_exchanges, do: @tier2_exchanges

  @doc "Returns Priority Tier 3 **roots** (hand-curated, does not include variants)."
  @spec tier3_exchanges() :: [String.t()]
  def tier3_exchanges, do: @tier3_exchanges

  @doc "Returns priority DEX **roots** (hand-curated, does not include variants)."
  @spec dex_exchanges() :: [String.t()]
  def dex_exchanges, do: @dex_exchanges

  @doc """
  Returns Tier 1 **members**: roots plus all variants/aliases inheriting
  from a Tier 1 root. This is the set used by `--tier1` scoping.
  """
  @spec tier1_members() :: [String.t()]
  def tier1_members, do: @tier1_members

  @doc "Returns Tier 2 **members** (roots + variants/aliases)."
  @spec tier2_members() :: [String.t()]
  def tier2_members, do: @tier2_members

  @doc "Returns Tier 3 **members** (roots + variants/aliases)."
  @spec tier3_members() :: [String.t()]
  def tier3_members, do: @tier3_members

  @doc "Returns DEX **members** (roots + variants/aliases)."
  @spec dex_members() :: [String.t()]
  def dex_members, do: @dex_members

  @doc """
  Returns the **root** exchanges for a given priority tier atom.

      iex> "binance" in CcxtExtract.Tiers.exchanges_for_tier(:tier1)
      true

      iex> "binanceus" in CcxtExtract.Tiers.exchanges_for_tier(:tier1)
      false
  """
  @spec exchanges_for_tier(:tier1 | :tier2 | :tier3 | :dex) :: [String.t()]
  def exchanges_for_tier(:tier1), do: @tier1_exchanges
  def exchanges_for_tier(:tier2), do: @tier2_exchanges
  def exchanges_for_tier(:tier3), do: @tier3_exchanges
  def exchanges_for_tier(:dex), do: @dex_exchanges

  @doc """
  Returns the **members** (roots + variants/aliases) for a given priority
  tier atom. This is the set used by `--tier*` scoping.

      iex> members = CcxtExtract.Tiers.members_for_tier(:tier1)
      iex> "binance" in members and "binanceus" in members
      true
  """
  @spec members_for_tier(:tier1 | :tier2 | :tier3 | :dex) :: [String.t()]
  def members_for_tier(:tier1), do: @tier1_members
  def members_for_tier(:tier2), do: @tier2_members
  def members_for_tier(:tier3), do: @tier3_members
  def members_for_tier(:dex), do: @dex_members

  @doc """
  Returns the priority tier for an exchange ID. Variants and aliases
  inherit their family root's tier.

      iex> CcxtExtract.Tiers.get_priority_tier("binance")
      :tier1

      iex> CcxtExtract.Tiers.get_priority_tier("binanceus")
      :tier1

      iex> CcxtExtract.Tiers.get_priority_tier("huobi")
      :tier3

      iex> CcxtExtract.Tiers.get_priority_tier("hyperliquid")
      :dex

      iex> CcxtExtract.Tiers.get_priority_tier("not_a_real_exchange")
      :unclassified
  """
  @spec get_priority_tier(String.t()) :: :tier1 | :tier2 | :tier3 | :dex | :unclassified
  def get_priority_tier(exchange_id) do
    Map.get(@tier_member_map, exchange_id, :unclassified)
  end

  @doc "True when `exchange_id` is a Tier 1 member (root or variant/alias)."
  @spec tier1?(String.t()) :: boolean()
  def tier1?(exchange_id), do: get_priority_tier(exchange_id) == :tier1

  @doc "True when `exchange_id` is a Tier 2 member (root or variant/alias)."
  # Tested against `@tier2_members` (not `get_priority_tier/1`) because tier2 is
  # intentionally empty: the type checker proves `get_priority_tier/1` can never
  # return `:tier2`, so `== :tier2` would warn as an always-false comparison.
  # `in []` compiles to `false`; re-adding a tier2 root makes this work on recompile.
  @spec tier2?(String.t()) :: boolean()
  def tier2?(exchange_id), do: exchange_id in @tier2_members

  @doc "True when `exchange_id` is a Tier 3 member (root or variant/alias)."
  @spec tier3?(String.t()) :: boolean()
  def tier3?(exchange_id), do: get_priority_tier(exchange_id) == :tier3

  @doc "True when `exchange_id` is a priority DEX member (root or variant/alias)."
  @spec dex?(String.t()) :: boolean()
  def dex?(exchange_id), do: get_priority_tier(exchange_id) == :dex

  @doc """
  Returns the human-readable display name for a tier.

      iex> CcxtExtract.Tiers.tier_display_name(:tier1)
      "TIER 1"

      iex> CcxtExtract.Tiers.tier_display_name(:dex)
      "DEX"
  """
  @spec tier_display_name(:tier1 | :tier2 | :tier3 | :dex) :: String.t()
  def tier_display_name(:tier1), do: "TIER 1"
  def tier_display_name(:tier2), do: "TIER 2"
  def tier_display_name(:tier3), do: "TIER 3"
  def tier_display_name(:dex), do: "DEX"

  @doc """
  True when any of the `--tier1 --tier2 --tier3 --dex` flags is set.

      iex> CcxtExtract.Tiers.has_tier_flags?(tier1: true)
      true

      iex> CcxtExtract.Tiers.has_tier_flags?(strict: true)
      false
  """
  @spec has_tier_flags?(keyword()) :: boolean()
  def has_tier_flags?(opts) do
    opts[:tier1] || opts[:tier2] || opts[:tier3] || opts[:dex] || false
  end

  @doc """
  Collects tier **members** (roots + variants/aliases) from all enabled
  tier flags, for use as a scope filter.

  Returns `{exchanges, label}` where `exchanges` is sorted-uniq and
  `label` is a header string like `"TIER 1 + DEX (14)"`.

      iex> {exchanges, _label} = CcxtExtract.Tiers.collect_tier_exchanges(tier1: true, dex: true)
      iex> "binance" in exchanges and "binanceus" in exchanges and "hyperliquid" in exchanges
      true
  """
  @spec collect_tier_exchanges(keyword()) :: {[String.t()], String.t()}
  def collect_tier_exchanges(opts) do
    tiers = Enum.filter([:tier1, :tier2, :tier3, :dex], fn tier -> opts[tier] end)

    exchanges =
      tiers
      |> Enum.flat_map(&members_for_tier/1)
      |> Enum.uniq()
      |> Enum.sort()

    label = build_tier_label(tiers, length(exchanges))
    {exchanges, label}
  end

  @doc false
  @spec build_tier_label([atom()], non_neg_integer()) :: String.t()
  def build_tier_label(tiers, count) do
    tier_names = Enum.map_join(tiers, " + ", &tier_display_name/1)
    "#{tier_names} (#{count})"
  end
end
