defmodule CcxtExtract.Currencies do
  @moduledoc """
  Derive lightweight per-currency metadata (including networks) from
  `loadMarkets()` runtime data.

  Introduced in Task 97 as the Phase 16 "currencies + network info" surface.
  The raw `ex.currencies` (populated as a side-effect of `loadMarkets()`) is
  the enriched runtime view — the one that actually contains `networks` for
  exchanges that implement `fetchCurrencies()` or equivalent.

  ## Output Shape

      %{
        "BTC" => %{
          "id" => "BTC",
          "code" => "BTC",
          "precision" => 8,
          "active" => true,
          "deposit" => true,
          "withdraw" => true,
          "networks" => %{
            "BTC" => %{"id" => "BTC", "code" => "BTC", "fee" => 0.0001, ...},
            ...
          }
        },
        ...
      }

  Returns `nil` when no currency data is available (consistent with
  `SymbolsIndex.derive/1` and `SymbolPatterns.derive/2`).

  ## Stripping

  Top-level `"info"` (and per-network `"info"`) are deliberately omitted.
  They contain the raw vendor payload and are the same source of bloat that
  caused the full `markets` snapshot to be replaced by the compact
  `symbols_index` (Task 117). Consumers who need the vendor `info` can still
  call `fetchCurrencies()` live or inspect `raw.describe.currencies` (static
  scaffold).

  QuickBEAM serializes JS `undefined` as the string sentinel `"__undefined"`
  (see `CcxtExtract.QuickbeamRuntime`). It is a serialization artifact, not a
  real value — emitting it as a field (e.g. `precision: "__undefined"`) would
  be a false claim about the exchange, and the typed `Currency` / `NetworkInfo`
  schema (`precision` is number-or-string-or-null; `id` / `code` are
  string-or-null) has no slot for it. Every sentinel-valued key is dropped
  recursively — an absent key is the lightweight, schema-conformant encoding
  of "the exchange did not surface this field".
  """

  # QuickBEAM's JSON-safe stand-in for JS `undefined`.
  @undefined_sentinel "__undefined"

  @doc """
  Derive a currencies map (code → currency record with networks) from the
  load_markets discovery shape.

  Accepts the outer map that `DiscoveryLoader` returns for a load_markets
  entry (`%{"market_count" => _, "markets" => _, "currencies" => _}`) or nil.
  Passing the bare inner currencies map is not currently supported (it falls
  through to the catch-all and returns nil, matching sibling derive functions).

  ## Parameters

    * `data` — map containing `"currencies"`, or nil
  """
  @spec derive(map() | nil) :: map() | nil
  def derive(nil), do: nil
  def derive(%{"currencies" => nil}), do: nil
  def derive(%{"currencies" => currencies}) when map_size(currencies) == 0, do: nil

  def derive(%{"currencies" => currencies}) when is_map(currencies) do
    Map.new(currencies, fn {code, entry} ->
      {code, normalize_currency(entry)}
    end)
  end

  def derive(_), do: nil

  # --- Internal ---

  @spec normalize_currency(term()) :: map()
  defp normalize_currency(entry) when is_map(entry) do
    entry
    |> Map.delete("info")
    |> Map.update("networks", %{}, &normalize_networks/1)
    |> strip_undefined()
  end

  defp normalize_currency(_), do: %{}

  @spec normalize_networks(term()) :: map()
  defp normalize_networks(nets) when is_map(nets) do
    Map.new(nets, fn {net_code, net} -> {net_code, normalize_network(net)} end)
  end

  defp normalize_networks(_), do: %{}

  @spec normalize_network(term()) :: map()
  defp normalize_network(net) when is_map(net) do
    Map.delete(net, "info")
  end

  defp normalize_network(_), do: %{}

  # Drop every `"__undefined"`-valued key, recursing through nested maps
  # (notably the per-network records). Lists are walked for completeness;
  # all other leaves pass through untouched.
  @spec strip_undefined(term()) :: term()
  defp strip_undefined(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> v == @undefined_sentinel end)
    |> Map.new(fn {k, v} -> {k, strip_undefined(v)} end)
  end

  defp strip_undefined(list) when is_list(list), do: Enum.map(list, &strip_undefined/1)

  defp strip_undefined(value), do: value
end
