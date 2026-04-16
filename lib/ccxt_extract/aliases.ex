defmodule CcxtExtract.Aliases do
  @moduledoc """
  Read-side helper for CCXT alias membership.

  An "alias" exchange is a thin TypeScript re-export with `'alias': true`
  in its `describe()` (e.g. `gateio extends gate`, `huobi extends htx`).
  Aliases carry no independent `describe()` data — CCXT's JS runtime answers
  with the parent's resolved describe. The QuickBEAM-backed extractors
  (`describe`, `url_templates`, `signing_fixtures`, `load_markets`)
  accordingly skip aliases via a `!d.alias` filter and never emit
  `priv/discoveries/<subdir>/<alias>.json` files.

  That asymmetry collides with tier-based scope expansion: `CcxtExtract.Tiers`
  pulls in the whole family from `class_hierarchy.json`, so scopes like
  `--tier1 --tier2 --dex` include `gateio` and `huobi` — ids whose per-exchange
  files legitimately never exist. Stage-3 guards that probe for those files
  must know which ids are aliases so they don't fail loudly on legitimately
  absent output.

  This module owns that knowledge. Single source of truth is
  `priv/discoveries/exchanges.json`, the artifact produced by
  `CcxtExtract.Exchanges` from CCXT's own `!!d.alias` runtime check.

  The conceptual precedent is `CcxtExtract.CoverageReport`: its `check_*`
  functions short-circuit on `is_alias` with `layer(false, false, "alias")`
  ("legitimately absent, reason: alias"). `exclude_aliases/1` and
  `TaskScope.scoped_ids_missing_file/3`'s `:exclude_aliases` opt apply the
  same principle at scope-check sites.

  ## Usage

      alias CcxtExtract.Aliases

      Aliases.alias_ids!()          # => #MapSet<["gateio", "huobi"]>
      Aliases.alias?("gateio")      # => true
      Aliases.exclude_aliases(scope) # => scope with aliases removed
  """

  alias CcxtExtract.JsonIO

  @exchanges_file "exchanges.json"

  @doc """
  Load the set of alias exchange ids from `priv/discoveries/exchanges.json`.

  Raises `Mix.Error` with remediation if the file is missing or malformed.
  Callers are Mix tasks that have already confirmed stage-1 ran, so a missing
  file is operator error (regeneratable via `mix ccxt_extract.exchanges`).

  No cross-call caching — Mix task invocations are short-lived and
  `exchanges.json` is rewritten by stage-1 of `ccxt_extract.update`.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec alias_ids!(String.t()) :: MapSet.t(String.t())
  def alias_ids!(path \\ exchanges_path()) do
    if !File.exists?(path) do
      Mix.raise("""
      Alias membership source missing: #{path}

      Run `mix ccxt_extract.exchanges` (or `mix ccxt_extract.setup` followed by
      `mix ccxt_extract.update`) to regenerate it. Alias-aware scope checks
      require this file because CCXT aliases (e.g. gateio, huobi) have no
      per-exchange describe/url_templates/signing_fixtures/load_markets
      output on disk.
      """)
    end

    path
    |> JsonIO.read_json!()
    |> Map.fetch!("exchanges")
    |> Enum.filter(& &1["alias"])
    |> MapSet.new(& &1["id"])
  end

  @doc """
  Return `true` if `id` is a CCXT alias.

  Loads `exchanges.json` on every call — fine for one-off checks; use
  `alias_ids!/0` directly when checking many ids in a loop.
  """
  @spec alias?(String.t()) :: boolean()
  def alias?(id) when is_binary(id) do
    MapSet.member?(alias_ids!(), id)
  end

  @doc """
  Subtract alias ids from a scope.

  `:all` passes through unchanged (alias filtering is a scoped-run concern;
  full-universe runs tolerate missing files by convention — see
  `TaskScope.scoped_ids_missing_file/3`'s `:all` clause).
  """
  @spec exclude_aliases(:all | MapSet.t(String.t())) :: :all | MapSet.t(String.t())
  def exclude_aliases(:all), do: :all

  def exclude_aliases(%MapSet{} = scope) do
    MapSet.difference(scope, alias_ids!())
  end

  defp exchanges_path do
    CcxtExtract.Paths.priv(Path.join("discoveries", @exchanges_file))
  end
end
