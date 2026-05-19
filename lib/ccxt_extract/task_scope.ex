defmodule CcxtExtract.TaskScope do
  @moduledoc """
  Shared scope-resolution plumbing for extraction Mix tasks.

  Every task that accepts `--tier1/--tier2/--tier3/--dex/--all/--exchange`
  loads the same universe from `priv/ccxt/ts/src/*.ts` (the CCXT TypeScript
  tree OXC extractors parse), delegates to `CcxtExtract.Scope.resolve/2`,
  and maps errors into `Mix.raise`. This module is the canonical home for
  that plumbing so tasks don't diverge.

  Typical use inside a Mix task (preferred):

      {scope, tier_scope, opts} = CcxtExtract.TaskScope.parse_and_resolve!(args)
      # or with task-specific switches:
      # {scope, tier_scope, opts} = CcxtExtract.TaskScope.parse_and_resolve!(args, @extra, @aliases)

  The one-liner replaces the previous duplicated preamble (OptionParser + manual
  validation + load_universe + resolve_scope! + to_manifest_value). The OXC
  discovery surface is fully on the helper; orchestration tasks (pipeline,
  update, determinism_check, contract_test) intentionally still do their own
  parsing for richer post-resolve dispatching.
  """

  alias CcxtExtract.Scope

  @scope_switches [
    tier1: :boolean,
    tier2: :boolean,
    tier3: :boolean,
    dex: :boolean,
    all: :boolean,
    exchange: :keep
  ]

  @doc """
  The six scope switches every extraction task accepts.

  Merge into task-local `@switches` keyword list:

      @switches Keyword.merge([type: :string], CcxtExtract.TaskScope.scope_switches())
  """
  @spec scope_switches() :: keyword()
  def scope_switches, do: @scope_switches

  @doc """
  Load the exchange-ID universe directly from `priv/ccxt/ts/src/*.ts`.

  The CCXT TypeScript tree is the source of truth OXC extractors parse, so
  deriving the universe from the same filenames is self-healing: a new
  exchange (e.g. `coincatch`) appears as soon as `mix ccxt_extract.setup`
  pulls it down, without waiting for a separate `exchanges.json`
  regeneration. WS-only exchanges don't exist in CCXT (every `pro/*.ts`
  has a REST counterpart), so `*.ts` is the full universe.

  Raises a `Mix.Error` with an actionable message if the TS source isn't
  present. Tasks call this before `resolve_scope!/2`.
  """
  @spec load_universe() :: [String.t()]
  def load_universe do
    ts_src = CcxtExtract.Paths.ts_src()

    if !File.dir?(ts_src) do
      Mix.raise("CCXT TypeScript source not found at #{ts_src}. Run `mix ccxt_extract.setup` first.")
    end

    ts_src
    |> Path.join("*.ts")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> Path.rootname()))
    |> Enum.sort()
  end

  @doc """
  Resolve opts + universe into a concrete scope or raise.

  Returns `:all` when the caller set `--all` or no narrowing flag, and a
  `MapSet` of exchange IDs otherwise. Emits a one-line `Mix.shell().info`
  with the scope label for scoped runs so operators can see what's active.

  Errors from `CcxtExtract.Scope.resolve/2` are mapped to `Mix.raise` with
  human-readable messages (fuzzy suggestions for unknown IDs, flag list for
  `--all` conflicts).
  """
  @spec resolve_scope!(keyword(), [String.t()]) :: :all | MapSet.t(String.t())
  def resolve_scope!(opts, universe) do
    case Scope.resolve(opts, universe) do
      {:ok, _ids, :all} ->
        :all

      {:ok, ids, {:scoped, label}} ->
        Mix.shell().info("Scope: #{label}")
        MapSet.new(ids)

      {:error, {:unknown_exchange, bad_ids, suggestions}} ->
        Mix.raise(format_unknown_exchange(bad_ids, suggestions))

      {:error, {:all_with_narrowing, conflicting}} ->
        flags = Enum.map_join(conflicting, ", ", &"--#{&1}")
        Mix.raise("--all conflicts with narrowing flag(s): #{flags}")
    end
  end

  @doc """
  Parse CLI args, reject unknown options and leftovers, and resolve scope.

  Collapses the 7-line preamble every scope-aware Mix task repeats:

      switches = Keyword.merge(extra_switches, scope_switches())
      {opts, leftover, invalid} = OptionParser.parse(args, strict: switches, aliases: aliases)
      # raise on invalid / leftover
      universe = load_universe()
      scope = resolve_scope!(opts, universe)
      tier_scope = Scope.to_manifest_value(opts)

  into a single call:

      {scope, tier_scope, opts} =
        CcxtExtract.TaskScope.parse_and_resolve!(args, [delay: :integer], d: :delay)

  Error messages are uniform across tasks:

    * `Unknown option(s): --foo, --bar`
    * `Unexpected argument(s): x, y. This task takes no positional arguments.`
    * (Scope conflicts and unknown IDs bubble up from `resolve_scope!/2`.)
  """
  @spec parse_and_resolve!([String.t()], keyword(), keyword()) ::
          {:all | MapSet.t(String.t()), term(), keyword()}
  def parse_and_resolve!(args, extra_switches \\ [], aliases \\ []) do
    switches = Keyword.merge(extra_switches, scope_switches())
    {opts, leftover, invalid} = OptionParser.parse(args, strict: switches, aliases: aliases)

    if invalid != [] do
      names = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{names}")
    end

    if leftover != [] do
      joined = Enum.join(leftover, ", ")
      Mix.raise("Unexpected argument(s): #{joined}. This task takes no positional arguments.")
    end

    universe = load_universe()
    scope = resolve_scope!(opts, universe)
    tier_scope = Scope.to_manifest_value(opts)

    {scope, tier_scope, opts}
  end

  @doc """
  Filter a list of entries to only those whose `id_key` value is in scope.

  `:all` passes the list through unchanged. A `MapSet` keeps only entries
  whose `id_key` value is a member.
  """
  @spec filter_entries([map()], :all | MapSet.t(String.t()), String.t()) :: [map()]
  def filter_entries(entries, :all, _id_key), do: entries

  def filter_entries(entries, %MapSet{} = scope, id_key) do
    Enum.filter(entries, &MapSet.member?(scope, Map.get(&1, id_key)))
  end

  @doc """
  Return the sorted list of scoped IDs whose `<id>.json` is missing in `dir`.

  `:all` short-circuits to `[]` — full-universe runs tolerate missing
  per-exchange files because some exchanges legitimately have none.

  Callers are expected to convert a non-empty list into a loud
  `Mix.raise`/flunk with remediation instructions. Kept separate from the
  raise call so unit tests can assert against the pure function without
  trapping `Mix.Error`.

  ## Options

    * `:exclude_aliases` (boolean, default `false`) — when `true`, drop CCXT
      alias ids (via `CcxtExtract.Aliases.exclude_aliases/1`) from the scope
      before the existence check. Tasks whose upstream extractor skips
      aliases (describe, url_templates, signing_fixtures, load_markets) opt
      into this so a scoped run that pulls in an alias-containing family
      (e.g. `--tier1 --tier2 --dex` bringing in `gateio`/`huobi`) does not
      fail on legitimately absent per-exchange output. Mirrors the
      `is_alias` → `layer(false, false, "alias")` pattern in
      `CcxtExtract.CoverageReport`.
  """
  @spec scoped_ids_missing_file(:all | MapSet.t(String.t()), String.t(), keyword()) ::
          [String.t()]
  def scoped_ids_missing_file(scope, dir, opts \\ [])

  def scoped_ids_missing_file(:all, _dir, _opts), do: []

  def scoped_ids_missing_file(%MapSet{} = scope, dir, opts) do
    scope
    |> maybe_exclude_aliases(Keyword.get(opts, :exclude_aliases, false))
    |> Enum.reject(fn id -> File.exists?(Path.join(dir, "#{id}.json")) end)
    |> Enum.sort()
  end

  defp maybe_exclude_aliases(scope, false), do: scope
  defp maybe_exclude_aliases(scope, true), do: CcxtExtract.Aliases.exclude_aliases(scope)

  @doc """
  Return the sorted list of exchange IDs currently present on disk under `dir`.

  Globs `*.json` and takes each basename without the extension. Files whose
  basename starts with `_` are treated as metadata (e.g. `_manifest.json`)
  and excluded. Non-existent or empty directories return `[]`.

  Used by per-exchange-directory tasks to rebuild their manifest's `exchanges`
  list from the ground truth after a scoped write — mirroring the "recompute
  envelope totals from merged entries" rule `AggregateWriter` enforces for
  single-aggregate files. Never carry manifest state across runs: re-derive
  from disk.
  """
  @spec rebuild_manifest_exchanges(Path.t()) :: [String.t()]
  def rebuild_manifest_exchanges(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> Path.rootname()))
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
  end

  @doc """
  Filter a list of exchange IDs by a resolved scope.

  `:all` is a pass-through; a `MapSet` keeps only IDs present in the set.
  Used by QuickBEAM-backed extractors to narrow the universe the JS runtime
  reports down to the current run's scope.
  """
  @spec filter_ids([String.t()], :all | MapSet.t(String.t())) :: [String.t()]
  def filter_ids(ids, :all), do: ids
  def filter_ids(ids, %MapSet{} = scope), do: Enum.filter(ids, &MapSet.member?(scope, &1))

  defp format_unknown_exchange(bad_ids, suggestions) do
    bad_ids
    |> Enum.map_join("\n", fn id ->
      case Map.get(suggestions, id, []) do
        [] -> "  • #{id} (no close matches)"
        matches -> "  • #{id} (did you mean: #{Enum.join(matches, ", ")}?)"
      end
    end)
    |> then(&"Unknown --exchange ID(s):\n#{&1}")
  end
end
