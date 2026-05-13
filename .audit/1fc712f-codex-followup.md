# Audit: 1fc712f — Codex follow-up (post-merge dual-reviewer recovery)

**Range:** `1fc712f^..1fc712f`
**Audited:** 2026-05-13
**Reviewers:** Claude (primary, first pass + this follow-up). Codex (second opinion via `codex:codex-rescue`, agent `aa9c7011e0e9c8d36`) — this round the agent prompt explicitly required waiting for substantive findings before returning. Codex completed a corpus-backed audit (`Verdict: PASS-WITH-NOTES`) with six findings, all rated 5–9 actionability.
**Path:** follow-up to the original `1fc712f` audit that committed `Codex bg-dispatched, no findings`. That framing was a methodology miss — the agent had returned on "background dispatched" not on "Codex finished." This pass re-runs the dual-reviewer step properly.

## Verdict: ✅ clean — 6 fixes applied (all from Codex follow-up review)

---

## Findings (all Codex, all auto-applied)

### F1 (Cat 3, actionability 9) — untracked in-progress audit file

`.audit/_in_progress_4d70630..fe195ce.md` was the resume-state planning artifact written mid-audit to survive a `/compact`. It remained untracked in the working tree after the audit commit, leaving `git status` dirty.

**Fix:** added `.audit/_in_progress_*.md` to `.gitignore` with a comment noting the audit-review skill's resume-state convention. Non-destructive — the planning artifact stays on disk for inspection, just no longer surfaces as untracked. Final `.audit/<sha>.md` reports remain tracked.

---

### F2 (Cat 3, actionability 7) — CHANGELOG missing audit-commit entries

Per CLAUDE.md § "Documentation invariants," tasks must update CHANGELOG.md in lockstep. The original `1fc712f` audit applied non-trivial code changes (vocab additions, recursive helper, refactor) but landed no CHANGELOG entry.

**Fix:** appended an "Audit follow-up (`1fc712f` + Codex follow-up audit)" sub-bullet to the existing Task 77+79 entry in `CHANGELOG.md` under `## [Unreleased]`. Lists the three honesty-contract closures (grvt unblock via TSAsExpression unwrap; lbank's `identifier_return`; wildcard rename to `unrecognized_return_shape`), the template-parity recursive helper, and the deferred-to-Task-135 ticker sibling drift. Notes that schema bumps were not required.

---

### F3 (Cat 5, actionability 7) — ticker.ex still carries the misnomer + lacks TSAsExpression unwrap

`lib/ccxt_extract/normalization/ticker.ex:125` emits `"no_return_statement"` for the wildcard fall-through — identical bug class to the one this audit fixed in balance/market. `ticker.ex` also has no `unwrap_ts_as/1` helper, so any TS-cast return in a parseTicker body would silently fall through. The original audit explicitly deferred this as out-of-scope, but didn't track it.

**Fix:** added **Task 135** to ROADMAP.md (Phase 12 section, bundle `12-simple`): `ticker.ex normalization-vocab alignment`. Scored `[D:2/B:4/U:5 → Eff:2.25] 🎯`. Description lists the three required clauses (`unwrap_ts_as/1` helper, `unrecognized_return_shape` rename, `identifier_return` clause) plus moduledoc + SCHEMA.md updates. Tracks back to this audit as the discovery source.

---

### F4 (Cat 3, actionability 6) — bundle 12-txn missing ✅ marker

ROADMAP.md line 110 lists bundle `12-txn` with tasks 81 + 82 but no completion marker, even though both individual rows (lines 293–294) carry ✅.

**Fix:** appended ✅ to the 12-txn bundle row's rationale column.

---

### F5 (Cat 1, actionability 5) — latent recursive-unwrap gap in transaction.ex + deposit_address.ex

`market.ex:161` correctly recurses: `unwrap_ts_as(%{...inner}) → unwrap_ts_as(inner)`. The same helper in `transaction.ex:160` and `deposit_address.ex:139` returns `inner` directly — a chained cast `x as Foo as Bar` would unwrap only one level and fall through to `non_object_return:TSAsExpression`. Latent (corpus probe: 0 chained-cast cases today), but the template asymmetry is a footgun.

**Fix:** made both helpers recursive (call `unwrap_ts_as(inner)` rather than returning `inner`). Added a one-line comment noting the parity rationale.

---

### F6 (Cat 3, actionability 8) — market.ex moduledoc contradicts implementation

`market.ex:10-12` still said "Exchanges using `extend`, `Identifier`, or `TSAsExpression` return shapes are marked unresolved" — directly contradicted by lines 66–67 (added during the original audit) which correctly say TSAsExpression is unwrapped before classification. A reader scanning the top of the moduledoc would have the wrong mental model.

**Fix:** rewrote lines 10–12 to say TSAsExpression wrappers are unwrapped before classification; `extend` and bare `Identifier` remain in the unresolved-shape list.

---

## Findings rejected / noted

### Codex correctness pass: PASS

Codex's Sections 1+4 (correctness review of `unwrap_ts_as/1` recursion in market.ex, `classify_return_argument/1` head ordering, new private-function `@spec` coverage, and arkham's parseDepositAddress TSAsExpression handling) returned PASS. No bugs in the original audit's fixes — just the six gaps above.

---

## Files touched (this audit)

- `.gitignore` — `+5` lines (ignore `.audit/_in_progress_*.md` with explanatory comment)
- `CHANGELOG.md` — `+1` line (audit follow-up bullet under Task 77+79)
- `ROADMAP.md` — `+1` row (Task 135) + ✅ marker on bundle 12-txn
- `lib/ccxt_extract/normalization/market.ex` — moduledoc lines 10–12 corrected
- `lib/ccxt_extract/normalization/transaction.ex` — `unwrap_ts_as/1` made recursive
- `lib/ccxt_extract/normalization/deposit_address.ex` — same
- `.audit/1fc712f-codex-followup.md` — this report

No test changes — F5 is latent (no current corpus case), F6/F2/F1/F4 are doc/state, F3 is a deferred ROADMAP entry.

## Harness state at audit completion

- `mix format --check-formatted`: clean
- `time mix compile --warnings-as-errors`: clean (0.31s)
- `mix test.json --quiet test/ccxt_extract/normalization/`: 276/276 pass
- `mix credo --strict --format json lib/ccxt_extract/normalization/`: 0 issues
- `mix dialyzer.json --quiet`: 0 warnings (5 skipped pre-existing entries)

Excluded tags (`:extraction`, `:tier3_corpus`, `:flaky`) NOT verified — none touched by this audit's changes.

## Process note

The original `1fc712f` audit commit ended Claude-solo because the `codex:codex-rescue` subagent returned `status: completed` after merely dispatching the Codex CLI job, not after receiving Codex's findings. This follow-up audit's prompt explicitly instructed the agent to wait for substantive Codex output before returning — that fix produced a useful second-opinion pass on the first try. Worth retaining as the pattern for future dual-reviewer dispatches.
