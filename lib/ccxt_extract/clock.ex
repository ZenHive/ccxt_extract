defmodule CcxtExtract.Clock do
  @moduledoc """
  Shared ISO8601 timestamp source for extraction envelopes.

  Defaults to wall-clock time, but honors application env overrides so
  deterministic harnesses can freeze timestamp fields without changing
  every extractor's public CLI.
  """

  @doc """
  Return the ISO8601 timestamp for `key`.

  When `Application.get_env(:ccxt_extract, key)` is set, that value wins.
  Otherwise the current UTC wall-clock is returned.
  """
  @spec timestamp(atom()) :: String.t()
  def timestamp(key \\ :extracted_at) when is_atom(key) do
    Application.get_env(:ccxt_extract, key) || DateTime.to_iso8601(DateTime.utc_now())
  end
end
