---
sha: fd5ae4f46b4e7f3b2838ffa58c03fe629cd0abfd
short_sha: fd5ae4f
audited_at: 2026-05-14
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: NORMALIZATION-DEDUP.md

**Original commit:** fd5ae4f — `NORMALIZATION-DEDUP.md`
**Author:** E.FU
**Files touched:** 1 (NORMALIZATION-DEDUP.md, new)
**LOC:** +172

Pure-prose design/findings doc — over the 100-LOC fast-path threshold, so it got a
full dual-reviewer pass. Categories 1-5 are empty (no production code); all findings
are Category 6 (factual / formatting drift inside the doc).

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | doc-gap | NORMALIZATION-DEDUP.md:22 | Claims `ohlcv.ex` is not in the clone clusters — verified it IS | applied |
| 2 | — | doc-gap (codex, unverified) | NORMALIZATION-DEDUP.md:140 | "50 clones" via `Reach.CloneAnalysis.analyze/2` vs Codex's 44 | noted only — not applied |
| 3 | 3 | doc-gap | NORMALIZATION-DEDUP.md:58 | Bucket A heading says "(3)" but the table lists 4 axes | applied |
| 4 | 2 | doc-gap | NORMALIZATION-DEDUP.md:104 | Malformed `` `@behaviour** `` — unclosed inline-code span | applied |

## Auto-applied fixes

- **NORMALIZATION-DEDUP.md:22** — Verified with `mix ex_dna --format json lib/ccxt_extract/normalization/`
  (the doc's own cited command, which returns exactly the 30 clones the Method section
  claims). `ohlcv.ex` appears in clone #27 — a mass-32 block common to all 9
  `normalization/` modules. `response_envelopes.ex` is correctly absent (0 hits). The
  doc's line-22 claim ("`ohlcv.ex` and `response_envelopes.ex` are not in the clone
  clusters") contradicts its own line-16 evidence for `ohlcv.ex`. Rewrote to keep
  `response_envelopes.ex` as outside-the-family and describe `ohlcv.ex`'s membership as
  marginal (one family-wide clone, none of the pairwise clusters) — to confirm during
  the refactor. Matters because the doc is a decision-input that will be folded into the
  roadmap; scoping `ohlcv.ex` out by mistake would carry into the eventual refactor task.
- **NORMALIZATION-DEDUP.md:58** — Bucket A heading "(3)" → "(4)". The table under it lists
  4 parameterization axes (`@unified_fields`, safe-call method vocab, wrapper method +
  reason prefix, field categories). Buckets B "(2)" and C "(3)" both match their lists;
  only A was off.
- **NORMALIZATION-DEDUP.md:104** — `` a `@behaviour** `` → `` a `@behaviour` ``. The
  original had an opening backtick with no close plus a stray `**`, breaking the inline
  code span. Corroborated independently by Claude and Codex.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 4 (Claude found it independently; Codex confirmed)
Codex-only findings (verified → applied): 1, 3
Codex-only findings (noted, not applied): 2 — Codex reported `Reach.CloneAnalysis.analyze/2`
  returns 44 clones vs the doc's 50. Not auto-applied: the exact invocation (args, config)
  the doc author used could not be reproduced deterministically, ExDNA-clone counts are
  config/version-sensitive, and the number sits in a non-load-bearing "Known limitation"
  prose section. Per the calibration rule, an unverified Codex-only finding stays noted,
  not applied. The doc's load-bearing `mix ex_dna` claim ("30 clones in normalization/")
  WAS verified — exact match.
Codex-only findings (discarded as over-flag): —
