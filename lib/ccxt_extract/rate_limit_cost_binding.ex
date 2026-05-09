defmodule CcxtExtract.RateLimitCostBinding do
  @moduledoc """
  Derives which bucket index and axes per-endpoint `rate_limit_costs` weights apply to,
  from the resolved rate-limit bucket wrapper returned by `get_rate_limit_buckets/2` (Task 90).
  """

  @doc """
  Returns `%{"bucket_index" => 0, "axes" => …}` from the first resolved bucket when the
  wrapper is usable; otherwise `nil` (unresolved, empty buckets, or missing axes).
  """
  @spec derive(term()) :: map() | nil
  def derive(wrapper) when is_map(wrapper) do
    reason = Map.get(wrapper, "unresolved_reason")
    buckets = Map.get(wrapper, "buckets", [])
    buckets = if is_list(buckets), do: buckets, else: []

    if reason != nil or buckets == [] do
      nil
    else
      case List.first(buckets) do
        %{"axes" => axes} when is_list(axes) -> %{"bucket_index" => 0, "axes" => axes}
        _ -> nil
      end
    end
  end

  def derive(_), do: nil
end
