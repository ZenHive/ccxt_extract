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

  For analysis modules whose in-memory result lacks a `tier_scope` field
  (e.g. `MethodAnalysis.extract/0`, `PublicExchanges.extract/0`,
  `CoverageReport.extract/0`), call `corpus_full_universe?/0` instead —
  it reads the canonical scope signal from
  `priv/discoveries/describe/_manifest.json`.
  """

  @canonical_scope_anchor Path.join(["discoveries", "describe", "_manifest.json"])

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
end
