# audit(70dd2bb) — feat: v4 cut (Task 142) (#31)

**Range:** 70dd2bb
**Subject:** feat: v4 cut — default emission and validation to v4 (Task 142) (#31)
**LOC:** 1011+ / 707- (35 files)
**Touches lib/:** yes (contract_test, pipeline, provenance, schema, validation, sign_recipe + 4 sub-modules, plus mix tasks)
**Classification:** full audit
**Reviewers:** Claude + Codex (gpt-5-codex, read-only)
**Verdict:** has-findings — most resolved subsequently by fa64144 (v3 teardown). Residual carry-overs absorbed into the fa64144 audit report.

## Context

Task 142 flipped default emission + validation from schema v3 to v4. Per the commit message's explicit "Out of scope (Task 143)" callout, the v3 builder/validator and `--schema-target` plumbing stayed reachable to be removed in the follow-up commit (fa64144). The commit message is exemplary — names the load-bearing change (validation.ex round-trip path rewrites from v3 → v4 paths), surfaces a separately-audited finding (Audit F5: `NormalizationStubRecord._unresolved_reason` enum widening for `"no_fetcher_dispatch"`), explains test rewrites with rationale, lists docs touched, names verification commands.

## Findings table (Codex, with reconciliation against current HEAD)

| # | Pri | Cat | File:Line | Description | Status post-fa64144 |
|---|---|---|---|---|---|
| C1 | 8 | bug | `test/integration/cached/sign_recipe_cached_test.exs:23-26,410-413` | Reads `["structure", "sign_recipe"]` (v3 path) | **DROPPED — false positive.** Current file reads `["auth", "sign_recipe"]` exclusively (verified via grep). Codex audited at the 70dd2bb commit boundary; the v4-path rewrite landed within 70dd2bb itself. |
| C2 | 8 | bug | `test/ccxt_extract/authenticated_sections_integration_test.exs:99-105,140-147` | Reads `runtime.describe.api`, `structure.authenticated_sections`, `structure.sign_method` | **VALID — absorbed into fa64144 audit as A7.** Applied. |
| C3 | 7 | greenfield | `test/integration/cached/request_shape_cached_test.exs` v3 fallback scaffold | Compat plumbing | **VALID — absorbed into fa64144 audit as A5.** Applied. |
| C4 | 7 | naming | `Schema.build_exchange_v4/4`, `Schema.validate_v4/1` | Misleading suffixes | **VALID — absorbed into fa64144 audit as A6.** Applied via Codex APPLY verdict (user previously declined; Codex+Claude convergent). |
| C5 | 6 | greenfield | `lib/ccxt_extract/pipeline.ex:56-548` | Dual-version dispatch, v3 schema_target normalization, v3 recipe path maps | **DROPPED — already resolved by fa64144** (entire `schema_target` plumbing deleted; `normalize_schema_target!` removed; v3 `recipe_path_map` clause inlined to v4-only). |
| C6 | 6 | greenfield | `lib/ccxt_extract/validation.ex:50-77,1164-1170` | `schema_target: 3` behavior + honest-skip path for v3 round-trip | **DROPPED — already resolved by fa64144** (round-trip skip removed; `build_schema_root/1` → `/0`). |
| C7 | 5 | test correctness | `test/ccxt_extract/contract_test_test.exs:18,1090-1094,1169-1172` | "v3-shaped exchange short-circuit" tests now use a v4 fixture (`clean_exchange()` is v4-shaped per the fixture revamp), so the test no longer exercises what its name claims | **VALID — absorbed into fa64144 audit as A3 follow-up.** Test names + describe rewritten to "no findings on clean v4 fixture with nil handlers" and "no findings when wrapper + binding both null (clean v4 fixture)". |
| C8 | 5 | doc-gap | `lib/ccxt_extract/provenance.ex:37-62` | Moduledoc v3 pointer examples + opt-in `--schema-target=4` language | **VALID — absorbed into fa64144 audit as A10.** Applied (Usage example updated to `/auth/authenticated_sections`). |
| C9 | 4 | extraction | `test/ccxt_extract/contract_test_test.exs:24-31,48-57,1096-1162,1193-1223` | Repeated partial v4 exchange-map construction despite the fixture helper revamp | **DEFERRED.** Real opportunity for follow-up — `schema_conformant/2` could absorb more of the inline `put_in` chains. Filing as roadmap task is appropriate; not blocking. |
| C10 | 4 | doc-gap | `CLAUDE.md:99-101` | Pipeline docs say schema v4 but don't enumerate the 8 top-level groups | **VALID — absorbed into fa64144 audit as A19.** Applied. |

## Rating

**6/10 — severity ceiling: serious — at the time of 70dd2bb merge.** The main risk was stale validation/test surface that could silently stop checking v4 output, plus public API naming that pointed callers at v3 semantics. Most of that was resolved by the follow-up fa64144 commit + this audit pass.

## On the `*_v4` naming question (Codex stance)

> "These should have been renamed at the v4 default cut, not deferred to the later v3 deletion. Once v4 became the default, suffixes like `validate_v4`, `build_exchange_v4`, `build_default_v4`, and `schema_v4_emit` stopped disambiguating and started implying v4 is still an alternate path. The cost is cognitive and practical: new callsites naturally reach for unsuffixed `validate/1` and get legacy v3 semantics, while tests and docs keep encoding 'v4 as special case' even after the architecture moved on."

Renames applied in this audit pass (per Codex's APPLY verdict + Claude convergence). Provenance precedent had already been set in fa64144 (`build_default_v4/0` → `build_default/0`, `raw_pointers_v4/0` → `raw_pointers/0`, etc.).

## Commit message hygiene

Exemplary. `feat: <description>` subject, body covers scope + rationale + load-bearing change + surfaces audit finding from a different review pass (F5) + explains test rewrites + lists docs touched + names verification commands. Sets a clear benchmark for substantive feature commits in this repo.

## Notes

Codex auditing per-commit at the commit boundary surfaces findings that may already be resolved by later commits in the range. The reconciliation pass (this report's "Status post-fa64144" column) shows that 3 of the 10 Codex findings on 70dd2bb were already addressed by the v3-teardown commit landing 13 hours later. Audit-review's per-commit reports + range-wide synthesis catches this; auto-applying findings without reconciling against current HEAD would double-touch already-fixed code.
