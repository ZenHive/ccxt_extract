defmodule CcxtExtract.ScopePrune do
  @moduledoc """
  Evict out-of-scope local state from discoveries/output and re-sync envelopes.

  Deletes per-exchange JSON files outside a resolved scope from:

    * every `priv/discoveries/<subdir>/` layout (e.g. `describe/`, `load_markets/`)
    * `priv/output/<id>.json`

  Then rewrites aggregate envelope files so their entry lists, `count`/`total_*`
  stats, and `tier_scope` stamps match the surviving in-scope files only.

  Never touches `class_hierarchy.json`. Honors `Paths.out/1` (`:priv_write_override`).
  """

  alias CcxtExtract.AggregateWriter
  alias CcxtExtract.JsonIO
  alias CcxtExtract.Paths
  alias CcxtExtract.Schema
  alias CcxtExtract.ScopeCleanup
  alias CcxtExtract.TaskScope

  @schema_file Schema.schema_filename()

  @type tier_scope :: CcxtExtract.Scope.manifest_value()

  @type envelope_spec :: %{
          required(:relative) => String.t(),
          required(:entry_key) => String.t(),
          required(:filter_key) => String.t(),
          required(:stats_fn) => AggregateWriter.stats_fn(),
          optional(:id_key) => String.t(),
          optional(:extra_from) => String.t() | nil,
          optional(:post_filter) => (map() -> boolean()) | nil
        }

  @type result :: %{
          dry_run: boolean(),
          in_scope_count: non_neg_integer(),
          removed_files: [String.t()],
          updated_envelopes: [String.t()],
          updated_manifests: [String.t()]
        }

  @doc """
  Prune out-of-scope per-exchange files and re-sync envelope aggregates.

  Options:

    * `:in_scope` (required) — `MapSet.t(String.t())` of exchange IDs to keep.
    * `:tier_scope` — manifest stamp for rewritten envelopes/manifests.
      Defaults to `"all"`.
    * `:force` — when `true`, delete files and rewrite envelopes. Default
      `false` (dry-run: report only).
  """
  @spec run(keyword()) :: {:ok, result()}
  def run(opts) do
    in_scope = Keyword.fetch!(opts, :in_scope)
    tier_scope = Keyword.get(opts, :tier_scope, "all")
    dry_run? = !Keyword.get(opts, :force, false)

    discoveries_dir = Paths.out("discoveries")
    output_dir = Paths.out("output")

    removed =
      []
      |> Enum.concat(prune_per_exchange_dirs(discoveries_dir, in_scope, dry_run?))
      |> Enum.concat(prune_output_dir(output_dir, in_scope, dry_run?))
      |> Enum.sort()

    updated_manifests =
      discoveries_dir
      |> per_exchange_subdirs()
      |> Enum.flat_map(&refresh_subdir_manifest(&1, tier_scope, dry_run?))
      |> Enum.concat(refresh_output_manifest(output_dir, tier_scope, dry_run?))
      |> Enum.sort()

    updated_envelopes =
      envelope_specs()
      |> Enum.flat_map(&reaggregate_envelope(&1, in_scope, tier_scope, dry_run?))
      |> Enum.sort()

    {:ok,
     %{
       dry_run: dry_run?,
       in_scope_count: MapSet.size(in_scope),
       removed_files: removed,
       updated_envelopes: updated_envelopes,
       updated_manifests: updated_manifests
     }}
  end

  @doc """
  Return absolute paths to discoveries subdirectories holding per-exchange JSON.
  """
  @spec per_exchange_subdirs(Path.t()) :: [Path.t()]
  def per_exchange_subdirs(discoveries_dir) do
    case File.ls(discoveries_dir) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(discoveries_dir, &1))
        |> Enum.filter(&per_exchange_subdir?/1)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp per_exchange_subdir?(path) do
    File.dir?(path) and
      path
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.any?(fn per_exchange_path ->
        base = Path.basename(per_exchange_path)
        not String.starts_with?(base, "_")
      end)
  end

  defp prune_per_exchange_dirs(discoveries_dir, in_scope, dry_run?) do
    discoveries_dir
    |> per_exchange_subdirs()
    |> Enum.flat_map(fn subdir ->
      prune_dir(subdir, in_scope, dry_run?, preserve: [])
    end)
  end

  defp prune_output_dir(output_dir, in_scope, dry_run?) do
    prune_dir(output_dir, in_scope, dry_run?, preserve: [@schema_file])
  end

  defp prune_dir(dir, in_scope, dry_run?, opts) do
    preserve = Keyword.get(opts, :preserve, [])

    if dry_run? do
      dir
      |> list_removable_files(in_scope, preserve)
      |> Enum.map(&Path.expand/1)
    else
      {:ok, removed} = ScopeCleanup.prune_out_of_scope(dir, in_scope, preserve: preserve)
      removed
    end
  end

  defp list_removable_files(dir, in_scope, preserve) do
    preserve_set = MapSet.new(preserve)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(fn name ->
          path = Path.join(dir, name)
          File.regular?(path) and removable_file?(name, in_scope, preserve_set)
        end)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp removable_file?(basename, in_scope, preserve_set) do
    Path.extname(basename) == ".json" and
      not String.starts_with?(basename, "_") and
      not MapSet.member?(preserve_set, basename) and
      not MapSet.member?(in_scope, Path.rootname(basename))
  end

  defp refresh_subdir_manifest(subdir, tier_scope, dry_run?) do
    manifest_path = Path.join(subdir, "_manifest.json")
    ids = TaskScope.rebuild_manifest_exchanges(subdir)

    if manifest_needs_update?(manifest_path, ids, tier_scope) do
      if dry_run? do
        [manifest_path]
      else
        write_subdir_manifest!(manifest_path, ids, tier_scope)
        [manifest_path]
      end
    else
      []
    end
  end

  defp refresh_output_manifest(output_dir, tier_scope, dry_run?) do
    manifest_path = Path.join(output_dir, "_manifest.json")
    schema_root = Path.rootname(@schema_file)

    ids =
      output_dir
      |> TaskScope.rebuild_manifest_exchanges()
      |> Enum.reject(&(&1 == schema_root))

    if manifest_needs_update?(manifest_path, ids, tier_scope) do
      if dry_run? do
        [manifest_path]
      else
        write_output_manifest!(manifest_path, ids, tier_scope)
        [manifest_path]
      end
    else
      []
    end
  end

  defp manifest_needs_update?(manifest_path, ids, tier_scope) do
    case JsonIO.read_json(manifest_path) do
      {:ok, data} when is_map(data) ->
        Map.get(data, "exchanges") != ids or Map.get(data, "tier_scope") != tier_scope

      _ ->
        ids != []
    end
  end

  defp write_subdir_manifest!(manifest_path, ids, tier_scope) do
    manifest = %{
      "extracted_at" => CcxtExtract.Clock.timestamp(:extracted_at),
      "count" => length(ids),
      "tier_scope" => tier_scope,
      "exchanges" => ids
    }

    File.mkdir_p!(Path.dirname(manifest_path))

    JsonIO.write_json!(manifest_path, manifest, pretty: true)
  end

  defp write_output_manifest!(manifest_path, ids, tier_scope) do
    manifest =
      case JsonIO.read_json(manifest_path) do
        {:ok, existing} when is_map(existing) ->
          existing
          |> Map.put("exchanges", ids)
          |> Map.put("exchange_count", length(ids))
          |> Map.put("tier_scope", tier_scope)
          |> Map.put("extracted_at", CcxtExtract.Clock.timestamp(:extracted_at))

        _ ->
          %{
            "extracted_at" => CcxtExtract.Clock.timestamp(:extracted_at),
            "tier_scope" => tier_scope,
            "exchange_count" => length(ids),
            "exchanges" => ids
          }
      end

    File.mkdir_p!(Path.dirname(manifest_path))

    JsonIO.write_json!(manifest_path, manifest, pretty: true)
  end

  defp reaggregate_envelope(spec, in_scope, tier_scope, dry_run?) do
    path = Paths.out(spec.relative)

    with {:ok, data} <- JsonIO.read_json(path),
         true <- is_map(data),
         entries when is_list(entries) <- Map.get(data, spec.entry_key) do
      filtered = filter_entries(entries, in_scope, spec)

      if envelope_needs_update?(data, filtered, tier_scope, spec.entry_key) do
        apply_envelope_update(path, filtered, spec, tier_scope, dry_run?, data)
      else
        []
      end
    else
      _ -> []
    end
  end

  defp apply_envelope_update(path, filtered, spec, tier_scope, dry_run?, data) do
    if dry_run? do
      [path]
    else
      extra = envelope_extra(data, spec)
      :ok = rewrite_envelope!(path, filtered, spec, tier_scope, extra)
      [path]
    end
  end

  defp filter_entries(entries, in_scope, spec) do
    post_filter = Map.get(spec, :post_filter)

    entries
    |> Enum.filter(fn entry ->
      id = Map.get(entry, spec.filter_key)

      is_binary(id) and MapSet.member?(in_scope, id) and
        (is_nil(post_filter) or post_filter.(entry))
    end)
    |> Enum.sort_by(&Map.fetch!(&1, spec.filter_key))
  end

  defp envelope_needs_update?(data, filtered, tier_scope, entry_key) do
    existing = Map.get(data, entry_key, [])

    existing != filtered or Map.get(data, "tier_scope") != tier_scope or
      Map.get(data, "count") != length(filtered)
  end

  defp envelope_extra(data, spec) do
    case Map.get(spec, :extra_from) do
      nil -> %{}
      key -> if type = Map.get(data, key), do: %{key => type}, else: %{}
    end
  end

  defp rewrite_envelope!(path, filtered, spec, tier_scope, extra) do
    AggregateWriter.write!(path, filtered,
      entry_key: spec.entry_key,
      id_key: Map.get(spec, :id_key, spec.filter_key),
      scope: :all,
      stats_fn: spec.stats_fn,
      tier_scope: tier_scope,
      extra: extra
    )
  end

  defp public_exchange_shape?(entry), do: is_map(entry) and is_binary(entry["id"])

  defp public_exchanges_patterns(entries) do
    entries
    |> Enum.group_by(& &1["credential_pattern"])
    |> Enum.map(fn {pattern, group} ->
      %{
        "pattern" => pattern,
        "count" => length(group),
        "exchanges" => group |> Enum.map(& &1["id"]) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{-&1["count"], &1["pattern"]})
  end

  defp public_exchanges_summary(entries) do
    advertise_count = Enum.count(entries, & &1["has_fetch_markets"])
    fully_public_count = Enum.count(entries, &(&1["credential_pattern"] == []))

    %{
      "all_have_fetch_markets" => advertise_count == length(entries),
      "credential_pattern_count" => length(public_exchanges_patterns(entries)),
      "fully_public_count" => fully_public_count,
      "fetch_markets_advertised_count" => advertise_count
    }
  end

  defp rate_limit_costs_stats(entries) do
    total =
      Enum.reduce(entries, 0, fn entry, acc ->
        case Map.get(entry, "rate_limit_costs") do
          costs when is_map(costs) -> acc + map_size(costs)
          _ -> acc
        end
      end)

    with_costs =
      Enum.count(entries, fn entry ->
        case Map.get(entry, "rate_limit_costs") do
          costs when is_map(costs) and map_size(costs) > 0 -> true
          _ -> false
        end
      end)

    %{"with_rate_limit_costs" => with_costs, "total_endpoints" => total}
  end

  defp rate_limit_buckets_stats(entries) do
    {with_bucket, with_rolling} =
      Enum.reduce(entries, {0, 0}, fn entry, {bw, br} ->
        buckets = get_in(entry, ["rate_limit_buckets", "buckets"]) || []
        rolling? = Enum.any?(buckets, &bucket_has_rolling_window?/1)
        {bw + bucket_increment(buckets), br + bool_inc(rolling?)}
      end)

    %{"with_bucket" => with_bucket, "with_rolling_window" => with_rolling}
  end

  defp bucket_has_rolling_window?(%{"rolling_window_ms" => ms}) when is_number(ms) and ms > 0, do: true

  defp bucket_has_rolling_window?(_), do: false

  defp bucket_increment([]), do: 0
  defp bucket_increment(_), do: 1
  defp bool_inc(true), do: 1
  defp bool_inc(false), do: 0

  defp envelope_specs do
    [
      %{
        relative: "discoveries/parse_methods.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.ParseMethods.write_stats/1
      },
      %{
        relative: "discoveries/ws_methods.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsMethods.write_stats/1
      },
      %{
        relative: "discoveries/sign_methods.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.SignMethod.write_stats/1
      },
      %{
        relative: "discoveries/request_defaults.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.RequestDefaults.write_stats/1
      },
      %{
        relative: "discoveries/raw_broadcast.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.RawBroadcast.write_stats/1
      },
      %{
        relative: "discoveries/pagination.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.Pagination.write_stats/1
      },
      %{
        relative: "discoveries/unified_endpoints.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.UnifiedEndpoints.write_stats/1
      },
      %{
        relative: "discoveries/interface_signatures.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.InterfaceSignatures.write_stats/1
      },
      %{
        relative: "discoveries/handle_errors.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.HandleErrors.write_stats/1
      },
      %{
        relative: "discoveries/fetch_methods.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.FetchMethods.write_stats/1
      },
      %{
        relative: "discoveries/ws_trades_semantics.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsTradesSemantics.write_stats/1
      },
      %{
        relative: "discoveries/ws_subscribe.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsSubscribe.write_stats/1
      },
      %{
        relative: "discoveries/ws_orderbook_semantics.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsOrderbookSemantics.write_stats/1
      },
      %{
        relative: "discoveries/ws_ohlcv_semantics.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsOhlcvSemantics.write_stats/1
      },
      %{
        relative: "discoveries/ws_heartbeat.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsHeartbeat.write_stats/1
      },
      %{
        relative: "discoveries/ws_dispatch.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsDispatch.write_stats/1
      },
      %{
        relative: "discoveries/ws_auth.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.WsAuth.write_stats/1
      },
      %{
        relative: "discoveries/overrides.json",
        entry_key: "exchanges",
        filter_key: "id",
        id_key: "node_key",
        stats_fn: &CcxtExtract.Overrides.write_stats/1
      },
      %{
        relative: "discoveries/method_descriptors.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &CcxtExtract.MethodDescriptors.write_stats/1
      },
      %{
        relative: "discoveries/methods_rest.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: fn _ -> %{} end,
        extra_from: "type"
      },
      %{
        relative: "discoveries/methods_ws.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: fn _ -> %{} end,
        extra_from: "type"
      },
      %{
        relative: "discoveries/url_templates.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: fn _ -> %{} end
      },
      %{
        relative: "discoveries/request_headers.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: fn _ -> %{} end
      },
      %{
        relative: "discoveries/rate_limit_costs.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &rate_limit_costs_stats/1
      },
      %{
        relative: "discoveries/rate_limit_buckets.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: &rate_limit_buckets_stats/1
      },
      %{
        relative: "discoveries/exchanges.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: fn _ -> %{} end
      },
      %{
        relative: "discoveries/public_exchanges.json",
        entry_key: "exchanges",
        filter_key: "id",
        stats_fn: fn entries ->
          %{
            "exchange_count" => length(entries),
            "summary" => public_exchanges_summary(entries),
            "credential_patterns" => public_exchanges_patterns(entries)
          }
        end,
        post_filter: &public_exchange_shape?/1
      }
    ]
  end
end
