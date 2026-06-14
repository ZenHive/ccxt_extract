defmodule CcxtExtract.Test.ScopeThresholds do
  @moduledoc """
  Envelope-dispatch helpers for cached integration tests.

  After Task 13b, cached integration tests dispatch on the `tier_scope`
  envelope stamp (stable, explicit) rather than observed exchange counts
  (brittle, requires proportional floors). Every aggregate emitter now
  stamps `tier_scope` consistently — `CcxtExtract.AggregateWriter` and
  `CcxtExtract.DiscoveryWriter` are the two write sites; both default to
  `"all"` and accept the `:tier_scope` option from
  `CcxtExtract.TaskScope.parse_and_resolve!/3`.

  ## Usage

      import CcxtExtract.Test.ScopeThresholds

      test "at least expected exchanges", %{data: data} do
        if full_universe?(data) do
          assert data["count"] >= 100
        else
          assert data["count"] == length(data["exchanges"])
          assert data["count"] > 0
        end
      end

      test "bitget recipe when in corpus scope" do
        case skip_unless_corpus_in_scope!("bitget") do
          :skip -> :ok
          :proceed -> assert ...
        end
      end

  For analysis modules whose in-memory result lacks a `tier_scope` field
  (e.g. `MethodAnalysis.extract/0`, `PublicExchanges.extract/0`,
  `CoverageReport.extract/0`), call `corpus_full_universe?/0` instead —
  it reads the canonical scope signal from
  `priv/discoveries/describe/_manifest.json`.

  For per-exchange `priv/output/<id>.json` assertions, use
  `corpus_in_scope?/1` or `skip_unless_corpus_in_scope!/1` — they read
  `priv/output/_manifest.json`'s `tier_scope` and resolve tier entries
  via `CcxtExtract.Tiers.members_for_tier/1`. When the output manifest
  lacks a stamp (legacy/stale), the on-disk output file set is the
  implicit scope.
  """

  alias CcxtExtract.TaskScope
  alias CcxtExtract.Tiers

  @canonical_scope_anchor Path.join(["discoveries", "describe", "_manifest.json"])
  @output_manifest Path.join(["output", "_manifest.json"])

  @doc """
  Returns `true` when the envelope's `tier_scope` stamp equals `"all"`.

  Treats the legacy `nil` (unstamped) case as full-universe to keep older
  fixtures usable. Post-Task-13a, every aggregate stamps `tier_scope`, so
  `nil` should not appear in fresh corpora.

  ## Examples

      iex> CcxtExtract.Test.ScopeThresholds.full_universe?(%{"tier_scope" => "all"})
      true

      iex> CcxtExtract.Test.ScopeThresholds.full_universe?(%{"tier_scope" => ["tier1"]})
      false

      iex> CcxtExtract.Test.ScopeThresholds.full_universe?(%{})
      true
  """
  @spec full_universe?(map()) :: boolean()
  def full_universe?(envelope) when is_map(envelope) do
    case Map.get(envelope, "tier_scope") do
      "all" -> true
      nil -> true
      _ -> false
    end
  end

  @doc """
  Returns `true` when the cached fixture corpus was produced by a
  full-universe run.

  Reads `tier_scope` from the canonical scope anchor —
  `priv/discoveries/describe/_manifest.json` — which is stamped by every
  scoped or full-universe `mix ccxt_extract.update` run. Use for analysis
  tests whose own in-memory result does not surface `tier_scope`
  (`MethodAnalysis.extract/0`, `PublicExchanges.extract/0`,
  `CoverageReport.extract/0`, etc.).
  """
  @spec corpus_full_universe?() :: boolean()
  def corpus_full_universe? do
    path = CcxtExtract.Paths.priv(@canonical_scope_anchor)

    case File.read(path) do
      {:ok, body} ->
        body |> Jason.decode!() |> full_universe?()

      {:error, _} ->
        # Anchor missing — treat as full-universe to avoid masking failures
        # on a fresh clone before extraction has run.
        true
    end
  end

  @doc """
  Returns `round(observed * fraction)` — for ratio-style assertions
  (e.g. "majority have parse methods"). Independent of scope; survives
  the envelope migration as the only count-derived helper that doesn't
  hardcode a full-universe threshold.

  ## Examples

      iex> CcxtExtract.Test.ScopeThresholds.proportional(100, 0.75)
      75

      iex> CcxtExtract.Test.ScopeThresholds.proportional(34, 0.5)
      17
  """
  @spec proportional(non_neg_integer(), float()) :: non_neg_integer()
  def proportional(observed, fraction) when is_integer(observed) and observed >= 0 do
    round(observed * fraction)
  end

  @doc """
  Returns `true` when `exchange_id` is inside the active output corpus scope.

  Reads `tier_scope` from `priv/output/_manifest.json` and resolves tier
  entries via `CcxtExtract.Tiers.members_for_tier/1` plus `exchange:` IDs.
  `"all"` means every exchange is in scope. A missing stamp falls back to
  the on-disk `priv/output/*.json` set so stale manifests still match
  physical fixture reality.

  ## Examples

      iex> CcxtExtract.Test.ScopeThresholds.in_scope?("binance", "all")
      true

      iex> CcxtExtract.Test.ScopeThresholds.in_scope?("bitget", ["tier1", "dex"])
      false

      iex> CcxtExtract.Test.ScopeThresholds.in_scope?("hyperliquid", ["tier1", "dex"])
      true
  """
  @spec in_scope?(String.t(), String.t() | [String.t()] | :implicit) :: boolean()
  def in_scope?(exchange_id, tier_scope) when is_binary(exchange_id) do
    MapSet.member?(scope_members(tier_scope), exchange_id)
  end

  @doc """
  Like `in_scope?/2`, but reads the output manifest (or implicit on-disk
  scope) at runtime.
  """
  @spec corpus_in_scope?(String.t()) :: boolean()
  def corpus_in_scope?(exchange_id) when is_binary(exchange_id) do
    in_scope?(exchange_id, read_output_tier_scope())
  end

  @doc """
  Returns `:proceed` when `exchange_id` is in corpus scope, `:skip` otherwise.

  Cached tests branch on the result — ExUnit has no public runtime `skip/1`
  API, so callers use:

      case skip_unless_corpus_in_scope!("bitget") do
        :skip -> :ok
        :proceed -> assert recipe("bitget", "private") == ...
      end
  """
  @spec skip_unless_corpus_in_scope!(String.t()) :: :proceed | :skip
  def skip_unless_corpus_in_scope!(exchange_id) when is_binary(exchange_id) do
    if corpus_in_scope?(exchange_id), do: :proceed, else: :skip
  end

  defp scope_members("all"), do: universe_members()

  defp scope_members(:implicit) do
    output_dir()
    |> TaskScope.rebuild_manifest_exchanges()
    |> MapSet.new()
  end

  defp scope_members(list) when is_list(list) do
    list
    |> Enum.flat_map(&manifest_entry_to_ids/1)
    |> MapSet.new()
  end

  defp read_output_tier_scope do
    path = CcxtExtract.Paths.priv(@output_manifest)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode!(body) do
          %{"tier_scope" => ts} when is_binary(ts) or is_list(ts) -> ts
          _ -> :implicit
        end

      {:error, _} ->
        :implicit
    end
  end

  defp universe_members do
    "discoveries/exchanges.json"
    |> CcxtExtract.Paths.priv()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("exchanges")
    |> MapSet.new(&Map.fetch!(&1, "id"))
  end

  defp output_dir, do: CcxtExtract.Paths.priv("output")

  defp manifest_entry_to_ids("tier1"), do: Tiers.members_for_tier(:tier1)
  defp manifest_entry_to_ids("tier2"), do: Tiers.members_for_tier(:tier2)
  defp manifest_entry_to_ids("tier3"), do: Tiers.members_for_tier(:tier3)
  defp manifest_entry_to_ids("dex"), do: Tiers.members_for_tier(:dex)

  defp manifest_entry_to_ids("exchange:" <> id), do: [id]
  defp manifest_entry_to_ids(_unknown), do: []
end
