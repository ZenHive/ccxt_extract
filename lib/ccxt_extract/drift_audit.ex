defmodule CcxtExtract.DriftAudit do
  @moduledoc """
  Compare current derivation + overrides (current output JSONs + overrides/<id>.json)
  against a baseline release's output (loaded from a git tag/ref via `git show` or
  from a --baseline-dir). Report-only; surfaces three categories of drift so humans
  can decide on override or derivation updates.

  Categories:
  - stale_override: override present for a path whose final value or underlying raw
    differs from the baseline snapshot.
  - flipped_derived: a field whose current provenance is "derived" and whose value
    differs from (or is absent in) the baseline.
  - new_raw: a key/subtree appears under "raw" in current that was absent from the
    baseline's raw (or whole baseline); not yet promoted by derivation logic.

  Each finding carries exchange id, RFC 6901 path, before/after values.
  """

  alias CcxtExtract.JsonIO
  alias CcxtExtract.OverrideRegistry
  alias CcxtExtract.Paths

  @type category :: :stale_override | :flipped_derived | :new_raw
  @type finding :: %{
          category: category(),
          exchange: String.t(),
          path: String.t(),
          before: term(),
          after: term(),
          details: map()
        }

  @doc """
  Run the drift audit.

  Options:
    * `:baseline_tag` — git ref (tag or commit) whose `priv/output/<id>.json` trees
      supply the "last-released" baselines. Used via `git show REF:priv/output/ID.json`.
    * `:baseline_dir` — directory containing baseline `<id>.json` files (takes
      precedence over `:baseline_tag` when both present). Mirrors an `--output` dir.
    * `:output_dir` — current assembled output dir (default: `Paths.out("output")`).
    * `:exchange_ids` — list of ids to audit; default all entries from current
      `_manifest.json`.

  Always returns `{:ok, report}`. Callers decide whether findings warrant action.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    baseline_tag = Keyword.get(opts, :baseline_tag)
    baseline_dir = Keyword.get(opts, :baseline_dir)
    output_dir = Keyword.get(opts, :output_dir, Paths.out("output"))
    exchange_ids = Keyword.get(opts, :exchange_ids, list_manifest_exchanges(output_dir))

    exchanges =
      exchange_ids
      |> Enum.sort()
      |> Enum.map(fn id ->
        audit_one(id, output_dir, baseline_tag, baseline_dir)
      end)

    report = build_report(exchanges, baseline_tag, baseline_dir)
    {:ok, report}
  end

  @doc "Write a report map (pretty JSON) to disk."
  @spec write!(map(), Path.t()) :: :ok
  def write!(report, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(report, pretty: true))
    :ok
  end

  @doc false
  @spec classify_maps(String.t(), map(), map() | term(), list()) :: [finding()]
  def classify_maps(id, current, baseline, overrides) do
    id
    |> stale_override_findings(current, baseline, overrides)
    |> maybe_append_flipped(id, current, baseline)
    |> maybe_append_new_raw(id, current, baseline)
  end

  # --- per-exchange ---

  defp audit_one(id, output_dir, baseline_tag, baseline_dir) do
    current = load_current(output_dir, id)
    baseline = load_baseline(baseline_tag, baseline_dir, id)
    overrides = load_overrides(id)
    findings = classify_maps(id, current, baseline, overrides)

    %{
      "exchange" => id,
      "baseline_load_error" => if(is_map(baseline), do: nil, else: inspect(baseline)),
      "findings" => Enum.map(findings, &finding_to_map/1)
    }
  end

  defp maybe_append_flipped(findings, id, current, baseline) when is_map(baseline) do
    findings ++ flipped_derived_findings(id, current, baseline)
  end

  defp maybe_append_flipped(findings, _id, _current, _baseline), do: findings

  defp maybe_append_new_raw(findings, id, current, baseline) when is_map(baseline) do
    findings ++ new_raw_findings(id, current, baseline)
  end

  defp maybe_append_new_raw(findings, _id, _current, _baseline), do: findings

  defp load_current(output_dir, id) do
    path = Path.join(output_dir, "#{id}.json")

    case JsonIO.read_json(path) do
      {:ok, m} when is_map(m) -> m
      _ -> %{"_load_error" => "missing_or_invalid_current"}
    end
  end

  defp load_baseline(nil, nil, _id), do: {:error, :no_baseline_specified}

  defp load_baseline(_tag, dir, id) when is_binary(dir) do
    path = Path.join(dir, "#{id}.json")

    case JsonIO.read_json(path) do
      {:ok, m} when is_map(m) -> m
      {:error, e} -> {:error, e}
    end
  end

  defp load_baseline(tag, _dir, id) when is_binary(tag) do
    ref = "#{tag}:priv/output/#{id}.json"

    case System.cmd("git", ["show", ref], stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, m} when is_map(m) -> m
          {:error, e} -> {:error, {:invalid_json, e}}
        end

      {err, _} ->
        {:error, {:git_show_failed, String.trim(err)}}
    end
  end

  defp load_overrides(id) do
    case OverrideRegistry.load(id) do
      list when is_list(list) -> list
      :none -> []
    end
  rescue
    _ -> []
  end

  defp list_manifest_exchanges(output_dir) do
    path = Path.join(output_dir, "_manifest.json")

    case JsonIO.read_json(path) do
      {:ok, %{"exchanges" => ids}} when is_list(ids) -> ids
      _ -> []
    end
  end

  # --- category (a) ---

  defp stale_override_findings(id, current, baseline, overrides) do
    Enum.flat_map(overrides, fn ov ->
      raw_path = Map.get(ov, "path", "")
      ptr = OverrideRegistry.translate_pointer(raw_path)
      base_val = safe_get(baseline, ptr)
      curr_val = safe_get(current, ptr)

      raw_delta = raw_backing_delta(id, ptr, current, baseline)

      if base_val != curr_val or raw_delta do
        [
          %{
            category: :stale_override,
            exchange: id,
            path: ptr,
            before: base_val,
            after: curr_val,
            details: %{
              "override_reason" => ov["reason"],
              "raw_delta" => raw_delta,
              "translated_from" => if(raw_path == ptr, do: nil, else: raw_path)
            }
          }
        ]
      else
        []
      end
    end)
  end

  # Heuristic: if the exchange has a "raw" section in both, and they differ at all
  # under keys that typically feed derivation for overridden paths, call it raw change.
  # Keeps the impl small; a full per-path raw provenance is future work.
  defp raw_backing_delta(_id, _ptr, _current, baseline) when not is_map(baseline), do: false

  defp raw_backing_delta(_id, _ptr, current, baseline) do
    c_raw = Map.get(current, "raw", %{})
    b_raw = Map.get(baseline, "raw", %{})
    c_raw != b_raw
  end

  # --- category (b) ---

  defp flipped_derived_findings(id, current, baseline) do
    prov = Map.get(current, "_provenance", %{})

    prov
    |> Enum.filter(fn {_ptr, src} -> src == "derived" end)
    |> Enum.flat_map(fn {ptr, _src} ->
      base_val = safe_get(baseline, ptr)
      curr_val = safe_get(current, ptr)

      if base_val == curr_val do
        []
      else
        [
          %{
            category: :flipped_derived,
            exchange: id,
            path: ptr,
            before: base_val,
            after: curr_val,
            details: %{}
          }
        ]
      end
    end)
  end

  # --- category (c) ---

  defp new_raw_findings(id, current, baseline) do
    c_raw = Map.get(current, "raw", %{})
    b_raw = if is_map(baseline), do: Map.get(baseline, "raw", %{}), else: %{}

    added = collect_added_paths(c_raw, b_raw, "/raw")

    Enum.map(added, fn {ptr, val} ->
      %{
        category: :new_raw,
        exchange: id,
        path: ptr,
        before: nil,
        after: val,
        details: %{}
      }
    end)
  end

  # Return list of {pointer, value} for leaves/entries present in `curr` subtree
  # but absent from `base` at the same pointer. Only walks maps; lists are treated
  # by index for presence (rare in raw). Keeps diff surface small and human-useful.
  defp collect_added_paths(curr, base, prefix) when is_map(curr) do
    Enum.flat_map(curr, fn {k, v} ->
      ptr = prefix <> "/" <> to_string(k)

      cond do
        not Map.has_key?(base || %{}, k) ->
          # whole subtree is new
          [{ptr, v}]

        is_map(v) ->
          collect_added_paths(v, Map.get(base, k), ptr)

        true ->
          # scalar or list present on both sides — for minimal we do not deep-diff
          # list contents here; a top-level new scalar under raw is caught by the
          # has_key? branch when its parent key is new.
          []
      end
    end)
  end

  defp collect_added_paths(_curr, _base, _prefix), do: []

  # --- pointer helpers (RFC 6901, minimal) ---

  defp safe_get(nil, _ptr), do: nil
  defp safe_get(data, _ptr) when not is_map(data), do: nil

  defp safe_get(data, "/" <> _ = ptr) do
    keys =
      ptr
      |> String.split("/")
      |> Enum.drop(1)
      |> Enum.map(&unescape/1)

    get_nested(data, keys)
  end

  defp safe_get(data, _), do: data

  defp get_nested(data, []), do: data

  defp get_nested(data, [k | rest]) when is_map(data) do
    case Map.fetch(data, k) do
      {:ok, v} -> get_nested(v, rest)
      :error -> nil
    end
  end

  defp get_nested(data, [k | rest]) when is_list(data) do
    case Integer.parse(k) do
      {idx, ""} when idx >= 0 ->
        case Enum.at(data, idx) do
          nil -> nil
          v -> get_nested(v, rest)
        end

      _ ->
        nil
    end
  end

  defp get_nested(_, _), do: nil

  defp unescape(s) do
    s
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  # --- report ---

  defp build_report(exchanges, baseline_tag, baseline_dir) do
    all_findings = Enum.flat_map(exchanges, & &1["findings"])
    by_cat = Enum.group_by(all_findings, & &1["category"])

    summary = %{
      "exchanges_compared" => length(exchanges),
      "stale_overrides" => length(Map.get(by_cat, "stale_override", [])),
      "flipped_derived" => length(Map.get(by_cat, "flipped_derived", [])),
      "new_raw" => length(Map.get(by_cat, "new_raw", [])),
      "total_findings" => length(all_findings)
    }

    %{
      "generated_at" => CcxtExtract.Clock.timestamp(:generated_at),
      "baseline" => %{"tag" => baseline_tag, "dir" => baseline_dir},
      "summary" => summary,
      "exchanges" => exchanges,
      "findings" => all_findings
    }
  end

  defp finding_to_map(f) do
    %{
      "category" => Atom.to_string(f.category),
      "exchange" => f.exchange,
      "path" => f.path,
      "before" => f.before,
      "after" => f.after,
      "details" => f.details
    }
  end
end
