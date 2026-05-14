# Audit: 4e235f3 — CLAUDE.md: drop linear-workflow.md import

**Range:** `4e235f3^..4e235f3`
**Audited:** 2026-05-14
**Reviewers:** Claude (primary). No Codex dispatch — tiny-commit fast-path.
**Path:** fast-path (3 deletions, docs-only, no `lib/` touched)

## Verdict: ✅ clean — fast-path

Docs-only commit: removes the `@~/.claude/includes/linear-workflow.md` import line from `CLAUDE.md` and the paragraph that cross-referenced its "Self-Authored Worktree Flow" cadence. Per the audit-review tiny-commit fast-path (≤100 LOC, no `lib/` or language-equivalent touched), no Codex dispatch and no 5-category sweep is warranted.

The change is self-consistent: it drops both the import directive AND the prose that depended on it, so there's no dangling reference to a no-longer-imported include. The commit message states the rationale (Linear cadence "not honored in practice") — this is the user's own workflow call, not a code-correctness matter. Nothing to fix.
