# Extract DiscoveryLoader from pipeline.ex

**Date:** 2026-04-16
**Source:** REFACTOR.md Item 1
**Status:** Approved

## Problem

`pipeline.ex` is 1,122 lines doing two jobs: discovery-file I/O (loading,
validating, integrity stats) and assembly logic (what data goes in each field).
Adding one new extractor costs 5 edit sites. The `validate_exchange_lookup_entry`
function is a 14-clause filename-string-match forest.

## Design

### New module: `CcxtExtract.DiscoveryLoader`

**File:** `lib/ccxt_extract/discovery_loader.ex`

**Public API:**

```elixir
@spec load_all!(String.t(), map()) :: map()
def load_all!(dir, exchanges_json)
# Returns %{describe: ..., load_markets: ..., classes: ..., sign_methods: ...,
#   handle_errors: ..., parse_methods: ..., ws_methods: ...,
#   interface_signatures: ..., pagination: ..., unified_endpoints: ...,
#   url_templates: ..., overrides: ..., canonical_has_keys: ...,
#   exchanges: [...], missing_files: [...], missing_entries: [...],
#   corrupt_entries: [...], orphan_entries: [...], id_mismatch_entries: [...]}

@spec read_json(String.t()) :: {:ok, term()} | {:error, {:missing_input | :invalid_json, String.t()}}
def read_json(path)
```

### Functions that move (become private in DiscoveryLoader)

- `load_all_data/2` -> body of `load_all!/2`
- `load_describe_files/2`, `reduce_describe_entry/3`, `read_describe_entry/2`
- `load_markets_files/2`, `reduce_markets_entry/3`, `read_markets_entry/2`, `markets_entry_id/1`
- `validate_manifest_ids!/2`
- `load_classes/3`
- `load_exchange_field/5`
- `load_sign_methods/3`
- `load_exchange_lookup/4`
- `load_overrides/3`
- `reduce_validated/3`
- `expected_exchange_ids/1`
- `empty_integrity_stats/0`, `add_stat_entry/3`
- `record_directory_orphans/4`, `record_global_orphans/4`
- `validate_expected_id/4`
- `validate_exchange_field_entry/3` (2 clauses)
- `validate_exchange_lookup_entry/2` (14 clauses)
- `fetch_required_key/4`, `validate_required_map_field/4`, `validate_optional_map_field/4`
- `compute_canonical_has_keys/1`
- `read_json/1` (becomes public)

### What stays in pipeline.ex (~628 lines)

- `extract/1` (public API) -- calls `DiscoveryLoader.load_all!/2`
- `write!/3`
- `filter_scope/2`, `assemble_and_validate/4`
- `build_exchange_data/3` and all `get_*` field-assembly helpers
- `resolve_auth_override/3`
- Parent-resolution helpers (`find_parent_exchange_id`, `get_parent_*`)
- `read_ccxt_version_info/0` -- calls `DiscoveryLoader.read_json/1`
- `copy_schema!/1`, `copy_base_methods!/2`, `build_manifest/2`

### Change to pipeline.ex `extract/1`

```elixir
# Before:
with {:ok, exchanges_json} <- read_json(exchanges_path) do
  data = load_all_data(dir, exchanges_json)

# After:
with {:ok, exchanges_json} <- DiscoveryLoader.read_json(exchanges_path) do
  data = DiscoveryLoader.load_all!(dir, exchanges_json)
```

And `read_ccxt_version_info/0`:
```elixir
# Before:
case read_json(Paths.version_file()) do

# After:
case DiscoveryLoader.read_json(Paths.version_file()) do
```

## Verification checkpoints

1. `mix test test/ccxt_extract/pipeline_test.exs` -- all existing tests pass unchanged
2. `mix test test/integration/cached/pipeline_cached_test.exs` -- cached integration path unchanged
3. `mix ccxt_extract.pipeline --tier1` -- output JSON byte-identical to pre-refactor baseline
4. New `test/ccxt_extract/discovery_loader_test.exs` -- unit tests for loader in isolation (mock discovery files, test integrity stats, test corrupt-file handling)

## Scope

~494 lines move out of pipeline.ex; ~10 lines of new glue code (module def, alias, public function heads). Pipeline.ex drops to ~628 lines. DiscoveryLoader ~504 lines. Net: same LOC, better seams.

## Deferred work

**REFACTOR.md Item 8 (new):** Promote `read_json/1` to `CcxtExtract.Paths` -- deduplicate the 7 private copies across pipeline, describe_key_analysis, method_analysis, summary, public_exchanges, coverage_report, family_analysis. D:1 / B:2 / ROI: 2.00.
