defmodule CcxtExtract.Test.StagedDiscoveries do
  @moduledoc """
  Symlink `priv/discoveries/` into a tmp dir for cached integration tests, then
  ensure Task 73b / 89 / 90 global JSON files are readable (synthesize when the
  canonical corpus omits them or leaves a broken symlink).
  """

  alias CcxtExtract.JsonIO
  alias CcxtExtract.RateLimitBuckets
  alias CcxtExtract.RequestHeaders

  @doc """
  Returns a tmp directory path containing symlink mirrors + synthesized stubs.
  Caller should `on_exit(fn -> File.rm_rf!(path) end)`.
  """
  @spec stage!(String.t()) :: String.t()
  def stage!(source_dir) do
    # `:erlang.unique_integer/1` only guarantees uniqueness within one VM
    # instance — the counter restarts each `mix test` run, so a leftover dir
    # from a crashed run (whose `on_exit` cleanup never fired) collides and
    # `File.ln_s/2` below trips `{:error, :eexist}`. Clear any stale dir first.
    tmp = Path.join(System.tmp_dir!(), "ccxt_staged_discoveries_#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    for entry <- File.ls!(source_dir) do
      src = Path.join(source_dir, entry)
      dst = Path.join(tmp, entry)
      :ok = File.ln_s(src, dst)
    end

    exchanges_path = Path.join(tmp, "exchanges.json")

    ids =
      case JsonIO.read_json(exchanges_path) do
        {:ok, %{"exchanges" => entries}} -> Enum.map(entries, & &1["id"])
        _ -> []
      end

    ensure_global_exchange_json!(tmp, "request_headers.json", ids, fn ids ->
      %{"exchanges" => Enum.map(ids, &%{"id" => &1, "request_headers" => RequestHeaders.empty_record()})}
    end)

    ensure_global_exchange_json!(tmp, "rate_limit_buckets.json", ids, fn ids ->
      %{"exchanges" => Enum.map(ids, &%{"id" => &1, "rate_limit_buckets" => RateLimitBuckets.empty_record()})}
    end)

    ensure_global_exchange_json!(tmp, "rate_limit_costs.json", ids, fn ids ->
      %{"exchanges" => Enum.map(ids, &%{"id" => &1, "rate_limit_costs" => %{}})}
    end)

    tmp
  end

  @spec ensure_global_exchange_json!(Path.t(), String.t(), [String.t()], ([String.t()] -> map())) :: :ok
  defp ensure_global_exchange_json!(tmp, filename, ids, synthetic_fn) do
    path = Path.join(tmp, filename)

    readable? =
      case JsonIO.read_json(path) do
        {:ok, %{"exchanges" => exchanges}} when is_list(exchanges) -> true
        _ -> false
      end

    if readable? do
      :ok
    else
      _ = File.rm(path)
      File.write!(path, Jason.encode!(synthetic_fn.(ids), pretty: true))
      :ok
    end
  end
end
