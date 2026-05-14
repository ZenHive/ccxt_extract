# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON so any consumer — in any language — can operate an exchange without walking AST.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Contract reference:** See [CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md) for the unfiltered list of what a consumer needs. Phases 10–16 tick items off that checklist.

**Schema contract:** See [SCHEMA.md](SCHEMA.md) for field-level definitions and version history of the emitted JSON.

> **🔗 Cross-repo rule (applies to EVERY task in this roadmap):** When a task ships, lands, or changes status, the implementer MUST also update `../ccxt_client/ROADMAP.md` — mark any dependent ccxt_client task as unblocked, flip its status, or add a new follow-up entry. A ccxt_extract task is **not complete** until its downstream ccxt_client impact is reflected there. The two roadmaps are a single contract surface viewed from two sides.

---

## 🎯 Current Focus

<!-- FOCUS:BEGIN -->
**Focus phase:** 11 — Request building contract (0 of 2 done · 0 in progress)

**Last shipped:** no recent shipments

**Up next:** Task 73f — Extend transaction_classification to non-unified raw broadcast endpoints [D:5/B:7/U:7 → Eff:1.4] 📋
<!-- FOCUS:END -->

**Priority goal: v4 schema-freeze.** A ~22-task freeze list (endpoint-invocation Phases 11/13/14 remainder + normalization Phase 12) must ship before v4 emission flips on. v4 publishes atomically — `ccxt_client` and downstream libs keep reading v3 throughout the freeze; v4 becomes the default in one cut once the freeze list is empty. **Phase 12 (response parsing / normalization) is promoted** from previously-deprioritized to schema-freeze gate because downstream libraries depend on the unified-method normalization surface for the v4 cut to be useful. The endpoint-invocation critical path (signing ✅ → request building → rate limits) is unchanged in priority order; Phase 12 ships in parallel with that path. See [v4 Schema-Freeze Plan](#v4-schema-freeze-plan) below and [Endpoint-Invocation Priority Order](#endpoint-invocation-priority-order).

**Phase 8 — Client harness + contract tests** complete; Task 57c is the only holdover and is now unblocked after Task 61a provenance shipped (2026-04-17). The target output is a three-tier merge (raw / derived / override). The **generic JSON-Pointer override contract shipped with Task 60** (see CHANGELOG) — override files use RFC 6901 paths, a `value` payload, required `reason`, and `verified_against`/`unverified` flags, validated by `CcxtExtract.OverrideRegistry` and the `override_registry_valid` contract-test invariant. The **generic merge stage shipped with Task 61b** (2026-04-16). **Task 61a shipped 2026-04-17** — every emitted JSON carries a `_provenance` map tagging each section as raw/derived/override; override-applied paths flip to `"override"` at the tail of `Pipeline.extract/1`. **Task 61c shipped 2026-04-17** — `_provenance` is now required and non-null at `schema_version: 2.0.0`; JSON Schema file renamed `exchange_v1.json` → `exchange_v2.json`; SCHEMA.md has migration notes. **Task 61d shipped 2026-04-17** — `provenance_covers_schema` contract-test invariant now fails loudly on drift between `Pipeline`-emitted sections and the `Provenance` declared pointer lists. Phase 9 contract is fully hardened; remaining Phase 9 items (62 validate_overrides, 63 drift_audit, 104 array-index pointers) are additive. **Task 64 shipped 2026-04-18** — Phase 10 opens with the `structure.sign_recipe` scaffold at schema 2.2.0. **Task 65 shipped 2026-04-18** — `crypto_op` + `signature_placement` now populated via the new `CcxtExtract.SignRecipe.Derive` module. **Task 66a shipped 2026-04-19** — `canonical_string` per-verb map at schema 2.3.0; first-run coverage populates `okx.private.GET` with `[timestamp, method, path, literal("?"), query]`. **Task 66b shipped 2026-04-21** — HMAC-with-body family now populates alongside hmac_simple; `okx.private.POST` emits `[timestamp, method, path, body]` with `family: "hmac_with_body"`. No schema bump (schema 2.3.0 already enumerated `hmac_with_body` + `source: body`; 66b filled the slot). Narrow addition: `@body_names` identifiers (`body`/`bodyPayload`) are exempt from the reassigned-filter in `classify_piece/2` because their name IS the authoritative body source tag in CCXT sign(). **Task 67 shipped 2026-04-24** — `auth_headers` + `nonce` populated on priority exchanges via new `AuthHeaders` / `Nonce` modules; shared AST tree-walkers extracted into `ASTHelpers`. Coverage: 6 priority exchanges with populated auth_headers (okx, coinbaseexchange, gate, kraken, bitfinex, aster), 5 more sections with honest empty-list (deribit, htx × 4), and ~17 sections total with populated nonce. Gate's timestamp chain (`timestampString → timestamp → parseToInt(nonce/1000) → this.nonce()`) resolves via a terminal-binding filter + identifier-chain resolver that picks the wire value over intermediate bindings. Kucoin's `this.extend({...}, headers)` init shape + conditional partner block are tracked as an MVP gap — nonce populates, auth_headers stays null. No schema bump (the 2.3.0 `auth_headers` / `nonce` slots were defined by Task 64). **Task 69 shipped 2026-04-24** — biconditional honesty contract now enforced: `SignRecipe.Derive` auto-flips `unresolved_reason` from `"not_yet_derived"` → `null` whenever every one of the six derivation fields is non-null, and the new `sign_recipe_honesty_valid` contract invariant fails loudly on any drift in the other direction. **Task 68 shipped 2026-04-24 — Phase 10 closes.** `pre_sign_transforms` now derives via the new `PreSignTransforms` module (three-pass detector: digest of `this.hmac(…)` 4th arg, `body = this.json(…)` encoding when consumed by crypto, post-signature `urlencode`/`encodeURIComponent`/`toLowerCase` wrappers). **okx.private is the first recipe in the project to auto-flip `unresolved_reason` to `null`** — all six derivation fields populate end-to-end. Seventeen sign_recipe entries across nine priority exchanges (aster/bitfinex/bitmex/coinbaseexchange/deribit/gate/htx/kraken/kucoin) now carry a populated `pre_sign_transforms`; htx emits the composite `[base64_encode, url_encode]` stack proving the post-signature detector. Terminal exchanges (binance/bybit ambiguous_ast, hyperliquid/derive/lighter custom_signing_family) correctly emit null. No schema bump — the 2.2.0 slot fills. Zero `sign_recipe_honesty_valid` findings; schema round-trip passes for every regenerated exchange. Next endpoint-invocation priority: 🎁 **11-shape** (Tasks 70 + 71 — HTTP verb + path template + body encoding).

**Task 100 shipped 2026-04-19** — 🎁 **16-testnet** opens with a structured `runtime.testnet_urls` derived field at schema 2.4.0. Classifies every exchange as `separate_host` (literal `urls.test` with `{hostname}` placeholders pre-resolved), `sandbox_flag` (only `options.sandboxMode` present), or `none` (neither — honest `unresolved_reason: "no_testnet_data"`). `sandbox_flag_field` is tracked independently of `pattern` so okx emits both signals truthfully. Across priority tiers: bybit/binance/derive/lighter/hyperliquid/deribit emit `separate_host` with fully-resolved URLs; okx/gate/bitget coexist `separate_host` + `sandbox_flag_field`; aster/kraken/htx/bitfinex/kucoin emit `none`. New `testnet_urls_shape_valid` contract invariant locks the shape (zero findings). Unblocks ccxt_client Task 61 (consumer no longer reaches into opaque `runtime.describe.urls.test`).

**Scope.** This roadmap prioritizes Tier 1, Tier 2, and DEX exchanges (canonical list in `priv/priority_tiers.json`; stamped as `exchange.tier` in each output JSON since schema 1.8.0). Tier 3 and unclassified exchanges are supported — we still extract everything — but tasks that exist only to handle their quirks (exotic signing, custom error handlers, outlier fee schedules) live in Superseded / Deferred until a priority exchange surfaces the need. See `CLAUDE.md` §"Tier-Based Scoping". Scope-refactor tasks (every Mix task now accepts `--tier*/--all/--exchange ID`, `_manifest.json` stamps `tier_scope`, both `mix ccxt_extract.update` and `mix ccxt_extract.pipeline` share a `--force`-gated git-status safety rail) tracked in [SCOPED-EXTRACTION-TASKS.md](SCOPED-EXTRACTION-TASKS.md) — Tasks 1–11 complete. **Task 13** (universal envelope `tier_scope` stamping across all aggregate files, not just `_manifest.json`) remains open — see Maintenance Backlog.

**Parallel packaging-axis work (2026-04-19 / 2026-04-20).** Task 116 shipped 2026-04-19 — compact-encoding flip on per-exchange spec writes, measured 54.4% reduction on binance (56.2MB → 25.6MB). **Task 117 shipped 2026-04-20** — schema 3.0.0 (breaking) prune of three dead-weight fields: `runtime.markets.markets` → compact `runtime.symbols_index`, dropped `structure.parse_methods` and `structure.ws_methods` from emission (extractors + discoveries preserved for future Phase 12 / Phase 15 consumption). Measured binance reduction: 25.6MB → 2.15MB (91.6% on this field; ~92% corpus-wide on priority tiers). Coordination: `../ccxt_client/ROADMAP.md` Task 105 (SymbolResolver migration + spec_test presence-check update, ~5 LOC) unblocked — may land now. Phase 10 work continues — T67 (auth_headers + nonce source) is the next endpoint-invocation critical-path task now that 🎁 **10-HMAC** (T66a + T66b) is complete for priority exchanges.

**Task 123 shipped 2026-04-24** — `structure.authenticated_sections` now emits dotted `<parent>.<child>` paths (e.g. `contract.private`, `spot.private`) alongside flat names for exchanges whose `describe.api` nests authenticated children one level deep under container keys (htx + huobi twin). No schema bump — field remains `string[]`. Unblocks `../ccxt_client/ROADMAP.md` Task 110 (raw_endpoint_probe classification cascade).

**v4 schema-freeze plan adopted 2026-05-08.** Roadmap restructured: Phase 12 promoted from "deprioritized — unified-only" to schema-freeze gate; ~22-task freeze list spans Phases 11/12/13/14 plus new Tasks 129 (carrier) and 130 (emit gate); v3 stays the published contract until the freeze list is empty (atomic v4 cut). `ccxt_client` takes exactly one migration; no piecemeal v3.x bumps reach consumers between v3.1.0 and the v4 flip. See [v4 Schema-Freeze Plan](#v4-schema-freeze-plan) for the full task list, reshape, and gate mechanism. `../ccxt_client/ROADMAP.md` carries the single tracking row (`Task v4-adopt`, 🔶 Blocked). **Task 130 shipped 2026-05-08** via PR #7 (INE-60) — `--schema-target=3|4` flag + `Schema.build_exchange_v4/4` + `priv/schema/exchange_v4.json` now in place; default emission stays v3, freeze-list tasks can verify v4 output as they ship.

> **Philosophy reminder:** Every value is either provable (emit it) or explicitly unprovable (`null` + reason). No silent guesses. Overrides (once Phase 9 ships) will fill gaps derivation can't reach and carry reasons too.

### Endpoint-Invocation Priority Order

Phases reordered by criticality for consumers calling *any* endpoint (unified or implicit). Phases 10/11/14 serve both — a unified call ultimately reaches the same HTTP surface as a raw call.

| Rank | Phase | Serves | Why it matters | Notes |
|------|-------|--------|----------------|-------|
| 1 | **Phase 10** (Signing) ✅ | Unified + non-unified | Closed 2026-04-24 (Tasks 64–69). okx.private is the first recipe with `unresolved_reason: null` end-to-end. | Shipped |
| 2 | **Phase 11** (Request building) | Unified + non-unified | Turns `(section, path)` into an HTTP request — verb, body encoding, timestamp, headers | **v4 freeze gate** — Tasks 70–73 |
| 2 | **Phase 12** (Normalization) | Unified | Field maps + envelopes for unified responses. Promoted 2026-05-08 from "deprioritized — unified-only" because downstream libs depend on the surface. | **v4 freeze gate** — Tasks 74–83 + 129 (NEW carrier) |
| 4 | **Phase 14** (Rate limits) | Unified + non-unified | Per-endpoint cost weights — derives from same `rateLimit`/`cost` annotations as Phase 11 | **v4 freeze gate** — Tasks 89–90 |
| 5 | **Phase 13** (Errors) | Unified + non-unified | `error_code_fields` (Task 49) + `throw_dispatches` (Task 55) already shipped — remainder is enhancement | **v4 freeze gate** — Tasks 85–88c |
| 6 | **Phase 9** (Override audit) | Scaffolding | Three-Strikes Rule needs somewhere to migrate to when AST can't prove a signing/request shape. Override contract + provenance + merge stage shipped; remaining items are auditing tooling. | Non-freeze — Tasks 62, 63, 104 |
| 7 | **Phase 16** (Market & currency semantics) | Unified + non-unified | Useful metadata but orthogonal to endpoint invocation | Non-freeze — Tasks 97, 98 |
| 8 | **Phase 15** (WS contract) | Streaming | Separate transport — not on the REST critical path | Post-v4 |

### v4 Schema-Freeze Plan

**Goal:** ship v4 atomically once the freeze list is empty. v3 stays the published contract throughout the freeze. Consumers (`ccxt_client`, downstream libs) take exactly one migration on the v4 flip — not N piecemeal v3.x bumps.

**Freeze list (~22 tasks):**

- **Endpoint-invocation (11 tasks):** Tasks 70, 71 (✅ PR #2), 72 (✅ PR #12), 73 (✅ PR #8), 73d (✅ PR #14, replaces #9) (Phase 11) · Tasks 85 (✅ PR #13), 86 (✅ PR #13), 87 (✅), 88a (✅ PR #6; v4-emit in PR #13), 88b (✅ PR #6; v4-emit in PR #13), 88c (✅ PR #6; v4-emission in PR #13) (Phase 13) · Tasks 89 (✅ PR #11), 90 (✅)
- **Normalization (11 tasks):** Task 129 (✅ PR #10, hardened in PR #15) · Tasks 74–83 (Phase 12)

**v4 Bundle Extras** (in v4 if shipped by cut, not strictly freeze-gating): Tasks 121 (descriptors), 122 (descriptor schema invariant), 126 (OpenAPI sibling).

**Soft gate:** Task 114 (extraction determinism audit) — ✅ **shipped 2026-05-14.** Extraction is now byte-deterministic for a fixed CCXT version + bundle + scope (`mix ccxt_extract.determinism_check` gates it), so freeze diffs are meaningful and the v4 emit default can flip without determinism noise drowning the signal.

**v4 emit gate (Task 130):** opt-in `--schema-target=4` flag, mirrors the existing `--pretty` plumbing (CLI flag → opts → `Pipeline.write!/3` → `Schema.build_exchange_v4/4`). v3 stays default until freeze list is empty AND `ccxt_client` has its v4 migration ready (Task 114 — the determinism soft gate — is ✅ green as of 2026-05-14). Schema files: `priv/schema/exchange_v3.json` (current) and `priv/schema/exchange_v4.json` (new) coexist during the freeze; v3 retained for one release post-flip per the established Task 61c → Task 107 → Task 117 precedent.

**v4 reshape — top-level sections** (consumer-shaped, not producer-shaped — see [SCHEMA.md § Version 4.0.0](SCHEMA.md#version-400--in-progress-gated) for the full path-migration table):

- `endpoints` — `unified`, `interfaces`, `raw` (implicit), `request: {defaults, shape}`, `pagination`, `descriptors`
- `auth` — `sign_recipe`, `sign_method`, `authenticated_sections`, `headers: {user_agent, default}`
- `errors` — `handle_errors`, `status_map`, `retry_classification`, `class_hierarchy`, `dispatch`
- `rate_limits` — `buckets`, `per_endpoint_cost`, `endpoint_cost_binding`
- `normalization` — `parse_methods_digest` (compact, NO AST body), `field_maps`, `response_envelopes`
- `markets` — `symbols_index`, `patterns`, `currencies`, `precision_mode`
- `testnet` — `pattern`, `urls`, `sandbox_flag_field`, `unresolved_reason` (promoted from `runtime.testnet_urls` to top-level)
- `raw` — `describe`, `class_info`, `method_inventory`, `url_templates`, `overrides_meta` (AST-level fallbacks for consumers that need them)

**🔗 Cross-repo coordination.** `../ccxt_client/ROADMAP.md` carries a single tracking row (`Task v4-adopt`, 🔶 Blocked) for the v4 migration. ccxt_client takes exactly one migration; the v4 cut is atomic. No piecemeal v3.x bumps reach `ccxt_client` between now and the v4 flip — that's the whole point of the gate.

### Bundle Index

Tasks are grouped into session-sized bundles in [`roadmap/tasks.toml`](roadmap/tasks.toml). Run `rmap bundles` for the live list, or `rmap next-bundle` for the next session-sized chunk. Bundle membership and per-task status are no longer hand-maintained here — `tasks.toml` is the source of truth, and this file is rendered from it.

Completed bundles (v4-emit, v4-freeze, 9-contract, 10-core, 10-HMAC, 9-pipeline, 11-shape, 10-finish, spec-size, 13-classify, 13-dispatch, 16-testnet, 12-orders/accounts/txn/envelope) are recorded in [CHANGELOG.md](CHANGELOG.md).

### ✅ Recently Completed

Tasks 13b, 68, 69, 67, 123, 66b, 117, 116, 100, 66a, 65, 64, 61d, 61c, 61a, 37, 60, 58, 57d, 56b, 57b, 59, 57, 56, 55, 54, 53, 52, 49, 47, 46 — see [CHANGELOG.md](CHANGELOG.md).

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
| Task 105 | ⬜ | 🎁 **maintenance** · Port super.*() delegation coverage off coincatch [D:2/B:3/U:2 → Eff:1.25] 📋 |
| Task 106 | ⬜ | 🎁 **maintenance** · Drifted-override fixture for override_paths_present_in_output [D:2/B:3/U:3 → Eff:1.5] 🚀 |
| Task 109 | ⬜ | 🎁 **maintenance** · Promote finding() map type to a %Finding{} struct [D:2/B:2/U:2 → Eff:1.0] 📋 |
| Task 110 | ⬜ | 🎁 **maintenance** · Triage 32 request_defaults_resolvable_reachable_from_unified findings [D:4/B:4/U:4 → Eff:1.0] 📋 |
| Task 124 | ⬜ | 🎁 **maintenance** · Prune Bybit discontinued spot/v3/private/* endpoints from extracted spec [D:4/B:4/U:4 → Eff:1.0] 📋 |
| Task 127 | ⬜ | 🎁 **maintenance** · Position-aware paths_rw_split sinks + variable-level sanitization [D:5/B:3/U:3 → Eff:0.6] ⚠️ |
| Task 136 | ⬜ | 🎁 **maintenance** · Re-track priv/output/ now that extraction is byte-deterministic [D:3/B:4/U:5 → Eff:1.5] 🚀 |
| Task 137 | ⬜ | 🎁 **maintenance** · Retrofit Pattern B timestamp writers to accept an :extracted_at opt [D:4/B:3/U:3 → Eff:0.75] ⚠️ |
| Task 141 | ⬜ | 🎁 **maintenance** · Backfill acceptance_criteria + decide on rmap doctor as a roadmap-health gate [D:3/B:3/U:3 → Eff:1.0] 📋 |
| Task 113 | 🔶 | 🎁 **10-sign-extend** · Track indirect signature placement via request-like object construction [D:4/B:3/U:3 → Eff:0.75] ⚠️ |
| Task 66e | 🔶 | 🎁 **10-sign-extend** · Expand canonical_string component vocabulary [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 66f | 🔶 | 🎁 **10-sign-extend** · Key-format disambiguation for Binance/Bybit HMAC branches [D:5/B:6/U:6 → Eff:1.2] 📋 |
| Task 66g | 🔶 | 🎁 **10-sign-extend** · Sub-verb expansion (POST vs PUT vs DELETE vs PATCH) in canonical_string [D:3/B:3/U:3 → Eff:1.0] 📋 |
| Task 66h | 🔶 | 🎁 **10-sign-extend** · Trace conditionally-reassigned body alias variables (kucoin endpart, coinbase payload) [D:5/B:4/U:4 → Eff:0.8] ⚠️ |
| Task 128 | 🔶 | 🎁 **10-sign-extend** · Multi-hop body alias resolution in pre_sign_transforms body-encoding detector [D:4/B:3/U:3 → Eff:0.75] ⚠️ |
| Task 126 | 🔶 | 🎁 **sibling-emit** · Secondary OpenAPI 3.1 emitter for REST exchanges [D:6/B:7/U:5 → Eff:1.0] 📋 |
| Task 125 | 🔶 | 🎁 **sibling-emit** · Secondary OpenRPC emitter for JSON-RPC exchanges (Deribit first) [D:3/B:3/U:2 → Eff:0.83] ⚠️ |
| Task 119 | ⬜ | 🎁 **scope-hygiene** · mix ccxt_extract.prune — evict out-of-scope local state [D:4/B:5/U:4 → Eff:1.12] 📋 |
| Task 120 | ⬜ | 🎁 **scope-hygiene** · Tier-scope-aware skip for authenticated_sections + sign_recipe cached tests [D:3/B:3/U:3 → Eff:1.0] 📋 |
| Task 121 | ⬜ | 🎁 **method-descriptors** · Extract unified-method descriptors from CCXT TS — TS signature + JSDoc overlay [D:6/B:7/U:8 → Eff:1.25] 📋 |
| Task 122 | ⬜ | 🎁 **method-descriptors** · Schema block + unified_method_descriptors_shape_valid contract-test invariant [D:3/B:4/U:5 → Eff:1.5] 🚀 |
| Task 139 | ⬜ | 🎁 **docs-drift** · Reconcile AGENTS.md cloud-agent guidance with retired [CSR]/[CX] strategy [D:2/B:3/U:3 → Eff:1.5] 🚀 |
| Task 140 | ⬜ | 🎁 **test-coverage** · Add pipeline-level integration tests for endpoint_cost_binding propagation [D:3/B:4/U:4 → Eff:1.33] 📋 |
| Task 138 | ⬜ | 🎁 **det-contract** · Extract JsonIO.write_json!/2,3 + a deterministic_write contract invariant [D:4/B:4/U:3 → Eff:0.88] ⚠️ |
| Task 66c | 🔶 | 🎁 **10-exotic** · Canonical string recipe — JWT / RSA / Ed25519 family [D:5/B:4/U:3 → Eff:0.7] ⚠️ |
| Task 66d | 🔶 | 🎁 **10-exotic** · Canonical string recipe — custom / outlier family [D:5/B:3/U:3 → Eff:0.6] ⚠️ |
| Task 24 | 🔶 | 🎁 **superseded** · Parity.Compare for richer diffs [D:3/B:3/U:2 → Eff:0.83] ⚠️ |
| Task 36 | 🔶 | 🎁 **superseded** · Schema migration framework [D:6/B:4/U:3 → Eff:0.58] ⚠️ |
| Task rate-limit-headers | 🔶 | 🎁 **superseded** · Rate-limit header extraction [D:7/B:3/U:3 → Eff:0.43] ⚠️ |
<!-- TASKS:END -->

---

## Phase 8: Client harness + contract tests 🔶

> All reference consumers live in their own git repos as **siblings** of `ccxt_extract/` (e.g. `../ccxt_client/`, future `../<rust-crate>/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but moved back to siblings in Task 56b to stop ccxt_extract's `CLAUDE.md` from being auto-loaded into every client session. `ccxt_extract` stays a pure extractor and ships a contract-test suite that validates the JSON surface without importing client code — catches "Elixir didn't notice this breaks Rust" drift.
>
> **🔗 Every task in this phase requires updating `../ccxt_client/ROADMAP.md` on completion.**

<!-- TASKS:BEGIN phase=8 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 57c | ⬜ | 🎁 **9-pipeline-follow-up** · unified_endpoints/has drift triage — Pattern C honest fix [D:3/B:5/U:5 → Eff:1.67] 🚀 |
<!-- TASKS:END -->

Completed tasks (56, 56b, 57, 57b, 57d, 58, 59) — see [CHANGELOG.md](CHANGELOG.md).

---

## Phase 9: Override infrastructure + provenance ⬜

> The three-tier output model requires override storage, merge logic, provenance tagging, and drift auditing. Lands before signing/parsing phases so every new derived field ships with an override fallback from day one.
>
> **This phase also enables the Three-Strikes Derivation Rule** (see CLAUDE.md) — without somewhere to migrate knowledge to, the rule has no exit. Every Phase 10–16 derivation ships knowing it can hand off to an override on patch #3 instead of accreting special cases.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — notably ccxt_client Tasks 53 (schema 2.0.0 adapter) and 63 (override contribution workflow).

<!-- TASKS:BEGIN phase=9 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 62 | ⬜ | 🎁 **9-audit** · mix ccxt_extract.validate_overrides [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 63 | ⬜ | 🎁 **9-audit** · mix ccxt_extract.drift_audit [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 104 | ⬜ | 🎁 **9-pipeline** · Array-index JSON Pointers in OverrideRegistry [D:2/B:3/U:2 → Eff:1.25] 📋 |
<!-- TASKS:END -->

---

## Phase 11: Request building contract ⬜

> Everything a consumer needs to turn a unified call into an HTTP request, excluding signing (Phase 10).
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 57 (adopt request-building contract) tracks this phase.

<!-- TASKS:BEGIN phase=11 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 73f | ⬜ | 🎁 **11-shape** · Extend transaction_classification to non-unified raw broadcast endpoints [D:5/B:7/U:7 → Eff:1.4] 📋 |
| Task 73e | ⬜ | 🎁 **11+14** · OXC-side extractor for sign-method-constructed User-Agent and runtime header mutations [D:5/B:3/U:3 → Eff:0.6] ⚠️ |
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
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 19/21/44/55 (parser + struct regeneration) depend on this phase.

<!-- TASKS:BEGIN phase=12 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 78c `[P]` | ⬜ | 🎁 **12-simple** · parseOHLCV hybrid Array.isArray exchanges (gate, possible binance options-fallback) [D:5/B:4/U:4 → Eff:0.8] ⚠️ |
| Task 78d `[P]` | ⬜ | 🎁 **12-simple** · parseOHLCV scrambled-coercion + heuristic exchanges (coinbaseexchange, kraken, kucoin) [D:5/B:4/U:4 → Eff:0.8] ⚠️ |
| Task 78f `[P]` | ⬜ | 🎁 **12-simple** · parseOHLCV discriminator vocabulary beyond market.inverse [D:3/B:4/U:4 → Eff:1.33] 📋 |
| Task 135 | ⬜ | 🎁 **12-simple** · ticker.ex normalization-vocab alignment [D:2/B:4/U:5 → Eff:2.25] 🎯 |
<!-- TASKS:END -->

Type-coercion tables fold into each per-type task (not standalone) — one task covers its type's field map + coercion + enums together so it fits in a session.

---

## Phase 13: Error contract ⬜

> **Supersedes Task 34.** Complete the error story: status-code maps, retry classification, class hierarchy export, and handler routing tables that consumers need to drive dispatch without AST.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 58 (adopt error contract) tracks this phase.

<!-- TASKS:BEGIN phase=13 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 132 | ⬜ | 🎁 **13-classify-fix** · Split predicate_kind http_status_in into eq vs range [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 133 | ⬜ | 🎁 **13-classify-safety** · Explicit error_class_hierarchy content-equality invariant in contract_test [D:2/B:4/U:3 → Eff:1.75] 🚀 |
| Task 134 | ⬜ | 🎁 **13-perf** · Thread precomputed error_dispatch through http_status_map/1 and retryable_buckets/1 [D:3/B:3/U:2 → Eff:0.83] ⚠️ |
<!-- TASKS:END -->

---

## Phase 15: WS contract ⬜

> Streaming equivalent of phases 10–13. Per-channel specs for subscription, auth, heartbeat, snapshot/delta semantics, and reconnect.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Phase 6 (Tasks 22–27) is gated on this phase landing.

<!-- TASKS:BEGIN phase=15 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 91 | ⬜ | 🎁 **15-msg** · WS subscribe / unsubscribe message shape per channel [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 92 | ⬜ | 🎁 **15-msg** · WS auth flow (sign-in msg / header / query param) [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 93 | ⬜ | 🎁 **15-msg** · Heartbeat / ping-pong pattern per exchange [D:3/B:6/U:7 → Eff:2.17] 🎯 |
| Task 94 | ⬜ | 🎁 **15-dispatch** · Channel → parse handler dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 95a `[P]` | ⬜ | 🎁 **15-semantics** · Snapshot/delta semantics — orderbook [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 95b `[P]` | ⬜ | 🎁 **15-semantics** · Snapshot/delta semantics — trades [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 95c `[P]` | ⬜ | 🎁 **15-semantics** · Snapshot/delta semantics — OHLCV [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 96 | 🔶 | 🎁 **15-reconnect** · Reconnect triggers + backoff policy hints [D:3/B:6/U:6 → Eff:2.0] 🎯 |
<!-- TASKS:END -->

---

## Phase 16: Market & currency semantics ⬜

> Remaining declarative metadata a consumer needs beyond `runtime.markets` and `runtime.describe`.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 60 (currency aliases) and 61 (testnet URL catalog) track this phase.

<!-- TASKS:BEGIN phase=16 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 97 | ⬜ | 🎁 **16-currency** · Currency aliases (commonCurrencies) + network info [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 98 | ⬜ | 🎁 **16-currency** · Precision mode + tick/step derivation semantics [D:3/B:6/U:7 → Eff:2.17] 🎯 |
| Task 99 | 🔶 | 🎁 **16-fees** · Tiered fee schedules + VIP level mapping [D:4/B:4/U:3 → Eff:0.88] ⚠️ |
| Task 99b | 🔶 | 🎁 **16-fees** · Funding / withdrawal / deposit fee catalog [D:4/B:4/U:3 → Eff:0.88] ⚠️ |
<!-- TASKS:END -->

---

## Superseded / Deferred

> ⛔ truly-superseded items only. The 🔶-deferred tasks (66c, 66d, 99, 99b, 24, 36, rate-limit header extraction) now live in [`roadmap/tasks.toml`](roadmap/tasks.toml) as `status = "blocked"` with a `blocked_reason`, rendered in their phase tables above — run `rmap list --status blocked` to see them.

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
