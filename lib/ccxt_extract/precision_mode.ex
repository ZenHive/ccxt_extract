defmodule CcxtExtract.PrecisionMode do
  @moduledoc """
  Decode the per-exchange precision configuration from `describe()`.

  Introduced in Task 98 as the Phase 16 "precision mode + tick/step
  derivation semantics" surface, alongside `CcxtExtract.Currencies`.

  CCXT exposes two integers in every `describe()` map:

    * `precisionMode` — how a market's `precision.{amount,price,cost}`
      value is to be interpreted.
    * `paddingMode` — whether rounded numbers are zero-padded to the
      precision width.

  Those two integers are the **interpretation key** for every market's
  `precision` values. Without them, a bare `0.001` is ambiguous: a literal
  tick size under `TICK_SIZE`, or a decimal-place count under
  `DECIMAL_PLACES`. This module decodes them into self-documenting strings;
  the tick/step derivation rule keyed by `mode` is documented in
  `SCHEMA.md` § Markets.

  ## Decode tables

  Constant values verified against the vendored CCXT source
  `priv/ccxt/ts/src/base/functions/number.ts`:

      precisionMode  2 -> "decimal_places"
                     3 -> "significant_digits"
                     4 -> "tick_size"

      paddingMode    5 -> "no_padding"
                     6 -> "pad_with_zero"

  ## Output shape

      %{"mode" => "tick_size", "padding_mode" => "no_padding"}

  Returns `nil` when no `describe` data is available — `describe` is nil,
  not a map, or carries no `precisionMode` key (consistent with the
  `nil`-on-missing contract of `CcxtExtract.Currencies.derive/1` and the
  other Phase 16 derivers). An unrecognized integer decodes to a `nil`
  sub-field rather than raising: CCXT's enum is closed, so this path is
  defensive only.
  """

  @doc """
  Derive the `markets.precision_mode` record from an exchange's `describe`
  map.

  ## Parameters

    * `describe` — the resolved `describe()` map (carrying `precisionMode`
      / `paddingMode`), or nil
  """
  @spec derive(map() | nil) :: %{String.t() => String.t() | nil} | nil
  def derive(describe) when is_map(describe) do
    case Map.fetch(describe, "precisionMode") do
      {:ok, precision_mode} ->
        %{
          "mode" => decode_precision(precision_mode),
          "padding_mode" => decode_padding(Map.get(describe, "paddingMode"))
        }

      :error ->
        nil
    end
  end

  def derive(_), do: nil

  # --- Internal ---

  @spec decode_precision(term()) :: String.t() | nil
  defp decode_precision(2), do: "decimal_places"
  defp decode_precision(3), do: "significant_digits"
  defp decode_precision(4), do: "tick_size"
  defp decode_precision(_), do: nil

  @spec decode_padding(term()) :: String.t() | nil
  defp decode_padding(5), do: "no_padding"
  defp decode_padding(6), do: "pad_with_zero"
  defp decode_padding(_), do: nil
end
