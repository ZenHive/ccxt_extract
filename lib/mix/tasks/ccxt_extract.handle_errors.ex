defmodule Mix.Tasks.CcxtExtract.HandleErrors do
  @shortdoc "Extract handleErrors() method AST from CCXT TypeScript source"

  @moduledoc """
  Extracts the `handleErrors()` method body as raw ESTree AST for every REST exchange.

  Parses TypeScript source files via OXC, finds the `handleErrors()` method on each
  exchange class, and writes the complete method AST (parameters, return type,
  and full body) to `priv/discoveries/handle_errors.json`.

  Also includes `exceptions` and `httpExceptions` from each exchange's `describe()`
  output (extracted in Task 6) alongside the method AST.

  Exchanges without a `handleErrors()` method are included with `"handle_errors": null`.

      mix ccxt_extract.handle_errors
      mix ccxt_extract.handle_errors --tier1 --dex
      mix ccxt_extract.handle_errors --exchange binance,deribit

  ## Options

    * `--tier1 --tier2 --tier3 --dex` — restrict extraction to the named
      priority tiers (combinable). Scoped runs merge into the existing
      aggregate; out-of-scope entries are preserved.
    * `--exchange ID` — restrict to explicit exchange IDs. Typos fail
      loudly with fuzzy suggestions.
    * `--all` — explicit full-universe run; conflicts with any narrowing flag.

  **Describe dependency.** This task reads
  `priv/discoveries/describe/<id>.json` to attach `exceptions` and
  `httpExceptions` to each entry. For scoped runs, every non-alias in-scope
  exchange must already have a describe file on disk; missing files fail
  loudly (run `mix ccxt_extract.describe` with the same scope first).
  CCXT aliases (e.g. `gateio`, `huobi`) are excluded from the guard — the
  describe extractor skips them by design (`!d.alias`), so their per-exchange
  files legitimately never exist. Mirrors the "legitimately absent, reason:
  alias" precedent in `CcxtExtract.CoverageReport`. Full-universe runs
  tolerate missing describe files across the board (some DEX exchanges have
  none) — fields are written as `null` in that case.

  The active scope is stamped into the JSON envelope as `tier_scope`.
  """

  use Mix.Task

  alias CcxtExtract.Scope
  alias CcxtExtract.TaskScope

  @switches TaskScope.scope_switches()

  @impl true
  def run(args) do
    {opts, leftover, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      switches = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unknown option(s): #{switches}")
    end

    if leftover != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(leftover, ", ")}")
    end

    universe = TaskScope.load_universe()
    scope = TaskScope.resolve_scope!(opts, universe)
    tier_scope = Scope.to_manifest_value(opts)

    assert_describe_files_present!(scope)

    Mix.shell().info("Extracting handleErrors() method AST from REST exchanges...")

    {:ok, all_exchanges, stats} = CcxtExtract.HandleErrors.extract()
    exchanges = TaskScope.filter_entries(all_exchanges, scope, "id")
    CcxtExtract.HandleErrors.write!(exchanges, scope: scope, tier_scope: tier_scope)

    with_handle_errors = Enum.count(exchanges, & &1["handle_errors"])
    error_count = length(stats.errors)

    Mix.shell().info("""
    Done. #{length(exchanges)} exchanges scanned, #{with_handle_errors} with handleErrors() method.
    #{if error_count > 0, do: "#{error_count} parse error(s).", else: ""}
    Output: priv/discoveries/handle_errors.json
    """)
  end

  # Scoped runs require describe files for every non-alias in-scope ID.
  # Aliases (gateio, huobi, etc.) are skipped by the describe extractor itself
  # (`!d.alias`), so their per-id files never exist — `:exclude_aliases`
  # honours that asymmetry. `--all` tolerates missing describe files across
  # the board (full-universe runs legitimately include exchanges with no
  # describe output, e.g. some DEX entries).
  defp assert_describe_files_present!(scope) do
    describe_dir = CcxtExtract.Paths.priv(Path.join("discoveries", "describe"))

    case TaskScope.scoped_ids_missing_file(scope, describe_dir, exclude_aliases: true) do
      [] ->
        :ok

      missing ->
        files = Enum.map_join(missing, "\n", &"  • #{&1}.json")

        Mix.raise("""
        Missing describe files for scoped exchange(s):
        #{files}

        Run the describe extractor for the same scope first, e.g.:
          mix ccxt_extract.describe --exchange #{Enum.join(missing, ",")}
        """)
    end
  end
end
