# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON so any consumer — in any language — can operate an exchange without walking AST.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Contract reference:** See [CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md) for the unfiltered list of what a consumer needs. Phases 10–16 tick items off that checklist.

**Schema contract:** See [SCHEMA.md](SCHEMA.md) for field-level definitions and version history of the emitted JSON.

> **🔗 Cross-repo rule (applies to EVERY task in this roadmap):** When a task ships, lands, or changes status, the implementer MUST also update `../ccxt_client/ROADMAP.md` — mark any dependent ccxt_client task as unblocked, flip its status, or add a new follow-up entry. A ccxt_extract task is **not complete** until its downstream ccxt_client impact is reflected there. The two roadmaps are a single contract surface viewed from two sides.

---

## 🎯 Current Focus

**Priority goal: endpoint-invocation contract (serves unified + non-unified).** The critical path is **signing → request building → rate limits**. These phases unlock both raw (implicit) and unified endpoints — anything you'd call needs them. Only Phase 12 (response parsing) is unified-specific (i.e., CCXT's normalized method surface like `fetchTicker`/`createOrder`, as opposed to raw implicit endpoints) and thus deprioritized. See [Endpoint-Invocation Priority Order](#endpoint-invocation-priority-order) below.

**Phase 8 — Client harness + contract tests** complete; Task 57c is the only holdover and is now unblocked after Task 61a provenance shipped (2026-04-17). The target output is a three-tier merge (raw / derived / override). The **generic JSON-Pointer override contract shipped with Task 60** (see CHANGELOG) — override files use RFC 6901 paths, a `value` payload, required `reason`, and `verified_against`/`unverified` flags, validated by `CcxtExtract.OverrideRegistry` and the `override_registry_valid` contract-test invariant. The **generic merge stage shipped with Task 61b** (2026-04-16). **Task 61a shipped 2026-04-17** — every emitted JSON carries a `_provenance` map tagging each section as raw/derived/override; override-applied paths flip to `"override"` at the tail of `Pipeline.extract/1`. **Task 61c shipped 2026-04-17** — `_provenance` is now required and non-null at `schema_version: 2.0.0`; JSON Schema file renamed `exchange_v1.json` → `exchange_v2.json`; SCHEMA.md has migration notes. **Task 61d shipped 2026-04-17** — `provenance_covers_schema` contract-test invariant now fails loudly on drift between `Pipeline`-emitted sections and the `Provenance` declared pointer lists. Phase 9 contract is fully hardened; remaining Phase 9 items (62 validate_overrides, 63 drift_audit, 104 array-index pointers) are additive. **Task 64 shipped 2026-04-18** — Phase 10 opens with the `structure.sign_recipe` scaffold at schema 2.2.0. **Task 65 shipped 2026-04-18** — `crypto_op` + `signature_placement` now populated via the new `CcxtExtract.SignRecipe.Derive` module. **Task 66a shipped 2026-04-19** — `canonical_string` per-verb map at schema 2.3.0; first-run coverage populates `okx.private.GET` with `[timestamp, method, path, literal("?"), query]`. **Task 66b shipped 2026-04-21** — HMAC-with-body family now populates alongside hmac_simple; `okx.private.POST` emits `[timestamp, method, path, body]` with `family: "hmac_with_body"`. No schema bump (schema 2.3.0 already enumerated `hmac_with_body` + `source: body`; 66b filled the slot). Narrow addition: `@body_names` identifiers (`body`/`bodyPayload`) are exempt from the reassigned-filter in `classify_piece/2` because their name IS the authoritative body source tag in CCXT sign(). 🎁 **10-HMAC** complete for priority exchanges; next Phase 10 critical-path work is Task 67 (auth_headers + nonce).

**Task 100 shipped 2026-04-19** — 🎁 **16-testnet** opens with a structured `runtime.testnet_urls` derived field at schema 2.4.0. Classifies every exchange as `separate_host` (literal `urls.test` with `{hostname}` placeholders pre-resolved), `sandbox_flag` (only `options.sandboxMode` present), or `none` (neither — honest `unresolved_reason: "no_testnet_data"`). `sandbox_flag_field` is tracked independently of `pattern` so okx emits both signals truthfully. Across priority tiers: bybit/binance/derive/lighter/hyperliquid/deribit emit `separate_host` with fully-resolved URLs; okx/gate/bitget coexist `separate_host` + `sandbox_flag_field`; aster/kraken/htx/bitfinex/kucoin emit `none`. New `testnet_urls_shape_valid` contract invariant locks the shape (zero findings). Unblocks ccxt_client Task 61 (consumer no longer reaches into opaque `runtime.describe.urls.test`).

**Scope.** This roadmap prioritizes Tier 1, Tier 2, and DEX exchanges (canonical list in `priv/priority_tiers.json`; stamped as `exchange.tier` in each output JSON since schema 1.8.0). Tier 3 and unclassified exchanges are supported — we still extract everything — but tasks that exist only to handle their quirks (exotic signing, custom error handlers, outlier fee schedules) live in Superseded / Deferred until a priority exchange surfaces the need. See `CLAUDE.md` §"Tier-Based Scoping". Scope-refactor tasks (every Mix task now accepts `--tier*/--all/--exchange ID`, `_manifest.json` stamps `tier_scope`, both `mix ccxt_extract.update` and `mix ccxt_extract.pipeline` share a `--force`-gated git-status safety rail) tracked in [SCOPED-EXTRACTION-TASKS.md](SCOPED-EXTRACTION-TASKS.md) — Tasks 1–11 complete. **Task 13** (universal envelope `tier_scope` stamping across all aggregate files, not just `_manifest.json`) remains open — see Maintenance Backlog.

**Parallel packaging-axis work (2026-04-19 / 2026-04-20).** Task 116 shipped 2026-04-19 — compact-encoding flip on per-exchange spec writes, measured 54.4% reduction on binance (56.2MB → 25.6MB). **Task 117 shipped 2026-04-20** — schema 3.0.0 (breaking) prune of three dead-weight fields: `runtime.markets.markets` → compact `runtime.symbols_index`, dropped `structure.parse_methods` and `structure.ws_methods` from emission (extractors + discoveries preserved for future Phase 12 / Phase 15 consumption). Measured binance reduction: 25.6MB → 2.15MB (91.6% on this field; ~92% corpus-wide on priority tiers). Coordination: `../ccxt_client/ROADMAP.md` Task 105 (SymbolResolver migration + spec_test presence-check update, ~5 LOC) unblocked — may land now. Phase 10 work continues — T67 (auth_headers + nonce source) is the next endpoint-invocation critical-path task now that 🎁 **10-HMAC** (T66a + T66b) is complete for priority exchanges.

**Task 123 shipped 2026-04-24** — `structure.authenticated_sections` now emits dotted `<parent>.<child>` paths (e.g. `contract.private`, `spot.private`) alongside flat names for exchanges whose `describe.api` nests authenticated children one level deep under container keys (htx + huobi twin). No schema bump — field remains `string[]`. Unblocks `../ccxt_client/ROADMAP.md` Task 110 (raw_endpoint_probe classification cascade).

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
| 13 | 🎁 **spec-size** ✅ | 116 ✅, 117 ✅ | Compact encoding (A, shipped 2026-04-19, 54.4% on binance) + dead-weight prune with schema 3.0.0 breaking change (B, shipped 2026-04-20, 91.6% additional on binance). Together cleared ccxt_client Hex 128MB publish cap with substantial headroom. |

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
| 🎁 **16-testnet** ✅ | 100 | Sandbox URL catalog — shipped 2026-04-19 at schema 2.4.0 |

### ✅ Recently Completed

Tasks 66b, 117, 116, 100, 66a, 65, 64, 61d, 61c, 61a, 37, 60, 58, 57d, 56b, 57b, 59, 57, 56, 55, 54, 53, 52, 49, 47, 46 — see [CHANGELOG.md](CHANGELOG.md).

### 📋 Next Up
| Task | Status | Notes |
|------|--------|-------|
| Task 100 | ✅ | 🎁 **16-testnet** · Shipped 2026-04-19 — schema 2.4.0 `runtime.testnet_urls` derived field with pattern enum (`separate_host` / `sandbox_flag` / `none`), `{hostname}` pre-resolution, independent `sandbox_flag_field`. New `testnet_urls_shape_valid` contract invariant. Unblocks ccxt_client T61. See [CHANGELOG.md](CHANGELOG.md). |
| Task 66a `[P]` | ✅ | 🎁 **10-HMAC** · Shipped 2026-04-19 — schema 2.3.0 per-verb `canonical_string` map; `CcxtExtract.SignRecipe.CanonicalString` populates hmac_simple entries. OKX.private.GET populated on first run; other priority exchanges null with truthful reasons (ambiguous_ast / custom_signing_family / pending 66b / 66e / 66f). See [CHANGELOG.md](CHANGELOG.md). |
| Task 116 | ✅ | 🎁 **spec-size · A** · Shipped 2026-04-19 — `pipeline.ex` per-exchange spec writes flipped to compact; manifests/fixtures/reports/discovery envelopes stay pretty. New `--pretty` debug flag on `mix ccxt_extract.pipeline` + `mix ccxt_extract.update`. Measured 54.4% reduction on binance (56.2MB pretty → 25.6MB compact). Insufficient alone to clear Hex 128MB cap on `ccxt_client` — T117 still required. See [CHANGELOG.md](CHANGELOG.md). |
| Task 117 | ✅ | 🎁 **spec-size · B** · Shipped 2026-04-20 — schema 3.0.0 (breaking). Replaced `runtime.markets.markets` with compact `runtime.symbols_index` (binance 23.6MB → ~30KB on this field), dropped `structure.parse_methods` and `structure.ws_methods` from emission (extractors + discovery files preserved for future Phase 12 / Phase 15 consumption). Binance total: 25.6MB → 2.15MB (91.6% additional reduction on top of T116). JSON Schema renamed `exchange_v2.json` → `exchange_v3.json`. New `CcxtExtract.SymbolsIndex` module; `Validation.validate_roundtrip/3` and `Provenance` pointer lists rebaselined; `provenance_covers_schema` zero findings. Migration notes in [SCHEMA.md](SCHEMA.md). Unblocks `ccxt_client` Task 105 (SymbolResolver migration). See [CHANGELOG.md](CHANGELOG.md). |
| Task 66b `[P]` | ✅ | 🎁 **10-HMAC** · Shipped 2026-04-21 — HMAC-with-body family populates alongside hmac_simple; no schema bump (2.3.0's `hmac_with_body` + `source: body` slots filled). `okx.private.POST` emits `[timestamp, method, path, body]`. Narrow `@body_names` reassigned-filter exemption lets `body = this.json(...); auth += body` populate cleanly while keeping kucoin/coinbase honestly null (name-collision risk with path aliases). See [CHANGELOG.md](CHANGELOG.md). |
| Task 65 | ✅ | Shipped 2026-04-18 — `crypto_op` + `signature_placement` populated via new `CcxtExtract.SignRecipe.Derive`. 10 priority exchanges get real values; binance/bybit/coinbase honestly emit `ambiguous_ast` for multi-algo conditional sign(); hyperliquid emits `custom_signing_family`. Zero new contract-test findings. See [CHANGELOG.md](CHANGELOG.md). |
| Task 64 | ✅ | Shipped 2026-04-18 — `structure.sign_recipe` scaffold at schema 2.2.0, per-section null records + `unresolved_reason: "not_yet_derived"`, two new contract-test invariants. See [CHANGELOG.md](CHANGELOG.md). |
| Task 57c | ⬜ | Now unblocked (61a shipped). Pattern A/B fixed (341 → 53); Pattern C residual can tag `has`-confirmed entries as `"derived"` at the provenance tier instead of silently filtering. |
| Task 61d | ✅ | Shipped 2026-04-17 — `provenance_covers_schema` contract-test invariant catches drift between Pipeline-emitted sections and Provenance's declared pointer lists (uncovered / orphan / tag-mismatch). Clean baseline across the full committed corpus. See [CHANGELOG.md](CHANGELOG.md). |
| Task 61c | ✅ | Shipped 2026-04-17 — Schema 2.0.0 promotes `_provenance` to required, non-null; JSON Schema file renamed `exchange_v1.json` → `exchange_v2.json`; SCHEMA.md migration notes added. See [CHANGELOG.md](CHANGELOG.md). |
| Task 61b | ✅ | Shipped 2026-04-16 — generic RFC 6901 merge via `OverrideRegistry.apply_all/2`. See [CHANGELOG.md](CHANGELOG.md). |
| Task 61a | ✅ | Shipped 2026-04-17 — `_provenance` map keyed by JSON Pointer, values `raw`/`derived`/`override`; schema bumped to 1.8.1 (additive, nullable). See [CHANGELOG.md](CHANGELOG.md). |
| Task 37 | ✅ | Shipped 2026-04-17 — Credo reverted from git-branch workaround to Hex `~> 1.7.18`. Handled by `[Codex]` rescue subagent. |

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
| Task 37 | ✅ | Shipped 2026-04-17 — Credo git-branch workaround reverted to Hex `~> 1.7.18`. See [CHANGELOG.md](CHANGELOG.md). |
| Task 101 | ✅ | Fixture refresh for oxc 0.7 / quickbeam 0.10 — shipped 2026-04-17. Full-universe regen cleared the cached `parse_methods` threshold in `coverage_report_cached_test.exs`; contract_test `--strict` findings all match documented baseline (Pattern C + tokocrypto unclassified). See [CHANGELOG.md](CHANGELOG.md#task-101-fixture-refresh-for-oxc-07--quickbeam-010). |
| Task 105 | ⬜ | Port `super.*()` delegation coverage off coincatch [D:2/B:3/U:2 → Eff:1.25] 📋 — coincatch was removed upstream; the test that validated `parse_file/1` walking a super-delegation chain was deleted in Task 101. Find another currently-shipping exchange with a non-trivial `super.*()` chain and reinstate targeted coverage, otherwise `parse_file` regressions on that code path escape. TODO marker at `test/ccxt_extract/unified_endpoints_test.exs`. |
| Task 13a | ✅ | Universal envelope `tier_scope` stamping — code-plumbing half [D:1/B:4/U:5 → Eff:4.5] 🎯 — shipped: `_base_methods.json` stamps `"all"` (universe-agnostic); `_validation_report.json` derives scope from `_manifest.json`; `_contract_test_report.json` threads scope from the TaskScope-parsed flags. See [CHANGELOG.md](CHANGELOG.md#task-13a). |
| Task 13b | ⬜ | Universal envelope `tier_scope` stamping — test-migration half [D:2/B:3/U:3 → Eff:1.5] 🚀 — depends on 13a. Migrate 9 cached integration tests from observed-count dispatch to envelope dispatch and shrink `test/support/scope_thresholds.ex` to just `proportional/2` (or delete). Three tracked `TODO(scope-envelope):` markers: `test/support/scope_thresholds.ex:22`, `test/integration/method_analysis_integration_test.exs:52`, `test/integration/public_exchanges_integration_test.exs:46`. |
| Task 102 | ✅ | Resolved 2026-04-17 by ccxt_client Task 85 — `ccxt_client/lib/ccxt/spec.ex:37` now reads `@spec_dir "priv/specs/json/output"`, aligned with ccxt_extract REFACTOR Item 9's split read/write layout. Cross-repo obligation discharged. |
| Task 106 | ⬜ | Drifted-override fixture for `override_paths_present_in_output` [D:2/B:3/U:3 → Eff:1.5] 🚀 — the contract-test invariant today only exercises the 0-finding case (see `test/ccxt_extract/contract_test_test.exs`). Add a fixture that injects a drifted override (pointer value absent from output) once `ContractTest.run_all/1` threads overrides through `observed`. Discovered during Task 61c. |
| Task 107 | ✅ | Shipped 2026-04-18 — `priv/schema/exchange_v1.json` deleted. SCHEMA.md history entry updated. See [CHANGELOG.md](CHANGELOG.md). |
| Task 108 | ✅ | Shipped 2026-04-18 — `CcxtExtract.Schema.schema_filename/0` is the single source of truth; 5 call sites in `pipeline.ex`, `validation.ex`, `contract_test.ex` now call the function. See [CHANGELOG.md](CHANGELOG.md). |
| Task 109 | ⬜ | Promote `finding()` map type to a `%Finding{}` struct [D:2/B:2/U:2 → Eff:1.0] 📋 — `CcxtExtract.ContractTest.@type finding :: %{...}` is constructed in five builder sites with identical `{exchange, invariant, path, message}` key sets. Replacing with a `defstruct [:exchange, :invariant, :path, :message]` + `@enforce_keys` gains compile-time key validation and silences the recurring `struct-hint` post-edit hook. Must `@derive Jason.Encoder` so `priv/output/_contract_test_report.json` stays free of `__struct__` keys, and re-verify that `Enum.sort/1` over findings produces the same ordering for downstream consumers. Discovered during Task 61d code review. |
| Task 110 | ⬜ | Triage 32 `request_defaults_resolvable_reachable_from_unified` findings [D:4/B:4/U:4 → Eff:1.0] 📋 — Baseline full-corpus run surfaces 32 helper-method findings (e.g. `bybit.fetchSpotMarkets`, `coinbase.fetchAccountsV2`, `binanceus.borrowIsolatedMargin`). These helpers get request-body literals extracted and ARE called transitively from a unified method, but `unified_endpoints` values store interface method names (`publicGetX`), so the reachability check can't see the call chain. Either (a) add a transitive-call analysis that walks unified method bodies for `this.<helper>()` calls, or (b) maintain a committed baseline allowlist like `priv/contract_test/error_code_fields_roots.json`. Discovered during Task 73c. |
| Task 111 | ✅ | Shipped 2026-04-18 — added `Paths.out_bundle/0` and `out_version_file/0`; retargeted `mix ccxt_extract.setup` writers. Read helpers unchanged. See [CHANGELOG.md](CHANGELOG.md). |
| Task 112 | ✅ | Shipped 2026-04-18 — `paths_rw_split` corpus-level invariant (runs once per `run_all/1`) uses `Reach.Project.taint_analysis` over `lib/**/*.ex` with same-file filter. Introduces `@corpus_invariants` registry alongside `@invariants`. See [CHANGELOG.md](CHANGELOG.md). |
| Task 113 | ⬜ | Track indirect signature placement via `request`-like object construction [D:4/B:3/U:3 → Eff:0.75] 📋 — htx (and likely a handful of others) build `const request = {..., Signature: signature}` then `url += '?' + this.urlencode(request)`. The placement is genuinely `query` with key `Signature`, but the initial Task 65 derivation only tracks direct `query = ...` / `headers['K'] = ...` / `body = this.json({...})` assignments. Add an object-level propagation step: when an ObjectExpression with a sig-referencing property is bound to a variable, follow the variable into subsequent `url += '?' + this.urlencode(<var>)` / `body = this.urlencode(<var>)` statements and attribute the placement accordingly. Discovered during Task 65 (htx.private ships with `signature_placement: null` until this lands). |
| ~~Task 113~~ (LFS) | ⛔ Superseded | Resolved 2026-04-18 by the chore untracking `priv/output/` and `priv/discoveries/*` (except `class_hierarchy.json`). LFS is moot once the paths aren't in the index. See [CHANGELOG.md](CHANGELOG.md) entry "stop tracking derived extraction corpus". The residual follow-up is **Task 114** below (audit extraction determinism). |
| Task 114 | ⬜ | Audit extraction determinism so the corpus becomes re-committable [D:6/B:6/U:5 → Eff:0.92] 📋 — Untracking (2026-04-18) stopped the bleeding but the root cause is churn, not size: every `mix ccxt_extract.update` produces ~110-file diffs even when upstream CCXT didn't change. Identify and eliminate non-deterministic sources: `generated_at` timestamps, map iteration order through JSON encoding, `AggregateWriter.merge/2` ordering semantics under scoped runs, silent upstream CCXT version drift. Success criterion: same CCXT version + same bundle + same scope → byte-identical output across runs. Once stable, revisit whether to re-track `priv/output/` — size becomes acceptable if diffs are meaningful and infrequent. |
| Task 115 | ⬜ | Self-healing `mix ccxt_extract.setup` — auto-provision `priv/ccxt` [D:3/B:5/U:7 → Eff:2.0] 🚀 — `lib/mix/tasks/ccxt_extract.setup.ex:47` currently calls `check_ts_source/0` and hard-fails if `priv/ccxt/ts/src` is absent. Fresh clones must sparse-clone manually before `mix setup` can run (see README Step 1). Make setup detect absence and do the sparse clone itself (depth-1, sparse-checkout `ts/src` + optionally `package.json`), turning `mix setup` into a true one-command bootstrap. Edge cases: existing `priv/ccxt` with wrong content (detect via `.git` presence + sparse-checkout state, don't overwrite), network failures (preserve any partial clone for retry), opt-out flag for users who want to symlink their own CCXT checkout. Discovered 2026-04-18 during Codex review of the corpus-untracking chore. |
| Task 66e | ⬜ | Expand `canonical_string` component vocabulary [D:4/B:7/U:7 → Eff:1.75] 🚀 — add `source: "nonce"` (Deribit uses both a wall-clock timestamp AND a per-request nonce in the canonical chain; tagging both as `timestamp` produces a consumer-ambiguous recipe), `source: "hostname"` (HTX v1 signs `method + hostname + path + query`), `source: "expiry"` (Phemex signs an `expiryString` field), and an `encoding: "delimited"` mode with explicit separator handling (Gate/HTX/Deribit use `.join("\n")`). Also consider a nested-op component source to capture Kraken's `binaryConcat(encode(url), hash(encode(nonce + body)))` and Gate's `SHA512(body)` slot. Discovered 2026-04-19 during Task 66a — those priority exchanges currently emit null `canonical_string` with `unresolved_reason: "not_yet_derived"`. |
| Task 66f | ⬜ | Key-format disambiguation for Binance/Bybit HMAC branches [D:5/B:6/U:6 → Eff:1.2] 📋 — both exchanges route `if (secret.indexOf('PRIVATE KEY') > -1) { rsa(...)/eddsa(...) } else { this.hmac(...) }`. Task 65 correctly emits `crypto_op: null` with `unresolved_reason: "ambiguous_ast"` for the whole recipe because no single crypto_op is truthful. A future pass could disambiguate by credential format: emit two alternative recipes, or a per-key-format discriminator. Likely overrides territory under the Three-Strikes Rule rather than a derivation extension. Discovered 2026-04-19 during Task 66a; not urgent because priority consumers currently use HMAC keys exclusively. |
| Task 66g | ⬜ | Sub-verb expansion (POST vs PUT vs DELETE vs PATCH) in `canonical_string` [D:3/B:3/U:3 → Eff:1.0] 📋 — `CanonicalString.flip_verb/1` currently maps the else-of-GET branch to `"POST"` for every non-GET verb. Consumers applying the POST recipe to PUT/DELETE/PATCH get the right canonical today because no priority exchange distinguishes those verbs inside sign() — they all fall into the same else-branch. Expand only when a sign() method actually tests `method === 'PUT'` / `=== 'DELETE'` / `=== 'PATCH'` distinctly. Discovered 2026-04-21 during Task 66b. TODO marker at `lib/ccxt_extract/sign_recipe/canonical_string.ex` above the `flip_verb/1` clauses. |
| Task 66h | ⬜ | Trace conditionally-reassigned body alias variables (kucoin `endpart`, coinbase `payload`) [D:5/B:4/U:4 → Eff:0.8] 📋 — kucoin's `let endpart = ''; if (method !== 'GET') endpart = body; auth += endpart` and coinbaseexchange's `let payload = ''; if (method !== 'GET') payload = this.json(body); auth += payload` pattern. Both currently emit `canonical_string: null` at the recipe level with `unresolved_reason: "not_yet_derived"` — Task 66b's `@body_names` exemption is deliberately narrow (the identifier `body`/`bodyPayload` by name only), so `endpart` and `payload` (the latter lives in `@path_names`) stay honestly null. A future pass would walk conditionally-reassigned identifiers whose RHS in each branch is itself a recognized body-shaped expression (`body`, `this.json(...)`, `this.urlencode(...)`), propagating the source tag per-verb. Risk: over-permissive tracing could mistakenly tag an unrelated identifier as body. Safer to ship overrides under the Three-Strikes Rule if a priority consumer needs kucoin/coinbase POST canonicals before the generic analysis lands. Discovered 2026-04-21 during Task 66b. |
| Task 116 | ✅ | 🎁 **spec-size · A** · Shipped 2026-04-19 — `pipeline.ex` per-exchange spec writes flipped to compact via new `:pretty` opt on `Pipeline.write!/3`. `aggregate_writer.ex` left untouched (writes `priv/discoveries/*` envelope files, kept pretty for diagnostics — explore confirmed it's not on the high-volume per-exchange path). Port-contract fixtures, manifests, validation/contract reports stay pretty. New `--pretty` debug flag on `mix ccxt_extract.update` + `mix ccxt_extract.pipeline`. Measured reduction: binance 56.2MB pretty → 25.6MB compact (54.4%, better than the pre-task ~48% estimate). Insufficient alone for Hex publish — pairs with Task 117. See [CHANGELOG.md](CHANGELOG.md). |
| Task 118 | ⬜ | 🎁 **spec-size · cleanup** · Delete `priv/schema/exchange_v2.json` after one-release grace window [D:1/B:2/U:2 → Eff:2.0] 📋 — Following the Task 61c → Task 107 precedent, Task 117 kept `exchange_v2.json` alive for one release alongside the new `exchange_v3.json`. Delete it in the next release cycle once downstream consumers have confirmed migration. Since `Schema.schema_filename/0` centralizes the reference (Task 108), the actual deletion is a `git rm` plus any stale test asset cleanup. Discovered 2026-04-20 during Task 117. |
| Task 119 | ⬜ | `mix ccxt_extract.prune` — evict out-of-scope local state [D:4/B:5/U:4 → Eff:1.13] 📋 — `AggregateWriter.merge/2` is intentionally additive so successive scoped runs accumulate, which means `priv/discoveries/` (both per-exchange subdirs like `describe/<id>.json`, `load_markets/<id>.json` and envelope aggregates like `methods_rest.json`, `sign_methods.json`, `url_templates.json`, `exchanges.json`, …) drift out of sync with the declared scope: on 2026-04-20 `priv/output/` held the 23 priority-tier files while `describe/` held 107 (86 out-of-scope) and `load_markets/` ~103. Everything except `class_hierarchy.json` is gitignored, so the safety rail never fires and `git status` can't see the drift — a scoped re-run won't evict these either. Task scope: a new mix task that accepts the same `--tier*/--all/--exchange ID` / `Paths.out(...)` plumbing as the rest of the pipeline, computes the in-scope ID set via `Tiers.members_for_tier/1` + class_hierarchy, deletes per-exchange files in all `priv/discoveries/<subdir>/` whose ID is out-of-scope (plus the matching `priv/output/<id>.json`), and then re-aggregates every envelope file (`methods_rest.json`, `methods_ws.json`, `sign_methods.json`, `handle_errors.json`, `interface_signatures.json`, `pagination.json`, `parse_methods.json`, `request_defaults.json`, `url_templates.json`, `ws_methods.json`, `overrides.json`, `exchanges.json`, `public_exchanges.json`) from only the surviving in-scope per-exchange files — don't touch `class_hierarchy.json` (compile-time load-bearing). Honor `:priv_write_override` so `PrivWriteCase` isolates test runs. `--dry-run` flag to print what would be deleted without touching disk. Safety rail: dry-run by default, require `--force` to actually delete (writes are destructive and hard to reverse without a full `--all` regen). Success criterion: after running with the same scope flags as the prior extraction, the set of IDs present in `priv/discoveries/describe/` equals the set in `priv/output/` equals the set implied by the envelope `by_exchange_id` stamps. Discovered 2026-04-20 from a scope-drift report (23 in `priv/output/`, 107 in `priv/discoveries/describe/`). |
| Task 120 | ⬜ | Tier-scope-aware skip for `authenticated_sections_integration_test` + `sign_recipe_cached_test` [D:3/B:3/U:3 → Eff:1.0] 📋 — two tests currently paper over scope drift with blunt skips: (a) `test/ccxt_extract/authenticated_sections_integration_test.exs:125-135` returns `[]` unconditionally for any override whose `priv/output/<id>.json` is absent, losing regression detection on full-universe runs for classified exchanges; (b) `test/integration/cached/sign_recipe_cached_test.exs:55-66` uses `@tag :tier3_corpus` + default-exclude via `test_helper.exs` to bypass bitget. Replace both with a scope-aware helper that reads `_manifest.json`'s `tier_scope`, resolves it via `CcxtExtract.Tiers.members_for_tier/1` + `class_hierarchy.json`, and only skips when the target exchange is honestly out of scope. Full-universe runs then flag a missing classified exchange loudly. Drop the `:tier3_corpus` ExUnit exclusion and the `@tag` decoration once the helper lands. Discovered 2026-04-20 during Task 117 code review — deferred to keep the spec-size commit focused. |
| Task 121 | ⬜ | 🎁 **method-descriptors** · Extract unified-method descriptors from CCXT TS — TS signature + JSDoc overlay [D:6/B:7/U:8 → Eff:1.25] 🚀 — CCXT's unified methods in `priv/ccxt/ts/src/` carry **two complementary axes of contract information** that together define the unified-method descriptor: **(a) the TS method signature itself** — ordered `.value.params` array with `.name`, `.typeAnnotation.typeAnnotation` (TS type), `.optional` flag (or trailing `?`), and `.right` (default value), plus the return-type annotation — and **(b) a leading JSDoc block** adding per-param prose descriptions, `@throws {ErrorClass}` entries, and a `@returns {Promise<T>}` shape. The TS signature is the structural source of truth (name/type/optional/default/return-type). JSDoc is the semantic overlay (description, error taxonomy, return-type prose). **Both halves matter — don't ship JSDoc alone.** Methods with complete TS signatures and no JSDoc still emit useful structural descriptors; JSDoc without the TS signature would be an incomplete consumer contract. Goal: extract both axes via an OXC pass over method definitions and emit a unified-method descriptor per method so each downstream client maps it to its own arg-shape convention (ccxt_client's Elixir-side `exchange:` + kwlist opts, a future Rust port's `&self, ..., Options`, etc.). **Do not encode any single consumer's arg-shape convention in the descriptor** — that's a client concern. Leave the emission shape (nested under `structure.unified_endpoints.<name>.descriptor`, or a sibling `structure.unified_method_descriptors` map, or corpus-level dedup) to the implementer — current shape of `unified_endpoints` is one honest anchor. **Extraction approach:** the TS-signature half is mechanical — OXC already exposes `.value.params` on method definitions; same AST traversal other extractors use. The JSDoc half is the unknown: OXC's ESTree does not include leading-trivia comments by default; verify whether OXC 0.7 surfaces JSDoc blocks through `node.leadingComments`, a program-level comments array, or requires a `preserve_comments`-equivalent second pass. If trivia is unreachable, QuickBEAM fallback over the TS source is the safety valve — but don't reach for it before checking. **Provenance:** both halves emit as `raw`. Partial descriptor is expected and honest: a method with a TS signature but no JSDoc emits `params: [%{name, ts_type, optional, default, description: null}, ...]` not empty description strings; `errors: null` with `unresolved_reason: "no_throws_annotation"` when JSDoc omits `@throws`; same for `returns`. Don't canonicalize TS type names into a portable type system, don't map `@throws` classes to an atom taxonomy — both are consumer concerns. **Receipts (`descriptor.source`):** while extracting TS signature + JSDoc overlay, also emit `descriptor.source` as the byte-for-byte method body slice from `priv/ccxt/ts/src/<file>.ts` using OXC's `.start`/`.end` offsets on the method AST node. Provenance: `raw` (pure substring — no whitespace normalization, no line-ending normalization, no trimming). Scope: **just the method body, not the surrounding class, not imports, not leading/trailing trivia** — the slice starts at `method.start` and ends at `method.end` exactly as OXC reports them. Value: the JSON descriptor becomes self-verifying — agents and humans consuming the descriptor via `CCXT.describe/2` / `CCXT.MCP.tools/0` can inspect the upstream source that backs each claim without a second network hop or `git clone ccxt`. Expected size: on the order of 20–50KB per exchange of added source text across its unified-method surface — comfortably within the Task 116/117 spec-size headroom. Long method bodies (e.g. binance's `sign()` ~200 lines) emit in full; trimming would undermine the receipts property and re-introduce the "summary vs reality" gap this field is explicitly closing. This turns the descriptor from *summary of what CCXT does* into *summary + the source text that proves it*. **Honest success:** same scope flags produce deterministic output across runs; methods with TS-only signatures emit structural descriptors; missing JSDoc never produces fabricated defaults. **Cross-repo:** on landing, flip ⬜ on `../ccxt_client/ROADMAP.md` Task 109 — the macro layer reads `__spec__()["unified_endpoints"]["<name>"]["descriptor"]` and composes TS structural params + JSDoc overlay with ccxt_client's hand-authored Elixir arg-shape convention (`exchange:` first arg, kwlist opts, etc.). Discovered 2026-04-21 during descripex surface audit — ccxt_client tidewave (port 4003) already serves `CCXT.describe/2` and `CCXT.MCP.tools/0` from hand-written annotations; this task moves the source of truth upstream while keeping language-specific arg-shape decisions with each consumer. |
| Task 122 | ⬜ | 🎁 **method-descriptors** · Schema block + `unified_method_descriptors_shape_valid` contract-test invariant for Task 121's output [D:3/B:4/U:5 → Eff:1.5] 🚀 — depends on 121. Add the chosen emission shape to the JSON Schema file (additive minor-version bump, not breaking, unless the implementer intentionally promotes to `required`), add shape invariant mirroring `testnet_urls_shape_valid`'s structure, and extend `CcxtExtract.Provenance.section_pointers/0` so `provenance_covers_schema` stays at zero findings. Update [SCHEMA.md](SCHEMA.md) with a field reference and the descriptor value space (what `params` looks like, how `errors` is scoped, when fields are null + reason). |
| Task 123 | ✅ | Recurse into nested `*.private` sub-sections when computing `structure.authenticated_sections` [D:3/B:8/U:6 → Eff:2.33] 🎯 — **Shipped 2026-04-24.** See [CHANGELOG.md](CHANGELOG.md). Historical description follows. — **Blocks 234 ccxt_client integration-test failures.** htx's spec today emits `structure.authenticated_sections: ["private", "v2Private"]` (flat, top-level only), but `runtime.describe.api` has nested sections `contract.private`, `contract.public`, `spot.private` (implicit), etc. Consumer-side probes that gate on this list classify every nested-private endpoint as public, call it with no auth, and receive `"Unknown error"` (code `"error"`). Same class of bug affects huobi (twin of htx) — 117 × 2 = 234 failures in `../ccxt_client/test/ccxt/raw_endpoint_probe_test.exs` on the 2026-04-21 run. Scope: extend the `authenticated_sections` derivation (wherever it walks `describe.api`) to recurse one level deeper and collect every `<parent>.<child>` pair whose child name matches `private` / `v2Private` / `privateV3` / etc. (same name-class filter, one level deeper). Emit as nested keys (`["contract.private", "spot.private", ...]`) so consumers can pattern-match on either tier. Success: `htx.authenticated_sections` includes the nested names; the ccxt_client probe cascade clears on re-run. Discovered 2026-04-21 from ccxt_client full-tag integration run (see `ccxt_client/ROADMAP.md` Task 110). |
| Task 124 | ⬜ | Prune Bybit's discontinued `spot/v3/private/*` endpoints from extracted spec [D:4/B:4/U:4 → Eff:1.0] 📋 — Bybit discontinued its V3 Spot Open API as of 2024-08-31 (official notice); live calls return `"We have discontinued Open API V3 services as of August 31 2024. Please refer to the official website announcement and upgrade to Open API V5"`. Upstream CCXT's TS source still lists these endpoints in `bybit.ts`'s `api.spot.v3.private` block, so extraction dutifully emits them into `structure.implicit_endpoints` / `unified_endpoints` — and ccxt_client's probe generator produces tests for them. Scope: three options in rough order of preference — (a) **push a PR upstream to ccxt** removing the dead V3 Spot endpoints (cleanest, but out of our repo); (b) **add an override entry** (JSON-Pointer deletion) under `priv/overrides/bybit/…` once the delete-pointer override semantics are nailed down; (c) **derivation-time filter** that drops endpoint paths known to be deprecated (risk: hardcodes a Bybit-specific policy into generic extraction logic). Discovered 2026-04-21 from ccxt_client full-tag integration run (22 "Open API V3 discontinued" INCONCLUSIVE warnings) — see `ccxt_client/ROADMAP.md` Task 111(b). Not urgent (endpoints are clearly dead, not silently broken), but wasted probe runs + user confusion accumulate. |
| Task 126 | ⬜ | 🎁 **openapi-emit** · Secondary OpenAPI 3.1 emitter for REST exchanges (the majority of CCXT) [D:6/B:7/U:5 → Eff:1.0] 📋 — Emit a sibling `priv/output/<id>.openapi.json` ([OpenAPI 3.1 spec](https://spec.openapis.org/oas/v3.1.0)) alongside the core `<id>.json` for every REST exchange. OpenAPI is the dominant descriptor for REST APIs (paths, verbs, params, request/response schemas, auth, servers) with a large ecosystem: Swagger UI, `openapi-generator` (Rust/Go/Python/TS/Java/… client codegen), Postman import, Prism mock servers, Stoplight editors. Scope: a new emitter (conceptually `CcxtExtract.OpenApi`) that projects already-extracted data — `structure.url_templates` → `servers[]` + `paths`, verb families in `runtime.describe.api` → HTTP `operations`, Task 121 unified-method descriptors (TS signature + JSDoc) → `parameters` / `requestBody` / `responses` schemas, `@throws` entries → `responses` error codes, `handle_errors` regex routing → `x-ccxt-error-routes` extension. Load-bearing exchange concerns that OpenAPI doesn't model natively land in namespaced extensions — `x-ccxt-sign` (reference into the core spec's `sign_recipe`, not duplicated), `x-ccxt-rate-limit` (token bucket + per-endpoint cost), `x-ccxt-sandbox-servers` (testnet switching), `x-ccxt-nonce` (nonce convention). Non-goals: **don't** replace the core schema (`exchange_v3.json` stays the source of truth — richer than OpenAPI for this domain); **don't** duplicate payloads between the core spec and the OpenAPI sibling (emit references like `$ref` / extension pointers so regeneration stays deterministic); **don't** fabricate response schemas for operations whose response shape hasn't been extracted (emit `responses.default` with `application/json` + empty schema + `x-ccxt-unresolved: "no_response_schema"` rather than lying). Verification: pipe each emitted doc through `openapi-generator validate` AND round-trip through Swagger Editor for a sampled set of priority exchanges; a Mix task should fail the emit if the document doesn't validate. Honest dependency: high-quality `parameters` / `requestBody` / `responses` fields depend on Task 121 (TS-signature + JSDoc descriptors). Pre-121 emission is valid but schemas degrade to `{"type": "object"}` — still useful for codegen-ing clients that forward params through, less useful for typed consumers. WebSocket surface is out of scope here — that's AsyncAPI territory and becomes its own sibling task if/when demand surfaces. Discovered 2026-04-23 during scope conversation (reframing of Task 125). Strategic position: this is the **primary** companion-artifact emitter; the OpenRPC variant (Task 125) is the narrow JSON-RPC tail. Shared emitter infrastructure (extension-namespace conventions, validation harness, write-path integration with `Pipeline`) lands here first. |
| Task 125 | ⬜ | 🎁 **openrpc-emit** · Secondary OpenRPC emitter for JSON-RPC exchanges (Deribit first) [D:3/B:3/U:2 → Eff:0.83] ⚠️ — **Depends on Task 126** (shared emitter infrastructure: extension-namespace conventions, validation harness, write-path integration). Emit an [OpenRPC 1.3](https://spec.open-rpc.org/) document alongside `priv/output/<id>.json` **only** for exchanges whose transport is JSON-RPC 2.0 (Deribit is the canonical case; audit `runtime.describe.urls.api` + sign-method shape to find the full set — likely ≤3 exchanges). OpenRPC is the JSON-RPC analogue of OpenAPI: a standardized descriptor for method names, param schemas, result schemas, error objects, links, and examples. Existing OpenRPC consumers include Ethereum tooling, a Playground UI, and several code-generators (TS/Rust/Python). Scope after Task 126 lands: reuse the shared emitter scaffolding, project the JSON-RPC subset — unified method names → OpenRPC `methods[]`, Task 121 TS-signature params → `params[].schema`, `@throws` entries → `errors[]`, response parse-method shape → `result.schema`. Write to `priv/output/<id>.openrpc.json`. Gate on an `openrpc_eligible` classifier (`runtime.describe` evidence), not a hardcoded allowlist. Non-goals: **don't** shoehorn REST exchanges into OpenRPC (fundamental transport mismatch — OpenRPC assumes a uniform JSON-RPC envelope that REST endpoints don't have); **don't** replace the core schema. Verify each emitted document with the OpenRPC Playground or `@open-rpc/schema-utils-js` validator. Discovered 2026-04-23 during scope conversation. U:2 reflects structural reach, not a demand claim: the JSON-RPC transport constraint makes this inapplicable to the REST majority of CCXT's surface regardless of consumer interest. Promote if JSON-RPC consumers show up or if the OpenRPC toolchain becomes a consumption path worth targeting proactively. |
| Task 117 | ✅ | 🎁 **spec-size · B** · Shipped 2026-04-20 — schema 3.0.0 prune with breaking schema rename. See [CHANGELOG.md](CHANGELOG.md). Historical description of discovered-work follows. Three mechanical drops, each proven dead via cross-repo grep of `ccxt_client/{lib,test}/`. **(1) Replace `runtime.markets.markets` with `runtime.symbols_index`.** The resolved `loadMarkets()` snapshot is 85% of every large exchange (`binance.runtime.markets` = 23.6MB compact). Only live reader is `ccxt_client/test/support/test_generator/symbol_resolver.ex`, which reads symbol keys plus per-symbol `type == "spot"` / `type == "swap"` flags for `first_market/2` fallback — never `price`, `precision`, `fees`, `limits`, `info`, `baseId`, or `quoteId`. New shape: `%{"BTC/USDT" => %{spot: true, swap: false}, ...}`. Binance 23.6MB → ~30KB on this field. **(2) Drop `structure.parse_methods`.** Zero live readers in `ccxt_client/lib/` or `test/` — only a `test/ccxt/spec_test.exs:43-46` presence assertion (ccxt_client Task 105 updates it). 24.5MB across corpus. **(3) Drop `structure.ws_methods`.** Same: zero live readers; `lib/ccxt/ws/config.ex:19` reference is a moduledoc comment explicitly arguing *for* removal once upstream surfaces `urls.api.ws` cleanly. 19.8MB across corpus. **Schema work:** bump to 3.0.0, rename to `priv/schema/exchange_v3.json`, remove the two dropped pointers from `Provenance.section_pointers/0` and from the schema's `required` list, re-baseline `provenance_covers_schema`. **Coordination:** land alongside `../ccxt_client/ROADMAP.md` Task 105 (SymbolResolver ~5 LOC + spec_test presence updates) — neither side breaks until both ship. Measurement target: post-116+117 corpus ≤ 90MB (≥30% headroom under Hex 128MB cap). Discovered 2026-04-19 during `ccxt_client` spec-size triage. |
| Task 127 | ⬜ | Position-aware `paths_rw_split` sinks + variable-level sanitization [D:5/B:3/U:3 → Eff:0.6] ⚠️ — Task 112's `paths_rw_split` corpus invariant lists `File.cp!`/`cp_r!`/`cp`/`cp_r`/`rename` in `@file_writer_fns`, which is position-unaware: `File.cp!(source, target)` legitimately takes a read-side path as arg 0, so `File.cp!(Paths.priv(...), target)` trips the invariant even though the writer target is unrelated. Follow-up 2026-04-24 worked around it in `pipeline.ex` by rewriting `File.cp!` as `File.write!(target, File.read!(source))` (byte-copy via the sanitizer chain) and by broadening `@file_reader_fns` to include `File.exists?`/`stat`/`ls`/`regular?`/`dir?`/`lstat*` so Reach's chop-level sanitization kills the `ccxt_extract.setup.ex:254-287` false positive where `Paths.priv → File.exists? → … → File.write!(out_version_file(), …)` propagates through control flow. **Both are band-aids.** The chop-level sanitizer mask-bleeds into a theoretical false negative on the pattern `path = Paths.priv(x); if File.exists?(path), do: File.write!(path, data)` — Codex flagged this 2026-04-24. Proper fix: (a) **position-aware sinks** — distinguish write-position args from read-position args on `cp!`/`cp_r!`/`rename`, likely by replacing `paths_rw_sink?/1` with a registry keyed on `{function, arity, write_arg_indices}`; (b) **variable-level sanitization** — ask Reach to sanitize the specific variable that passes through a reader, not every node on the chop, so a subsequent direct variable→sink flow still flags when the sink arg is the original path and doesn't flag when the sink arg is an unrelated value computed in the same function. Variable-level sanitization likely needs a Reach-side change (`Reach.Project.taint_analysis/2` currently marks sanitized = "any node in chop matches", see `deps/reach/lib/reach/project.ex:121-123`); if upstream won't carry it, an ad-hoc shim inside `check_paths_rw_split/1` that re-checks the sink's argument provenance against the sanitizer set would work. Once either lands: narrow `@file_reader_fns` back to content readers (`read`/`read!`/`stream!`/`open`/`open!`), restore `File.cp!` in `pipeline.ex:683`, and delete both TODO blocks. Discovered 2026-04-24 during staged-review of the paths_rw_split sanitizer-broadening change. Inline TODO references at `lib/ccxt_extract/contract_test.ex` (above `@file_reader_fns`) and `lib/ccxt_extract/pipeline.ex:683`. |

**Task 101: Fixture refresh for oxc 0.7 / quickbeam 0.10.** The source migration (AST `:type`/`:kind` string→atom across 12 extractors, error-tuple shape changes, `mix.exs` version bumps) has shipped. What remains is cached: the `parse_methods` coverage threshold is calibrated against fixtures generated before the migration. Run `mix ccxt_extract.update` to regenerate discoveries + outputs, then `mix ccxt_extract.contract_test --strict` to confirm byte-identical output across priority tiers. quickbeam 0.10's JS line coverage (`mix test --cover`) and `Beam.XML.parse` are available but not required.

---

## Phase 8: Client harness + contract tests 🔶

> All reference consumers live in their own git repos as **siblings** of `ccxt_extract/` (e.g. `../ccxt_client/`, future `../<rust-crate>/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but moved back to siblings in Task 56b to stop ccxt_extract's `CLAUDE.md` from being auto-loaded into every client session. `ccxt_extract` stays a pure extractor and ships a contract-test suite that validates the JSON surface without importing client code — catches "Elixir didn't notice this breaks Rust" drift.
>
> **🔗 Every task in this phase requires updating `../ccxt_client/ROADMAP.md` on completion.**

| Task | Status | Notes |
|------|--------|-------|
| Task 57c | ⬜ | 🎁 **9-pipeline-follow-up** · Pattern A/B fixed (341 → 53). Provenance now lands (Task 61a, 2026-04-17) so the honest Pattern C fix is unblocked — tag `has`-confirmed entries as `"derived"` rather than silently filtering. Still deferred until a Tier 1/2/DEX exchange surfaces a Pattern C failure. [D:3/B:5/U:5 → Eff:1.67] 🚀 |

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
| Task 61a `[P]` | ✅ | 🎁 **9-pipeline** · Provenance tagging on raw + derived fields [D:4/B:8/U:8 → Eff:2.0] 🚀 SHIPPED 2026-04-17 — see [CHANGELOG.md](CHANGELOG.md). |
| Task 61b | ✅ | 🎁 **9-pipeline** · Override merge pipeline stage [D:4/B:9/U:9 → Eff:2.25] 🎯 SHIPPED 2026-04-16 — see [CHANGELOG.md](CHANGELOG.md). |
| Task 61c | ✅ | 🎁 **9-contract** · Schema 2.0.0 bump + migration notes in SCHEMA.md [D:2/B:6/U:6 → Eff:3.0] 🎯 SHIPPED 2026-04-17 — see [CHANGELOG.md](CHANGELOG.md). |
| Task 61d | ✅ | 🎁 **9-pipeline** · Provenance-covers-schema contract invariant [D:2/B:5/U:5 → Eff:2.5] 🎯 SHIPPED 2026-04-17 — `mix ccxt_extract.contract_test` now runs `provenance_covers_schema`: fails when a `/runtime/*` or `/structure/*` section emitted by `Pipeline.build_exchange_data/3` is missing from `Provenance.raw_pointers/0 ++ Provenance.derived_pointers/0`, when a declared pointer's key path doesn't resolve in output, or when `_provenance` tags disagree with the raw/derived split. Override-tagged paths always pass. Clean baseline across the full committed corpus. See [CHANGELOG.md](CHANGELOG.md). |
| Task 62 | ⬜ | 🎁 **9-audit** · `mix ccxt_extract.validate_overrides` [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 63 | ⬜ | 🎁 **9-audit** · `mix ccxt_extract.drift_audit` [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 104 | ⬜ | 🎁 **9-pipeline** · Array-index JSON Pointers in `OverrideRegistry` [D:2/B:3/U:2 → Eff:1.5] 📋 — extend `pointer_to_keys/1` to emit `Access.at/1` for numeric segments. Currently raises loudly (see error message). Unblock when a real override file needs `/path/0/...`. |

**Task 60: Override directory contract** — Define `priv/overrides/<exchange>.json` format: JSON Pointer paths into the canonical output, a `value` payload, required `reason`, optional `verified_against` (runtime probe output or CCXT source reference) and `unverified: true` flag. Document in SCHEMA.md. Ship an example override for one exchange.

**Task 61a: Provenance tagging on raw + derived (✅ shipped 2026-04-17)** — Every emitted exchange JSON now carries a top-level `_provenance` map keyed by RFC 6901 JSON Pointers, with values `"raw"` / `"derived"` / `"override"`. `CcxtExtract.Provenance.build_default/0` stamps the default map in `Schema.build_exchange/4`; `Pipeline.apply_exchange_overrides/1` threads applied-pointer paths through the per-entry reduce and `Provenance.stamp_overrides/2` flips them to `"override"` at the tail. Granularity is section + direct children — fine enough to distinguish derivation modules, coarse enough to avoid per-leaf noise. `handle_errors` sub-keys split individually (three raw, two derived). Schema bumped 1.8.0 → 1.8.1 (additive, nullable). Task 61c makes it required at 2.0.0.

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
| Task 64 | ✅ | 🎁 **10-core** · Signing recipe schema design SHIPPED 2026-04-18 at schema 2.2.0 — `structure.sign_recipe` per-section declarative scaffold, all-null records + `unresolved_reason: "not_yet_derived"`, `priv/schema/sign_recipe_v1.json` standalone contract, two contract-test invariants, `/structure/sign_recipe` registered in derived provenance. Pipeline syncs recipe keys with `authenticated_sections` post-override. See [CHANGELOG.md](CHANGELOG.md). |
| Task 65 | ✅ | 🎁 **10-core** · `crypto_op` + `signature_placement` from `sign()` AST — shipped 2026-04-18. See [CHANGELOG.md](CHANGELOG.md). |
| Task 66a `[P]` | ✅ | Shipped 2026-04-19 — schema 2.3.0 per-verb `canonical_string` map. See [CHANGELOG.md](CHANGELOG.md). |
| Task 66b `[P]` | ✅ | Shipped 2026-04-21 — HMAC-with-body family populates the POST slot of the 2.3.0 per-verb map; no schema bump. See [CHANGELOG.md](CHANGELOG.md). |
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
| Task 73c | ✅ | 🎁 **11-request** · Per-method default request body extractor SHIPPED 2026-04-17 at schema 2.1.0 — `structure.request_defaults: method → {key → {value, kind, reason}}` with three resolution tiers (direct literal / `this.extend` unwrap / const-trace with reassignment-aware skip), closed-vocabulary unresolved reasons, `request_defaults_resolvable_reachable_from_unified` contract invariant. hyperliquid.fetch_time golden fixture intact. See [CHANGELOG.md](CHANGELOG.md). |
| Task 73d | ⬜ | 🎁 **11-shape** · Per-endpoint `transactional` / `on_chain` flag [D:4/B:6/U:6 → Eff:1.5] 📋 — Extract a per-endpoint boolean (or small enum) marking endpoints whose POST body is a signed on-chain transaction rather than an authenticated API mutation. **Detection signals:** signed-payload helpers (`signTx`, `signTransaction`, `signL1Action`, `signEIP712`), web3 / EIP-712 typed-data builders, on-chain submission helpers (`sendTx` / `sendTxBatch` style), DEX-specific signing imports. **Why:** consumers (ccxt_client, others) need to distinguish "authenticated mutation requiring API credentials" from "public on-chain broadcast requiring wallet signing." Both are POST writes but the credential/safety model is different. Today the lighter spec emits `public_post_sendtx` / `public_post_sendtxbatch` as `authenticated: false`, which is correct as far as `authenticated_sections` goes — but downstream consumers can't tell from that alone whether the endpoint is a benign public-read POST (kucoin `bullet-public`) or a signed on-chain broadcast that should be tagged as a write-path probe. **Will only get worse as more DEXes are added** (hyperliquid, derive, lighter today; more in priority-tier scope as the DEX list grows). **Consumer uptake:** ccxt_client Task 117 — replaces `RawEndpointProbe.Config.treat_post_as_safe?/1` (currently hardcodes `derive` + `hyperliquid`) with a spec-driven read; may collapse the `:public_dangerous` / `:private_dangerous` auth-class split (T108b) into a uniform classification. |

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
| Task 91 | ⬜ | 🎁 **15-msg** · WS subscribe / unsubscribe message shape per channel [D:5/B:8/U:8 → Eff:1.6] 🚀 — **scope:** ship both the frame envelope shape *and* per-method channel-name templates (e.g. `"tickers.{symbol}"`, `"book.{symbol}.raw"`). ccxt_client T94 already ports envelope patterns from bak; T97 is blocked on the channel templates specifically. |
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
| Task 100 | ✅ | 🎁 **16-testnet** · Testnet/sandbox URL catalog [D:2/B:5/U:6 → Eff:2.75] 🎯 SHIPPED 2026-04-19 — new `runtime.testnet_urls` derived field with `pattern` enum (`separate_host` / `sandbox_flag` / `none`), `{hostname}` pre-resolution, independent `sandbox_flag_field` for `options.sandboxMode` detection. Schema 2.3.0 → 2.4.0 (additive). New `testnet_urls_shape_valid` contract invariant. Unblocks ccxt_client T61. See [CHANGELOG.md](CHANGELOG.md). |

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

**Three-tier JSON is the target contract.** Once Phase 9 fully ships, output will merge raw extraction + derived analysis + curated overrides with per-field provenance. **Current state (2026-04-17):** Tasks 60, 61a, 61b shipped — overrides apply end-to-end via `OverrideRegistry.apply_all/2` and each path carries a `_provenance` tier tag (`"raw"` / `"derived"` / `"override"`) at `schema_version: 1.8.1`. Only the Schema 2.0.0 bump (Task 61c) remains, which promotes `_provenance` from additive-nullable to required. Either way, consumers read the emitted JSON; they do not re-derive or walk AST. Contract tests (`mix ccxt_extract.contract_test`, Task 57) enforce cross-field invariants so drift surfaces before it reaches a consumer.

**Versioning follows semver** on the `schema_version` field. See [SCHEMA.md](SCHEMA.md).

---

## Notes

- Task descriptions are prompts for Claude to implement — explore the codebase and discover the right approach. See `CLAUDE.md` for session-size, honesty-rule, and three-tier contract guidance.
- Previous "Anti-Bias Rule" and "Extraction vs Interpretation" framings are retired. The replacement rule: every value is provable or explicitly unprovable; interpretation happens in derivation + overrides, not in consumers.
- `[Codex]` marker — tasks suitable for Codex/OpenAI delegation: self-contained, no OXC/QuickBEAM NIF deps. Phase 10–16 tasks touch AST or runtime and generally stay in-house.
- `[P]` marker — task can run in parallel with its siblings in the same phase. Many per-type parse tasks and per-family signing tasks carry `[P]`.
- Raw AST remains in the output. Consumers may inspect it for debugging or novel needs, but a consumer that *requires* walking AST to operate exposes a gap the roadmap should close.
- **Source of truth is CCXT, not exchange docs.** See [CLAUDE.md §"Source of truth: CCXT, not exchange docs"](CLAUDE.md#source-of-truth-ccxt-not-exchange-docs). Exchange vendor docs enter only as override `verified_against`, Tier 1 gap enrichment (tracked as a task), or a future third-source verification layer — never as a primary extraction target. Proposals to replace CCXT extraction with doc-reading are a 110× work multiplier without reliability gains.
