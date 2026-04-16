defmodule CcxtExtract.DiscoveryWriter do
  @moduledoc """
  Shared writer for whole-map discovery/report JSON files.

  Stamps the active `tier_scope` into the envelope, ensures the parent
  directory exists, encodes pretty JSON, and writes to disk. Used by
  analysis and report modules that emit a single map per run, distinct
  from `CcxtExtract.AggregateWriter` which handles scoped-merge writes
  over entry lists.
  """

  @doc """
  Write `data` to `default_path` (or `opts[:output_path]` if provided).

  Stamps `"tier_scope"` (from `opts[:tier_scope]`, default `"all"`) into
  the top-level map before encoding. Creates the parent directory if it
  does not exist.
  """
  @spec write!(map(), String.t(), keyword()) :: :ok
  def write!(data, default_path, opts \\ []) do
    output_path = Keyword.get(opts, :output_path, default_path)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    stamped = Map.put(data, "tier_scope", tier_scope)

    output_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(output_path, Jason.encode!(stamped, pretty: true))
    :ok
  end
end
