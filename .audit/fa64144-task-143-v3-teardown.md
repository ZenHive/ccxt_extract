# audit(fa64144) — task(143): v3 teardown

**Range:** fa64144
**Subject:** task(143): v3 teardown — delete exchange_v3.json + all schema_target plumbing
**LOC:** 255+ / 3608- (24 files)
**Touches lib/:** yes (contract_test, override_registry, pipeline, provenance, schema, validation, 3 mix tasks)
**Classification:** full audit
**Reviewers:** Claude + Codex (gpt-5-codex, read-only)
**Verdict:** has-findings (all auto-applied + 3 discuss-design resolved via Codex dialogue → APPLY)

## Findings table (synthesized)

| # | Pri | Cat | File:Line | Description | Source |
|---|---|---|---|---|---|
| A1 | 9 | bug | `lib/ccxt_extract/override_registry.ex:171` (apply_all/2) | Direct callers with legacy v3-shaped override entries could put_in at `/structure/...` on v4 maps; helper bypassed `translate_pointer/1`. Pipeline avoids via `apply_override_entry`; unit tests at line 198+ used v3-shaped fixtures so the bug was masked. | Codex |
| A2 | 9 | bug | `lib/ccxt_extract/contract_test.ex:1268` (check_normalization_shape_valid) | Treated missing `normalization` top-level key as a v3-shape silent skip; post-v3 that's an extractor regression, not a fallback. | Codex |
| A3 | 9 | bug (discuss-design) | `lib/ccxt_extract/contract_test.ex:1699` (check_handler_dispatch_v4_shape_valid) | `v4_shape?/1` gate dead post-v3; silent `[]` return reachable through `mix ccxt_extract.contract_test` against stale gitignored output dirs. **Pre-commit Finding 8 user-declined.** Codex APPLY: "silent-skip on unknown shape is now a correctness gap, not a v3 compatibility path." Convergent. | Codex+Claude |
| A4 | 8 | doc-gap | `priv/schema/sign_recipe_v1.json:5` | Description referenced deleted `exchange_v3.json` AND deleted `test/ccxt_extract/sign_recipe_test.exs` parity enforcer. | Codex |
| A5 | 8 | dead-code | `test/integration/cached/request_shape_cached_test.exs` lines 25-29, 51-57, 66, 301-304 | TODO(Task 143) scaffold + `v4_or_v3_pointer/1` helper + `||` v3-fallback chains + `exchange_v3.json` reject filter. **Pre-commit Finding 1 carry-over (not applied before commit).** | Codex+Claude |
| A6 | 7 | naming (discuss-design) | `lib/ccxt_extract/schema.ex`, `validation.ex` | `_v4` suffix on `build_exchange_v4/4`, `validate_v4/1`, `check_schema_version_v4/2`, `@required_*_v4` attrs survived; v3 disambiguation no longer needed. **Pre-commit Finding 7 user-declined.** Codex APPLY: "`ccxt_client` doesn't reference the `_v4` function names; greenfield mode has no compat constraint; Provenance already renamed its equivalents in fa64144." Convergent. | Codex+Claude |
| A7 | 8 | bug | `test/ccxt_extract/authenticated_sections_integration_test.exs:103-145` | Read `runtime.describe.api`, `structure.authenticated_sections`, `structure.sign_method` (v3 paths). On v4 output these were nil — test silently no-op. | Codex |
| A8 | 6 | dead-code | `test/integration/cached/schema_v4_emit_cached_test.exs` (5 sites) | `schema_target: 4` opt passed to `Pipeline.extract/1` — opt no longer recognized after fa64144 deleted the `--schema-target` plumbing. | Codex |
| A9 | 6 | doc-gap | `ROADMAP.md:33,54,65` | "v3 stays the published contract" / "v3 stays default" / "Schema files: `exchange_v3.json` (current) and `exchange_v4.json` (new) coexist" — present tense, stale post-Task-143. **Pre-commit Finding 6 carry-over.** | Codex+Claude |
| A10 | 6 | doc-gap | `lib/ccxt_extract/provenance.ex:61` | Moduledoc Usage example used `/structure/authenticated_sections` path. | Codex |
| A12 | 6 | roadmap | `roadmap/tasks.toml:524` (Task 140 body — formerly 90b) | Body referenced `Schema.build_exchange_v3/v4` and "both v3 and v4 paths" — obsolete test plan post-v3-delete. | Codex |
| A14 | 5 | doc-gap | `lib/ccxt_extract/contract_test.ex:1967` moduledoc | `raw_pointers_v4/0 ++ derived_pointers_v4/0` reference — functions renamed to canonical names in fa64144. **Pre-commit Finding 3 carry-over.** | Codex+Claude |
| A15 | 5 | doc-gap | `test/support/exchange_fixtures.ex:6-7` moduledoc | Same `raw_pointers_v4/0` / `derived_pointers_v4/0` references. **Pre-commit Finding 4 carry-over.** | Codex+Claude |
| A16 | 5 | stale-comment | `lib/ccxt_extract/pipeline.ex:301` | "Path map varies by schema target (Task 130)" — `recipe_path_map/1` is single-path v4-only after fa64144. | Codex |
| A18 | 4 | doc-gap | `CHANGELOG.md` fa64144 entry | "the entire `schema_*_for/1` and `schema_*_v4/0` family removed" could read as "all `_v4` names gone"; `validate_v4`/`build_exchange_v4` survived at the time. The audit pass extends the rename, so a fresh CHANGELOG entry under "### Audit pass" documents the broader coverage. | Claude |
| A19 | 4 | doc-gap | `CLAUDE.md` "Per-exchange JSON pipeline" | Didn't enumerate the 8 v4 top-level groups (`endpoints`, `auth`, `errors`, `rate_limits`, `normalization`, `markets`, `testnet`, `raw`). | Codex |
| A22 | 5 | test-coverage | `test/ccxt_extract/override_registry_test.exs:254-256` | Placeholder comment where 6 `translate_pointer/2` direct unit tests used to live; arity changed to `/1` in fa64144 with zero direct coverage. Only 1 of 20 prefix-rewrite rules exercised via Pipeline integration tests. **Pre-commit Finding 2 user-approved (never landed).** | Codex+Claude |

## Codex-dialogue resolution (discuss-design items)

| Item | Pre-commit decision | Codex verdict | Final |
|---|---|---|---|
| A3 (`v4_shape?` gate) | User declined | APPLY | **Convergent → applied.** Footgun reachable via standalone `mix ccxt_extract.contract_test` on stale gitignored output dirs. |
| A6 (`_v4` rename) | User declined | APPLY | **Convergent → applied.** No `ccxt_client` references; Provenance precedent already set in fa64144. |
| A22 (translate_pointer/1 unit tests) | User approved | APPLY | **Convergent → applied.** 19 of 20 prefix rules previously uncovered. |

## Actions applied

20 fix-edits across 23 files. Tests pass: 2637 / 0 failed (offline suite; `:extraction`/`:tier3_corpus`/`:flaky` excluded per harness config). Compile clean.

## Notes

The structural pattern across A1, A2, A3 — all three Pri-9 findings — is the same: code that said *"if v3, short-circuit this check"* now silently short-circuits on all input, because v3 inputs no longer exist but the gate logic never fired and the dead branch became a footgun. The greenfield "delete don't wrap" rule needs a companion: *delete the gates that wrapped, not just the wrapped thing.*
