defmodule CcxtExtract.Test.ScopeThresholds do
  @moduledoc """
  Scope-aware count thresholds for integration tests that read cached
  discovery fixtures.

  Committed fixtures under `priv/discoveries/` may be generated under a
  scoped extraction (~34 exchanges) or a full-universe extraction (~110).
  Many cached-integration assertions need to dispatch on which regime
  produced the fixture, but most fixtures do not stamp `tier_scope` at
  all, and `method_analysis.json` / `public_exchanges.json` stamp
  `"all"` regardless of actual scope — so the stamp cannot be trusted.
  This helper dispatches on the **observed count** instead.

  ## Gap-free dispatch

  The cutoff is `observed >= full_universe_floor` (not a separate
  smaller cutoff). A mismatched cutoff/floor pair (e.g. `cutoff=90,
  floor=100`) creates a dead zone where mid-range observations enter
  the strict branch but fail the assertion. Aligning cutoff with floor
  closes that class of bug by construction.

  ## TODO(scope-envelope)

  Followup: `SCOPED-EXTRACTION-TASKS.md` Task 13 tracks stamping
  `tier_scope` into every aggregate envelope via `AggregateWriter`.
  Once landed, tests should dispatch on the envelope (stable, explicit)
  rather than observed count (brittle, requires proportional floors).
  This module becomes thinner or unnecessary at that point.

  ## Usage

      import CcxtExtract.Test.ScopeThresholds

      test "at least expected exchanges", %{data: data} do
        assert data["count"] >= min_count(data["count"], 100)
      end
  """

  @default_scoped_fraction 0.3

  @doc """
  Returns a minimum-count floor given the observed count.

  When `observed >= full_universe_floor`, returns the full-universe
  floor unchanged (strict assertion). Otherwise returns a proportional
  floor — `round(full_universe_floor * scoped_fraction)` (default 0.3).

  Cutoff equals floor, so there is no dead zone between the two
  branches.

  ## Examples

      iex> CcxtExtract.Test.ScopeThresholds.min_count(110, 100)
      100

      iex> CcxtExtract.Test.ScopeThresholds.min_count(34, 100)
      30

      iex> CcxtExtract.Test.ScopeThresholds.min_count(34, 90, 0.5)
      45
  """
  @spec min_count(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  def min_count(observed, full_universe_floor, scoped_fraction \\ @default_scoped_fraction) do
    if observed >= full_universe_floor do
      full_universe_floor
    else
      round(full_universe_floor * scoped_fraction)
    end
  end

  @doc """
  Returns a minimum-total floor dispatched on a separate count signal.

  Use for aggregate totals (e.g. `total_methods`) where the full-universe
  total and the scoped-mode total don't follow the default proportional
  ratio, or where scaling differs per layer.

  Cutoff equals `full_universe_count_floor`, gap-free by construction.
  """
  @spec min_total(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  def min_total(observed_count, full_universe_count_floor, full_total, scoped_total) do
    if observed_count >= full_universe_count_floor, do: full_total, else: scoped_total
  end

  @doc """
  Returns a proportional floor — `round(observed * fraction)`.

  Use for ratio-style assertions (e.g. "majority have parse methods").
  """
  @spec proportional(non_neg_integer(), float()) :: non_neg_integer()
  def proportional(observed, fraction) do
    round(observed * fraction)
  end
end
