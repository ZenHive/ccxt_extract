defmodule CcxtExtract.Progress do
  @moduledoc """
  Shared progress-logging helper for per-item extraction loops.

  `map/2` wraps `Enum.with_index |> Enum.map` with periodic `Logger.info`
  output at a fixed interval, so extraction modules don't each re-implement
  the same `rem(idx, 20) == 0` boilerplate.
  """

  require Logger

  @every 20

  @doc """
  Map `fun` over `items`, logging a progress line every #{@every} items.

  Logged line is `"  <idx>/<total>..."` at `Logger.info` level. The total is
  computed once up front from `length(items)`, so `items` must be a realized
  list (not a stream).
  """
  @spec map([a], (a -> b)) :: [b] when a: var, b: var
  def map(items, fun) do
    total = length(items)

    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, idx} ->
      if rem(idx, @every) == 0, do: Logger.info("  #{idx}/#{total}...")
      fun.(item)
    end)
  end
end
