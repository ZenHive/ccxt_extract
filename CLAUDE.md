# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`ccxt_extract` is an Elixir library that serializes everything the CCXT JS library knows about 110+ cryptocurrency exchanges into language-agnostic JSON, so consumers in any language (Elixir, Rust, Go, Python) can call exchanges without walking AST. See [README.md](README.md) for user-facing setup and [ROADMAP.md](ROADMAP.md) for the active work plan.

## Standard imports

@~/.claude/includes/across-instances.md
@~/.claude/includes/critical-rules.md
@~/.claude/includes/task-prioritization.md
@~/.claude/includes/task-writing.md
@~/.claude/includes/workflow-philosophy.md
@~/.claude/includes/web-command.md
@~/.claude/includes/elixir-setup.md
@~/.claude/includes/ex-unit-json.md
@~/.claude/includes/dialyzer-json.md
@~/.claude/includes/code-style.md
@~/.claude/includes/development-commands.md
@~/.claude/includes/development-philosophy.md
@~/.claude/includes/elixir-volt.md
@~/.claude/includes/oxc.md
@~/.claude/includes/quickbeam.md
@~/.claude/includes/reach.md

---

## Architecture (big picture)

### Two extraction tools, one pipeline

Every output field is produced by exactly one of two complementary passes. Understanding which pass owns which field is critical before editing.

| Tool | Input | Output scope | Speed | Used in |
|------|-------|--------------|-------|---------|
| **OXC** (Rust NIF) | CCXT TS source at `priv/ccxt/ts/src/` | **Structural** — method ASTs, class hierarchy, type annotations, section membership, sign-method bodies | ~43ms per file | `oxc_extractor`, `oxc_batch`, `method_ast`, `parse_methods`, `sign_method`, `sign_recipe` (scaffold, Task 64 — populated by Tasks 65–69), `handle_errors`, `throw_dispatches`, `interface_signatures`, `request_defaults` |
| **QuickBEAM** (Zig NIF) | `priv/ccxt_bundle.js` (the browser bundle copied during `ccxt_extract.setup`) | **Resolved runtime** — full `describe()` after inheritance, URL templates, rate limits, nonce defaults | ~13s for all exchanges | `quickbeam_runtime`, `describe`, `load_markets`, `url_templates`, `signing_fixtures` |

Neither tool alone is sufficient. `contract_test` cross-validates the two (e.g., every method named in resolved `describe().api` must exist in the parsed class AST or an ancestor). Divergence means a silent regression — fix the extractor, not the test.

### Per-exchange JSON pipeline

Raw extractors write to `priv/discoveries/*.json` (and subdirs like `describe/<id>.json`, `load_markets/<id>.json`). `CcxtExtract.Pipeline` then assembles those into per-exchange files under `priv/output/<id>.json` validated against `priv/schema/exchange_v2.json`. Provenance is becoming explicit (see Phase 9 / Task 61a in ROADMAP) — fields will carry `raw`/`derived`/`override` tags plus the reason for any override.

The stages are, in order:

1. **`mix ccxt_extract.exchanges`** — discover the universe of exchange IDs.
2. **Per-extractor mix tasks** — each writes a slice to `priv/discoveries/`.
3. **`mix ccxt_extract.pipeline`** — merges slices into `priv/output/<id>.json`.
4. **`mix ccxt_extract.update`** — orchestrator: runs 1+2+3 as one scoped transaction.
5. **`mix ccxt_extract.validate`** — JSV-validates every output against the schema.
6. **`mix ccxt_extract.contract_test`** — runs cross-extractor invariants.

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

### Tier-based scoping (philosophy)

Raw extraction runs for every CCXT exchange regardless of tier. **Derivation effort** (signing recipes, fee schedules, error handlers) is scoped to Tier 1 + Tier 2 + priority DEX. Tier 3 and unclassified exchanges receive `null + reason` for derived fields until a priority consumer surfaces a concrete need. Roots are hand-curated in `priv/priority_tiers.json`; variants inherit their root's tier via `class_hierarchy.json`. A tier task that exists only to handle Tier-3 quirks belongs in "Superseded / Deferred", not active phases.

### Signing fixtures are the port contract

`priv/fixtures/signing/<id>.json` is the handoff between CCXT truth and any port. They're generated by calling CCXT's real `exchange.sign()` under frozen credentials, timestamps, and nonces (`Date.now() = 1700000000000`, etc.). Output is byte-identical across runs except `generated_at`. Consumers replay frozen inputs against their own signing code and assert byte-equal `url`/`method`/`headers`/`body`. Case preservation inside `input`/`output` (`apiKey`, `X-BAPI-SIGN`) IS the wire contract — do not camelize/snake-case at extraction time.

### Overrides

`priv/overrides/<id>.json` uses RFC 6901 JSON-Pointer paths with a `value` payload, required `reason`, and `verified_against`/`unverified` flags. `CcxtExtract.OverrideRegistry` validates them and the `override_registry_valid` contract-test invariant gates them. Overrides are a last resort for fields that extraction can't prove — every override needs a reason.

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

# scoped refresh — e.g. only priority families
mix ccxt_extract.update --tier1 --tier2 --dex

# single-exchange or mixed
mix ccxt_extract.update --exchange binance,deribit
mix ccxt_extract.update --tier1 --exchange hyperliquid

# write elsewhere (consumer's dir, no git rail)
mix ccxt_extract.update --tier1 --output /path/to/consumer/ccxt

# assemble only (discoveries → output/)
mix ccxt_extract.pipeline

# validate outputs against priv/schema/exchange_v2.json
mix ccxt_extract.validate

# cross-extractor invariants (QuickBEAM vs OXC)
mix ccxt_extract.contract_test

# regenerate port-contract signing vectors
mix ccxt_extract.signing_fixtures

# Tidewave MCP server (for runtime exploration via `mcp__tidewave__*`)
mix tidewave   # listens on http://localhost:4001

# tests (see test section below for flags)
time mix compile --warnings-as-errors
mix test.json --exclude extraction
mix test.json                      # includes :extraction (slow, requires priv/ccxt)
mix dialyzer.json --quiet
mix credo --strict --format json
mix sobelow --mark-skip-all        # re-mark skips after a scan
```

## Test conventions

- **`:extraction` tag is excluded by default** (`test/test_helper.exs` sets `ExUnit.start(exclude: [:extraction])`). Tests tagged `:extraction` hit the real CCXT source + bundle and are slow. Run them explicitly with `mix test.json --include extraction` when touching extractor internals.
- **`test/integration/cached/*_cached_test.exs`** — assert against the already-committed `priv/discoveries/` corpus. Fast; they don't re-run extraction. **These dispatch on observed counts, not envelope stamps**, because committed fixtures may come from a scoped run (~34 exchanges) or a full run (~110). Use `CcxtExtract.Test.ScopeThresholds` (`test/support/scope_thresholds.ex`) — `min_count/3`, `min_total/4`, `proportional/2` — not ad-hoc `if count >= N` ladders. Cutoff must equal floor: `>= 90` branch returning `>= 100` creates a dead zone for counts in `[90, 99]`.
- **`test/integration/*_integration_test.exs`** (non-cached) — actually run extractors against `priv/ccxt`. Always tagged `:extraction`. Use `CcxtExtract.PrivWriteCase` to isolate writes, not ad-hoc rename/restore tricks.
- **`test/support/*.ex`** — only compiled when `MIX_ENV=test` (see `elixirc_paths(:test)` in `mix.exs`). Put test helpers here, not in `lib/`.
- Single-test runs: `mix test.json path/to/test.exs:LINE` or `mix test.json --failed` for fast iteration.

## Documentation invariants

Every task must update docs in lockstep with code — a task is incomplete until:

1. **[ROADMAP.md](ROADMAP.md)** — task status flipped (`⬜` → `✅`), phase summary and "Current Focus" refreshed.
2. **[CHANGELOG.md](CHANGELOG.md)** — `## [Unreleased]` entry with what shipped and key decisions.
3. **[CLAUDE.md](CLAUDE.md)** — if architecture, conventions, or invariants moved.
4. **[SCHEMA.md](SCHEMA.md)** — if the emitted JSON shape changed (bump the schema version on breaking changes).
5. **[CONSUMER_CONTRACT.md](CONSUMER_CONTRACT.md)** — if a checklist item moved between `⬜` / `🚧` / `✅`.
6. **[../ccxt_client/ROADMAP.md](../ccxt_client/ROADMAP.md)** (cross-repo rule) — flip or unblock any dependent consumer task. A ccxt_extract task is not complete until its downstream ccxt_client impact is reflected.

Scope-refactor work lives in [SCOPED-EXTRACTION-TASKS.md](SCOPED-EXTRACTION-TASKS.md) (Tasks 1–11 done; future envelope-stamping work tracked there as Task 13). The generic [REFACTOR.md](REFACTOR.md) tracks remaining structural cleanups.

## Review conventions

From [AGENTS.md](AGENTS.md): review requests get **one overall rating** for the intended or current change set. If staged vs unstaged mismatch matters, flag it as a finding or blocker, not as a separate score.
