defmodule CcxtExtract.AggregateWriter do
  @moduledoc """
  Scope-aware, merge-safe writer for discovery aggregate JSON files.

  Every extractor that writes an aggregate under `priv/discoveries/` routes
  through this module so two invariants always hold:

    1. **Scoped merges preserve out-of-scope entries and accumulate
       `tier_scope`.** A `--tier1` run replaces only tier1 entries in the
       aggregate, keeps everything else intact, and unions its
       `tier_scope` stamp with the file's existing one. A `:all` scope
       replaces the entries list wholesale and stamps its own scope. This
       makes a `--tier1` then `--tier2` sequence byte-identical to a
       single `--tier1 --tier2` run (Task 114).
    2. **Envelope totals are recomputed from the final merged entries on
       every write.** `stats_fn` runs against the sorted, post-merge list,
       so it is impossible for `count`/`with_*`/`total_*` to drift from
       the entries they describe.

  Invariant 2 closes the drift-bug class previously observed on
  `parse_methods.json`, `ws_methods.json`, and `overrides.json` where
  envelope scalars disagreed with a recomputation over `exchanges`.

  ## Options

    * `:entry_key` (required) — JSON key for the entries list (e.g.
      `"exchanges"`, `"classes"`).
    * `:id_key` (required) — field used to identify an entry during merge
      (e.g. `"id"`, `"node_key"`).
    * `:scope` (required) — `:all` or `MapSet.t(String.t())`. `:all`
      replaces the entries list wholesale (and skips reading the
      existing file, so a corrupt aggregate gets overwritten instead
      of blocking the write). A MapSet merges into the existing file:
      in-scope existing entries are replaced by `new_entries`;
      out-of-scope entries are preserved. **Callers must pre-filter
      `new_entries` to the scope** — entries outside the MapSet are
      appended verbatim and can produce duplicates.
    * `:stats_fn` (required) — `([map()] -> map())` that returns envelope
      fields derived from the final merged, sorted entries (e.g.
      `%{"with_parse_methods" => 99, "total_methods" => 1541}`). Must be
      pure and deterministic over its input.
    * `:tier_scope` — output of `CcxtExtract.Scope.to_manifest_value/1`.
      Stamped as `"tier_scope"`. Defaults to `"all"`. On a scoped
      (MapSet) merge it is unioned with the existing file's stamp via
      `CcxtExtract.Scope.merge_manifest_values/2`, so the stamp always
      reflects every tier/exchange the merged file holds.
    * `:extracted_at` — ISO8601 timestamp. Defaults to `DateTime.utc_now/0`.
    * `:extra` — additional static envelope fields (e.g.
      `%{"type" => "rest"}` for `methods_{rest,ws}.json`). Applied after
      the base envelope but before `stats_fn` output, so `stats_fn` wins
      on key conflict.

  Every write routes through `CcxtExtract.AstNormalize.to_encodable/1`,
  which rewrites OXC atom `:type` values to PascalCase strings and
  recursively sorts map keys so the on-disk JSON is byte-deterministic
  (Task 114). There is no opt-out — deterministic emit is a contract,
  not a tunable.

  ## Example

      CcxtExtract.AggregateWriter.write!(
        "priv/discoveries/parse_methods.json",
        new_exchanges,
        entry_key: "exchanges",
        id_key: "id",
        scope: MapSet.new(~w(binance bybit okx)),
        stats_fn: fn entries ->
          %{
            "with_parse_methods" => Enum.count(entries, & &1["parse_method_count"] > 0),
            "total_methods" => Enum.sum(Enum.map(entries, & &1["parse_method_count"]))
          }
        end,
        tier_scope: ["tier1"]
      )
  """

  alias CcxtExtract.AstNormalize
  alias CcxtExtract.JsonIO
  alias CcxtExtract.Scope

  @type scope :: :all | MapSet.t(String.t())
  @type stats_fn :: ([map()] -> map())

  @type write_opt ::
          {:entry_key, String.t()}
          | {:id_key, String.t()}
          | {:scope, scope}
          | {:stats_fn, stats_fn}
          | {:tier_scope, String.t() | [String.t()]}
          | {:extracted_at, String.t()}
          | {:extra, map()}

  @type write_opts :: [write_opt]

  @doc """
  Write `new_entries` to `path`, merging with any existing aggregate.

  See module doc for option semantics. Returns `:ok` on success; raises
  `File.Error` on I/O failure or a plain `RuntimeError` if the existing
  file is malformed (corrupt JSON, or `entry_key` present with a
  non-list value).
  """
  @spec write!(String.t(), [map()], write_opts()) :: :ok
  # sobelow_skip ["Traversal.FileModule"]
  def write!(path, new_entries, opts) when is_binary(path) and is_list(new_entries) and is_list(opts) do
    entry_key = Keyword.fetch!(opts, :entry_key)
    id_key = Keyword.fetch!(opts, :id_key)
    scope = Keyword.fetch!(opts, :scope)
    stats_fn = Keyword.fetch!(opts, :stats_fn)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    extracted_at = Keyword.get(opts, :extracted_at, DateTime.to_iso8601(DateTime.utc_now()))
    extra = Keyword.get(opts, :extra, %{})

    # :all replaces the file wholesale, so a corrupt existing aggregate
    # must not block the overwrite. Only read when a MapSet scope requires
    # preserving out-of-scope entries.
    {existing, existing_tier_scope} =
      case scope do
        :all -> {[], nil}
        %MapSet{} -> read_existing(path, entry_key)
      end

    merged =
      existing
      |> merge(new_entries, scope, id_key)
      |> Enum.sort_by(&Map.fetch!(&1, id_key))

    stats = stats_fn.(merged)

    # On a scoped (MapSet) merge the file accumulates entries across runs,
    # so `tier_scope` must reflect every tier/exchange the merged file holds
    # — not just the latest caller's scope. Union the on-disk stamp with the
    # caller's. A `:all` scope replaces wholesale, so its caller-supplied
    # stamp stands alone (`existing_tier_scope` is nil). (Task 114.)
    tier_scope =
      case existing_tier_scope do
        nil -> tier_scope
        prev -> Scope.merge_manifest_values(prev, tier_scope)
      end

    # `tier_scope` is stamped LAST so neither `:extra` nor the `:stats_fn`
    # output can shadow it — the stamp is the contract, not an extractor's
    # incidental stats.
    envelope =
      %{
        "extracted_at" => extracted_at,
        "count" => length(merged),
        entry_key => merged
      }
      |> Map.merge(extra)
      |> Map.merge(stats)
      |> Map.put("tier_scope", tier_scope)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(AstNormalize.to_encodable(envelope), pretty: true))
    :ok
  end

  # Reads the on-disk aggregate, returning `{entries, tier_scope}`. A
  # missing file yields `{[], nil}`; a malformed file raises. The
  # `tier_scope` is surfaced so `write!/3` can union it with the caller's
  # on a scoped merge (Task 114).
  @spec read_existing(String.t(), String.t()) :: {[map()], Scope.manifest_value() | nil}
  defp read_existing(path, entry_key) do
    case JsonIO.read_json(path) do
      {:ok, data} when is_map(data) ->
        {extract_entries_or_raise(data, entry_key, path), Map.get(data, "tier_scope")}

      {:ok, other} ->
        raise "Corrupt #{path}: expected a JSON object, got #{inspect(other)}"

      {:error, {:missing_input, _}} ->
        {[], nil}

      {:error, {:invalid_json, detail}} ->
        raise "Malformed JSON in #{path}: #{detail}"
    end
  end

  defp extract_entries_or_raise(data, entry_key, path) do
    case Map.get(data, entry_key) do
      entries when is_list(entries) ->
        entries

      nil ->
        # Existing file predates the aggregate shape — treat as empty.
        []

      other ->
        raise "Corrupt #{path}: expected #{entry_key} to be a list, got #{inspect(other)}"
    end
  end

  defp merge(_existing, new_entries, :all, _id_key), do: new_entries

  defp merge(existing, new_entries, %MapSet{} = scope, id_key) do
    Enum.reject(existing, &MapSet.member?(scope, Map.get(&1, id_key))) ++ new_entries
  end
end
