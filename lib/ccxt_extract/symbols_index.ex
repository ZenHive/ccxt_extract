defmodule CcxtExtract.SymbolsIndex do
  @moduledoc """
  Compact per-symbol spot/swap classification for consumer symbol resolution.

  Introduced at schema 3.0.0 (Task 117) as the derived replacement for
  `runtime.markets.markets` — the full `loadMarkets()` snapshot that shipped
  under schema 2.x. That snapshot accounted for ~85% of every large exchange's
  emitted JSON (binance ~23.6MB) and had exactly one live field use across
  every known consumer: per-market `spot` / `swap` boolean classification for
  fast symbol-to-type lookup. Every other field in the snapshot (price,
  precision, fees, limits, info, baseId, quoteId) is drift-prone across
  extraction runs and must be sourced from a live `loadMarkets()` call at
  consumer runtime — which was the only safe path anyway.

  ## Output Shape

      %{
        "BTC/USDT" => %{"spot" => true, "swap" => false},
        "BTC/USDT:USDT" => %{"spot" => false, "swap" => true},
        ...
      }

  Returns `nil` when no market data is available (matches
  `SymbolPatterns.derive/2`'s convention).

  ## Derivation

  For each market, `spot` and `swap` are `true` when the source market carries
  the matching top-level boolean (`market["spot"] == true`) **or** when
  `market["type"]` equals the matching string literal. Both signals are
  populated by CCXT's `loadMarkets()` for every exchange — checking both
  guards against exchanges that set one but not the other.

  Consumers that need `market_count` can compute it via `map_size/1` (Elixir),
  `len()` (Python), `.len()` (Rust). See `SCHEMA.md` 3.0.0 migration notes.
  """

  @doc """
  Derive a compact spot/swap symbol index from market data.

  Accepts the outer `runtime.markets` shape (`%{"market_count" => _, "markets" => _}`)
  to match the interface used by `CcxtExtract.SymbolPatterns.derive/2`.

  ## Parameters

    * `markets_data` — the `runtime.markets` map with `"markets"` key, or nil
  """
  @spec derive(map() | nil) :: %{String.t() => %{String.t() => boolean()}} | nil
  def derive(nil), do: nil
  def derive(%{"markets" => nil}), do: nil
  def derive(%{"markets" => markets}) when map_size(markets) == 0, do: nil

  def derive(%{"markets" => markets}) when is_map(markets) do
    Map.new(markets, fn {symbol, market} ->
      {symbol,
       %{
         "spot" => spot?(market),
         "swap" => swap?(market)
       }}
    end)
  end

  def derive(_), do: nil

  defp spot?(market) when is_map(market), do: market["spot"] == true or market["type"] == "spot"

  defp spot?(_), do: false

  defp swap?(market) when is_map(market), do: market["swap"] == true or market["type"] == "swap"

  defp swap?(_), do: false
end
