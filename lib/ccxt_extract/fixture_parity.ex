defmodule CcxtExtract.FixtureParity do
  @moduledoc """
  Compare committed signing fixtures (`priv/fixtures/signing/*.json`) against
  freshly regenerated output from `CcxtExtract.SigningFixtures.extract/0`.

  Surfaces silent drift that would otherwise sneak into a PR: extractor code
  changes that alter a fixture shape without anyone re-running the generator,
  or CCXT-version bumps that change `sign()` output.

  Volatile keys (`generated_at`) are stripped before diffing — everything else
  must match byte-for-byte. `ccxt_version` is intentionally compared: if CCXT
  upgrades, fixtures must be regenerated and that shows up as drift here.

  Pure diff is exposed as `diff/2` so tests can exercise it without booting
  QuickBEAM. `check/1` is the batteries-included entry point that regenerates
  via QuickBEAM and diffs against disk.
  """

  alias CcxtExtract.JsonIO

  @fixtures_dir "fixtures/signing"
  @volatile_keys ["generated_at"]

  @doc """
  Regenerate fixtures in-memory and diff against `fixtures_dir`.

  Returns a report map with `summary` and `exchanges` keys. Does not touch
  the filesystem. Callers (the mix task) write the report.
  """
  @spec check(String.t()) :: {:ok, map()}
  def check(fixtures_dir \\ CcxtExtract.Paths.priv(@fixtures_dir)) do
    {:ok, fresh} = CcxtExtract.SigningFixtures.extract()
    disk = load_disk(fixtures_dir)
    {:ok, diff(disk, fresh)}
  end

  @doc """
  Pure diff. `disk` is `%{"<id>" => fixture_map}` as loaded from disk,
  `fresh` is the list returned by `SigningFixtures.extract/0`.

  Report shape:

      %{
        "summary" => %{
          "total" => n,
          "match" => n,
          "drift" => n,
          "missing_on_disk" => n,
          "extra_on_disk" => n
        },
        "exchanges" => [
          %{"exchange" => id, "status" => "match" | "drift" | "missing" | "extra",
            "diff_keys" => [path, ...]}
        ]
      }
  """
  @spec diff(%{String.t() => map()}, [map()]) :: map()
  def diff(disk, fresh) when is_map(disk) and is_list(fresh) do
    fresh_by_id = Map.new(fresh, &{&1["exchange"], &1})
    disk_ids = MapSet.new(Map.keys(disk))
    fresh_ids = MapSet.new(Map.keys(fresh_by_id))

    missing = fresh_ids |> MapSet.difference(disk_ids) |> Enum.sort()
    extra = disk_ids |> MapSet.difference(fresh_ids) |> Enum.sort()
    shared = fresh_ids |> MapSet.intersection(disk_ids) |> Enum.sort()

    entries =
      Enum.map(missing, &%{"exchange" => &1, "status" => "missing", "diff_keys" => []}) ++
        Enum.map(extra, &%{"exchange" => &1, "status" => "extra", "diff_keys" => []}) ++
        Enum.map(shared, fn id ->
          diff_keys = diff_fixture(disk[id], fresh_by_id[id])
          status = if diff_keys == [], do: "match", else: "drift"
          %{"exchange" => id, "status" => status, "diff_keys" => diff_keys}
        end)

    entries = Enum.sort_by(entries, & &1["exchange"])

    summary = %{
      "total" => length(entries),
      "match" => Enum.count(entries, &(&1["status"] == "match")),
      "drift" => Enum.count(entries, &(&1["status"] == "drift")),
      "missing_on_disk" => length(missing),
      "extra_on_disk" => length(extra)
    }

    %{"summary" => summary, "exchanges" => entries}
  end

  @doc """
  Return `true` when the report shows any deviation from committed fixtures.
  """
  @spec has_drift?(map()) :: boolean()
  def has_drift?(report) do
    s = report["summary"]
    s["drift"] > 0 or s["missing_on_disk"] > 0 or s["extra_on_disk"] > 0
  end

  @doc """
  Load committed fixtures from disk. Keys are exchange IDs. Files starting
  with `_` are excluded — convention for metadata (`_manifest.json`) and
  generated reports (`_parity_report.json`) that share the directory.
  """
  @spec load_disk(String.t()) :: %{String.t() => map()}
  def load_disk(fixtures_dir) do
    fixtures_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Map.new(fn filename ->
      id = Path.rootname(filename)
      fixture = fixtures_dir |> Path.join(filename) |> JsonIO.read_json!()
      {id, fixture}
    end)
  end

  # Compare two fixtures; return a sorted list of JSON-pointer-ish paths
  # that differ. Ignores keys in @volatile_keys at any depth.
  defp diff_fixture(a, b) do
    a
    |> strip_volatile()
    |> walk_diff(strip_volatile(b), "")
    |> Enum.sort()
  end

  defp strip_volatile(map) when is_map(map) do
    map
    |> Map.drop(@volatile_keys)
    |> Map.new(fn {k, v} -> {k, strip_volatile(v)} end)
  end

  defp strip_volatile(list) when is_list(list), do: Enum.map(list, &strip_volatile/1)
  defp strip_volatile(other), do: other

  defp walk_diff(a, b, path) when is_map(a) and is_map(b) do
    keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))

    Enum.flat_map(keys, fn k ->
      walk_diff(Map.get(a, k), Map.get(b, k), "#{path}/#{k}")
    end)
  end

  defp walk_diff(a, b, path) when is_list(a) and is_list(b) do
    if length(a) == length(b) do
      a
      |> Enum.zip(b)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{av, bv}, i} -> walk_diff(av, bv, "#{path}/#{i}") end)
    else
      [path]
    end
  end

  defp walk_diff(a, b, path) do
    if a == b, do: [], else: [path]
  end

  @doc """
  Write the report to `path` as pretty JSON.
  """
  @spec write!(map(), String.t()) :: :ok
  def write!(report, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(report, pretty: true))
    :ok
  end
end
