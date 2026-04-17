# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON so any consumer — in any language — can operate an exchange without walking AST.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Contract reference:** See [CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md) for the unfiltered list of what a consumer needs. Phases 10–16 tick items off that checklist.

**Schema contract:** See [SCHEMA.md](SCHEMA.md) for field-level definitions and version history of the emitted JSON.

> **🔗 Cross-repo rule (applies to EVERY task in this roadmap):** When a task ships, lands, or changes status, the implementer MUST also update `../ccxt_client/ROADMAP.md` — mark any dependent ccxt_client task as unblocked, flip its status, or add a new follow-up entry. A ccxt_extract task is **not complete** until its downstream ccxt_client impact is reflected there. The two roadmaps are a single contract surface viewed from two sides.

---

## 🎯 Current Focus

**Priority goal: endpoint-invocation contract (serves unified + non-unified).** The critical path is **signing → request building → rate limits**. These phases unlock both raw (implicit) and unified endpoints — anything you'd call needs them. Only Phase 12 (response parsing) is unified-specific (i.e., CCXT's normalized method surface like `fetchTicker`/`createOrder`, as opposed to raw implicit endpoints) and thus deprioritized. See [Endpoint-Invocation Priority Order](#endpoint-invocation-priority-order) below.

**Phase 8 — Client harness + contract tests** complete; Task 57c is the only holdover and is blocked on Phase 9 provenance (🎁 **9-pipeline**). The target output is a three-tier merge (raw / derived / override). The **generic JSON-Pointer override contract shipped with Task 60** (see CHANGELOG) — override files use RFC 6901 paths, a `value` payload, required `reason`, and `verified_against`/`unverified` flags, validated by `CcxtExtract.OverrideRegistry` and the `override_registry_valid` contract-test invariant. The **generic merge stage shipped with Task 61b** (2026-04-16) — all 14 override files now flow end-to-end via `OverrideRegistry.apply_all/2`. Still pending: per-field provenance tagging (Task 61a), then Schema 2.0.0 (61c). Today's output is `schema_version: 1.8.0`, overrides-applied, **no `_provenance` map yet** — running an extract won't produce one; 61a is code work.

**Scope.** This roadmap prioritizes Tier 1, Tier 2, and DEX exchanges (canonical list in `priv/priority_tiers.json`; stamped as `exchange.tier` in each output JSON since schema 1.8.0). Tier 3 and unclassified exchanges are supported — we still extract everything — but tasks that exist only to handle their quirks (exotic signing, custom error handlers, outlier fee schedules) live in Superseded / Deferred until a priority exchange surfaces the need. See `CLAUDE.md` §"Tier-Based Scoping". Scope-refactor tasks (every Mix task now accepts `--tier*/--all/--exchange ID`, `_manifest.json` stamps `tier_scope`, both `mix ccxt_extract.update` and `mix ccxt_extract.pipeline` share a `--force`-gated git-status safety rail) tracked in [SCOPED-EXTRACTION-TASKS.md](SCOPED-EXTRACTION-TASKS.md) — Tasks 1–11 complete. **Task 13** (universal envelope `tier_scope` stamping across all aggregate files, not just `_manifest.json`) remains open — see Maintenance Backlog.

> **Philosophy reminder:** Every value is either provable (emit it) or explicitly unprovable (`null` + reason). No silent guesses. Overrides (once Phase 9 ships) will fill gaps derivation can't reach and carry reasons too.

### Endpoint-Invocation Priority Order

Phases reordered by criticality for consumers calling *any* endpoint (unified or implicit). Phases 10/11/14 serve both — a unified call ultimately reaches the same HTTP surface as a raw call.

| Rank | Phase | Serves | Why it matters | Notes |
|------|-------|--------|----------------|-------|
| 1 | **Phase 10** (Signing) | Unified + non-unified | Without signing recipes, **no private endpoint** (unified or raw) is callable without AST walking | Biggest unlock |
| 2 | **Phase 11** (Request building) | Unified + non-unified | Turns `(section, path)` into an HTTP request — verb, body encoding, timestamp, headers | Pairs with Phase 10 |
| 3 | **Phase 14** (Rate limits) | Unified + non-unified | Per-endpoint cost weights — derives from same `rateLimit`/`cost` annotations as Phase 11 | Pair with Phase 11 |
| 4 | **Phase 9** (Override infrastructure) | Scaffolding | Three-Strikes Rule needs somewhere to migrate to when AST can't prove a signing/request shape. **Consider Task 60 as narrow precursor before Phase 10.** | Prerequisite |
| 5 | **Phase 13** (Errors) | Unified + non-unified | `error_code_fields` (Task 49) + `throw_dispatches` (Task 55) already shipped — remainder is enhancement | Already partial |
| 6 | **Phase 16** (Market & currency semantics) | Unified + non-unified | Useful metadata but orthogonal to endpoint invocation | Can defer |
| 7 | **Phase 15** (WS contract) | Streaming | Separate transport — not on the REST critical path | Can defer |
| 8 | **Phase 12** (Response parsing) | **Unified only** | Non-unified callers parse their own responses. The one phase truly unified-specific. | Deprioritized |

### Bundle Index

Tasks grouped into session-sized bundles that share AST passes, schema design, or doc surface. Bundle IDs appear as 🎁 tags in phase tables below — **phase tables remain the canonical per-task status**. `[P]` = parallel-safe with sibling bundles.

**Endpoint-invocation critical path (in order):**

| # | Bundle | Tasks | Rationale |
|---|--------|-------|-----------|
| 1 | 🎁 **A** (close Phase 8) | 58 remainder | `regenerate_fixtures` alias + `validate_fixtures` parity check — closes Phase 8. Task 57c moved to after 🎁 **9-pipeline**; honest fix requires provenance tier (Task 61a) |
| 2 | 🎁 **9-contract** | 60, 61c | JSON-Pointer override contract + schema 2.0.0 bump — both doc-heavy, ship together |
| 3 | 🎁 **10-core** | 64, 65 | Signing recipe schema + crypto op / signature placement — shared `sign()` AST walker |
| 4 | 🎁 **10-HMAC** `[P]` | 66a, 66b | HMAC-simple + HMAC-with-body — same canonical-string derivation |
| 5 | 🎁 **9-pipeline** | 61a, 61b | Provenance tags + override merge stage — both pipeline plumbing. **Unblocks Task 57c** (unified_endpoints/has drift triage) |
| 6 | 🎁 **11-shape** | 70, 71 | Verb + path template + body encoding — single section-level AST pass |
| 7 | 🎁 **10-finish** | 67, 68, 69 | Headers/nonce + transforms + round-trip validation |
| 8 | 🎁 **11+14** | 72, 73, 73b, 89, 90 | Timestamps, headers, rate-limit buckets + per-endpoint cost — all from `rateLimit`/`cost` annotations |
| 9 | 🎁 **10-exotic** | 66c, 66d | JWT/RSA/Ed25519 + custom/outlier signing families — **deferred to Superseded/Deferred** (no priority exchange uses these) |
| 10 | 🎁 **9-audit** | 62, 63 | validate_overrides + drift_audit — both auditing tooling |
| 11 | 🎁 **13-classify** | 85, 86, 87 | HTTP status map + retry classification + class hierarchy export |
| 12 | 🎁 **13-dispatch** `[P]` | 88a, 88b, 88c | Handler routing tables (error/signing/parse) |

**Deferred bundles (Phase 12 unified-only, Phase 15 WS, Phase 16 metadata):**

| Bundle | Tasks | Rationale |
|--------|-------|-----------|
| 🎁 **12-simple** `[P]` | 74, 76, 78 | parseTicker/Trade/OHLCV — simpler field maps |
| 🎁 **12-orders** `[P]` | 75, 80 | parseOrder + parsePosition — shared enum tables |
| 🎁 **12-accounts** `[P]` | 77, 79 | parseBalance + parseMarket |
| 🎁 **12-txn** `[P]` | 81, 82 | parseTransaction + parseDepositAddress |
| 🎁 **12-envelope** | 83 | Response envelope paths per method group |
| 🎁 **15-msg** | 91, 92, 93 | WS subscribe + auth + heartbeat |
| 🎁 **15-dispatch** | 94 | Channel → parse handler |
| 🎁 **15-semantics** `[P]` | 95a, 95b, 95c | Snapshot/delta for orderbook/trades/OHLCV |
| 🎁 **15-reconnect** | 96 | Reconnect triggers + backoff |
| 🎁 **16-currency** | 97, 98 | commonCurrencies + precision mode |
| 🎁 **16-fees** | 99, 99b | Tiered + funding/withdrawal fees — **deferred to Superseded/Deferred** (not required by priority consumers) |
| 🎁 **16-testnet** | 100 | Sandbox URL catalog |

### ✅ Recently Completed

Tasks 60, 58, 57d, 56b, 57b, 59, 57, 56, 55, 54, 53, 52, 49, 47, 46 — see [CHANGELOG.md](CHANGELOG.md).

### 📋 Next Up
| Task | Status | Notes |
|------|--------|-------|
| Task 61a | ⬜ | Provenance tagging (`raw`/`derived`/`override`) — now unblocked. With the v1 override contract live (Task 60), 61a can mark fields per-path without guessing at payload shape. |
| Task 61b | ✅ | Shipped 2026-04-16 — generic RFC 6901 merge via `OverrideRegistry.apply_all/2`; 14/14 override files now flow end-to-end. 61a dependency was aspirational; 61b is useful standalone and provenance tagging will tag override writes when 61a lands. See [CHANGELOG.md](CHANGELOG.md). |
| Task 57c | 🔶 | Pattern A/B fixed (341 → 53); Pattern C residual blocked on 61a — honest fix needs provenance tier (see Task 57c entry in Phase 8) |
| Task 61c | ⬜ | Schema 2.0.0 bump — folds provenance into exchange JSON. Depends on 61a (61b ✅ shipped). |
| Task 37 | ⬜ | Fix Credo compatibility on Elixir 1.18+ `[Codex]` |

### Quick Commands
```bash
mix ccxt_extract.update          # Full re-extract
mix ccxt_extract.pipeline        # Assemble per-exchange JSON
mix ccxt_extract.validate        # JSON Schema + round-trip
mix test.json --quiet            # Fast tests (cached)
mix test.json --quiet --include extraction  # Full tests
```

Full command list in [CLAUDE.md](CLAUDE.md).

---

## Maintenance Backlog

> Open technical-debt items outside the phased work. Completed Phase 7 tasks (Tasks 35, 38, 39, 42–47) moved to CHANGELOG.md.

| Task | Status | Notes |
|------|--------|-------|
| Task 37 | ⬜ | Fix Credo compatibility on Elixir 1.18+ [D:2/B:4/U:3 → Eff:1.50] `[Codex]` |
| Task 101 | 🔶 | Fixture refresh for oxc 0.7 / quickbeam 0.10 [D:1/B:4/U:4 → Eff:4.0] 🎯 — source migration shipped (`mix.exs` at `{:oxc, "~> 0.7"}, {:quickbeam, "~> 0.10"}`; 12-file AST atom-keys migration done; coincatch orphan cleared). What remains: run `mix ccxt_extract.update` to regenerate discoveries so `parse_methods` coverage threshold recalibrates against fresh fixtures, then `mix ccxt_extract.contract_test --strict`. See [CHANGELOG.md](CHANGELOG.md#task-101) and `SCOPED-EXTRACTION-TASKS.md` "Known drift". |
| Task 13a | ✅ | Universal envelope `tier_scope` stamping — code-plumbing half [D:1/B:4/U:5 → Eff:4.5] 🎯 — shipped: `_base_methods.json` stamps `"all"` (universe-agnostic); `_validation_report.json` derives scope from `_manifest.json`; `_contract_test_report.json` threads scope from the TaskScope-parsed flags. See [CHANGELOG.md](CHANGELOG.md#task-13a). |
| Task 13b | ⬜ | Universal envelope `tier_scope` stamping — test-migration half [D:2/B:3/U:3 → Eff:1.5] 🚀 — depends on 13a. Migrate 9 cached integration tests from observed-count dispatch to envelope dispatch and shrink `test/support/scope_thresholds.ex` to just `proportional/2` (or delete). Three tracked `TODO(scope-envelope):` markers: `test/support/scope_thresholds.ex:22`, `test/integration/method_analysis_integration_test.exs:52`, `test/integration/public_exchanges_integration_test.exs:46`. |
| Task 102 | ⬜ | Fix `ccxt_client` read-path drift from REFACTOR Item 9 [D:1/B:7/U:8 → Eff:7.5] 🎯 — REFACTOR Item 9 split write sites (`--output DIR` now writes to `DIR/output/<id>.json`). `ccxt_client/lib/ccxt/spec.ex:26` still reads `@spec_dir "priv/specs/json"` (flat). Any `mix ccxt_extract.update --output ../ccxt_client/priv/specs/json` now writes where the client won't read, including the full-sweep recovery command in `ccxt_client/ROADMAP.md:100`. Code fix belongs in ccxt_client (update `@spec_dir` or append `/output`); this entry tracks our cross-repo obligation per the roadmap banner rule at line 11. |

**Task 101: Fixture refresh for oxc 0.7 / quickbeam 0.10.** The source migration (AST `:type`/`:kind` string→atom across 12 extractors, error-tuple shape changes, `mix.exs` version bumps) has shipped. What remains is cached: the `parse_methods` coverage threshold is calibrated against fixtures generated before the migration. Run `mix ccxt_extract.update` to regenerate discoveries + outputs, then `mix ccxt_extract.contract_test --strict` to confirm byte-identical output across priority tiers. quickbeam 0.10's JS line coverage (`mix test --cover`) and `Beam.XML.parse` are available but not required.

---

## Phase 8: Client harness + contract tests 🔶

> All reference consumers live in their own git repos as **siblings** of `ccxt_extract/` (e.g. `../ccxt_client/`, future `../<rust-crate>/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but moved back to siblings in Task 56b to stop ccxt_extract's `CLAUDE.md` from being auto-loaded into every client session. `ccxt_extract` stays a pure extractor and ships a contract-test suite that validates the JSON surface without importing client code — catches "Elixir didn't notice this breaks Rust" drift.
>
> **🔗 Every task in this phase requires updating `../ccxt_client/ROADMAP.md` on completion.**

| Task | Status | Notes |
|------|--------|-------|
| Task 57c | 🔶 | 🎁 **9-pipeline-follow-up** · Pattern A/B fixed (341 → 53). Residual 53 Pattern C findings cluster on Tier 3 / unclassified exchanges — defer until provenance lands (61a) AND a Tier 1/2/DEX exchange surfaces a Pattern C failure [D:3/B:5/U:5 → Eff:1.67] 🚀 |

Completed (Tasks 56, 56b, 57, 57b, 57d, 58, 59) — see [CHANGELOG.md](CHANGELOG.md).

**Task 57c: Resolve residual Pattern C `unified_endpoints`/`has` drift (53 findings)** — The Pattern A (child `has: false` inherited via merge) and Pattern B (internal routing helpers picked up by prefix-match) buckets are fixed in the pipeline; 288 findings resolved. The residual 53 are Pattern C: CCXT's base `Exchange.ts` declares `has[method] = undefined` and the child implements the method but never flips the flag to `true`. Resolving these honestly requires emitting `{value: true, source: "derived"}` in the unified `has` view while preserving the raw `"__undefined"` — which is exactly what Task 61a's provenance tier provides.

> **Still blocked on Task 61a (provenance).** Without a provenance tier there are only two dishonest moves for Pattern C: (a) a silent pipeline filter that hides the disagreement contract_test is designed to surface, or (b) a premature override migration with no JSON-Pointer contract to land in. 61a gives the honest third option: tag AST-derived vs has-confirmed entries so the fix records the split instead of erasing it. See [CHANGELOG.md](CHANGELOG.md) for the Pattern A/B fix details.

---

## Phase 9: Override infrastructure + provenance ⬜

> The three-tier output model requires override storage, merge logic, provenance tagging, and drift auditing. Lands before signing/parsing phases so every new derived field ships with an override fallback from day one.
>
> **This phase also enables the Three-Strikes Derivation Rule** (see CLAUDE.md) — without somewhere to migrate knowledge to, the rule has no exit. Every Phase 10–16 derivation ships knowing it can hand off to an override on patch #3 instead of accreting special cases.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — notably ccxt_client Tasks 53 (schema 2.0.0 adapter) and 63 (override contribution workflow).

| Task | Status | Notes |
|------|--------|-------|
| Task 60 | ✅ | 🎁 **9-contract** · Generic JSON-Pointer override contract + SCHEMA.md docs [D:3/B:7/U:8 → Eff:2.5] 🎯 — shipped: RFC 6901 `path`, `value` payload, `reason`, `verified_against`/`unverified` exclusivity, `OverrideRegistry` loader, `priv/schema/override_v1.json`, `override_registry_valid` contract-test invariant, 14 existing files migrated. See [CHANGELOG.md](CHANGELOG.md). |
| Task 61a `[P]` | ⬜ | 🎁 **9-pipeline** · Provenance tagging on raw + derived fields [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 61b | ✅ | 🎁 **9-pipeline** · Override merge pipeline stage [D:4/B:9/U:9 → Eff:2.25] 🎯 SHIPPED 2026-04-16 — see [CHANGELOG.md](CHANGELOG.md). |
| Task 61c | ⬜ | 🎁 **9-contract** · Schema 2.0.0 bump + migration notes in SCHEMA.md [D:2/B:6/U:6 → Eff:3.0] 🎯 |
| Task 62 | ⬜ | 🎁 **9-audit** · `mix ccxt_extract.validate_overrides` [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 63 | ⬜ | 🎁 **9-audit** · `mix ccxt_extract.drift_audit` [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 104 | ⬜ | 🎁 **9-pipeline** · Array-index JSON Pointers in `OverrideRegistry` [D:2/B:3/U:2 → Eff:1.5] 📋 — extend `pointer_to_keys/1` to emit `Access.at/1` for numeric segments. Currently raises loudly (see error message). Unblock when a real override file needs `/path/0/...`. |

**Task 60: Override directory contract** — Define `priv/overrides/<exchange>.json` format: JSON Pointer paths into the canonical output, a `value` payload, required `reason`, optional `verified_against` (runtime probe output or CCXT source reference) and `unverified: true` flag. Document in SCHEMA.md. Ship an example override for one exchange.

**Task 61a: Provenance tagging on raw + derived** — Every field in the emitted JSON gains a parallel `_provenance` map keyed by the same paths, with values `"raw"` / `"derived"` / `"override"`. Task 61b already shipped without provenance (the dependency was aspirational, not structural); when 61a lands it must tag override-applied paths at the tail of `Pipeline.extract/1` where `OverrideRegistry.apply_all/2` runs. Alternative shape (inline per-field `{value, source}` tuples) is rejected as noisy — keep the main payload clean, store provenance alongside.

**Task 61b: Override merge pipeline stage (✅ shipped 2026-04-16)** — Applies `priv/overrides/<exchange>.json` on top of raw+derived output as the final stage of `Pipeline.extract/1` via `OverrideRegistry.apply_all/2`. Invalid override applications are rescued and logged at the callsite so one corrupt file can't brick the full build; the `override_paths_present_in_output` contract-test invariant surfaces drift (override value absent at its pointer path) loudly — keeping loud-fail at build-check time, not per-exchange assembly time. Shipped scope: shallow string-key pointers only; numeric segments (array indices) raise until a real override needs deep indexing (Task 104). When Task 61a lands, override-applied paths will be tagged `"override"` in the provenance map.

**Task 61c: Schema 2.0.0 bump** — Bump `schema_version` to 2.0.0 and rename the schema file `exchange_v1.json` → `exchange_v2.json`. Keep `exchange_v1.json` around for one release so consumers can diff; delete in the following release. Document the provenance contract (top-level `_provenance` map, required on every exchange) and the breaking changes in SCHEMA.md. Discovery (2026-04-16): the `override_paths_present_in_output` integration test in `test/ccxt_extract/contract_test_test.exs` currently exercises the 0-finding case only — add a drifted-override fixture when `run_all/1` is restructured to thread overrides through `observed`.

**Task 62: validate_overrides** — `mix ccxt_extract.validate_overrides` checks each override against runtime behavior where a probe exists (e.g., if override sets a URL, cross-check against runtime url_templates; if override sets a signing field, cross-check against live sign() probe). Emits a report per exchange: verified vs unverified-with-reason.

**Task 63: drift_audit** — `mix ccxt_extract.drift_audit` compares current derivation + overrides against the last-released output. Flags: (a) overrides whose underlying raw data changed (override may be stale), (b) derived fields that flipped value or disappeared, (c) new raw fields not yet derived. Output is an audit report, not a fail; humans decide.

**Task 104: Array-index JSON Pointers in OverrideRegistry** — Extend `OverrideRegistry.pointer_to_keys/1` to emit `Access.at/1` for numeric segments so override paths like `/structure/sign_method/params/0/name` resolve to deep list elements. Today the function raises loudly with a TODO marker — fine while every shipped override file uses shallow string-key pointers. Unblock when an override file needs to replace a specific element of a list. Low urgency; no evidence of need as of 2026-04-16.

---

## Phase 10: Request signing contract ⬜

> **Supersedes Task 33.** A consumer must be able to construct an authenticated request without walking `sign()` AST. This phase emits a declarative signing recipe per exchange per API section: crypto op, canonical-string instructions, signature placement, auth headers, nonce source, pre-sign transforms. Honesty rule: each field derived when provable, null+reason otherwise, overrides fill gaps.
>
> **Three-Strikes Rule applies.** Each Phase 10 derivation module declares its patch count in its header (e.g. `# Patch count: 0/3`). At patch #3, migrate to `priv/overrides/<exchange>.json` rather than stretching the derivation further. See CLAUDE.md for the full rule.

**Downstream signal:** `ccxt_client/lib/ccxt/signing/classifier.ex` (AST-walker) becomes redundant when this phase ships `signing.pattern` directly. Schema design should enable its deletion without Elixir-side contortions.

> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 54 (retire classifier) and 56 (spec-driven pattern modules) depend on this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 64 | ⬜ | 🎁 **10-core** · Signing recipe schema design [D:5/B:9/U:9 → Eff:1.8] 🚀 |
| Task 65 | ⬜ | 🎁 **10-core** · Crypto op + signature placement from `sign()` AST [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 66a `[P]` | ⬜ | 🎁 **10-HMAC** · Canonical string recipe — HMAC-simple family [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 66b `[P]` | ⬜ | 🎁 **10-HMAC** · Canonical string recipe — HMAC-with-body family [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 67 | ⬜ | 🎁 **10-finish** · Auth header set + nonce source derivation [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 68 | ⬜ | 🎁 **10-finish** · Pre-sign transforms (hex/base64/lowercase/url-encode) [D:4/B:6/U:7 → Eff:1.63] 🚀 |
| Task 69 | ⬜ | 🎁 **10-finish** · Signing round-trip validation + contract invariants [D:3/B:7/U:7 → Eff:2.33] 🚀 |

Per-task scope is a single declarative field (or family) across all exchanges. Each task seed may split further if the AST surface proves too large during implementation research.

---

## Phase 11: Request building contract ⬜

> Everything a consumer needs to turn a unified call into an HTTP request, excluding signing (Phase 10).
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 57 (adopt request-building contract) tracks this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 70 | ⬜ | 🎁 **11-shape** · HTTP verb + path template + path-param rules per method [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 71 | ⬜ | 🎁 **11-shape** · Body encoding + content-type per section [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 72 | ⬜ | 🎁 **11+14** · Timestamp source + format per section [D:3/B:6/U:7 → Eff:2.17] 🚀 |
| Task 73 | ⬜ | 🎁 **11+14** · Per-method rate-limit cost + weight axis [D:3/B:7/U:7 → Eff:2.33] 🚀 |
| Task 73b | ⬜ | 🎁 **11+14** · User-agent + default headers per exchange [D:2/B:5/U:5 → Eff:2.5] 🎯 |
| Task 73c | ⬜ | 🎁 **11-request** · Per-method default request body from literal object expressions flowing into HTTP calls. Extract `const request = {…}` (or inline object) whose value reaches `this.<httpCall>(…)`; emit `structure.request_defaults` as `method → {key → {value, kind, reason}}`. Literal primitives resolve to `kind: "literal"`; non-literal values emit `kind: "unresolved"` with a closed-vocabulary reason tag (Honesty Rule). Override-mergeable via `/structure/request_defaults[/<method>]`. Contract invariant: every resolvable entry must have a non-empty `unified_endpoints` entry. Schema bump 1.8.0 → 1.8.1 (additive, nullable). Blocks ccxt_client POST-body integration; current concrete failure: hyperliquid.fetch_time [D:4/B:7/U:9 → Eff:2.0] 🚀 |

> **Three-Strikes escalation for Task 73c:** If the request-object derivation is patched three times to handle new shapes (conditional keys, spread elaboration, reassignment tracking, etc.), the Three-Strikes Rule requires a replacement tier — surfacing a bounded mechanics-AST subtree per CLAUDE.md's mechanics carve-out rather than continuing to stretch the derivation. No task created yet; this is a placeholder for when/if the patch counter reaches 3/3.

---

## Phase 12: Response parsing contract ⬜ (deprioritized — unified-only)

> **Priority note:** This is the one phase that serves *only* unified-method consumers — non-unified callers parse their own responses. Deprioritized until Phases 10/11/14 complete the endpoint-invocation surface (which serves both unified and non-unified). Keep tasks as-is; pull from here only when signing + request-building is shipped.
>
> For every CCXT `parse*` method, emit a field map that a consumer can apply without walking AST. Each task covers one `parse*` type end-to-end: field name mapping (exchange-native key → unified key), type coercion (safeString/safeNumber/safeTimestamp) per field, enum tables (status/side/type), timestamp format, nested-path traversal.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 19/21/44/55 (parser + struct regeneration) depend on this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 74 `[P]` | ⬜ | 🎁 **12-simple** · `parseTicker` field map + coercion + enums [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 75 `[P]` | ⬜ | 🎁 **12-orders** · `parseOrder` field map + status/side/type enums [D:5/B:9/U:9 → Eff:1.8] 🚀 |
| Task 76 `[P]` | ⬜ | 🎁 **12-simple** · `parseTrade` field map [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 77 `[P]` | ⬜ | 🎁 **12-accounts** · `parseBalance` field map [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 78 `[P]` | ⬜ | 🎁 **12-simple** · `parseOHLCV` field map + timestamp format [D:3/B:7/U:7 → Eff:2.33] 🚀 |
| Task 79 `[P]` | ⬜ | 🎁 **12-accounts** · `parseMarket` field map [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 80 `[P]` | ⬜ | 🎁 **12-orders** · `parsePosition` field map [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 81 `[P]` | ⬜ | 🎁 **12-txn** · `parseTransaction` (deposit/withdrawal) field map [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 82 `[P]` | ⬜ | 🎁 **12-txn** · `parseDepositAddress` field map [D:3/B:6/U:6 → Eff:2.0] 🚀 |
| Task 83 | ⬜ | 🎁 **12-envelope** · Response envelope paths per method group [D:4/B:8/U:8 → Eff:2.0] 🚀 |

Type-coercion tables fold into each per-type task (not standalone) — one task covers its type's field map + coercion + enums together so it fits in a session.

---

## Phase 13: Error contract ⬜

> **Supersedes Task 34.** Complete the error story: status-code maps, retry classification, class hierarchy export, and handler routing tables that consumers need to drive dispatch without AST.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 58 (adopt error contract) tracks this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 85 | ⬜ | 🎁 **13-classify** · HTTP status → error class map per exchange [D:3/B:7/U:7 → Eff:2.33] 🚀 |
| Task 86 | ⬜ | 🎁 **13-classify** · Retryable classification (rate-limit/network/server-busy/auth) [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 87 | ⬜ | 🎁 **13-classify** · Error class hierarchy export [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 88a `[P]` | ⬜ | 🎁 **13-dispatch** · Handler routing — error dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 88b `[P]` | ⬜ | 🎁 **13-dispatch** · Handler routing — signing dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 88c `[P]` | ⬜ | 🎁 **13-dispatch** · Handler routing — parse dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |

---

## Phase 14: Rate-limit contract ⬜

> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 59 (multi-bucket rate limiter) depends on this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 89 | ⬜ | 🎁 **11+14** · Bucket config — axes (IP/UID/order-weight), refill, size [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 90 | ⬜ | 🎁 **11+14** · Per-endpoint cost weights against bucket axis [D:4/B:7/U:8 → Eff:1.88] 🚀 |

---

## Phase 15: WS contract ⬜

> Streaming equivalent of phases 10–13. Per-channel specs for subscription, auth, heartbeat, snapshot/delta semantics, and reconnect.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Phase 6 (Tasks 22–27) is gated on this phase landing.

| Task | Status | Notes |
|------|--------|-------|
| Task 91 | ⬜ | 🎁 **15-msg** · WS subscribe / unsubscribe message shape per channel [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 92 | ⬜ | 🎁 **15-msg** · WS auth flow (sign-in msg / header / query param) [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 93 | ⬜ | 🎁 **15-msg** · Heartbeat / ping-pong pattern per exchange [D:3/B:6/U:7 → Eff:2.17] 🚀 |
| Task 94 | ⬜ | 🎁 **15-dispatch** · Channel → parse handler dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 95a `[P]` | ⬜ | 🎁 **15-semantics** · Snapshot/delta semantics — orderbook [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 95b `[P]` | ⬜ | 🎁 **15-semantics** · Snapshot/delta semantics — trades [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 95c `[P]` | ⬜ | 🎁 **15-semantics** · Snapshot/delta semantics — OHLCV [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 96 | 🔶 | 🎁 **15-reconnect** · Deferred — priority exchanges already handle reconnect behavior in the consumer; no derived recipe needed until proven. Originally: Reconnect triggers + backoff policy hints [D:3/B:6/U:6 → Eff:2.0] |

---

## Phase 16: Market & currency semantics ⬜

> Remaining declarative metadata a consumer needs beyond `runtime.markets` and `runtime.describe`.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 60 (currency aliases) and 61 (testnet URL catalog) track this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 97 | ⬜ | 🎁 **16-currency** · Currency aliases (`commonCurrencies`) + network info [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 98 | ⬜ | 🎁 **16-currency** · Precision mode + tick/step derivation semantics [D:3/B:6/U:7 → Eff:2.17] 🚀 |
| Task 100 | ⬜ | 🎁 **16-testnet** · Testnet/sandbox URL catalog + proxy patterns [D:2/B:5/U:6 → Eff:2.75] 🚀 |

---

## Superseded / Deferred

| Task | Status | Reason |
|------|--------|--------|
| Task 66c | 🔶 Deferred | 🎁 **10-exotic** · Canonical string recipe — JWT / RSA / Ed25519 family. No Tier 1/2/DEX exchange uses these signing schemes; revisit if priority list expands. |
| Task 66d | 🔶 Deferred | 🎁 **10-exotic** · Canonical string recipe — custom / outlier family. Tail-only; per Three-Strikes Rule, migrate to overrides when a priority exchange needs custom signing. |
| Task 99 | 🔶 Deferred | 🎁 **16-fees** · Tiered fee schedules + VIP level mapping. Tiered fee schedules not required by priority consumers. |
| Task 99b | 🔶 Deferred | 🎁 **16-fees** · Funding / withdrawal / deposit fee catalog. Withdrawal/deposit fees not required by priority consumers. |
| Task 33 | ⛔ Superseded | Original rationale ("consumers should classify from AST") is explicitly retired by the new consumer contract. Replaced by **Phase 10** (Tasks 64–69). |
| Task 34 | ⛔ Superseded | Same — "derivable from existing AST" is no longer a valid deferral under the consumer contract. Replaced by **Phase 13** (Task 88a/b/c handler routing). |
| Task 24 | 🔶 Deferred | Parity.Compare for richer diffs — adds sibling-project path dependency. Improve diffs inline if needed. |
| Task 36 | 🔶 Deferred | Schema migration framework — still premature. Build when a real v3.0 need emerges with concrete requirements. (Schema 2.0.0 from Task 61c is a one-time bump, not ongoing migration tooling.) |
| Rate-limit header extraction | 🔶 Deferred | Confirmed not observable from static analysis or `describe()` — headers are response behavior scattered across handler code. Consumer-side heuristics stay (see ccxt_client Task 50). Revisit only if a simpler observation method surfaces. |

---

## Completed Phases

- **Phase 1: Setup & Discovery ✅** — CCXT source setup, exchange inventory, describe() keys, method inventory, integration tests. See CHANGELOG.md.
- **Phase 2: Runtime Extraction (QuickBEAM) ✅** — Full describe(), family analysis, loadMarkets(). See CHANGELOG.md.
- **Phase 3: Structural Extraction (OXC AST) ✅** — sign(), handleErrors(), parse*(), WS methods, overrides. See CHANGELOG.md.
- **Phase 4: Output Format & Validation ✅** — JSON Schema, pipeline, coverage, validation. See CHANGELOG.md.
- **Phase 5: Distribution ✅** — `--output`, version pinning, schema contract, update workflow. See CHANGELOG.md.
- **Phase 6: Go Extractor Parity ✅ (partial)** — Tasks 30, 31, 32 complete. Tasks 33, 34 superseded above.

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

**Three-tier JSON is the target contract.** Once Phase 9 fully ships, output will merge raw extraction + derived analysis + curated overrides with per-field provenance. **Partial state (2026-04-17):** Tasks 60 + 61b shipped — overrides apply end-to-end via `OverrideRegistry.apply_all/2`. Per-field `_provenance` tagging (Task 61a) and the Schema 2.0.0 bump (61c) remain ⬜; today's `schema_version: 1.8.0` output carries no `_provenance` map. Either way, consumers read the emitted JSON; they do not re-derive or walk AST. Contract tests (`mix ccxt_extract.contract_test`, Task 57) will enforce cross-field invariants so drift surfaces before it reaches a consumer.

**Versioning follows semver** on the `schema_version` field. See [SCHEMA.md](SCHEMA.md).

---

## Notes

- Task descriptions are prompts for Claude to implement — explore the codebase and discover the right approach. See `CLAUDE.md` for session-size, honesty-rule, and three-tier contract guidance.
- Previous "Anti-Bias Rule" and "Extraction vs Interpretation" framings are retired. The replacement rule: every value is provable or explicitly unprovable; interpretation happens in derivation + overrides, not in consumers.
- `[Codex]` marker — tasks suitable for Codex/OpenAI delegation: self-contained, no OXC/QuickBEAM NIF deps. Phase 10–16 tasks touch AST or runtime and generally stay in-house.
- `[P]` marker — task can run in parallel with its siblings in the same phase. Many per-type parse tasks and per-family signing tasks carry `[P]`.
- Raw AST remains in the output. Consumers may inspect it for debugging or novel needs, but a consumer that *requires* walking AST to operate exposes a gap the roadmap should close.
