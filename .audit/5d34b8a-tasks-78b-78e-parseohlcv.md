# Audit — `5d34b8a` Tasks 78b + 78e — parseOHLCV object-input + parse8601 timestamp wrapper

- **Commit:** `5d34b8a2f8874b8d229d9b6e943efa3e218b202f`
- **Parent:** `c4e2bb8`
- **PR:** #18 (squash-merged into `development`)
- **Branch (deleted):** `feat/bundle-1-78b-78e-ohlcv-object-input`
- **LOC:** 618 (lib/ + test/ + docs) — full machinery (≥100 LOC)
- **Reviewers:** Claude (audit-review Step 5a) + Codex CLI (Step 5b — agent `a7f7723543e467c49`, ~9m)
- **Verdict:** clean — 4 corroborated pre-existing doc-gap/test-diagnostic findings auto-applied; 0 new defects.

## Reviewer convergence

| Finding | Claude | Codex | Verdict |
|---|:---:|:---:|---|
| `ohlcv.ex:17` moduledoc Output template asserts `input_shape` always present | ✅ | ✅ | corroborated |
| `CHANGELOG.md:11` "(one branch array, another object)" misdescribes single-branch trigger | ✅ | ✅ | corroborated |
| `SCHEMA.md:276` lists 4-item vocab + treats 78e as future; line 322 lists 5-item vocab + says shipped | ✅ | ✅ | corroborated |
| `schema_v4_emit_cached_test.exs:173` bare `assert == :ok` instead of diagnostic `case` (line 76 pattern) | — | ✅ | Codex-only — verified against line 76; promoted from `discuss` default to apply |
| `ohlcv.ex:333` `non_safe_coercion:safeNumber` flagged as Cat 1 candidate | — | flagged + rejected | Codex self-rejected — moduledoc line 51 documents this as intentional honest-null for bitmex's `convertFromRawQuantity`; not a bug |

All four corroborated/promoted findings are **pre-existing** — they predate this PR's diff but were surfaced by the post-merge audit pass over the same range. None block the merge that already shipped.

## Auto-applied fixes (audit-review Step 9)

### Fix 1 — `lib/ccxt_extract/normalization/ohlcv.ex` (moduledoc Output template)

Expanded the inline `"guard"` map literal onto multiple lines and annotated `"input_shape"` as optional. The implementation's `:mixed` and `:no_pure_slots` paths emit `%{"kind" => "always"}` without `"input_shape"` — the prose at lines 38-41 already covered this, but the Output template at the top of the moduledoc presented `input_shape` as always-present. Now consistent.

### Fix 2 — `CHANGELOG.md` (Tasks 78b + 78e entry, mixed-locators sentence)

Reworded "genuinely mixed locators (one branch array, another object)" → "a single branch with mixed locators (some pure slots indexed, others keyed within the same branch — defensive: no real exchange does this)". The previous wording implied a multi-branch trigger; the actual extractor detects mixed integer/string locators *within* a single branch's pure slots.

### Fix 3 — `SCHEMA.md` (Task 78 closed-vocabulary section)

Reframed line 276 to "**Closed `coercion` vocabulary (initial Task 78 scope):**" with a forward-reference to the post-78b/78e vocabulary further below ("object-input shape (Tasks 78b + 78e)"). Resolved internal contradiction: line 276 listed 4 items + treated 78e as future; line 322 listed 5 items + said 78e shipped. Both lines are now mutually-consistent — line 276 is the historical baseline; line 322 is the current vocab.

### Fix 4 — `test/integration/cached/schema_v4_emit_cached_test.exs:173` (diagnostic case pattern)

Replaced bare `assert Validation.validate_schema(exchange, v4_root) == :ok, "..."` with the diagnostic `case` pattern already used at line 76 of the same file. On schema validation failure, the new pattern surfaces the first 5 finding paths + messages via `flunk/1` instead of just "validation failed for X". Diagnostic-pattern consistency within a file — Codex-flagged, verified against line 76 callsite, applied.

## Verification

- **Compile:** `time mix compile --warnings-as-errors` — clean (0 warnings, 0.39s user)
- **Test:** `mix test.json test/integration/cached/schema_v4_emit_cached_test.exs` — 4/4 pass; new case-pattern at line 173 is exercised by the priority loop and survives validation against the four 78b/78e exchanges (`hyperliquid`, `lighter`, `bitmex`, `htx`)
- **Codex full-suite tail:** Codex's audit pass ran the offline suite — 2292/2292 pass; `:extraction` / `:tier3_corpus` / `:flaky` excluded as expected.

## Out-of-scope (not applied)

- **`lib/ccxt_extract/pipeline.ex:898/909` Sobelow flags** — directory-traversal warnings on `schema_target`/`schema_source`/`target`/`source` variables. Pre-existing, not in any file this PR or this audit touched. Per `critical-rules.md` § "FIX HOOK-FLAGGED ISSUES ON FILES YOU TOUCH", scope is touched files only. Project-wide Sobelow hygiene is `mix sobelow --mark-skip-all` territory (per memory `feedback_sobelow_mark_skip_all.md`) and belongs to a separate hygiene pass, not this audit.
- **Worktree cleanup** — `~/_DATA/worktrees/ccxt_extract/bundle-1-78b-78e/` still exists with untracked gitignored `priv/output/`. Per memory `feedback_no_destructive_without_asking.md`, surfacing the manual-cleanup command at the end of this run rather than auto-removing.
