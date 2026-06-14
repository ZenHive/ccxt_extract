# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON so any consumer — in any language — can operate an exchange without walking AST.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Contract reference:** See [CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md) for the unfiltered list of what a consumer needs. Phases 10–16 tick items off that checklist.

**Schema contract:** See [SCHEMA.md](SCHEMA.md) for field-level definitions and version history of the emitted JSON.

---

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** not set — add [focus] to tasks.toml
<!-- FOCUS:END -->

**Active milestone: `feature_complete`.** Tests the hypothesis that the v4 JSON contract is sufficient for a downstream consumer to operate every priority-tier exchange end-to-end — signing, request, response, errors, rate limits, WS, market/currency — without re-deriving from CCXT AST. Pick the next task with `rmap next` (auto-biases to the active milestone). v4 schema cut (the prior milestone) shipped 2026-05-19; for the historical narrative see [CHANGELOG.md](CHANGELOG.md).

**Scope.** Raw extraction runs universe-wide. *Derivation effort* (signing recipes, fee schedules, error handlers) is scoped to the 7-exchange option-seller set in `priv/priority_tiers.json`; everything else gets `null + reason` until a priority consumer surfaces a concrete need. Slider mechanics in [CLAUDE.md § Tier-based scoping](CLAUDE.md#tier-based-scoping-philosophy).

> **Philosophy reminder:** Every value is either provable (emit it) or explicitly unprovable (`null` + reason). No silent guesses. Overrides fill gaps derivation can't reach and carry reasons too.

### Endpoint-Invocation Priority Order

Phases ranked by criticality for consumers calling *any* endpoint (unified or implicit). Used to disambiguate when two `rmap next` candidates tie on `Eff` — prefer the lower rank.

| Rank | Phase | Serves | Why it matters |
|------|-------|--------|----------------|
| 1 | **Phase 10** (Signing) ✅ | Unified + non-unified | Closed (see CHANGELOG). |
| 2 | **Phase 11** (Request building) | Unified + non-unified | Turns `(section, path)` into an HTTP request — verb, body encoding, timestamp, headers. |
| 2 | **Phase 12** (Normalization) | Unified | Field maps + envelopes for unified responses. |
| 4 | **Phase 14** (Rate limits) ✅ | Unified + non-unified | Per-endpoint cost weights. Closed (see CHANGELOG). |
| 5 | **Phase 13** (Errors) | Unified + non-unified | Status-code maps, retry classification, dispatch routing. |
| 6 | **Phase 9** (Override audit) | Scaffolding | Three-Strikes Rule's escape hatch when AST can't prove a shape. |
| 7 | **Phase 16** (Market & currency) | Unified + non-unified | Declarative metadata orthogonal to endpoint invocation. |
| 8 | **Phase 15** (WS contract) | Streaming | Separate transport; not on the REST critical path. |

### Bundle Index

Tasks are grouped into session-sized bundles in [`roadmap/tasks.toml`](roadmap/tasks.toml). Run `rmap bundles` for the live list, or `rmap next-bundle` for the next session-sized chunk. Bundle membership and per-task status are not hand-maintained here — `tasks.toml` is the source of truth, and this file is rendered from it.

The v4 cut shipped 2026-05-19; for the v4 reshape (top-level sections, path migration), see [SCHEMA.md § Version 4.0.0](SCHEMA.md#version-400--in-progress-gated). Completed bundles are recorded in [CHANGELOG.md](CHANGELOG.md).

### Quick Commands
```bash
mix ccxt_extract.update          # Full re-extract
mix ccxt_extract.pipeline        # Assemble per-exchange JSON
mix ccxt_extract.validate        # JSON Schema + round-trip
mix test.json --quiet            # Fast tests (cached)
mix test.json --quiet --include extraction  # Full tests

rmap validate                    # Check roadmap/tasks.toml
rmap render                      # Regenerate ROADMAP.md + roadmap/data.json
rmap next                        # Highest-Eff pending task (focus-biased)
rmap bundles                     # List session-sized task bundles
```

Full command list in [CLAUDE.md](CLAUDE.md).

---

## Phase 0: Maintenance Backlog

> Open technical-debt items outside the phased work. Completed Phase 7 tasks (Tasks 35, 38, 39, 42–47) moved to CHANGELOG.md. Audit-surfaced follow-ups (legacy "Audit-Surfaced Follow-Ups" section) are now the `docs-drift`, `test-coverage`, and `det-contract` bundles — per-task audit provenance lives in each task body. The legacy duplicate IDs 132/133 (audit copies) were renumbered to 139/140 at the rmap migration (Task 138 is the post-f3ea824 audit's `det-contract` follow-up); Phase 13's 132/133 keep their IDs.

<!-- TASKS:BEGIN phase=0 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 105 | ✅ | 🎁 **maintenance** · Port super.*() delegation coverage off coincatch [D:2/B:3/U:2 → Eff:1.25?] 📋 |
| Task 106 | ✅ | 🎁 **maintenance** · Drifted-override fixture for override_paths_present_in_output [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 109 | ✅ | 🎁 **maintenance** · Promote finding() map type to a %Finding{} struct [D:2/B:2/U:2 → Eff:1.0?] 📋 |
| Task 110 | ✅ | 🎁 **maintenance** · Triage 32 request_defaults_resolvable_reachable_from_unified findings [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 124 | ✅ | 🎁 **maintenance** · Prune Bybit discontinued spot/v3/private/* endpoints from extracted spec [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 127 | ✅ | 🎁 **maintenance** · Position-aware paths_rw_split sinks + variable-level sanitization [D:5/B:3/U:3 → Eff:0.6?] ⚠️ |
| Task 136 | ✅ | 🎁 **maintenance** · Re-track priv/output/ now that extraction is byte-deterministic [D:3/B:4/U:5 → Eff:1.5?] 🚀 |
| Task 137 | ✅ | 🎁 **maintenance** · Retrofit Pattern B timestamp writers to accept an :extracted_at opt [D:4/B:3/U:3 → Eff:0.75?] ⚠️ |
| Task 141 | ✅ | 🎁 **maintenance** · Author real specs for WS milestone tasks 94 + 95a/95b/95c [D:3/B:3/U:3 → Eff:1.0] 📋 |
| Task 113 | ⬜ | 🎁 **10-sign-extend** · Track indirect signature placement via request-like object construction [D:4/B:3/U:3 → Eff:0.75?] ⚠️ |
| Task 66e | ⬜ | 🎁 **10-sign-extend** · Expand canonical_string component vocabulary [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 66f | ⬜ | 🎁 **10-sign-extend** · Key-format disambiguation for Binance/Bybit HMAC branches [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 66g | ⬜ | 🎁 **10-sign-extend** · Sub-verb expansion (POST vs PUT vs DELETE vs PATCH) in canonical_string [D:3/B:3/U:3 → Eff:1.0?] 📋 |
| Task 66h | ⬜ | 🎁 **10-sign-extend** · Trace conditionally-reassigned body alias variables (kucoin endpart, coinbase payload) [D:5/B:4/U:4 → Eff:0.8?] ⚠️ |
| Task 128 | ⬜ | 🎁 **10-sign-extend** · Multi-hop body alias resolution in pre_sign_transforms body-encoding detector [D:4/B:3/U:3 → Eff:0.75?] ⚠️ |
| Task 126 | ⬜ | 🎁 **sibling-emit** · Secondary OpenAPI 3.1 emitter for REST exchanges [D:6/B:7/U:5 → Eff:1.0?] 📋 |
| Task 125 | ⬜ | 🎁 **sibling-emit** · Secondary OpenRPC emitter for JSON-RPC exchanges (Deribit first) [D:3/B:3/U:2 → Eff:0.83?] ⚠️ |
| Task 119 | ✅ | 🎁 **scope-hygiene** · mix ccxt_extract.prune — evict out-of-scope local state [D:4/B:5/U:4 → Eff:1.12?] 📋 |
| Task 120 | ✅ | 🎁 **scope-hygiene** · Tier-scope-aware skip for authenticated_sections + sign_recipe cached tests [D:3/B:3/U:3 → Eff:1.0?] 📋 |
| Task 139 | ✅ | 🎁 **docs-drift** · Reconcile AGENTS.md cloud-agent guidance with retired [CSR]/[CX] strategy [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 140 | ✅ | 🎁 **test-coverage** · Add pipeline-level integration tests for endpoint_cost_binding propagation [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 138 | ✅ | 🎁 **det-contract** · Extract JsonIO.write_json!/2,3 + a deterministic_write contract invariant [D:4/B:4/U:3 → Eff:0.88?] ⚠️ |
| Task 66c | ⬜ | 🎁 **10-exotic** · Canonical string recipe — JWT / RSA / Ed25519 family [D:5/B:4/U:3 → Eff:0.7?] ⚠️ |
| Task 66d | ⬜ | 🎁 **10-exotic** · Canonical string recipe — custom / outlier family [D:5/B:3/U:3 → Eff:0.6?] ⚠️ |
| Task 24 | ⬜ | 🎁 **superseded** · Parity.Compare for richer diffs [D:3/B:3/U:2 → Eff:0.83?] ⚠️ |
| Task 36 | ⛔ | 🎁 **superseded** · Schema migration framework [D:6/B:4/U:3 → Eff:0.58?] ⚠️ |
| Task rate-limit-headers | 🔶 | 🎁 **superseded** · Rate-limit header extraction [D:7/B:3/U:3 → Eff:0.43?] ⚠️ ⛔ Confirmed not observable from static analysis or describe() — headers are response behavior scattered across handler code. Consumer-side heuristics stay (ccxt_client Task 50). Revisit only if a simpler observation method surfaces. |
| Task 142 | ✅ | 🎁 **maintenance** · 🚀 **v4** · v4 cut — flip default emission and validation to v4 [D:4/B:9/U:9 → Eff:2.25] 🎯 |
| Task 143 | ✅ | 🎁 **maintenance** · 🚀 **v4** · v3 teardown — delete v3 and all schema_target plumbing [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 144 | ✅ | 🎁 **scope-hygiene** · 🚀 **feature_complete** · TaskScope.parse_and_resolve! accepts task-specific switches [D:2/B:5/U:6 → Eff:2.75] 🎯 |
| Task 145 | ✅ | 🎁 **maintenance** · Paths read/write split — tighten read-only writer modules [D:3/B:3/U:3 → Eff:1.0] 📋 |
| Task 146 | ✅ | 🎁 **maintenance** · 🚀 **feature_complete** · 🐛 Audit-surfaced: ws_heartbeat scoped extraction drops extends-chain ancestors [D:4/B:5/U:4 → Eff:1.12] 📋 |
| Task 150 | ⬜ | 🎁 **10-exotic** · Resolve non-literal digest identifiers in pre_sign_transforms via local bindings [D:4/B:3/U:4 → Eff:0.88] ⚠️ |
| Task 151 | ⬜ | 🎁 **10-exotic** · AuthHeaders: support this.extend(ObjectExpression, _) header init shape [D:4/B:3/U:4 → Eff:0.88] ⚠️ |
<!-- TASKS:END -->

---

## Phase 8: Client harness + contract tests 🔶

> All reference consumers live in their own git repos as **siblings** of `ccxt_extract/` (e.g. `../ccxt_client/`, future `../<rust-crate>/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but moved back to siblings in Task 56b to stop ccxt_extract's `CLAUDE.md` from being auto-loaded into every client session. `ccxt_extract` stays a pure extractor and ships a contract-test suite that validates the JSON surface without importing client code — catches "Elixir didn't notice this breaks Rust" drift.
>

<!-- TASKS:BEGIN phase=8 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 57c | ⬜ | 🎁 **9-pipeline-follow-up** · unified_endpoints/has drift triage — Pattern C honest fix [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 148 | ⬜ | 🎁 **9-pipeline-follow-up** · authenticated_sections reachability — walk class inheritance + intersect [D:3/B:4/U:4 → Eff:1.33] 📋 |
| Task 149 | ⬜ | 🎁 **9-pipeline-follow-up** · Load overrides once in contract_test run_all/1, thread through observed [D:2/B:2/U:2 → Eff:1.0] 📋 |
| Task 152 | ✅ | 🎁 **9-pipeline-follow-up** · Regenerate corpus full-universe (derivation unscoped) after all-exchange scope flip [D:1/B:5/U:5 → Eff:5.0] 🎯 |
<!-- TASKS:END -->

Completed tasks (56, 56b, 57, 57b, 57d, 58, 59) — see [CHANGELOG.md](CHANGELOG.md).

---

## Phase 9: Override infrastructure + provenance ⬜

> The three-tier output model requires override storage, merge logic, provenance tagging, and drift auditing. Lands before signing/parsing phases so every new derived field ships with an override fallback from day one.
>
> **This phase also enables the Three-Strikes Derivation Rule** (see CLAUDE.md) — without somewhere to migrate knowledge to, the rule has no exit. Every Phase 10–16 derivation ships knowing it can hand off to an override on patch #3 instead of accreting special cases.
>

<!-- TASKS:BEGIN phase=9 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 62 | ✅ | 🎁 **9-audit** · 🚀 **feature_complete** · mix ccxt_extract.validate_overrides [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 63 | ✅ | 🎁 **9-audit** · 🚀 **feature_complete** · mix ccxt_extract.drift_audit [D:5/B:7/U:6 → Eff:1.3?] 📋 |
| Task 104 | ✅ | 🎁 **9-pipeline** · 🚀 **feature_complete** · Array-index JSON Pointers in OverrideRegistry [D:2/B:3/U:2 → Eff:1.25?] 📋 |
| Task 147 | ✅ | 🎁 **9-audit** · 🚀 **feature_complete** · Map drift_audit stale overrides to precise raw dependencies [D:4/B:5/U:4 → Eff:1.12] 📋 |
<!-- TASKS:END -->

---

## Phase 11: Request building contract ⬜

> Everything a consumer needs to turn a unified call into an HTTP request, excluding signing (Phase 10).
>

<!-- TASKS:BEGIN phase=11 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 73f | ✅ | 🎁 **11-shape** · 🚀 **feature_complete** · Extend transaction_classification to non-unified raw broadcast endpoints [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 73e | ⬜ | 🎁 **11+14** · OXC-side extractor for sign-method-constructed User-Agent and runtime header mutations [D:5/B:3/U:3 → Eff:0.6?] ⚠️ |
<!-- TASKS:END -->

> **Three-Strikes escalation for Task 73c:** If the request-object derivation is patched three times to handle new shapes (conditional keys, spread elaboration, reassignment tracking, etc.), the Three-Strikes Rule requires a replacement tier — surfacing a bounded mechanics-AST subtree per CLAUDE.md's mechanics carve-out rather than continuing to stretch the derivation. No task created yet; this is a placeholder for when/if the patch counter reaches 3/3.

---

## Phase 12: Response parsing contract 🔶 (v4 schema-freeze gate ✅ cleared 2026-05-14)

> **Freeze-gate cleared 2026-05-14.** Every normalization-bundle task on the v4 freeze list ships: Task 129 carrier (PR #10/#15), Tasks 74–82 field maps (Phase 12 wave), Task 83a fetcher extractor, Task 83b envelopes. v4 emission is fully populated for the normalization section. The four remaining `⬜` rows below (Tasks 78c, 78d, 78f, 135) are **non-gating edge cases** — parseOHLCV hybrid shapes, scrambled-coercion outliers, multi-market discriminator vocab, and ticker.ex vocab alignment — and may ship post-v4-cut.
>
> **Priority note (updated 2026-05-08):** Phase 12 is **promoted** from the prior "deprioritized — unified-only" stance. While only unified-method consumers read normalized response shapes directly, downstream libraries that depend on `ccxt_client` need the normalization surface populated for the v4 schema cut to be useful. Phase 12 ships **in parallel with** the endpoint-invocation critical path (Phases 11/13/14), not after.
>
> **NEW prerequisite: Task 129** (`normalization` block carrier) — scaffolds the v4 `normalization` section with `parse_methods_digest` (compact, **NO AST body** — full bodies blow the 128 MB Hex publish cap that Tasks 116/117 cleared) and stub `field_maps` keyed by parser type. Phase 12 Tasks 74–83 populate the field maps on top of this scaffold. Task 129 lands first.
>
> For every CCXT `parse*` method, emit a field map that a consumer can apply without walking AST. Each task covers one `parse*` type end-to-end: field name mapping (exchange-native key → unified key), type coercion (safeString/safeNumber/safeTimestamp) per field, enum tables (status/side/type), timestamp format, nested-path traversal.
>

<!-- TASKS:BEGIN phase=12 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 121 | ✅ | 🎁 **method-descriptors** · 🚀 **feature_complete** · Extract unified-method descriptors from CCXT TS — TS signature + JSDoc overlay [D:6/B:7/U:8 → Eff:1.25?] 📋 |
| Task 122 | ✅ | 🎁 **method-descriptors** · 🚀 **feature_complete** · Schema block + unified_method_descriptors_shape_valid contract-test invariant [D:3/B:4/U:5 → Eff:1.5?] 🚀 |
| Task 78c `[P]` | ✅ | 🎁 **parse-ohlcv** · 🚀 **feature_complete** · parseOHLCV hybrid Array.isArray branch (binance options-fallback) [D:5/B:4/U:4 → Eff:0.8?] ⚠️ |
| Task 78d `[P]` | ⛔ | 🎁 **parse-ohlcv** · parseOHLCV scrambled-coercion + heuristic exchanges (coinbaseexchange, kraken, kucoin) [D:5/B:4/U:4 → Eff:0.8?] ⚠️ |
| Task 78f `[P]` | ✅ | 🎁 **parse-ohlcv** · 🚀 **feature_complete** · parseOHLCV discriminator vocabulary beyond market.inverse [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 135 | ✅ | 🎁 **ticker-normalization** · 🚀 **feature_complete** · ticker.ex normalization-vocab alignment [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 153 | ⬜ | 🎁 **12-normalization** · Accept (or normalize) the "no_fetcher_dispatch" _unresolved_reason sentinel [D:2/B:3/U:3 → Eff:1.5] 🚀 |
<!-- TASKS:END -->

Type-coercion tables fold into each per-type task (not standalone) — one task covers its type's field map + coercion + enums together so it fits in a session.

---

## Phase 13: Error contract ⬜

> **Supersedes Task 34.** Complete the error story: status-code maps, retry classification, class hierarchy export, and handler routing tables that consumers need to drive dispatch without AST.
>

<!-- TASKS:BEGIN phase=13 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 132 | ✅ | 🎁 **13-classify-fix** · 🚀 **feature_complete** · Split predicate_kind http_status_in into eq vs range [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 133 | ✅ | 🎁 **13-classify-safety** · 🚀 **feature_complete** · Explicit error_class_hierarchy content-equality invariant in contract_test [D:2/B:4/U:3 → Eff:1.75?] 🚀 |
| Task 134 | ✅ | 🎁 **13-perf** · 🚀 **feature_complete** · Thread precomputed error_dispatch through http_status_map/1 and retryable_buckets/1 [D:3/B:3/U:2 → Eff:0.83?] ⚠️ |
| Task 154 | ⬜ | 🎁 **13-error-hierarchy** · Handle string-valued exceptions.exact entries (apex) in error_classes_covered_by_hierarchy [D:2/B:2/U:2 → Eff:1.0] 📋 |
<!-- TASKS:END -->

---

## Phase 15: WS contract ⬜

> Streaming equivalent of phases 10–13. Per-channel specs for subscription, auth, heartbeat, snapshot/delta semantics, and reconnect.
>

<!-- TASKS:BEGIN phase=15 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 91 `[P]` | ✅ | 🎁 **15-msg** · 🚀 **feature_complete** · WS subscribe / unsubscribe message shape per channel [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 92 `[P]` | ✅ | 🎁 **15-msg** · 🚀 **feature_complete** · WS auth flow (sign-in msg / header / query param) [D:4/B:7/U:8 → Eff:1.88?] 🚀 |
| Task 93 `[P]` | ✅ | 🎁 **15-msg** · 🚀 **feature_complete** · Heartbeat / ping-pong pattern per exchange [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 94 `[P]` | ✅ | 🎁 **15-dispatch** · 🚀 **feature_complete** · Channel → parse handler dispatch tables [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 95a `[P]` | ✅ | 🎁 **15-semantics** · 🚀 **feature_complete** · Snapshot/delta semantics — orderbook [D:5/B:8/U:8 → Eff:1.6?] 🚀 |
| Task 95b `[P]` | ✅ | 🎁 **15-semantics** · 🚀 **feature_complete** · Snapshot/delta semantics — trades [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 95c `[P]` | ✅ | 🎁 **15-semantics** · 🚀 **feature_complete** · Snapshot/delta semantics — OHLCV [D:4/B:7/U:7 → Eff:1.75?] 🚀 |
| Task 96 | ⬜ | 🎁 **15-reconnect** · Reconnect triggers + backoff policy hints [D:3/B:6/U:6 → Eff:2.0?] 🎯 |
<!-- TASKS:END -->

---

## Phase 16: Market & currency semantics ⬜

> Remaining declarative metadata a consumer needs beyond `runtime.markets` and `runtime.describe`.
>

<!-- TASKS:BEGIN phase=16 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 97 | ✅ | 🎁 **16-currency** · 🚀 **feature_complete** · Currency aliases (commonCurrencies) + network info [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 98 | ✅ | 🎁 **16-currency** · 🚀 **feature_complete** · Precision mode + tick/step derivation semantics [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 99 | ⬜ | 🎁 **16-fees** · Tiered fee schedules + VIP level mapping [D:4/B:4/U:3 → Eff:0.88?] ⚠️ |
| Task 99b | ⬜ | 🎁 **16-fees** · Funding / withdrawal / deposit fee catalog [D:4/B:4/U:3 → Eff:0.88?] ⚠️ |
<!-- TASKS:END -->

---

## Superseded / Deferred

> ⛔ truly-superseded items only. The 🔶-deferred tasks (66c, 66d, 99, 99b, 24, rate-limit header extraction) now live in [`roadmap/tasks.toml`](roadmap/tasks.toml) as `status = "blocked"` with a `blocked_reason`, rendered in their phase tables above — run `rmap list --status blocked` to see them. Task 36 was promoted to `status = "superseded"` (PR #30) and now renders ⛔ in its phase table above.

| Task | Status | Reason |
|------|--------|--------|
| Task 33 | ⛔ Superseded | Original rationale ("consumers should classify from AST") is explicitly retired by the new consumer contract. Replaced by **Phase 10** (Tasks 64–69). |
| Task 34 | ⛔ Superseded | Same — "derivable from existing AST" is no longer a valid deferral under the consumer contract. Replaced by **Phase 13** (Task 88a/b/c handler routing). |
| ~~Task 113~~ (LFS) | ⛔ Superseded | Resolved 2026-04-18 by the chore untracking `priv/output/` and `priv/discoveries/*` (except `class_hierarchy.json`). LFS is moot once the paths aren't in the index. The residual follow-up was Task 114 (extraction determinism), shipped 2026-05-14. |

---

## Completed Phases

- **Phase 1: Setup & Discovery ✅** — CCXT source setup, exchange inventory, describe() keys, method inventory, integration tests. See CHANGELOG.md.
- **Phase 2: Runtime Extraction (QuickBEAM) ✅** — Full describe(), family analysis, loadMarkets(). See CHANGELOG.md.
- **Phase 3: Structural Extraction (OXC AST) ✅** — sign(), handleErrors(), parse*(), WS methods, overrides. See CHANGELOG.md.
- **Phase 4: Output Format & Validation ✅** — JSON Schema, pipeline, coverage, validation. See CHANGELOG.md.
- **Phase 5: Distribution ✅** — `--output`, version pinning, schema contract, update workflow. See CHANGELOG.md.
- **Phase 6: Go Extractor Parity ✅ (partial)** — Tasks 30, 31, 32 complete. Tasks 33, 34 superseded above.
- **Phase 10: Request signing contract ✅** — Declarative signing recipe per exchange per API section (Tasks 64–69). okx.private is the first recipe with `unresolved_reason: null` end-to-end. Corner-case AST follow-ups live in the `10-sign-extend` bundle (Phase 0). See CHANGELOG.md.
- **Phase 14: Rate-limit contract ✅** — Bucket config + per-endpoint cost weights (Tasks 89, 90). See CHANGELOG.md.

---

## Consumer Architecture

> Reference for future instances. Not tasks.

**The pipeline:**
```
ccxt_extract                              Consumer projects (each its own git repo, sibling dirs)
─────────────                             ─────────────────
mix ccxt_extract.pipeline                     ../ccxt_client/              Elixir — compile-time macros read JSON
  --output ../ccxt_client/priv/specs  →      ../<rust-crate>/             Rust — build.rs / serde_json
                                              ../<python-pkg>/             Python — json.load at import
```

**Sibling-repo clients.** Each language client is an independent git repo living as a sibling of `ccxt_extract/` (e.g. `../ccxt_client/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but relocated back to siblings (Task 56b) because nested `CLAUDE.md` discovery pulled ccxt_extract's full context into every client session.

**Three-tier JSON is the target contract.** Once Phase 9 fully ships, output will merge raw extraction + derived analysis + curated overrides with per-field provenance. **Current state (2026-04-17):** Tasks 60, 61a, 61b shipped — overrides apply end-to-end via `OverrideRegistry.apply_all/2` and each path carries a `_provenance` tier tag (`"raw"` / `"derived"` / `"override"`) at `schema_version: 1.8.1`. Only the Schema 2.0.0 bump (Task 61c) remains, which promotes `_provenance` from additive-nullable to required. Either way, consumers read the emitted JSON; they do not re-derive or walk AST. Contract tests (`mix ccxt_extract.contract_test`, Task 57) enforce cross-field invariants so drift surfaces before it reaches a consumer.

**Versioning follows semver** on the `schema_version` field. See [SCHEMA.md](SCHEMA.md).

---

## Notes

- **This file is generated.** `ROADMAP.md` is rendered from [`roadmap/tasks.toml`](roadmap/tasks.toml) by `rmap render` (the [rmap](../rmap/) CLI). Edit task status / scores / bundles in `tasks.toml`, then run `rmap render` — never hand-edit the `<!-- TASKS:* -->` / `<!-- FOCUS:* -->` marker blocks. Prose outside the markers is byte-preserved across renders, so the narrative sections here are safe to hand-edit. `roadmap/data.json` is the agent-facing view, regenerated by the same command.
- Task descriptions are prompts for Claude to implement — explore the codebase and discover the right approach. See `CLAUDE.md` for session-size, honesty-rule, and three-tier contract guidance.
- Previous "Anti-Bias Rule" and "Extraction vs Interpretation" framings are retired. The replacement rule: every value is provable or explicitly unprovable; interpretation happens in derivation + overrides, not in consumers.
- `[CSR]` and `[Codex]` markers — RETIRED. Historical occurrences on completed (✅) tasks indicate the PR was cloud-delegated when it shipped (`[CSR]` = Cursor Background Agent, `[Codex]` = Codex Cloud). New tasks should not carry these markers; cloud-agent delegation is no longer used in this project. See `CLAUDE.md` § "Worktree workflow" for the local-Claude-Code workflow that replaces it.
- `[P]` marker — task can run in parallel with its siblings in the same phase. In `roadmap/tasks.toml` this is `markers = ["parallel"]`; the rendered table shows it as a `[P]` tag.
- Raw AST remains in the output. Consumers may inspect it for debugging or novel needs, but a consumer that *requires* walking AST to operate exposes a gap the roadmap should close.
- **Source of truth is CCXT, not exchange docs.** See [CLAUDE.md §"Source of truth: CCXT, not exchange docs"](CLAUDE.md#source-of-truth-ccxt-not-exchange-docs). Exchange vendor docs enter only as override `verified_against`, Tier 1 gap enrichment (tracked as a task), or a future third-source verification layer — never as a primary extraction target. Proposals to replace CCXT extraction with doc-reading are a 110× work multiplier without reliability gains.
