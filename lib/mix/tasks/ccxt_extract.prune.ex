defmodule Mix.Tasks.CcxtExtract.Prune do
  @shortdoc "Evict out-of-scope local discoveries/output state and re-sync envelopes"

  @moduledoc """
  Deletes out-of-scope per-exchange JSON from discoveries subdirectories and
  `priv/output/`, then rewrites aggregate envelope files so their entry lists,
  stats, and `tier_scope` stamps match the declared scope.

  Dry-run by default — pass `--force` to apply deletions and rewrites.

      mix ccxt_extract.prune --tier1 --dex
      mix ccxt_extract.prune --exchange binance,deribit --force
      mix ccxt_extract.prune --all --force

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — narrow to named priority tiers
    * `--exchange ID` — explicit exchange IDs (repeatable, comma-separated)
    * `--all` — full universe (conflicts with narrowing flags)
    * `--force` — apply deletions and envelope rewrites (default: dry-run)
    * `--output DIR` — redirect all writes under `DIR` via `:priv_dir_override`

  Never touches `class_hierarchy.json`. Honors `:priv_write_override` for
  reads/writes routed through `CcxtExtract.Paths.out/1`.
  """

  use Mix.Task

  alias CcxtExtract.ScopePrune
  alias CcxtExtract.TaskScope

  @impl true
  def run(args) do
    {scope, tier_scope, opts} = TaskScope.parse_and_resolve!(args, [force: :boolean, output: :string], [])

    with_priv_override(opts, fn ->
      universe = TaskScope.load_universe()
      in_scope = scope_to_set(scope, universe)
      dry_run? = !opts[:force]

      mode = if dry_run?, do: "DRY-RUN", else: "APPLY"
      Mix.shell().info("Scope prune (#{mode}): keeping #{MapSet.size(in_scope)} exchange(s)...")

      {:ok, result} =
        ScopePrune.run(in_scope: in_scope, tier_scope: tier_scope, force: opts[:force] || false)

      report(result)
    end)
  end

  defp scope_to_set(:all, universe), do: MapSet.new(universe)
  defp scope_to_set(%MapSet{} = scope, _universe), do: scope

  defp with_priv_override(opts, fun) do
    case opts[:output] do
      nil ->
        fun.()

      path ->
        resolved = Path.expand(path)
        prior = Application.get_env(:ccxt_extract, :priv_dir_override)
        Application.put_env(:ccxt_extract, :priv_dir_override, resolved)

        try do
          fun.()
        after
          case prior do
            nil -> Application.delete_env(:ccxt_extract, :priv_dir_override)
            value -> Application.put_env(:ccxt_extract, :priv_dir_override, value)
          end
        end
    end
  end

  defp report(%{dry_run: dry_run?, removed_files: removed, updated_envelopes: envelopes, updated_manifests: manifests}) do
    Mix.shell().info("Would remove #{length(removed)} per-exchange file(s).")

    for path <- Enum.take(removed, 10) do
      Mix.shell().info("  - #{path}")
    end

    if length(removed) > 10 do
      Mix.shell().info("  ... and #{length(removed) - 10} more")
    end

    Mix.shell().info("Would update #{length(envelopes)} envelope file(s) and #{length(manifests)} manifest(s).")

    if dry_run? do
      Mix.shell().info("Dry-run only. Re-run with --force to apply.")
    else
      Mix.shell().info("Applied. Re-run without --force any time to preview changes.")
    end
  end
end
