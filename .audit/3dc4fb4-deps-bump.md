# audit(3dc4fb4) — deps: bump 6 packages

**Range:** 3dc4fb4
**Subject:** deps: bump 6 packages — oxc 0.13, reach 2.4 (cascades ex_ast 0.12), quickbeam 0.10.13, npm 0.7.4, doctor 0.23
**LOC:** 13+ / 13- (2 files)
**Touches lib/:** no
**Classification:** fast-path (≤100 LOC AND no lib/)
**Verdict:** clean — fast-path

Mechanical version bumps in `mix.exs` + `mix.lock`. Cross-instance memory + CLAUDE.md include surface (oxc.md, reach.md, quickbeam.md, npm-ci-verify.md) already reflect the bumped versions, so no doc drift. No behavior change inferred from the lock-file delta.
