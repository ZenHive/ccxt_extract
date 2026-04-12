# ROADMAP

**Vision:** Extract everything CCXT knows about 111+ exchanges into language-agnostic JSON so any consumer — in any language — can operate an exchange without walking AST.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Contract reference:** See [CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md) for the unfiltered list of what a consumer needs. Phases 10–16 tick items off that checklist.

**Schema contract:** See [SCHEMA.md](SCHEMA.md) for field-level definitions and version history of the emitted JSON.

> **🔗 Cross-repo rule (applies to EVERY task in this roadmap):** When a task ships, lands, or changes status, the implementer MUST also update `../ccxt_client/ROADMAP.md` — mark any dependent ccxt_client task as unblocked, flip its status, or add a new follow-up entry. A ccxt_extract task is **not complete** until its downstream ccxt_client impact is reflected there. The two roadmaps are a single contract surface viewed from two sides.

---

## 🎯 Current Focus

**Phase 8 — Client harness + contract tests** kicking off. Phase 7 (data quality) winding down. A major *planning* restructure landed with this roadmap: the old "Anti-Bias Rule" and "Extraction vs Interpretation" framings are retired (see CLAUDE.md). The target output is a three-tier merge (raw / derived / override) and the consumer contract explicitly forbids consumers walking AST — but **none of that has shipped yet**. Today's output is raw + derived only; override infrastructure and per-field provenance arrive in Phase 9. Several previously-deferred tasks are superseded under the new rules.

> **Philosophy reminder:** Every value is either provable (emit it) or explicitly unprovable (`null` + reason). No silent guesses. Overrides (once Phase 9 ships) will fill gaps derivation can't reach and carry reasons too.

### ✅ Recently Completed
| Task | Description | Notes |
|------|-------------|-------|
| Task 57c | Relocate clients back to sibling repos | Nested `CLAUDE.md` walked into ccxt_extract context in every client session; moved to `../ccxt_client/` |
| Task 57b | Wire `contract_test` into `mix ccxt_extract.update` | Non-strict Stage 6 between validate and analytics |
| Task 56 | `clients/` layout + relocate ccxt_client | Superseded by Task 57c; historical record |
| Task 59 | `CONSUMER_CONTRACT.md` skeleton with lifecycle trackers | — |
| Task 55 | `throw_dispatches` from `handleErrors()` AST | Schema 1.7.0 |
| Task 54 | Stabilize `error_code_fields` contract | Schema 1.6.0 |
| Task 53 | Field semantics for `error_code_fields` | Schema 1.5.0 |
| Task 52 | Authenticated sections from `sign()` AST | Schema 1.4.0 |
| Task 49 | `error_code_fields` from `handleErrors()` AST | Schema 1.3.0 |
| Task 47 | URL templates round-trip validation | — |
| Task 46 | URL templates extractor (raw probe model) | Schema 1.2.0 |

### 📋 Next Up
| Task | Status | Notes |
|------|--------|-------|
| Task 57c | ⬜ | Triage contract_test findings (unified_endpoints/has drift) |
| Task 57d | ⬜ | Fix authenticated_sections derivation for inherited sign() |
| Task 58 | ⬜ | Golden JSON fixtures + regenerate command |
| Task 60 | ⬜ | `priv/overrides/` directory contract + schema |
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

## Phase 7: Data Quality & Maintenance

> Technical debt and code quality improvements. Most tasks complete; one open.

| Task | Status | Notes |
|------|--------|-------|
| Task 37 | ⬜ | Fix Credo compatibility on Elixir 1.18+ [D:2/B:4/U:3 → Eff:1.50] `[Codex]` |

Completed Phase 7 tasks (Tasks 35, 38, 39, 42–47) moved to CHANGELOG.md.

---

## Phase 8: Client harness + contract tests ⬜

> All reference consumers live in their own git repos as **siblings** of `ccxt_extract/` (e.g. `../ccxt_client/`, future `../<rust-crate>/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but moved back to siblings in Task 57c to stop ccxt_extract's `CLAUDE.md` from being auto-loaded into every client session. `ccxt_extract` stays a pure extractor and ships a contract-test suite that validates the JSON surface without importing client code — catches "Elixir didn't notice this breaks Rust" drift.
>
> **🔗 Every task in this phase requires updating `../ccxt_client/ROADMAP.md` on completion.**

| Task | Status | Notes |
|------|--------|-------|
| Task 56 `[P]` | ✅ | Establish `clients/` layout — shipped |
| Task 57 | ✅ | `mix ccxt_extract.contract_test` skeleton — shipped |
| Task 58 | ⬜ | Golden JSON fixtures + regenerate command [D:3/B:7/U:7 → Eff:2.3] 🎯 |
| Task 59 | ✅ | `CONSUMER_CONTRACT.md` skeleton — shipped |
| Task 57b `[P]` | ✅ | Wire `contract_test` into `mix ccxt_extract.update` — shipped |
| Task 57c | ⬜ | Triage contract_test findings (unified_endpoints/has drift) [D:5/B:7/U:7 → Eff:1.4] 📋 |
| Task 57d `[P]` | ⬜ | Fix authenticated_sections derivation for inherited sign() [D:3/B:6/U:5 → Eff:1.83] 🚀 |

**Task 57: Contract-test skeleton** — Add `mix ccxt_extract.contract_test` that loads emitted JSON and runs cross-field semantic invariants. Seed invariants: every `structure.unified_endpoints` key is claimed in `runtime.describe.has` (value `true` or `"emulated"`); every `authenticated_sections` entry appears in `runtime.describe.api`; every `error_code_fields` root is in the committed baseline at `priv/contract_test/error_code_fields_roots.json` (deriving the safelist from the same corpus would be tautological). Each invariant failure points at the exchange + field path. Distinct from `validate` (schema conformance + round-trip); this catches semantic drift across fields.

**Task 57b: Wire contract_test into update** — Add `contract_test` as a non-strict stage after `validate` in `mix ccxt_extract.update`. Must update stage-flow assertions in `test/mix/tasks/update_test.exs`. `--strict` stays available for CI / pre-commit callers.

**Task 57c: Triage unified_endpoints/has drift** — Initial contract_test run surfaced ~341 findings where `structure.unified_endpoints` declares a method but `runtime.describe.has[method]` is `false`, `:missing`, or `"__undefined"`. For each pattern, determine whether `unified_endpoints` is over-declaring (extractor bug) or `has` is under-declaring (extraction gap). Fix the underlying derivation. Success: green invariant on the full corpus without weakening the rule.

**Task 57d: Authenticated sections derivation for inherited sign()** — tokocrypto's 7 contract_test findings show sections inherited from binance's sign() AST that aren't in tokocrypto's runtime api. Walk the class-inheritance chain when deriving `authenticated_sections` and intersect against the child's resolved describe() api. See `lib/ccxt_extract/authenticated_sections.ex`.

**Task 58: Golden JSON fixtures** — Commit golden JSON for three reference exchanges covering auth variety: binance (HMAC with body), bybit (HMAC headers), deribit (JSON-RPC). Add `mix ccxt_extract.regenerate_fixtures` to regenerate and a CI check that the committed fixtures match current output. Fixture diffs become PR-reviewable signals of contract drift.

---

## Phase 9: Override infrastructure + provenance ⬜

> The three-tier output model requires override storage, merge logic, provenance tagging, and drift auditing. Lands before signing/parsing phases so every new derived field ships with an override fallback from day one.
>
> **This phase also enables the Three-Strikes Derivation Rule** (see CLAUDE.md) — without somewhere to migrate knowledge to, the rule has no exit. Every Phase 10–16 derivation ships knowing it can hand off to an override on patch #3 instead of accreting special cases.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — notably ccxt_client Tasks 53 (schema 2.0.0 adapter) and 63 (override contribution workflow).

| Task | Status | Notes |
|------|--------|-------|
| Task 60 | ⬜ | `priv/overrides/` directory contract + schema [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 61a `[P]` | ⬜ | Provenance tagging on raw + derived fields [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 61b | ⬜ | Override merge pipeline stage [D:4/B:9/U:9 → Eff:2.25] 🚀 |
| Task 61c | ⬜ | Schema 2.0.0 bump + migration notes in SCHEMA.md [D:2/B:6/U:6 → Eff:3.0] 🎯 |
| Task 62 | ⬜ | `mix ccxt_extract.validate_overrides` [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 63 | ⬜ | `mix ccxt_extract.drift_audit` [D:5/B:7/U:6 → Eff:1.3] 📋 |

**Task 60: Override directory contract** — Define `priv/overrides/<exchange>.json` format: JSON Pointer paths into the canonical output, a `value` payload, required `reason`, optional `verified_against` (runtime probe output or CCXT source reference) and `unverified: true` flag. Document in SCHEMA.md. Ship an example override for one exchange.

**Task 61a: Provenance tagging on raw + derived** — Every field in the emitted JSON gains a parallel `_provenance` map keyed by the same paths, with values `"raw"` / `"derived"` / `"override"`. Ship for raw + derived first; override values are tagged when Task 61b lands. Alternative shape (inline per-field `{value, source}` tuples) is rejected as noisy — keep the main payload clean, store provenance alongside.

**Task 61b: Override merge pipeline stage** — Add a merge stage that applies `priv/overrides/<exchange>.json` on top of raw+derived output before emission. Override values tag provenance `"override"`. Invalid override paths (pointing at non-existent locations) fail the pipeline loudly.

**Task 61c: Schema 2.0.0 bump** — Bump `schema_version` to 2.0.0 and rename the schema file `exchange_v1.json` → `exchange_v2.json`. Keep `exchange_v1.json` around for one release so consumers can diff; delete in the following release. Document the provenance contract (top-level `_provenance` map, required on every exchange) and the breaking changes in SCHEMA.md.

**Task 62: validate_overrides** — `mix ccxt_extract.validate_overrides` checks each override against runtime behavior where a probe exists (e.g., if override sets a URL, cross-check against runtime url_templates; if override sets a signing field, cross-check against live sign() probe). Emits a report per exchange: verified vs unverified-with-reason.

**Task 63: drift_audit** — `mix ccxt_extract.drift_audit` compares current derivation + overrides against the last-released output. Flags: (a) overrides whose underlying raw data changed (override may be stale), (b) derived fields that flipped value or disappeared, (c) new raw fields not yet derived. Output is an audit report, not a fail; humans decide.

---

## Phase 10: Request signing contract ⬜

> **Supersedes Task 33.** A consumer must be able to construct an authenticated request without walking `sign()` AST. This phase emits a declarative signing recipe per exchange per API section: crypto op, canonical-string instructions, signature placement, auth headers, nonce source, pre-sign transforms. Honesty rule: each field derived when provable, null+reason otherwise, overrides fill gaps.

**Downstream signal:** `ccxt_client/lib/ccxt/signing/classifier.ex` (AST-walker) becomes redundant when this phase ships `signing.pattern` directly. Schema design should enable its deletion without Elixir-side contortions.

> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 54 (retire classifier) and 56 (spec-driven pattern modules) depend on this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 64 | ⬜ | Signing recipe schema design [D:5/B:9/U:9 → Eff:1.8] 🚀 |
| Task 65 | ⬜ | Crypto op + signature placement from `sign()` AST [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 66a `[P]` | ⬜ | Canonical string recipe — HMAC-simple family [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 66b `[P]` | ⬜ | Canonical string recipe — HMAC-with-body family [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 66c `[P]` | ⬜ | Canonical string recipe — JWT / RSA / Ed25519 family [D:6/B:7/U:7 → Eff:1.17] 📋 |
| Task 66d | ⬜ | Canonical string recipe — custom / outlier family [D:7/B:6/U:6 → Eff:0.86] ⚠️ |
| Task 67 | ⬜ | Auth header set + nonce source derivation [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 68 | ⬜ | Pre-sign transforms (hex/base64/lowercase/url-encode) [D:4/B:6/U:7 → Eff:1.63] 🚀 |
| Task 69 | ⬜ | Signing round-trip validation + contract invariants [D:3/B:7/U:7 → Eff:2.33] 🚀 |

Per-task scope is a single declarative field (or family) across all exchanges. Each task seed may split further if the AST surface proves too large during implementation research.

---

## Phase 11: Request building contract ⬜

> Everything a consumer needs to turn a unified call into an HTTP request, excluding signing (Phase 10).
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 57 (adopt request-building contract) tracks this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 70 | ⬜ | HTTP verb + path template + path-param rules per method [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 71 | ⬜ | Body encoding + content-type per section [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 72 | ⬜ | Timestamp source + format per section [D:3/B:6/U:7 → Eff:2.17] 🚀 |
| Task 73 | ⬜ | Per-method rate-limit cost + weight axis [D:3/B:7/U:7 → Eff:2.33] 🚀 |
| Task 73b | ⬜ | User-agent + default headers per exchange [D:2/B:5/U:5 → Eff:2.5] 🎯 |

---

## Phase 12: Response parsing contract ⬜

> For every CCXT `parse*` method, emit a field map that a consumer can apply without walking AST. Each task covers one `parse*` type end-to-end: field name mapping (exchange-native key → unified key), type coercion (safeString/safeNumber/safeTimestamp) per field, enum tables (status/side/type), timestamp format, nested-path traversal.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 19/21/44/55 (parser + struct regeneration) depend on this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 74 `[P]` | ⬜ | `parseTicker` field map + coercion + enums [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 75 `[P]` | ⬜ | `parseOrder` field map + status/side/type enums [D:5/B:9/U:9 → Eff:1.8] 🚀 |
| Task 76 `[P]` | ⬜ | `parseTrade` field map [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 77 `[P]` | ⬜ | `parseBalance` field map [D:4/B:8/U:8 → Eff:2.0] 🚀 |
| Task 78 `[P]` | ⬜ | `parseOHLCV` field map + timestamp format [D:3/B:7/U:7 → Eff:2.33] 🚀 |
| Task 79 `[P]` | ⬜ | `parseMarket` field map [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 80 `[P]` | ⬜ | `parsePosition` field map [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 81 `[P]` | ⬜ | `parseTransaction` (deposit/withdrawal) field map [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 82 `[P]` | ⬜ | `parseDepositAddress` field map [D:3/B:6/U:6 → Eff:2.0] 🚀 |
| Task 83 | ⬜ | Response envelope paths per method group [D:4/B:8/U:8 → Eff:2.0] 🚀 |

Type-coercion tables fold into each per-type task (not standalone) — one task covers its type's field map + coercion + enums together so it fits in a session.

---

## Phase 13: Error contract ⬜

> **Supersedes Task 34.** Complete the error story: status-code maps, retry classification, class hierarchy export, and handler routing tables that consumers need to drive dispatch without AST.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 58 (adopt error contract) tracks this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 85 | ⬜ | HTTP status → error class map per exchange [D:3/B:7/U:7 → Eff:2.33] 🚀 |
| Task 86 | ⬜ | Retryable classification (rate-limit/network/server-busy/auth) [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 87 | ⬜ | Error class hierarchy export [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 88a `[P]` | ⬜ | Handler routing — error dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 88b `[P]` | ⬜ | Handler routing — signing dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 88c `[P]` | ⬜ | Handler routing — parse dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |

---

## Phase 14: Rate-limit contract ⬜

> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Task 59 (multi-bucket rate limiter) depends on this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 89 | ⬜ | Bucket config — axes (IP/UID/order-weight), refill, size [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 90 | ⬜ | Per-endpoint cost weights against bucket axis [D:4/B:7/U:8 → Eff:1.88] 🚀 |

---

## Phase 15: WS contract ⬜

> Streaming equivalent of phases 10–13. Per-channel specs for subscription, auth, heartbeat, snapshot/delta semantics, and reconnect.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Phase 6 (Tasks 22–27) is gated on this phase landing.

| Task | Status | Notes |
|------|--------|-------|
| Task 91 | ⬜ | WS subscribe / unsubscribe message shape per channel [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 92 | ⬜ | WS auth flow (sign-in msg / header / query param) [D:4/B:7/U:8 → Eff:1.88] 🚀 |
| Task 93 | ⬜ | Heartbeat / ping-pong pattern per exchange [D:3/B:6/U:7 → Eff:2.17] 🚀 |
| Task 94 | ⬜ | Channel → parse handler dispatch tables [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 95a `[P]` | ⬜ | Snapshot/delta semantics — orderbook [D:5/B:8/U:8 → Eff:1.6] 🚀 |
| Task 95b `[P]` | ⬜ | Snapshot/delta semantics — trades [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 95c `[P]` | ⬜ | Snapshot/delta semantics — OHLCV [D:4/B:7/U:7 → Eff:1.75] 🚀 |
| Task 96 | ⬜ | Reconnect triggers + backoff policy hints [D:3/B:6/U:6 → Eff:2.0] 🚀 |

---

## Phase 16: Market & currency semantics ⬜

> Remaining declarative metadata a consumer needs beyond `runtime.markets` and `runtime.describe`.
>
> **🔗 Every task here requires updating `../ccxt_client/ROADMAP.md`** — ccxt_client Tasks 60 (currency aliases) and 61 (testnet URL catalog) track this phase.

| Task | Status | Notes |
|------|--------|-------|
| Task 97 | ⬜ | Currency aliases (`commonCurrencies`) + network info [D:3/B:7/U:8 → Eff:2.5] 🎯 |
| Task 98 | ⬜ | Precision mode + tick/step derivation semantics [D:3/B:6/U:7 → Eff:2.17] 🚀 |
| Task 99 | ⬜ | Tiered fee schedules + VIP level mapping [D:4/B:6/U:6 → Eff:1.5] 🚀 |
| Task 99b | ⬜ | Funding / withdrawal / deposit fee catalog [D:3/B:6/U:6 → Eff:2.0] 🚀 |
| Task 100 | ⬜ | Testnet/sandbox URL catalog + proxy patterns [D:2/B:5/U:6 → Eff:2.75] 🚀 |

---

## Superseded / Deferred

| Task | Status | Reason |
|------|--------|--------|
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

**Sibling-repo clients.** Each language client is an independent git repo living as a sibling of `ccxt_extract/` (e.g. `../ccxt_client/`). Clients were briefly nested under `clients/<lang>/<project>/` (Task 56) but relocated back to siblings (Task 57) because nested `CLAUDE.md` discovery pulled ccxt_extract's full context into every client session.

**Three-tier JSON is the target contract.** Once Phase 9 ships, output will merge raw extraction + derived analysis + curated overrides with per-field provenance. Today's output is raw + derived only — overrides and `_provenance` tags arrive in Tasks 60–61b. Either way, consumers read the emitted JSON; they do not re-derive or walk AST. Contract tests (`mix ccxt_extract.contract_test`, Task 57) will enforce cross-field invariants so drift surfaces before it reaches a consumer.

**Versioning follows semver** on the `schema_version` field. See [SCHEMA.md](SCHEMA.md).

---

## Notes

- Task descriptions are prompts for Claude to implement — explore the codebase and discover the right approach. See `CLAUDE.md` for session-size, honesty-rule, and three-tier contract guidance.
- Previous "Anti-Bias Rule" and "Extraction vs Interpretation" framings are retired. The replacement rule: every value is provable or explicitly unprovable; interpretation happens in derivation + overrides, not in consumers.
- `[Codex]` marker — tasks suitable for Codex/OpenAI delegation: self-contained, no OXC/QuickBEAM NIF deps. Phase 10–16 tasks touch AST or runtime and generally stay in-house.
- `[P]` marker — task can run in parallel with its siblings in the same phase. Many per-type parse tasks and per-family signing tasks carry `[P]`.
- Raw AST remains in the output. Consumers may inspect it for debugging or novel needs, but a consumer that *requires* walking AST to operate exposes a gap the roadmap should close.
