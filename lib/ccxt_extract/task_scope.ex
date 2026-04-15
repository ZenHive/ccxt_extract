defmodule CcxtExtract.TaskScope do
  @moduledoc """
  Shared scope-resolution plumbing for extraction Mix tasks.

  Every task that accepts `--tier1/--tier2/--tier3/--dex/--all/--exchange`
  loads the same universe from `priv/ccxt/ts/src/*.ts` (the CCXT TypeScript
  tree OXC extractors parse), delegates to `CcxtExtract.Scope.resolve/2`,
  and maps errors into `Mix.raise`. This module is the canonical home for
  that plumbing so tasks don't diverge.

  Typical use inside a Mix task:

      {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches)
      universe = CcxtExtract.TaskScope.load_universe()
      scope = CcxtExtract.TaskScope.resolve_scope!(opts, universe)
      tier_scope = CcxtExtract.Scope.to_manifest_value(opts)
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
  """
  @spec scoped_ids_missing_file(:all | MapSet.t(String.t()), String.t()) :: [String.t()]
  def scoped_ids_missing_file(:all, _dir), do: []

  def scoped_ids_missing_file(%MapSet{} = scope, dir) do
    scope
    |> Enum.reject(fn id -> File.exists?(Path.join(dir, "#{id}.json")) end)
    |> Enum.sort()
  end

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
