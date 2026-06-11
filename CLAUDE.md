# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`ccxt_extract` is an Elixir library that serializes everything the CCXT JS library knows about 110+ cryptocurrency exchanges into language-agnostic JSON, so consumers in any language (Elixir, Rust, Go, Python) can call exchanges without walking AST. See [README.md](README.md) for user-facing setup and [ROADMAP.md](ROADMAP.md) for the active work plan — `ROADMAP.md` is **generated** by `rmap` (the roadmap CLI) from `roadmap/tasks.toml`; edit the TOML, not the Markdown (see § Documentation invariants).

## Project stance — greenfield

This repo is in **greenfield mode until further notice. No backward compatibility.**
Removing complexity is the priority. When in doubt: delete the old path, don't wrap it.

- Old schema versions are deleted, not retained alongside the new one.
- Do not add compatibility shims, migration aliases, dual-version dispatch, or
  "one release" retention windows without explicit user direction.
- Breaking changes do not require a deprecation period — the sole consumer
  (`../ccxt_client/`) takes one coordinated migration.

## Delivery target — `feature_complete` milestone

**v4 schema cut: ✅ shipped 2026-05-18.** The active milestone is now **`feature_complete`** — run `rmap milestones` for the live count. Definition: every pending task in the contract-defining phases (9 override infra, 11 request, 12 response, 13 error, 15 WS, 16 currency) + the method-descriptors bundle + the infrastructure tasks that gate them.

**Why this milestone is the goal.** Closing `feature_complete` ends ccxt_extract's mission for `../ccxt_client/`. After it lands, ccxt_client can freeze the v4 JSON it consumes and treat further ccxt_extract releases as **optional regenerations against new CCXT versions**, not a live dependency. The architecture supports this — `ccxt_extract` is a generator, not an ingestion runtime; the JSON it emits is a static, schema-pinned contract that ccxt_client can fork, vendor, or own outright once the milestone closes.

**How to pick the next task.** Use `rmap next --milestone feature_complete`. **It filters dep-blocked tasks**, so the visible list is "pickable now" not "the whole milestone" — `rmap list --status pending --milestone feature_complete` is the full inventory, and `rmap next --marker parallel` surfaces the worktree-dispatchable subset. **Do not name specific task numbers, Eff scores, or a "current queue" in this file** — rmap already computes what has shipped, what is unblocked, and what is pickable; any snapshot here rots on the next merge. Ask rmap at runtime.

**Scope discipline.** `feature_complete`'s membership is **exclusion-driven** — blocked / superseded / pure-hygiene tasks stay out by design. Push back on proposals to add new contract-surface tasks unless a priority consumer (typically `../ccxt_client/`) has surfaced a concrete need; the milestone is a *ceiling*, not a backlog. Infrastructure / hygiene tasks join only when they gate an existing milestone task (the pattern Task 144 set, where downstream tasks gained a `depends_on` edge + an enforcement acceptance criterion).

## Standard imports

Per `~/.claude/setup-guide.md` § Selective-Load Philosophy (Opus 4.8): eager-load only the irreducible floor; everything else is **skill-on-demand**. `response-conventions` loads globally via `~/.claude/CLAUDE.md`. The floor here is two includes:

- **`critical-rules`** — hard guardrails that must stay ambient every session (a guardrail the model invokes "when relevant" fails exactly when it doesn't realize the rule applies).
- **`harness-workflow`** — this repo is **harness-registered with auto-land**, so the implement → review → land loop and its delegation roster (cursor / codex / grok first, **opus only if needed** — opus tokens are precious) are load-bearing every session, not on-demand reference. (The `harness.yml` GitHub Action is the separate deterministic CI gate that auto-land's merge waits on.)

@~/.claude/includes/critical-rules.md
@~/.claude/includes/harness-workflow.md

Everything this repo previously eager-imported is now reachable as an auto-synced skill with a byte-identical body — `@`-importing one **and** enabling its sibling skill pays twice for the same tokens. The mapping:

- **Roadmap / workflow** → `tasks:rmap`, `tasks:roadmap-planning`, `tasks:task-writing`, `workflow:workflow-philosophy`, `workflow:git-worktrees`, `elixir:web-command`
- **Elixir core** → `elixir:ex-unit-json`, `elixir:dialyzer-json`, `elixir:code-style`, `elixir:development-commands`, `elixir:development-philosophy`, `elixir:elixir-setup`
- **Volt + static analysis** → `elixir-volt:elixir-volt`, `elixir-volt:oxc`, `elixir-volt:quickbeam`, `elixir-volt:npm-ci-verify`, `elixir:reach`

The model self-invokes these on matching work; the *hard* parts are hook-enforced independently (no-IO-in-`@doc` + TODO-tagging via `warn-doctest-io-and-untagged-todos.sh`; format / compile-warnings / credo / doctor / sobelow via the pre-commit stack).

**Re-add candidates (per-project escape hatch).** `oxc`, `quickbeam`, and `reach` are niche custom Hex packages this codebase is *built on* — the OXC/QuickBEAM two-tool extraction pipeline and Reach's `taint_analysis` in `contract_test` (`paths_rw_split` invariant). Their includes carry "runtime-verified corrections to common misconceptions" (atom-keyed AST, the browser-stub footgun, source-vs-BEAM frontend). If you observe Opus guessing these APIs, `@`-import the specific one for this project rather than re-eager-loading the whole stack — that's the setup-guide-sanctioned reversal, kept empirical (re-add on observed failure, not preemptively).

## Plugins & MCP

**Project-scope plugins** (`.claude/settings.json`, committed — visible to anyone cloning the repo):

| Plugin | Purpose |
|---|---|
| `elixir@zenhive` | Elixir skills + agents (hex-docs-search, integration-testing, dialyzer-json, ex-unit-json, usage-rules, npm-* suite, reach, etc.) |
| `elixir-volt@zenhive` | Volt-stack skills — `oxc`, `quickbeam`, `elixir-volt`, npm-* suite. This repo's two-tool extraction pipeline (OXC Rust NIF + QuickBEAM Zig NIF) is built on it. |
| `elixir-workflows@zenhive` | Mix / ExUnit / dev workflow commands; `workflow-generator` skill |
| `harness@zenhive` | `harness-driver` + `harness-workflow` skills — this repo is harness-registered with auto-land (`landing_policy: auto`, target `development`). |

The `zenhive` marketplace (`ZenHive/claude-marketplace`) is declared in this file's `extraKnownMarketplaces` so a fresh clone resolves these without relying on user-scope registration. Universal-core plugins (code-simplifier, feature-dev, claude-md-management, hookify, remember, git-commit, review, tasks, workflow, delegation, dev-discipline, codex) load at user scope and apply here implicitly — don't re-declare. New stack-specific plugins go in `.claude/settings.json`. See `~/.claude/plugin-catalog.md` for the picker.

**MCP servers** (`.mcp.json`, committed):

| Server | Endpoint | Purpose |
|---|---|---|
| `tidewave` | `http://localhost:4002/tidewave/mcp` | Runtime exploration via `mcp__tidewave__*` — `project_eval`, `get_logs`, `get_source_location`, `get_docs`, `search_package_docs`. Started by `mix tidewave` (or `iex -S mix tidewave`). |
| `harness` | `http://localhost:4018/harness/mcp` | Implement → review → land dispatch via `mcp__harness__*` — `dispatch-task`, `dispatch-await`, `dispatch-status`, `roadmap-*`, `project_registry-*`. Served by the long-lived harness BEAM (`iex -S mix` in the harness checkout). |

Tidewave port for this repo is 4002 (see `~/.claude/tidewave-ports.md` registry). Restart Claude Code if `.mcp.json` changes.

---

## Worktree workflow

Branch-worthy work lives in a git worktree at `~/_DATA/worktrees/ccxt_extract/<id>/`, not on a branch in the main checkout (`~/_DATA/code/ccxt_extract/`). The worktree IS the scope authorization for `git commit` / `git push` / `gh pr create` on that branch — full rules in `~/.claude/includes/worktree-workflow.md`.

**This repo's tracking-ID convention:** `<id>` is the ROADMAP task number when the work tracks a roadmap entry (e.g. `task-105`, `task-119`), or a short feature name for unscheduled work (e.g. `fix-aggregate-merge`). With cloud-agent delegation retired (see ROADMAP.md § Notes), Linear issue IDs are no longer in scope as worktree IDs.

**Cleanup:** after PR merge or branch deletion, run `git worktree remove ~/_DATA/worktrees/ccxt_extract/<id>` and `git worktree prune` in the same session — completion of a task includes worktree teardown.

**Corpus in fresh worktrees:** the gitignored extraction corpus (`priv/output/`, `priv/discoveries/<not class_hierarchy.json>`, `priv/ccxt/`, `priv/ccxt_bundle.js`) is filesystem-isolated per worktree — git only materializes tracked content when adding a worktree. Run `mix ccxt_extract.link_corpus` to symlink the existing corpus from the main checkout instead of regenerating via `mix ccxt_extract.update`. Run `mix ccxt_extract.unlink_corpus` before regenerating in-worktree — directory symlinks are write-transparent, so corpus regeneration without unlinking writes back into the main checkout.

**`[P]` parallel marker in ROADMAP.md** — independent tasks tagged `[P]` are explicitly safe to dispatch into separate worktrees concurrently. They predate cloud delegation and are unaffected by the `[CSR]` retirement.

---

## Architecture (big picture)

### Two extraction tools, one pipeline

Every output field is produced by exactly one of two complementary passes. Understanding which pass owns which field is critical before editing.

| Tool | Input | Output scope | Speed | Used in |
|------|-------|--------------|-------|---------|
| **OXC** (Rust NIF) | CCXT TS source at `priv/ccxt/ts/src/` | **Structural** — method ASTs, class hierarchy, type annotations, section membership, sign-method bodies | ~43ms per file | `oxc_extractor`, `oxc_batch`, `method_ast`, `parse_methods` (discovery files only — not emitted to per-exchange JSON since schema 3.0.0 / Task 117; Phase 12 consumes from `priv/discoveries/parse_methods.json`), `method_descriptors` (Task 121 — discovery-only TS signature + JSDoc overlay), `sign_method`, `sign_recipe` (scaffold, Task 64 — populated by Tasks 65–69), `handle_errors`, `throw_dispatches`, `error_class_hierarchy` (Task 87 — corpus-global tree from `errorHierarchy.ts`, copied into every per-exchange JSON), `interface_signatures`, `request_defaults`, `ws_methods` (discovery files only — same Phase 15 treatment), `ws_heartbeat` (Task 93 — emits the per-exchange `websocket.heartbeat` section), `ws_auth` (Task 92 — emits the per-exchange `websocket.auth` section), `ws_dispatch` (Task 94 — emits the per-exchange `websocket.dispatch` section), `ws_orderbook_semantics` (Task 95a), `ws_trades_semantics` (Task 95b), `ws_ohlcv_semantics` (Task 95c) |
| **QuickBEAM** (Zig NIF) | `priv/ccxt_bundle.js` (the browser bundle copied during `ccxt_extract.setup`) | **Resolved runtime** — full `describe()` after inheritance, URL templates, rate limits, nonce defaults, request headers | ~13s for all exchanges | `quickbeam_runtime`, `describe`, `load_markets`, `url_templates`, `signing_fixtures`, `request_headers` |

Neither tool alone is sufficient. `contract_test` cross-validates the two (e.g., every method named in resolved `describe().api` must exist in the parsed class AST or an ancestor). Divergence means a silent regression — fix the extractor, not the test.

### Per-exchange JSON pipeline

Raw extractors write to `priv/discoveries/*.json` (and subdirs like `describe/<id>.json`, `load_markets/<id>.json`). `CcxtExtract.Pipeline` then assembles those into per-exchange files under `priv/output/<id>.json` validated against `priv/schema/exchange_v4.json`. The v4 top-level groups are `endpoints`, `auth`, `errors`, `rate_limits`, `normalization`, `websocket`, `markets`, `testnet`, and `raw` (consumer-shaped, not producer-shaped — see `SCHEMA.md` for the full path-migration table). Provenance is explicit — every emitted JSON carries a flat top-level `_provenance` map keying each section (by RFC 6901 JSON Pointer) to `raw`/`derived`/`override`. Override *reasons* live in the `priv/overrides/<id>.json` entry, not inline in the emitted payload.

**Both paths are gitignored derived state.** `priv/output/` and `priv/discoveries/*` are not tracked in git — they're regenerated per CCXT release and would otherwise bloat the repo (~1GB of JSON per full-universe run, already accumulated 827MB in `.git`). The one exception is `priv/discoveries/class_hierarchy.json`, which `lib/ccxt_extract/tiers.ex` reads at compile time via `@external_resource` and must remain committed. Fresh clones materialize the rest via `mix setup`; external consumers via `mix ccxt_extract.update --output DIR`.

**Re-track evaluated and deferred (Task 136).** Task 114 made extraction byte-deterministic for a fixed CCXT version + bundle, so the working assumption was that re-tracking `priv/output/` would now yield meaningful, infrequent diffs. A real two-version measurement (v4.5.54 → v4.5.56, regenerated same-wall-clock so live data cancels) says **determinism is necessary but not sufficient** — two churn sources survive it:
  1. **Live `markets` data is not version-pinned.** `markets.symbols_index` + `markets.currencies` come from live `loadMarkets()` HTTP calls and are 5–45% (avg ~22%) of each per-exchange file. Two regenerations ~5 minutes apart already drifted for `deribit` and `bitmex` (new option expiries / listings). The determinism gate only holds back-to-back; across the days between real CCXT bumps, most exchanges' market listings drift, so a re-tracked corpus would churn on *every* regeneration regardless of version.
  2. **Method ASTs embed absolute source byte offsets.** `raw.overrides_meta.*.new_methods` carries each node's `start`/`end` byte offset, so a small edit near the top of a source file shifts every downstream offset and rewrites the (large) AST blob — `okx`'s 16-line source change produced a 102KB packed git delta, defeating delta-compression.
  Costs measured: one-time ~7.94MB packed for the full 116-file corpus (≈1% of `.git`); ~955KB packed for an 8-exchange two-version bump. The git-status safety rail re-arms automatically the moment `priv/output/` leaves `.gitignore` (`git status --porcelain` stops hiding it) — no code change needed. `priv/discoveries/` (733MB, pure intermediate, zero consumer value) is a clear no. **Path to re-track:** exclude or snapshot-pin the live `markets` subtree from the tracked artifact, and make AST offsets relative/strippable, then re-track the version-deterministic remainder. Until then `priv/output/` stays gitignored. See `CHANGELOG.md` § Task 136 for the full measurement.

The stages are, in order:

1. **`mix ccxt_extract.exchanges`** — discover the universe of exchange IDs.
2. **Per-extractor mix tasks** — each writes a slice to `priv/discoveries/`.
3. **`mix ccxt_extract.pipeline`** — merges slices into `priv/output/<id>.json`.
4. **`mix ccxt_extract.update`** — orchestrator: runs 1+2+3 as one scoped transaction.
5. **`mix ccxt_extract.validate`** — JSV-validates every output against the schema.
6. **`mix ccxt_extract.contract_test`** — runs cross-extractor invariants.

### Determinism gate

Extraction is **byte-deterministic** for a fixed CCXT version + bundle + scope: two consecutive runs of the same scope produce byte-identical output (Task 114). Two mechanisms enforce this:

- **`mix ccxt_extract.determinism_check`** runs an extraction task twice into isolated tmp dirs and byte-diffs every `.json` file. It freezes the timestamp envelope keys (`extracted_at`, `generated_at`, `checked_at`, `validated_at`, `recorded_at`) to a constant via `CcxtExtract.Clock` (overridable through application env) while the tasks execute, then re-encodes both sides through sorted-key canonical JSON so map-iteration order can't masquerade as drift. `--strip-keys` remains available for custom fields or other JsonDiff consumers (e.g. signing fixture parity). Exit non-zero on any divergence. Run it after touching any extractor or the pipeline.
- **`Pipeline.check_version_drift!/1`** runs at the top of `Pipeline.extract/1` and aborts loudly when `priv/ccxt` HEAD or `priv/ccxt_bundle.js` no longer matches the baseline in `priv/ccxt_version.json` — silent upstream drift can't regenerate the corpus against a different CCXT without a signal. Bypass with `--allow-version-drift` when the drift is intentional (a deliberate CCXT bump).

`AstNormalize.to_encodable/1` deep-sorts object keys before encoding — the load-bearing fix (Task 114) that, together with the Pattern B clock retrofit (Task 137), gives the current determinism guarantee without per-run key stripping in the common case.

### Scope is orthogonal to the stages

Every per-exchange extraction task takes the same flag set, parsed by `CcxtExtract.Scope`:

```
--tier1 --tier2 --tier3 --dex --all --exchange ID[,ID2] [--exchange ID3 ...]
```

`--exchange` is repeatable AND comma-split; unknown IDs abort with fuzzy suggestions via `String.jaro_distance/2`. Tier flags expand to **the whole family** (root + inheriting variants/aliases) by composing `Tiers.members_for_tier/1` with `class_hierarchy.json`. Default = full universe.

Corpus-level tasks (`setup`, `exchanges`, `base_methods`, top-level `validate`) run unscoped by design. `classes.ex` is a documented exception — flags only stamp `tier_scope`; the actual hierarchy load is always full-universe because family inheritance is load-bearing.

`AggregateWriter` merges scoped runs with existing on-disk aggregates and recomputes envelope totals from the final merged entries, so successive scoped runs accumulate without drift. **Do not** replace its merge logic with an overwrite.

### Paths: read vs write split (load-bearing for tests)

`CcxtExtract.Paths` splits read sites from write sites:

- `Paths.priv/1`, `Paths.priv_dir/0`, `Paths.discoveries/0`, `Paths.bundle/0`, `Paths.version_file/0`, `Paths.ts_src/0` — **reads**, honor `:priv_dir_override`.
- `Paths.out/1`, `Paths.out_priv_dir/0`, `Paths.out_bundle/0`, `Paths.out_version_file/0` — **writes**, honor `:priv_write_override` first, then fall through to `:priv_dir_override`.

Integration tests set the narrower `:priv_write_override` via `CcxtExtract.PrivWriteCase` (`test/support/priv_write_case.ex`) to redirect writes into a tmp dir while reads still hit the committed corpus. `PrivWriteCase` enforces `async: false` because the override is a VM-global app env. When adding a new write site, use `Paths.out(...)` / `out_bundle/0` / `out_version_file/0`, not the read helpers. External consumers running `mix ccxt_extract.update --output DIR` get the broader `:priv_dir_override` so everything (reads + writes) lands under `DIR`.

The split is enforced by the `paths_rw_split` corpus-level invariant in `mix ccxt_extract.contract_test` — `Reach.Project.taint_analysis/2` over `lib/**/*.ex` with a same-file filter. New direct-call leaks like `File.write!(Paths.priv(...))` surface at the next contract-test run.

### Safety rails

- `mix ccxt_extract.update` and `mix ccxt_extract.pipeline` abort if `priv/output/` or `priv/discoveries/` has uncommitted changes. Bypass with `--force`. The rail is skipped automatically under `--output DIR` (external target dirs aren't expected to be git repos).
- Safety-rail paths are computed through `Paths.out(...)` (not a compile-time `@attribute`) so the test overrides correctly isolate them.
- **Post-untrack note:** `priv/output/` and `priv/discoveries/*` (except `class_hierarchy.json`) are gitignored. The rail is effectively inert for ignored paths — `git status` doesn't see them, so no abort fires on regeneration. This is expected, not a regression. The rail still protects `priv/discoveries/class_hierarchy.json`, which is compile-time load-bearing and worth a manual pause when it drifts. The rail needs no code to re-arm if a path is re-tracked: it runs `git status --porcelain -- <path>`, which begins reporting `priv/output/` the instant it leaves `.gitignore` (verified during Task 136 — see the re-track note under "Per-exchange JSON pipeline").

### Tier-based scoping (philosophy)

Raw extraction runs for every CCXT exchange regardless of tier. **Derivation effort** (signing recipes, fee schedules, error handlers) is scoped to the **7-exchange option-seller set** — Tier 1 (`binance` + its `binanceusdm` variant, `bybit`, `okx`, `deribit`) plus priority DEX (`hyperliquid`, `derive`). Tier 2 is **intentionally empty** (see the frozen-curation note below). Tier 3 and unclassified exchanges receive `null + reason` for derived fields until a priority consumer surfaces a concrete need. Roots are hand-curated in `priv/priority_tiers.json`; variants inherit their root's tier via `class_hierarchy.json`. A tier task that exists only to handle Tier-3 quirks belongs in "Superseded / Deferred", not active phases.

The derivation scope is a **movable slider**. Re-add an exchange — or a matching family group — by lifting its root back into `tier1` / `tier2` / `dex` in `priv/priority_tiers.json`, then running a scoped `mix ccxt_extract.update --exchange <id>`. Raw discoveries are already on disk universe-wide, so a re-add only *unlocks derivation* — no catch-up extraction. `tier2` is kept as the empty key precisely as the staging bucket for these re-additions.

**Pre-narrow tier curation (frozen 2026-05-20).** Before the narrowing to the 7-exchange option-seller set, the tiers were:

| Tier  | Roots                                                                                                  |
|-------|--------------------------------------------------------------------------------------------------------|
| tier1 | binance, bybit, okx, deribit, coinbaseexchange                                                         |
| tier2 | kraken, kucoin, gate, htx, bitmex, bitfinex                                                            |
| tier3 | bitget, bingx, bitmart, coinex, cryptocom, mexc, hashkey, woo, dydx, paradex, apex, woofipro, modetrade |
| dex   | hyperliquid, aster, lighter, derive                                                                    |

The narrowing demoted `coinbaseexchange` (tier1→tier3), all six tier2 roots (→tier3), and `aster` + `lighter` (dex→tier3) when the sole consumer (`../ccxt_client/`) scoped to 7 exchanges, retiring the speculative market-maker / options framing that justified the broader set. This table is the reference for re-adding exchanges in matching family groups.

### Signing fixtures are the port contract

`priv/fixtures/signing/<id>.json` is the handoff between CCXT truth and any port. They're generated by calling CCXT's real `exchange.sign()` under frozen credentials, timestamps, and nonces (`Date.now() = 1700000000000`, etc.). Output is byte-identical across runs except `generated_at`. Consumers replay frozen inputs against their own signing code and assert byte-equal `url`/`method`/`headers`/`body`. Case preservation inside `input`/`output` (`apiKey`, `X-BAPI-SIGN`) IS the wire contract — do not camelize/snake-case at extraction time.

### Overrides

`priv/overrides/<id>.json` uses RFC 6901 JSON-Pointer paths with a `value` payload, required `reason`, and `verified_against`/`unverified` flags. `CcxtExtract.OverrideRegistry` validates them and the `override_registry_valid` contract-test invariant gates them. Overrides are a last resort for fields that extraction can't prove — every override needs a reason.

### Source of truth: CCXT, not exchange docs

Extraction targets the CCXT JS source (OXC) + resolved runtime (QuickBEAM) — **not** exchange-vendor API docs. CCXT is a reconciliation layer: years of maintainer work reconcile published docs → real wire behavior → exchange bugs → undocumented quirks, and that reconciliation lives in method bodies and `describe()` maps. Docs lag reality (CCXT routinely ships wire fixes before vendor docs update); 110+ exchanges mean 110+ incompatible doc shapes (rare OpenAPI specs, hand-written markdown, PDFs, Postman collections, occasional non-English-only pages). CCXT has already normalized that surface into one schema — that normalization is the asset this library crystallizes into JSON.

Exchange docs enter the pipeline in three narrow roles only:

1. **Override justification** — `verified_against` in `priv/overrides/<id>.json` cites a docs URL as evidence when an override corrects CCXT. Docs are evidence for a claim, not a primary source.
2. **Gap enrichment (Tier 1 only)** — fields CCXT doesn't model at all (leverage tiers, rebate schedules, sub-account limits). Track as a roadmap task before reading docs.
3. **Verification (future)** — a third-source check in `contract_test` would strengthen today's OXC-vs-QuickBEAM cross-check (still CCXT-vs-CCXT). Not yet built.

**Do not** propose redesigning the pipeline to read vendor docs as a primary source — that's 110× the work for less reliability. Narrow gaps go through overrides or a tracked task, not a refactor.

---

## Cross-surface git workflow

This repo gets worked from multiple Claude surfaces — Claude Code CLI (local clone), Claude macOS app (separate clone), occasionally the iOS app. Each surface has its own working copy; history on `zenhive` may have been rewritten by another surface between sessions. `git fetch --prune zenhive` early in every session.

When local is many commits ahead of remote, compare **author dates** against the remote tip before pushing. Locals authored **before** remote's last commit are usually duplicates of rewritten history from another surface (same message, different SHA), not new work — only commits authored **after** remote's tip are genuinely new.

To integrate after another surface's rewrite: `git rebase --onto zenhive/development <last-duplicate-sha> development -X theirs` replays only the genuinely-new commits and auto-resolves JSON conflicts toward local (regenerable via `mix ccxt_extract.update`). Never force-push.

---

## Common commands

```bash
# one-time setup (install CCXT, copy bundle, verify tools)
mix deps.get
mix ccxt_extract.setup

# full refresh, full universe
mix ccxt_extract.update

# scoped refresh — the 7-exchange derivation-scoped set
mix ccxt_extract.update --tier1 --dex

# single-exchange or mixed
mix ccxt_extract.update --exchange binance,deribit
mix ccxt_extract.update --tier1 --exchange hyperliquid

# write elsewhere (consumer's dir, no git rail)
mix ccxt_extract.update --tier1 --output /path/to/consumer/ccxt

# assemble only (discoveries → output/)
mix ccxt_extract.pipeline

# validate outputs against priv/schema/exchange_v4.json
mix ccxt_extract.validate

# cross-extractor invariants (QuickBEAM vs OXC)
mix ccxt_extract.contract_test

# verify extraction is byte-deterministic across consecutive runs
mix ccxt_extract.determinism_check

# regenerate port-contract signing vectors
mix ccxt_extract.signing_fixtures

# audit priv/overrides entries against AST/runtime probes
mix ccxt_extract.validate_overrides
mix ccxt_extract.validate_overrides --strict

# Tidewave MCP server (for runtime exploration via `mcp__tidewave__*`)
mix tidewave   # listens on http://localhost:4002

# tests (see test section below for flags)
time mix compile --warnings-as-errors
mix test.json --exclude extraction
mix test.json                      # includes :extraction (slow, requires priv/ccxt)
mix dialyzer.json --quiet
mix credo --strict --format json
mix sobelow --mark-skip-all        # re-mark skips after a scan
```

## Toolchain & check commands

**Reviewer-facing — this section is intentionally self-contained.** Cross-family reviewers (codex / cursor / grok under harness auto-land) read `AGENTS.md` (generated from this file by `claude-marketplace/scripts/sync-agents-md.sh`), not your local Claude skills. Since `ex_unit_json` / `dialyzer_json` are no longer eager-imported (Opus-4.8 skill-on-demand), the facts below must live here or reviewers won't have them.

- **Canonical gate:** `mix precommit.full` — format · compile (warnings-as-errors) · credo --strict · doctor · test+cover · dialyzer. The `harness.yml` GitHub Action runs the same stack as a deterministic PR check that auto-land's merge waits on.
- **`mix test.json` (`ex_unit_json`) emits JSON by design.** It is *not* a build failure — parse the payload for real failures (`summary.result`, `.tests[] | select(.state=="failed")`). Exit code 2 = test failures or coverage-below-threshold, **not** a tooling error. Flaky reds auto-heal via one isolated retry (a failure that passes on retry moves to `flaky[]` and exit code is 0).
- **`mix dialyzer.json` (`dialyzer_json`) emits JSON by design.** Same rule: never flag the JSON envelope as a crash. If the JSON encoder can't serialize a particular warning shape, **plain `mix dialyzer` is the authoritative dialyzer check** — fall back to it rather than reporting a failure.
- **`:extraction` tests are excluded by default** and require the gitignored corpus (`mix ccxt_extract.update` materializes it). CI runs `mix ccxt_extract.update` before the suite because `test_helper.exs` raises on missing corpus sentinels. Don't read an excluded/needs-corpus skip as a regression.

## Test conventions

- **`:extraction` tag is excluded by default** (`test/test_helper.exs` sets `ExUnit.start(exclude: [:extraction, :tier3_corpus, :flaky])`). Tests tagged `:extraction` hit the real CCXT source + bundle and are slow. Run them explicitly with `mix test.json --include extraction` when touching extractor internals. The `:flaky` exclude is permanent infra (no tests carry the tag in the green state) — Task 131 added it so `--exclude flaky` in `harness.yml:89` is operational the day a regression needs quarantine.
- **`Mix.shell()` is VM-global.** Tests that capture Mix output via `Mix.shell(Mix.Shell.Process)` MUST save `prior_shell = Mix.shell()` and restore in `try/after` or `on_exit`. Files that exercise code calling `Mix.shell().info(...)` and assert on `capture_io` should defensively pin `Mix.shell(Mix.Shell.IO)` in their parent `setup` — `setup_task_test.exs` is the reference pattern (Task 131). Without the pin, leaked `Mix.Shell.Process` from another file routes output via `:erlang.send` and `capture_io` returns `""`.
- **`Reach.Project.from_glob/1` carries a 5s `Task.async_stream` default.** Reach 2.2 doesn't thread a `:timeout` opt through `parse_files`/`build_module_sdgs`, so under async test pool contention even small fixture globs trip the timeout. Test files calling `ContractTest.check_paths_rw_split/1` (or `Reach.Project.from_glob/1` directly) should declare `async: false` until upstream Reach exposes a timeout knob. `contract_test_test.exs` is the reference (Task 131).
- **`test/integration/cached/*_cached_test.exs`** — assert against the already-committed `priv/discoveries/` corpus. Fast; they don't re-run extraction. **These dispatch on observed counts, not envelope stamps**, because committed fixtures may come from a scoped run (~34 exchanges) or a full run (~110). Use `CcxtExtract.Test.ScopeThresholds` (`test/support/scope_thresholds.ex`) — `min_count/3`, `min_total/4`, `proportional/2` — not ad-hoc `if count >= N` ladders. Cutoff must equal floor: `>= 90` branch returning `>= 100` creates a dead zone for counts in `[90, 99]`.
- **`test/integration/*_integration_test.exs`** (non-cached) — actually run extractors against `priv/ccxt`. Always tagged `:extraction`. Use `CcxtExtract.PrivWriteCase` to isolate writes, not ad-hoc rename/restore tricks.
- **`test/support/*.ex`** — only compiled when `MIX_ENV=test` (see `elixirc_paths(:test)` in `mix.exs`). Put test helpers here, not in `lib/`.
- Single-test runs: `mix test.json path/to/test.exs:LINE` or `mix test.json --failed` for fast iteration.

## Documentation invariants

Every task must update docs in lockstep with code — a task is incomplete until:

1. **[roadmap/tasks.toml](roadmap/tasks.toml)** — the typed source of truth for the roadmap. Flip task status with `rmap status <id> <state>` (or hand-edit the TOML), then `rmap render` regenerates `ROADMAP.md` + `roadmap/data.json`. **Do not hand-edit `ROADMAP.md`** — it is a generated view; `rmap` recomputes the focus block and Eff glyphs, so there is no separate "phase summary / Current Focus" sync step. `rmap validate --check-render` gates drift.
2. **[CHANGELOG.md](CHANGELOG.md)** — `## [Unreleased]` entry with what shipped and key decisions.
3. **[CLAUDE.md](CLAUDE.md)** — if architecture, conventions, or invariants moved.
4. **[SCHEMA.md](SCHEMA.md)** — if the emitted JSON shape changed.
5. **[CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md)** — if a checklist item moved between `⬜` / `🚧` / `✅`.
6. **[../ccxt_client/ROADMAP.md](../ccxt_client/ROADMAP.md)** (cross-repo rule) — flip or unblock any dependent consumer task. A ccxt_extract task is not complete until its downstream ccxt_client impact is reflected.

Scope-refactor work lives in [SCOPED-EXTRACTION-TASKS.md](SCOPED-EXTRACTION-TASKS.md) (Tasks 1–11 done; future envelope-stamping work tracked there as Task 13). The generic [REFACTOR.md](REFACTOR.md) tracks remaining structural cleanups.

## Review conventions

From [AGENTS.md](AGENTS.md): review requests get **one overall rating** for the intended or current change set. If staged vs unstaged mismatch matters, flag it as a finding or blocker, not as a separate score.
