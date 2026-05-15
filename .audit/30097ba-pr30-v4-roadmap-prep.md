# Audit — `30097ba` (PR #30: v4 roadmap prep)

**Commit:** `30097ba987092daaeee78fd5c3e7a46294e70982`
**Subject:** roadmap: prioritize v4 cut — tasks 142/143, supersede 36, greenfield stance (#30)
**Range:** `30097ba^..30097ba`
**Audited:** 2026-05-15
**Verdict:** ⚠️ → ✅ — 4 doc-drift findings, all fixed in this `audit(...)` commit.

## Scope

Docs + roadmap data + lockfile only — `CLAUDE.md`, `ROADMAP.md`, `mix.lock`, `roadmap/data.json`, `roadmap/tasks.toml`. No `lib/` code. 205 LOC (inflated by generated `roadmap/data.json` + `mix.lock`). Full audit (>100 LOC threshold), Cat 1 (bugs) had no code surface — all findings are Cat 6 (doc drift).

## Findings — all CONFIRMED, all fixed

Three PR bots (Codex GitHub bot, Copilot ×3) flagged 4 doc-consistency issues. Each verified against the codebase and fixed. Notably **3 of the 4 were introduced or worsened by this very commit** — exactly the post-merge hygiene class this pass exists to sweep.

| # | Severity | Finding | Verified against | Fix |
|---|----------|---------|------------------|-----|
| 1 | 5 | `AGENTS.md` (auto-generated from `CLAUDE.md`) not regenerated — greenfield stance never reached it; stale since 2026-05-09 (`756d196`) | `AGENTS.md:1` generation header + `claude-marketplace-elixir/scripts/sync-agents-md.sh` | Regenerated via the sync script. 810 del / 365 ins reflects 6 days of `CLAUDE.md` + `~/.claude/includes/*.md` drift, not just this commit. Deterministic artifact; file intact (3079 lines, 208 headings, all `@`-imports inlined). |
| 2 | 7 | `CLAUDE.md` Per-exchange JSON pipeline §: "every field carries a `raw`/`derived`/`override` tag plus the reason for any override" — factually wrong | `lib/ccxt_extract/provenance.ex` moduledoc: "flat top-level `_provenance` map keyed by RFC 6901 JSON Pointer ... **rather than inline per-field tuples**"; `"override"` reason "Carries a required `reason` **in the override file**" | Reworded to: flat top-level `_provenance` map keying each section to raw/derived/override; override reasons live in `priv/overrides/<id>.json`, not in the payload. This commit made an already-loose future-tense line ("provenance is becoming explicit ... fields will carry") into a definitively-wrong present-tense claim. |
| 3 | 6 | `ROADMAP.md:69` "v3 retained for one release post-flip" contradicts the greenfield stance this commit added (forbids "one release retention windows") and Task 143 added in the same PR ("Delete v3 entirely ... per the greenfield stance") | `CLAUDE.md` § "Project stance — greenfield" + `roadmap/tasks.toml` Task 143 body | Reworded to "v3 is deleted once v4 is the default (Task 143, v3 teardown) — no retention window, per the greenfield stance." Legal hand-edit — line 69 is prose outside the rmap marker pairs (byte-preserved). |
| 4 | 5 | `ROADMAP.md:286` "Superseded / Deferred" note lists Task 36 among 🔶-deferred items "live in tasks.toml as `status = "blocked"`" — but this commit flipped Task 36 to `status = "superseded"` (⛔) | `roadmap/tasks.toml` Task 36 `status = "superseded"`; rendered glyph ⛔ at `ROADMAP.md:147` | Removed `36` from the blocked-list; added a one-line note that Task 36 is now ⛔ superseded. Legal hand-edit — prose outside marker pairs. |

## Noted, not fixed (out of scope for a single-commit audit)

- **`ROADMAP.md` "v4 Schema-Freeze Plan" narrative (≈ lines 25–82)** describes the freeze as *ongoing* ("v3 stays the published contract throughout the freeze", "v3 stays default until freeze list is empty"). But the freeze gate **cleared 2026-05-14** (`ROADMAP.md:207`), and Tasks 142/143 now own the cut + teardown. The whole narrative section needs a reconciliation pass to present-tense. Larger than a mechanical audit fix — candidate for a dedicated `docs-drift` rmap task (compare Task 139, which already tracks a related `AGENTS.md` reconciliation).

## Codex second-opinion

**Dispatched** (`codex:codex-rescue`, parallel) — **did not return.** Job hung > 1h43m on a docs-only commit (reportedly "inspecting `mix.lock`"). Finalized on Claude's findings, which are independently verified against the codebase with hard evidence (`provenance.ex` moduledoc, `AGENTS.md` header, `roadmap/tasks.toml`, `ROADMAP.md` prose). No `discuss-design` findings — all 4 are Cat 6 doc fixes with unambiguous correct direction, so the Claude+Codex dialogue path was not load-bearing here. The mandatory-dispatch gap is recorded for honesty; the audit verdict does not depend on it.

## Files changed by this audit

- `AGENTS.md` — regenerated from `CLAUDE.md`
- `CLAUDE.md` — provenance wording corrected (finding #2)
- `ROADMAP.md` — retention-clause + superseded-note corrected (findings #3, #4)

## Process notes

- PR #30 squash-merged to `development` as `30097ba`; local `development` reconciled (the local-only `aca8b37 mix.lock` was a byte-identical duplicate, rebased away).
- Worktree `~/_DATA/worktrees/ccxt_extract/v4-roadmap-prep` left untouched (may have an active session) — its local branch couldn't be auto-deleted by `gh pr merge --delete-branch`; manual `git worktree remove` is the user's call.
