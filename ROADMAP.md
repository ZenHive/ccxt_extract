# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON so any consumer — in any language — can operate an exchange without walking AST.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Contract reference:** See [CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md) for the unfiltered list of what a consumer needs. Phases 10–16 tick items off that checklist.

**Schema contract:** See [SCHEMA.md](SCHEMA.md) for field-level definitions and version history of the emitted JSON.

> **🔗 Cross-repo rule (applies to EVERY task in this roadmap):** When a task ships, lands, or changes status, the implementer MUST also update `../ccxt_client/ROADMAP.md` — mark any dependent ccxt_client task as unblocked, flip its status, or add a new follow-up entry. A ccxt_extract task is **not complete** until its downstream ccxt_client impact is reflected there. The two roadmaps are a single contract surface viewed from two sides.

---

## 🎯 Current Focus

**Priority goal: endpoint-invocation contract (serves unified + non-unified).** The critical path is **signing → request building → rate limits**. These phases unlock both raw (implicit) and unified endpoints — anything you'd call needs them. Only Phase 12 (response parsing) is unified-specific (i.e., CCXT's normalized method surface like `fetchTicker`/`createOrder`, as opposed to raw implicit endpoints) and thus deprioritized. See [Endpoint-Invocation Priority Order](#endpoint-invocation-priority-order) below.

**Phase 8 — Client harness + contract tests** complete; Task 57c is the only holdover and is now unblocked after Task 61a provenance shipped (2026-04-17). The target output is a three-tier merge (raw / derived / override). The **generic JSON-Pointer override contract shipped with Task 60** (see CHANGELOG) — override files use RFC 6901 paths, a `value` payload, required `reason`, and `verified_against`/`unverified` flags, validated by `CcxtExtract.OverrideRegistry` and the `override_registry_valid` contract-test invariant. The **generic merge stage shipped with Task 61b** (2026-04-16). **Task 61a shipped 2026-04-17** — every emitted JSON carries a `_provenance` map tagging each section as raw/derived/override; override-applied paths flip to `"override"` at the tail of `Pipeline.extract/1`. **Task 61c shipped 2026-04-17** — `_provenance` is now required and non-null at `schema_version: 2.0.0`; JSON Schema file renamed `exchange_v1.json` → `exchange_v2.json`; SCHEMA.md has migration notes. **Task 61d shipped 2026-04-17** — `provenance_covers_schema` contract-test invariant now fails loudly on drift between `Pipeline`-emitted sections and the `Provenance` declared pointer lists. Phase 9 contract is fully hardened; remaining Phase 9 items (62 validate_overrides, 63 drift_audit, 104 array-index pointers) are additive. **Task 64 shipped 2026-04-18** — Phase 10 opens with the `structure.sign_recipe` scaffold at schema 2.2.0. **Task 65 shipped 2026-04-18** — `crypto_op` + `signature_placement` now populated via the new `CcxtExtract.SignRecipe.Derive` module. **Task 66a shipped 2026-04-19** — `canonical_string` per-verb map at schema 2.3.0; first-run coverage populates `okx.private.GET` with `[timestamp, method, path, literal("?"), query]`. **Task 66b shipped 2026-04-21** — HMAC-with-body family now populates alongside hmac_simple; `okx.private.POST` emits `[timestamp, method, path, body]` with `family: "hmac_with_body"`. No schema bump (schema 2.3.0 already enumerated `hmac_with_body` + `source: body`; 66b filled the slot). Narrow addition: `@body_names` identifiers (`body`/`bodyPayload`) are exempt from the reassigned-filter in `classify_piece/2` because their name IS the authoritative body source tag in CCXT sign(). **Task 67 shipped 2026-04-24** — `auth_headers` + `nonce` populated on priority exchanges via new `AuthHeaders` / `Nonce` modules; shared AST tree-walkers extracted into `ASTHelpers`. Coverage: 6 priority exchanges with populated auth_headers (okx, coinbaseexchange, gate, kraken, bitfinex, aster), 5 more sections with honest empty-list (deribit, htx × 4), and ~17 sections total with populated nonce. Gate's timestamp chain (`timestampString → timestamp → parseToInt(nonce/1000) → this.nonce()`) resolves via a terminal-binding filter + identifier-chain resolver that picks the wire value over intermediate bindings. Kucoin's `this.extend({...}, headers)` init shape + conditional partner block are tracked as an MVP gap — nonce populates, auth_headers stays null. No schema bump (the 2.3.0 `auth_headers` / `nonce` slots were defined by Task 64). **Task 69 shipped 2026-04-24** — biconditional honesty contract now enforced: `SignRecipe.Derive` auto-flips `unresolved_reason` from `"not_yet_derived"` → `null` whenever every one of the six derivation fields is non-null, and the new `sign_recipe_honesty_valid` contract invariant fails loudly on any drift in the other direction. **Task 68 shipped 2026-04-24 — Phase 10 closes.** `pre_sign_transforms` now derives via the new `PreSignTransforms` module (three-pass detector: digest of `this.hmac(…)` 4th arg, `body = this.json(…)` encoding when consumed by crypto, post-signature `urlencode`/`encodeURIComponent`/`toLowerCase` wrappers). **okx.private is the first recipe in the project to auto-flip `unresolved_reason` to `null`** — all six derivation fields populate end-to-end. Seventeen sign_recipe entries across nine priority exchanges (aster/bitfinex/bitmex/coinbaseexchange/deribit/gate/htx/kraken/kucoin) now carry a populated `pre_sign_transforms`; htx emits the composite `[base64_encode, url_encode]` stack proving the post-signature detector. Terminal exchanges (binance/bybit ambiguous_ast, hyperliquid/derive/lighter custom_signing_family) correctly emit null. No schema bump — the 2.2.0 slot fills. Zero `sign_recipe_honesty_valid` findings; schema round-trip passes for every regenerated exchange. Next endpoint-invocation priority: 🎁 **11-shape** (Tasks 70 + 71 — HTTP verb + path template + body encoding).

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
| 3 | 🎁 **10-core** ✅ | 64 ✅, 65 ✅ | Signing recipe schema + crypto op / signature placement — shared `sign()` AST walker |
| 4 | 🎁 **10-HMAC** `[P]` ✅ | 66a ✅, 66b ✅ | HMAC-simple + HMAC-with-body — same canonical-string derivation |
| 5 | 🎁 **9-pipeline** | 61a, 61b | Provenance tags + override merge stage — both pipeline plumbing. **Unblocks Task 57c** (unified_endpoints/has drift triage) |
| 6 | 🎁 **11-shape** | 70, 71 | Verb + path template + body encoding — single section-level AST pass (**next up** — Phase 10 closed, this is the next endpoint-invocation critical-path bundle) |
| 7 | 🎁 **10-finish** ✅ | 67 ✅, 68 ✅, 69 ✅ | Headers/nonce + transforms + round-trip validation — **all three shipped 2026-04-24; Phase 10 closes.** okx.private is the first recipe to auto-flip `unresolved_reason` to `null`. |
| 8 | 🎁 **11+14** | 72, 73, 73b, 89, 90 | Timestamps, headers, rate-limit buckets + per-endpoint cost — all from `rateLimit`/`cost` annotations |
| 9 | 🎁 **10-exotic** | 66c, 66d | JWT/RSA/Ed25519 + custom/outlier signing families — **deferred to Superseded/Deferred** (no priority exchange uses these) |
| 10 | 🎁 **9-audit** | 62, 63 | validate_overrides + drift_audit — both auditing tooling |
| 11 | 🎁 **13-classify** | 85, 86, 87 | HTTP status map + retry classification + class hierarchy export |
| 12 | 🎁 **13-dispatch** `[P]` | 88a, 88b, 88c | Handler routing tables (error/signing/parse) |
| 13 | 🎁 **spec-size** ✅ | 116 ✅, 117 ✅ | Compact encoding (A, shipped 2026-04-19, 54.4% on binance) + dead-weight prune with schema 3.0.0 breaking change (B, shipped 2026-04-20, 91.6% additional on binance). Together cleared ccxt_client Hex 128MB publish cap with substantial headroom. |
| 14 | 🎁 **10-sign-extend** | 66e, 66f, 66g, 66h, 113 | Sign-recipe derivation patches — shared AST walker (`CcxtExtract.SignRecipe.*`). All extend the same sign() traversal infrastructure; small ones (66g) are plausibly batch-shippable when sign_methods.json is already loaded. |
| 15 | 🎁 **scope-hygiene** `[P]` | 13b, 119, 120 | Tier-scope drift cleanup: envelope test migration, `mix ccxt_extract.prune` task, scope-aware test skips. 13b + 120 share an envelope-reading helper and could ship together. |
| 16 | 🎁 **sibling-emit** | 126, 125 | OpenAPI + OpenRPC secondary emitters — shared emitter infrastructure (extension-namespace conventions, validation harness, `Pipeline` write-path integration). 126 first (REST majority); 125 reuses the scaffolding for the JSON-RPC tail. |

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

Tasks 68, 69, 67, 123, 66b, 117, 116, 100, 66a, 65, 64, 61d, 61c, 61a, 37, 60, 58, 57d, 56b, 57b, 59, 57, 56, 55, 54, 53, 52, 49, 47, 46 — see [CHANGELOG.md](CHANGELOG.md).

### 📋 Next Up
| Task | Status | Notes |
|------|--------|-------|
| Task 57c | ⬜ | Now unblocked (61a shipped). Pattern A/B fixed (341 → 53); Pattern C residual can tag `has`-confirmed entries as `"derived"` at the provenance tier instead of silently filtering. |

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
| Task 105 `[CSR]` | ⬜ | Port `super.*()` delegation coverage off coincatch [D:2/B:3/U:2 → Eff:1.25] 📋 — coincatch was removed upstream; the test that validated `parse_file/1` walking a super-delegation chain was deleted in Task 101. Find another currently-shipping exchange with a non-trivial `super.*()` chain and reinstate targeted coverage, otherwise `parse_file` regressions on that code path escape. TODO marker at `test/ccxt_extract/unified_endpoints_test.exs`. |
| Task 13b `[CSR]` | ⬜ | 🎁 **scope-hygiene** · Universal envelope `tier_scope` stamping — test-migration half [D:2/B:3/U:3 → Eff:1.5] 🚀 — depends on 13a. Migrate 9 cached integration tests from observed-count dispatch to envelope dispatch and shrink `test/support/scope_thresholds.ex` to just `proportional/2` (or delete). Three tracked `TODO(scope-envelope):` markers: `test/support/scope_thresholds.ex:22`, `test/integration/method_analysis_integration_test.exs:52`, `test/integration/public_exchanges_integration_test.exs:46`. |
| Task 106 `[CSR]` | ⬜ | Drifted-override fixture for `override_paths_present_in_output` [D:2/B:3/U:3 → Eff:1.5] 🚀 — the contract-test invariant today only exercises the 0-finding case (see `test/ccxt_extract/contract_test_test.exs`). Add a fixture that injects a drifted override (pointer value absent from output) once `ContractTest.run_all/1` threads overrides through `observed`. Discovered during Task 61c. |
| Task 109 `[CSR]` | ⬜ | Promote `finding()` map type to a `%Finding{}` struct [D:2/B:2/U:2 → Eff:1.0] 📋 — `CcxtExtract.ContractTest.@type finding :: %{...}` is constructed in five builder sites with identical `{exchange, invariant, path, message}` key sets. Replacing with a `defstruct [:exchange, :invariant, :path, :message]` + `@enforce_keys` gains compile-time key validation and silences the recurring `struct-hint` post-edit hook. Must `@derive Jason.Encoder` so `priv/output/_contract_test_report.json` stays free of `__struct__` keys, and re-verify that `Enum.sort/1` over findings produces the same ordering for downstream consumers. Discovered during Task 61d code review. |
| Task 110 `[CSR]` | ⬜ | Triage 32 `request_defaults_resolvable_reachable_from_unified` findings [D:4/B:4/U:4 → Eff:1.0] 📋 — Baseline full-corpus run surfaces 32 helper-method findings (e.g. `bybit.fetchSpotMarkets`, `coinbase.fetchAccountsV2`, `binanceus.borrowIsolatedMargin`). These helpers get request-body literals extracted and ARE called transitively from a unified method, but `unified_endpoints` values store interface method names (`publicGetX`), so the reachability check can't see the call chain. Either (a) add a transitive-call analysis that walks unified method bodies for `this.<helper>()` calls, or (b) maintain a committed baseline allowlist like `priv/contract_test/error_code_fields_roots.json`. Discovered during Task 73c. |
| Task 113 | ⬜ | 🎁 **10-sign-extend** · Track indirect signature placement via `request`-like object construction [D:4/B:3/U:3 → Eff:0.75] 📋 — htx (and likely a handful of others) build `const request = {..., Signature: signature}` then `url += '?' + this.urlencode(request)`. The placement is genuinely `query` with key `Signature`, but the initial Task 65 derivation only tracks direct `query = ...` / `headers['K'] = ...` / `body = this.json({...})` assignments. Add an object-level propagation step: when an ObjectExpression with a sig-referencing property is bound to a variable, follow the variable into subsequent `url += '?' + this.urlencode(<var>)` / `body = this.urlencode(<var>)` statements and attribute the placement accordingly. Discovered during Task 65 (htx.private ships with `signature_placement: null` until this lands). |
| ~~Task 113~~ (LFS) | ⛔ Superseded | Resolved 2026-04-18 by the chore untracking `priv/output/` and `priv/discoveries/*` (except `class_hierarchy.json`). LFS is moot once the paths aren't in the index. See [CHANGELOG.md](CHANGELOG.md) entry "stop tracking derived extraction corpus". The residual follow-up is **Task 114** below (audit extraction determinism). |
| Task 114 | ⬜ | Audit extraction determinism so the corpus becomes re-committable [D:6/B:6/U:5 → Eff:0.92] 📋 — Untracking (2026-04-18) stopped the bleeding but the root cause is churn, not size: every `mix ccxt_extract.update` produces ~110-file diffs even when upstream CCXT didn't change. Identify and eliminate non-deterministic sources: `generated_at` timestamps, map iteration order through JSON encoding, `AggregateWriter.merge/2` ordering semantics under scoped runs, silent upstream CCXT version drift. Success criterion: same CCXT version + same bundle + same scope → byte-identical output across runs. Once stable, revisit whether to re-track `priv/output/` — size becomes acceptable if diffs are meaningful and infrequent. |
| Task 115 `[CSR]` | ⬜ | Self-healing `mix ccxt_extract.setup` — auto-provision `priv/ccxt` [D:3/B:5/U:7 → Eff:2.0] 🚀 — `lib/mix/tasks/ccxt_extract.setup.ex:47` currently calls `check_ts_source/0` and hard-fails if `priv/ccxt/ts/src` is absent. Fresh clones must sparse-clone manually before `mix setup` can run (see README Step 1). Make setup detect absence and do the sparse clone itself (depth-1, sparse-checkout `ts/src` + optionally `package.json`), turning `mix setup` into a true one-command bootstrap. Edge cases: existing `priv/ccxt` with wrong content (detect via `.git` presence + sparse-checkout state, don't overwrite), network failures (preserve any partial clone for retry), opt-out flag for users who want to symlink their own CCXT checkout. Discovered 2026-04-18 during Codex review of the corpus-untracking chore. |
| Task 66e | ⬜ | 🎁 **10-sign-extend** · Expand `canonical_string` component vocabulary [D:4/B:7/U:7 → Eff:1.75] 🚀 — add `source: "nonce"` (Deribit uses both a wall-clock timestamp AND a per-request nonce in the canonical chain; tagging both as `timestamp` produces a consumer-ambiguous recipe), `source: "hostname"` (HTX v1 signs `method + hostname + path + query`), `source: "expiry"` (Phemex signs an `expiryString` field), and an `encoding: "delimited"` mode with explicit separator handling (Gate/HTX/Deribit use `.join("\n")`). Also consider a nested-op component source to capture Kraken's `binaryConcat(encode(url), hash(encode(nonce + body)))` and Gate's `SHA512(body)` slot. Discovered 2026-04-19 during Task 66a — those priority exchanges currently emit null `canonical_string` with `unresolved_reason: "not_yet_derived"`. |
| Task 66f | ⬜ | 🎁 **10-sign-extend** · Key-format disambiguation for Binance/Bybit HMAC branches [D:5/B:6/U:6 → Eff:1.2] 📋 — both exchanges route `if (secret.indexOf('PRIVATE KEY') > -1) { rsa(...)/eddsa(...) } else { this.hmac(...) }`. Task 65 correctly emits `crypto_op: null` with `unresolved_reason: "ambiguous_ast"` for the whole recipe because no single crypto_op is truthful. A future pass could disambiguate by credential format: emit two alternative recipes, or a per-key-format discriminator. Likely overrides territory under the Three-Strikes Rule rather than a derivation extension. Discovered 2026-04-19 during Task 66a; not urgent because priority consumers currently use HMAC keys exclusively. |
| Task 66g `[CSR]` | ⬜ | 🎁 **10-sign-extend** · Sub-verb expansion (POST vs PUT vs DELETE vs PATCH) in `canonical_string` [D:3/B:3/U:3 → Eff:1.0] 📋 — `CanonicalString.flip_verb/1` currently maps the else-of-GET branch to `"POST"` for every non-GET verb. Consumers applying the POST recipe to PUT/DELETE/PATCH get the right canonical today because no priority exchange distinguishes those verbs inside sign() — they all fall into the same else-branch. Expand only when a sign() method actually tests `method === 'PUT'` / `=== 'DELETE'` / `=== 'PATCH'` distinctly. Discovered 2026-04-21 during Task 66b. TODO marker at `lib/ccxt_extract/sign_recipe/canonical_string.ex` above the `flip_verb/1` clauses. |
| Task 66h | ⬜ | 🎁 **10-sign-extend** · Trace conditionally-reassigned body alias variables (kucoin `endpart`, coinbase `payload`) [D:5/B:4/U:4 → Eff:0.8] 📋 — kucoin's `let endpart = ''; if (method !== 'GET') endpart = body; auth += endpart` and coinbaseexchange's `let payload = ''; if (method !== 'GET') payload = this.json(body); auth += payload` pattern. Both currently emit `canonical_string: null` at the recipe level with `unresolved_reason: "not_yet_derived"` — Task 66b's `@body_names` exemption is deliberately narrow (the identifier `body`/`bodyPayload` by name only), so `endpart` and `payload` (the latter lives in `@path_names`) stay honestly null. A future pass would walk conditionally-reassigned identifiers whose RHS in each branch is itself a recognized body-shaped expression (`body`, `this.json(...)`, `this.urlencode(...)`), propagating the source tag per-verb. Risk: over-permissive tracing could mistakenly tag an unrelated identifier as body. Safer to ship overrides under the Three-Strikes Rule if a priority consumer needs kucoin/coinbase POST canonicals before the generic analysis lands. Discovered 2026-04-21 during Task 66b. |
| Task 118 `[CSR]` | ⬜ | 🎁 **spec-size · cleanup** · Delete `priv/schema/exchange_v2.json` after one-release grace window [D:1/B:2/U:2 → Eff:2.0] 📋 — Following the Task 61c → Task 107 precedent, Task 117 kept `exchange_v2.json` alive for one release alongside the new `exchange_v3.json`. Delete it in the next release cycle once downstream consumers have confirmed migration. Since `Schema.schema_filename/0` centralizes the reference (Task 108), the actual deletion is a `git rm` plus any stale test asset cleanup. Discovered 2026-04-20 during Task 117. |
| Task 119 `[CSR]` | ⬜ | 🎁 **scope-hygiene** · `mix ccxt_extract.prune` — evict out-of-scope local state [D:4/B:5/U:4 → Eff:1.13] 📋 — `AggregateWriter.merge/2` is intentionally additive so successive scoped runs accumulate, which means `priv/discoveries/` (both per-exchange subdirs like `describe/<id>.json`, `load_markets/<id>.json` and envelope aggregates like `methods_rest.json`, `sign_methods.json`, `url_templates.json`, `exchanges.json`, …) drift out of sync with the declared scope: on 2026-04-20 `priv/output/` held the 23 priority-tier files while `describe/` held 107 (86 out-of-scope) and `load_markets/` ~103. Everything except `class_hierarchy.json` is gitignored, so the safety rail never fires and `git status` can't see the drift — a scoped re-run won't evict these either. Task scope: a new mix task that accepts the same `--tier*/--all/--exchange ID` / `Paths.out(...)` plumbing as the rest of the pipeline, computes the in-scope ID set via `Tiers.members_for_tier/1` + class_hierarchy, deletes per-exchange files in all `priv/discoveries/<subdir>/` whose ID is out-of-scope (plus the matching `priv/output/<id>.json`), and then re-aggregates every envelope file (`methods_rest.json`, `methods_ws.json`, `sign_methods.json`, `handle_errors.json`, `interface_signatures.json`, `pagination.json`, `parse_methods.json`, `request_defaults.json`, `url_templates.json`, `ws_methods.json`, `overrides.json`, `exchanges.json`, `public_exchanges.json`) from only the surviving in-scope per-exchange files — don't touch `class_hierarchy.json` (compile-time load-bearing). Honor `:priv_write_override` so `PrivWriteCase` isolates test runs. `--dry-run` flag to print what would be deleted without touching disk. Safety rail: dry-run by default, require `--force` to actually delete (writes are destructive and hard to reverse without a full `--all` regen). Success criterion: after running with the same scope flags as the prior extraction, the set of IDs present in `priv/discoveries/describe/` equals the set in `priv/output/` equals the set implied by the envelope `by_exchange_id` stamps. Discovered 2026-04-20 from a scope-drift report (23 in `priv/output/`, 107 in `priv/discoveries/describe/`). |
| Task 120 `[CSR]` | ⬜ | 🎁 **scope-hygiene** · Tier-scope-aware skip for `authenticated_sections_integration_test` + `sign_recipe_cached_test` [D:3/B:3/U:3 → Eff:1.0] 📋 — two tests currently paper over scope drift with blunt skips: (a) `test/ccxt_extract/authenticated_sections_integration_test.exs:125-135` returns `[]` unconditionally for any override whose `priv/output/<id>.json` is absent, losing regression detection on full-universe runs for classified exchanges; (b) `test/integration/cached/sign_recipe_cached_test.exs:55-66` uses `@tag :tier3_corpus` + default-exclude via `test_helper.exs` to bypass bitget. Replace both with a scope-aware helper that reads `_manifest.json`'s `tier_scope`, resolves it via `CcxtExtract.Tiers.members_for_tier/1` + `class_hierarchy.json`, and only skips when the target exchange is honestly out of scope. Full-universe runs then flag a missing classified exchange loudly. Drop the `:tier3_corpus` ExUnit exclusion and the `@tag` decoration once the helper lands. Discovered 2026-04-20 during Task 117 code review — deferred to keep the spec-size commit focused. |
| Task 121 `[CSR]` | ⬜ | 🎁 **method-descriptors** · Extract unified-method descriptors from CCXT TS — TS signature + JSDoc overlay [D:6/B:7/U:8 → Eff:1.25] 🚀 — CCXT's unified methods in `priv/ccxt/ts/src/` carry **two complementary axes of contract information** that together define the unified-method descriptor: **(a) the TS method signature itself** — ordered `.value.params` array with `.name`, `.typeAnnotation.typeAnnotation` (TS type), `.optional` flag (or trailing `?`), and `.right` (default value), plus the return-type annotation — and **(b) a leading JSDoc block** adding per-param prose descriptions, `@throws {ErrorClass}` entries, and a `@returns {Promise<T>}` shape. The TS signature is the structural source of truth (name/type/optional/default/return-type). JSDoc is the semantic overlay (description, error taxonomy, return-type prose). **Both halves matter — don't ship JSDoc alone.** Methods with complete TS signatures and no JSDoc still emit useful structural descriptors; JSDoc without the TS signature would be an incomplete consumer contract. Goal: extract both axes via an OXC pass over method definitions and emit a unified-method descriptor per method so each downstream client maps it to its own arg-shape convention (ccxt_client's Elixir-side `exchange:` + kwlist opts, a future Rust port's `&self, ..., Options`, etc.). **Do not encode any single consumer's arg-shape convention in the descriptor** — that's a client concern. Leave the emission shape (nested under `structure.unified_endpoints.<name>.descriptor`, or a sibling `structure.unified_method_descriptors` map, or corpus-level dedup) to the implementer — current shape of `unified_endpoints` is one honest anchor. **Extraction approach:** the TS-signature half is mechanical — OXC already exposes `.value.params` on method definitions; same AST traversal other extractors use. The JSDoc half is the unknown: OXC's ESTree does not include leading-trivia comments by default; verify whether OXC 0.7 surfaces JSDoc blocks through `node.leadingComments`, a program-level comments array, or requires a `preserve_comments`-equivalent second pass. If trivia is unreachable, QuickBEAM fallback over the TS source is the safety valve — but don't reach for it before checking. **Provenance:** both halves emit as `raw`. Partial descriptor is expected and honest: a method with a TS signature but no JSDoc emits `params: [%{name, ts_type, optional, default, description: null}, ...]` not empty description strings; `errors: null` with `unresolved_reason: "no_throws_annotation"` when JSDoc omits `@throws`; same for `returns`. Don't canonicalize TS type names into a portable type system, don't map `@throws` classes to an atom taxonomy — both are consumer concerns. **Receipts (`descriptor.source`):** while extracting TS signature + JSDoc overlay, also emit `descriptor.source` as the byte-for-byte method body slice from `priv/ccxt/ts/src/<file>.ts` using OXC's `.start`/`.end` offsets on the method AST node. Provenance: `raw` (pure substring — no whitespace normalization, no line-ending normalization, no trimming). Scope: **just the method body, not the surrounding class, not imports, not leading/trailing trivia** — the slice starts at `method.start` and ends at `method.end` exactly as OXC reports them. Value: the JSON descriptor becomes self-verifying — agents and humans consuming the descriptor via `CCXT.describe/2` / `CCXT.MCP.tools/0` can inspect the upstream source that backs each claim without a second network hop or `git clone ccxt`. Expected size: on the order of 20–50KB per exchange of added source text across its unified-method surface — comfortably within the Task 116/117 spec-size headroom. Long method bodies (e.g. binance's `sign()` ~200 lines) emit in full; trimming would undermine the receipts property and re-introduce the "summary vs reality" gap this field is explicitly closing. This turns the descriptor from *summary of what CCXT does* into *summary + the source text that proves it*. **Honest success:** same scope flags produce deterministic output across runs; methods with TS-only signatures emit structural descriptors; missing JSDoc never produces fabricated defaults. **Cross-repo:** on landing, flip ⬜ on `../ccxt_client/ROADMAP.md` Task 109 — the macro layer reads `__spec__()["unified_endpoints"]["<name>"]["descriptor"]` and composes TS structural params + JSDoc overlay with ccxt_client's hand-authored Elixir arg-shape convention (`exchange:` first arg, kwlist opts, etc.). Discovered 2026-04-21 during descripex surface audit — ccxt_client tidewave (port 4003) already serves `CCXT.describe/2` and `CCXT.MCP.tools/0` from hand-written annotations; this task moves the source of truth upstream while keeping language-specific arg-shape decisions with each consumer. |
| Task 122 `[CSR]` | ⬜ | 🎁 **method-descriptors** · Schema block + `unified_method_descriptors_shape_valid` contract-test invariant for Task 121's output [D:3/B:4/U:5 → Eff:1.5] 🚀 — depends on 121. Add the chosen emission shape to the JSON Schema file (additive minor-version bump, not breaking, unless the implementer intentionally promotes to `required`), add shape invariant mirroring `testnet_urls_shape_valid`'s structure, and extend `CcxtExtract.Provenance.section_pointers/0` so `provenance_covers_schema` stays at zero findings. Update [SCHEMA.md](SCHEMA.md) with a field reference and the descriptor value space (what `params` looks like, how `errors` is scoped, when fields are null + reason). |
| Task 124 | ⬜ | Prune Bybit's discontinued `spot/v3/private/*` endpoints from extracted spec [D:4/B:4/U:4 → Eff:1.0] 📋 — Bybit discontinued its V3 Spot Open API as of 2024-08-31 (official notice); live calls return `"We have discontinued Open API V3 services as of August 31 2024. Please refer to the official website announcement and upgrade to Open API V5"`. Upstream CCXT's TS source still lists these endpoints in `bybit.ts`'s `api.spot.v3.private` block, so extraction dutifully emits them into `structure.implicit_endpoints` / `unified_endpoints` — and ccxt_client's probe generator produces tests for them. Scope: three options in rough order of preference — (a) **push a PR upstream to ccxt** removing the dead V3 Spot endpoints (cleanest, but out of our repo); (b) **add an override entry** (JSON-Pointer deletion) under `priv/overrides/bybit/…` once the delete-pointer override semantics are nailed down; (c) **derivation-time filter** that drops endpoint paths known to be deprecated (risk: hardcodes a Bybit-specific policy into generic extraction logic). Discovered 2026-04-21 from ccxt_client full-tag integration run (22 "Open API V3 discontinued" INCONCLUSIVE warnings) — see `ccxt_client/ROADMAP.md` Task 111(b). Not urgent (endpoints are clearly dead, not silently broken), but wasted probe runs + user confusion accumulate. |
| Task 126 `[CSR]` | ⬜ | 🎁 **sibling-emit · openapi** · Secondary OpenAPI 3.1 emitter for REST exchanges (the majority of CCXT) [D:6/B:7/U:5 → Eff:1.0] 📋 — Emit a sibling `priv/output/<id>.openapi.json` ([OpenAPI 3.1 spec](https://spec.openapis.org/oas/v3.1.0)) alongside the core `<id>.json` for every REST exchange. OpenAPI is the dominant descriptor for REST APIs (paths, verbs, params, request/response schemas, auth, servers) with a large ecosystem: Swagger UI, `openapi-generator` (Rust/Go/Python/TS/Java/… client codegen), Postman import, Prism mock servers, Stoplight editors. Scope: a new emitter (conceptually `CcxtExtract.OpenApi`) that projects already-extracted data — `structure.url_templates` → `servers[]` + `paths`, verb families in `runtime.describe.api` → HTTP `operations`, Task 121 unified-method descriptors (TS signature + JSDoc) → `parameters` / `requestBody` / `responses` schemas, `@throws` entries → `responses` error codes, `handle_errors` regex routing → `x-ccxt-error-routes` extension. Load-bearing exchange concerns that OpenAPI doesn't model natively land in namespaced extensions — `x-ccxt-sign` (reference into the core spec's `sign_recipe`, not duplicated), `x-ccxt-rate-limit` (token bucket + per-endpoint cost), `x-ccxt-sandbox-servers` (testnet switching), `x-ccxt-nonce` (nonce convention). Non-goals: **don't** replace the core schema (`exchange_v3.json` stays the source of truth — richer than OpenAPI for this domain); **don't** duplicate payloads between the core spec and the OpenAPI sibling (emit references like `$ref` / extension pointers so regeneration stays deterministic); **don't** fabricate response schemas for operations whose response shape hasn't been extracted (emit `responses.default` with `application/json` + empty schema + `x-ccxt-unresolved: "no_response_schema"` rather than lying). Verification: pipe each emitted doc through `openapi-generator validate` AND round-trip through Swagger Editor for a sampled set of priority exchanges; a Mix task should fail the emit if the document doesn't validate. Honest dependency: high-quality `parameters` / `requestBody` / `responses` fields depend on Task 121 (TS-signature + JSDoc descriptors). Pre-121 emission is valid but schemas degrade to `{"type": "object"}` — still useful for codegen-ing clients that forward params through, less useful for typed consumers. WebSocket surface is out of scope here — that's AsyncAPI territory and becomes its own sibling task if/when demand surfaces. Discovered 2026-04-23 during scope conversation (reframing of Task 125). Strategic position: this is the **primary** companion-artifact emitter; the OpenRPC variant (Task 125) is the narrow JSON-RPC tail. Shared emitter infrastructure (extension-namespace conventions, validation harness, write-path integration with `Pipeline`) lands here first. |
| Task 125 `[CSR]` | ⬜ | 🎁 **sibling-emit · openrpc** · Secondary OpenRPC emitter for JSON-RPC exchanges (Deribit first) [D:3/B:3/U:2 → Eff:0.83] ⚠️ — **Depends on Task 126** (shared emitter infrastructure: extension-namespace conventions, validation harness, write-path integration). Emit an [OpenRPC 1.3](https://spec.open-rpc.org/) document alongside `priv/output/<id>.json` **only** for exchanges whose transport is JSON-RPC 2.0 (Deribit is the canonical case; audit `runtime.describe.urls.api` + sign-method shape to find the full set — likely ≤3 exchanges). OpenRPC is the JSON-RPC analogue of OpenAPI: a standardized descriptor for method names, param schemas, result schemas, error objects, links, and examples. Existing OpenRPC consumers include Ethereum tooling, a Playground UI, and several code-generators (TS/Rust/Python). Scope after Task 126 lands: reuse the shared emitter scaffolding, project the JSON-RPC subset — unified method names → OpenRPC `methods[]`, Task 121 TS-signature params → `params[].schema`, `@throws` entries → `errors[]`, response parse-method shape → `result.schema`. Write to `priv/output/<id>.openrpc.json`. Gate on an `openrpc_eligible` classifier (`runtime.describe` evidence), not a hardcoded allowlist. Non-goals: **don't** shoehorn REST exchanges into OpenRPC (fundamental transport mismatch — OpenRPC assumes a uniform JSON-RPC envelope that REST endpoints don't have); **don't** replace the core schema. Verify each emitted document with the OpenRPC Playground or `@open-rpc/schema-utils-js` validator. Discovered 2026-04-23 during scope conversation. U:2 reflects structural reach, not a demand claim: the JSON-RPC transport constraint makes this inapplicable to the REST majority of CCXT's surface regardless of consumer interest. Promote if JSON-RPC consumers show up or if the OpenRPC toolchain becomes a consumption path worth targeting proactively. |
| Task 127 | ⬜ | Position-aware `paths_rw_split` sinks + variable-level sanitization [D:5/B:3/U:3 → Eff:0.6] ⚠️ — Task 112's `paths_rw_split` corpus invariant lists `File.cp!`/`cp_r!`/`cp`/`cp_r`/`rename` in `@file_writer_fns`, which is position-unaware: `File.cp!(source, target)` legitimately takes a read-side path as arg 0, so `File.cp!(Paths.priv(...), target)` trips the invariant even though the writer target is unrelated. Follow-up 2026-04-24 worked around it in `pipeline.ex` by rewriting `File.cp!` as `File.write!(target, File.read!(source))` (byte-copy via the sanitizer chain) and by broadening `@file_reader_fns` to include `File.exists?`/`stat`/`ls`/`regular?`/`dir?`/`lstat*` so Reach's chop-level sanitization kills the `ccxt_extract.setup.ex:254-287` false positive where `Paths.priv → File.exists? → … → File.write!(out_version_file(), …)` propagates through control flow. **Both are band-aids.** The chop-level sanitizer mask-bleeds into a theoretical false negative on the pattern `path = Paths.priv(x); if File.exists?(path), do: File.write!(path, data)` — Codex flagged this 2026-04-24. Proper fix: (a) **position-aware sinks** — distinguish write-position args from read-position args on `cp!`/`cp_r!`/`rename`, likely by replacing `paths_rw_sink?/1` with a registry keyed on `{function, arity, write_arg_indices}`; (b) **variable-level sanitization** — ask Reach to sanitize the specific variable that passes through a reader, not every node on the chop, so a subsequent direct variable→sink flow still flags when the sink arg is the original path and doesn't flag when the sink arg is an unrelated value computed in the same function. Variable-level sanitization likely needs a Reach-side change (`Reach.Project.taint_analysis/2` currently marks sanitized = "any node in chop matches", see `deps/reach/lib/reach/project.ex:121-123`); if upstream won't carry it, an ad-hoc shim inside `check_paths_rw_split/1` that re-checks the sink's argument provenance against the sanitizer set would work. Once either lands: narrow `@file_reader_fns` back to content readers (`read`/`read!`/`stream!`/`open`/`open!`), restore `File.cp!` in `pipeline.ex:683`, and delete both TODO blocks. Discovered 2026-04-24 during staged-review of the paths_rw_split sanitizer-broadening change. Inline TODO references at `lib/ccxt_extract/contract_test.ex` (above `@file_reader_fns`) and `lib/ccxt_extract/pipeline.ex:683`. |
| Task 128 | ⬜ | 🎁 **10-sign-extend** · Multi-hop body alias resolution in `pre_sign_transforms` body-encoding detector [D:4/B:3/U:3 → Eff:0.75] 📋 — Task 68's `PreSignTransforms.body_reached_by_crypto?/2` resolves a single alias hop: when the crypto call references identifier X, it walks X's local declarator/`=`/`+=` reassignments one level looking for `body` or `this.json(...)` in the RHS. This catches okx (`auth += body`) and bitfinex (`const auth = '/api/' + request + nonce + body`). It does NOT catch multi-hop chains like `payload = body; auth += payload; this.hmac(auth, …)` or fixed-point fan-in `auth += a; auth += b; … where one of {a,b,…} ultimately resolves to body`. Scope: extend the tracer to a bounded fixed-point — visit each crypto-arg identifier, expand its 1-hop set, recurse on identifiers found in the RHS, with a small max-depth guard (3–4) to prevent runaway and a visited-set to prevent cycles. Honest "did not converge in N hops" → emit `{json_encode, body}` only on a confident reach; otherwise leave honestly empty (the bicondictional still flips because `[]` is non-nil). Don't conflate with Task 66h (canonical_string concat-chain resolution) — the two share the alias-hop primitive but their consumer fields differ. Promote when a priority exchange surfaces the multi-hop shape. Discovered 2026-04-26 during Task 68 staged-review (Codex flagged the okx 1-hop case; this is the natural follow-up for chains the 1-hop bound can't reach). Inline TODO reference at `lib/ccxt_extract/sign_recipe/pre_sign_transforms.ex:282-283` (the comment block on `body_reached_by_crypto?/2`). |

---

## Phase 8: Client harness + contract tests 🔶

> All reference consumers live in their own git repos as **siblings** of `ccxt_extract/` (e.g. `../ccxt_client/`, future `../<rust-crate>/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but moved back to siblings in Task 56b to stop ccxt_extract's `CLAUDE.md` from being auto-loaded into every client session. `ccxt_extract` stays a pure extractor and ships a contract-test suite that validates the JSON surface without importing client code — catches "Elixir didn't notice this breaks Rust" drift.
>
> **🔗 Every task in this phase requires updating `../ccxt_client/ROADMAP.md` on completion.**

| Task | Status | Notes |
|------|--------|-------|
| Task 57c | ⬜ | 🎁 **9-pipeline-follow-up** · Pattern A/B fixed (341 → 53). Provenance now lands (Task 61a, 2026-04-17) so the honest Pattern C fix is unblocked — tag `has`-confirmed entries as `"derived"` rather than silently filtering. Still deferred until a Tier 1/2/DEX exchange surfaces a Pattern C failure. [D:3/B:5/U:5 → Eff:1.67] 🚀 |

Completed (Tasks 56, 56b, 57, 57b, 57d, 58, 59) — see [CHANGELOG.md](CHANGELOG.md).

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
| Task 62 | ⬜ | 🎁 **9-audit** · `mix ccxt_extract.validate_overrides` [D:4/B:7/U:7 → Eff:1.75] 🚀 — cross-check each override against runtime behavior where a probe exists (URL override vs runtime `url_templates`; signing override vs live sign() probe). Emit per-exchange report: verified vs unverified-with-reason. |
| Task 63 | ⬜ | 🎁 **9-audit** · `mix ccxt_extract.drift_audit` [D:5/B:7/U:6 → Eff:1.3] 📋 — compare current derivation + overrides against the last-released output. Flags: (a) overrides whose underlying raw data changed (stale override), (b) derived fields that flipped value or disappeared, (c) new raw fields not yet derived. Report only; humans decide. |
| Task 104 | ⬜ | 🎁 **9-pipeline** · Array-index JSON Pointers in `OverrideRegistry` [D:2/B:3/U:2 → Eff:1.5] 📋 — extend `pointer_to_keys/1` to emit `Access.at/1` for numeric segments so paths like `/structure/sign_method/params/0/name` resolve to deep list elements. Currently raises loudly with a TODO marker — fine while every shipped override file uses shallow string-key pointers. Unblock when a real override file needs `/path/0/...`. |

---

## Phase 10: Request signing contract ✅

> **Supersedes Task 33.** A consumer must be able to construct an authenticated request without walking `sign()` AST. This phase emits a declarative signing recipe per exchange per API section: crypto op, canonical-string instructions, signature placement, auth headers, nonce source, pre-sign transforms. Honesty rule: each field derived when provable, null+reason otherwise, overrides fill gaps.
>
> **Phase 10 closed 2026-04-24 with Task 68.** All seven tasks (64, 65, 66a, 66b, 67, 68, 69) shipped. **okx.private is the first recipe in the project to have `unresolved_reason: null`** — Task 69's biconditional auto-flipped once Task 68 populated the sixth derivation field. 17 sign_recipe entries across 9 priority exchanges carry a populated `pre_sign_transforms`; terminal exchanges correctly emit null. Remaining Phase 10 work lives in 🎁 **10-sign-extend** (Tasks 66e-h, 113) as follow-ups for corner-case AST shapes not observed in priority sign() methods.
>
> **Three-Strikes Rule applies.** Each Phase 10 derivation module declares its patch count in its header (e.g. `# Patch count: 0/3`). At patch #3, migrate to `priv/overrides/<exchange>.json` rather than stretching the derivation further. See CLAUDE.md for the full rule.

**Downstream signal:** `ccxt_client/lib/ccxt/signing/classifier.ex` (AST-walker) becomes redundant when this phase ships `signing.pattern` directly. Schema design should enable its deletion without Elixir-side contortions.

> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 54 (retire classifier) and 56 (spec-driven pattern modules) depend on this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 64 | ✅ | 🎁 **10-core** · Shipped 2026-04-18 at schema 2.2.0. See [CHANGELOG.md](CHANGELOG.md#task-64-signing-recipe-schema-scaffold-schema-220). |
| Task 65 | ✅ | 🎁 **10-core** · Shipped 2026-04-18. See [CHANGELOG.md](CHANGELOG.md#task-65-crypto_op--signature_placement-derivation). |
| Task 66a `[P]` | ✅ | 🎁 **10-HMAC** · Shipped 2026-04-19 at schema 2.3.0. See [CHANGELOG.md](CHANGELOG.md#task-66a-hmac-simple-canonical_string-derivation-schema-230). |
| Task 66b `[P]` | ✅ | 🎁 **10-HMAC** · Shipped 2026-04-21; no schema bump. See [CHANGELOG.md](CHANGELOG.md#task-66b-hmac-with-body-canonical_string-family-post-populates). |
| Task 67 | ✅ | 🎁 **10-finish** · Shipped 2026-04-24 — `auth_headers` + `nonce` derivation via new `AuthHeaders` / `Nonce` modules. See [CHANGELOG.md](CHANGELOG.md#task-67-auth-header-set--nonce-source-derivation). |
| Task 68 | ✅ | 🎁 **10-finish** · Shipped 2026-04-24 — `pre_sign_transforms` derivation via new `PreSignTransforms` module; closes Phase 10. **okx.private** is the first recipe to auto-flip `unresolved_reason` to `null` via Task 69's biconditional. See [CHANGELOG.md](CHANGELOG.md#task-68-pre-sign-transforms-derivation). |
| Task 69 | ✅ | 🎁 **10-finish** · Shipped 2026-04-24 — biconditional contract on `sign_recipe.<section>.unresolved_reason` enforced write-side via `SignRecipe.Derive` auto-flip and read-side via new `sign_recipe_honesty_valid` contract invariant. See [CHANGELOG.md](CHANGELOG.md#task-69-signing-recipe-biconditional-contract). |

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
| Task 73c | ✅ | 🎁 **11-request** · Shipped 2026-04-17 at schema 2.1.0. See [CHANGELOG.md](CHANGELOG.md#task-73c-per-method-default-request-body-extractor-schema-210). |
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
| Task 88a `[P]` `[CSR]` | ⬜ | 🎁 **13-dispatch** · Handler routing — error dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 88b `[P]` `[CSR]` | ⬜ | 🎁 **13-dispatch** · Handler routing — signing dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 88c `[P]` `[CSR]` | ⬜ | 🎁 **13-dispatch** · Handler routing — parse dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |

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
| Task 100 | ✅ | 🎁 **16-testnet** · Shipped 2026-04-19 at schema 2.4.0. See [CHANGELOG.md](CHANGELOG.md#task-100-testnet--sandbox-url-catalog-schema-240). |

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
- `[CSR]` marker — tasks suitable for Cursor cloud-agent delegation (Background Agent runs Opus 4.7 + has Elixir/OTP, hex.pm, mix tasks, internet — no Tidewave). Full eligibility filter in `~/.claude/includes/linear-workflow.md` § "Delegation Eligibility Filter Order". (Note: the prior `[Codex]` marker is retired — Codex Cloud code-mutation delegation is suspended workspace-wide because the harness has no Elixir runtime.)
- `[P]` marker — task can run in parallel with its siblings in the same phase. Many per-type parse tasks and per-family signing tasks carry `[P]`.
- Raw AST remains in the output. Consumers may inspect it for debugging or novel needs, but a consumer that *requires* walking AST to operate exposes a gap the roadmap should close.
- **Source of truth is CCXT, not exchange docs.** See [CLAUDE.md §"Source of truth: CCXT, not exchange docs"](CLAUDE.md#source-of-truth-ccxt-not-exchange-docs). Exchange vendor docs enter only as override `verified_against`, Tier 1 gap enrichment (tracked as a task), or a future third-source verification layer — never as a primary extraction target. Proposals to replace CCXT extraction with doc-reading are a 110× work multiplier without reliability gains.
