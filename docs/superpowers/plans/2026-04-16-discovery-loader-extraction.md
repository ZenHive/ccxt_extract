# DiscoveryLoader Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract discovery-file I/O and validation from `pipeline.ex` into a new `CcxtExtract.DiscoveryLoader` module, leaving `pipeline.ex` focused on assembly logic.

**Architecture:** Mechanical refactor. All `load_*` private functions, `validate_exchange_*` clause forests, integrity-stats accumulation, `compute_canonical_has_keys/1`, and `read_json/1` move verbatim to a new module. `Pipeline.extract/1` gains one alias and three call-site edits. Safety net = existing tests + byte-identical output diff against a pre-refactor snapshot.

**Tech Stack:** Elixir, Jason (JSON), ExUnit (testing), Mix tasks (pipeline verification).

**Spec:** `docs/superpowers/specs/2026-04-16-discovery-loader-extraction.md`

---

## File Structure

**Create:**
- `lib/ccxt_extract/discovery_loader.ex` — new module, ~510 lines
- `test/ccxt_extract/discovery_loader_test.exs` — new isolation tests

**Modify:**
- `lib/ccxt_extract/pipeline.ex` — remove ~500 lines of loading code, add `alias CcxtExtract.DiscoveryLoader`, update 3 call sites; drops from 1,122 lines to ~628 lines
- `REFACTOR.md` — mark Item 1 shipped, add Item 8 (Paths promotion)
- `CHANGELOG.md` — add entry under `## [Unreleased]`

---

### Task 1: Establish baseline

**Files:** no changes — verification only.

- [ ] **Step 1: Run full test suite, verify green**

Run: `mix test --quiet`
Expected: all tests pass. If anything is red, STOP — do not start the refactor with a broken baseline.

- [ ] **Step 2: Snapshot current tier1 pipeline output**

Run:
```bash
mix ccxt_extract.pipeline --tier1 --output tmp/baseline_tier1
```
Expected: exits 0, writes per-exchange JSON to `tmp/baseline_tier1/`.

- [ ] **Step 3: Verify snapshot is non-empty**

Run: `ls tmp/baseline_tier1/ | wc -l`
Expected: >= 10 files (tier1 exchanges + `_manifest.json` + `exchange_v1.json` + `_base_methods.json`).

- [ ] **Step 4: No commit — baseline is working-tree-only**

The snapshot in `tmp/` is disposable; it only exists to diff against in Task 2 Step 9.

---

### Task 2: Extract DiscoveryLoader module

**Files:**
- Create: `lib/ccxt_extract/discovery_loader.ex`
- Modify: `lib/ccxt_extract/pipeline.ex`

- [ ] **Step 1: Create the new module file with skeleton**

Create `lib/ccxt_extract/discovery_loader.ex` with the following header:

```elixir
defmodule CcxtExtract.DiscoveryLoader do
  @moduledoc """
  Load and validate discovery artifacts produced by extractors.

  Reads the 14 discovery files (global + per-exchange) from the
  discoveries directory, validates each entry against its expected
  shape, accumulates integrity stats (missing/corrupt/orphan/id-mismatch
  entries), and returns the data map that `CcxtExtract.Pipeline`
  consumes during assembly.

  ## Usage

      {:ok, exchanges_json} = DiscoveryLoader.read_json("priv/discoveries/exchanges.json")
      data = DiscoveryLoader.load_all!("priv/discoveries", exchanges_json)
      data.describe   # => %{"binance" => %{...}, ...}
      data.missing_entries  # => []

  `load_all!/2` raises only when a manifest is structurally corrupt
  (non-string IDs, missing required top-level keys). Missing or invalid
  individual entries are captured in integrity stats rather than raised.
  """

  alias CcxtExtract.Schema

  @doc """
  Read all discovery files from `dir`, validate each, and return a map
  containing per-exchange lookups plus integrity stats.

  `exchanges_json` is the parsed `exchanges.json` envelope (caller-loaded
  so that the pipeline can short-circuit on missing-envelope before any
  loading work starts).
  """
  @spec load_all!(String.t(), map()) :: map()
  def load_all!(dir, exchanges_json) do
    # body moves from Pipeline.load_all_data/2 in Step 2
  end

  @doc """
  Read a JSON file and decode it.

  Returns `{:ok, decoded}`, `{:error, {:missing_input, detail}}` when the
  file does not exist, or `{:error, {:invalid_json, detail}}` when
  decoding fails.
  """
  @spec read_json(String.t()) ::
          {:ok, term()} | {:error, {:missing_input | :invalid_json, String.t()}}
  def read_json(path) do
    # body moves from Pipeline.read_json/1 in Step 2
  end
end
```

- [ ] **Step 2: Move the loading/validation code from pipeline.ex**

Cut the following from `lib/ccxt_extract/pipeline.ex`:

1. **Lines 418–428** (`compute_canonical_has_keys/1`) — move to DiscoveryLoader. Keep as `defp` inside the new module.
2. **Lines 580–1074** (`load_all_data/2` through `read_json/1`) — move to DiscoveryLoader.

In the destination file (`discovery_loader.ex`):
- Paste the `load_all_data/2` body as the body of the `load_all!/2` public function (remove the old `defp load_all_data(dir, exchanges_json) do` wrapper — keep only its body inside `def load_all!`).
- Paste `read_json/1` body as the body of the public `read_json/1` (change `defp` to `def`).
- Paste all other helpers as `defp` (they remain private to DiscoveryLoader).

Functions being moved (every one of them goes to DiscoveryLoader):
- `load_describe_files/2`, `reduce_describe_entry/3`, `read_describe_entry/2`
- `load_markets_files/2`, `reduce_markets_entry/3`, `read_markets_entry/2`, `markets_entry_id/1` (both clauses)
- `validate_manifest_ids!/2`
- `load_classes/3`
- `load_exchange_field/5`
- `load_sign_methods/3`
- `load_exchange_lookup/4`
- `load_overrides/3`
- `reduce_validated/3`
- `expected_exchange_ids/1`
- `empty_integrity_stats/0`
- `add_stat_entry/3`
- `record_directory_orphans/4`
- `record_global_orphans/4` (both clauses)
- `validate_expected_id/4`
- `validate_exchange_field_entry/3` (both clauses)
- `validate_exchange_lookup_entry/2` (all 14 clauses)
- `fetch_required_key/4`
- `validate_required_map_field/4` (both clauses)
- `validate_optional_map_field/4` (all 3 clauses)
- `compute_canonical_has_keys/1`
- `read_json/1` (now public)

The `alias CcxtExtract.Schema` in the DiscoveryLoader skeleton (Step 1) is required because the validation helpers call `Schema.type_name/1`.

- [ ] **Step 3: Update pipeline.ex — add alias**

In `lib/ccxt_extract/pipeline.ex`, update the alias block (around line 21–23) from:

```elixir
  alias CcxtExtract.Paths
  alias CcxtExtract.Schema
  alias CcxtExtract.ScopeCleanup
```

to:

```elixir
  alias CcxtExtract.DiscoveryLoader
  alias CcxtExtract.Paths
  alias CcxtExtract.Schema
  alias CcxtExtract.ScopeCleanup
```

- [ ] **Step 4: Update pipeline.ex — extract/1 call sites**

In `Pipeline.extract/1` (around lines 45–85), replace:

```elixir
    with {:ok, exchanges_json} <- read_json(exchanges_path) do
      data = load_all_data(dir, exchanges_json)
```

with:

```elixir
    with {:ok, exchanges_json} <- DiscoveryLoader.read_json(exchanges_path) do
      data = DiscoveryLoader.load_all!(dir, exchanges_json)
```

- [ ] **Step 5: Update pipeline.ex — read_ccxt_version_info/0**

In `Pipeline.read_ccxt_version_info/0` (around line 1080), replace:

```elixir
  defp read_ccxt_version_info do
    case read_json(Paths.version_file()) do
      {:ok, data} -> data
      {:error, _} -> %{}
    end
  end
```

with:

```elixir
  defp read_ccxt_version_info do
    case DiscoveryLoader.read_json(Paths.version_file()) do
      {:ok, data} -> data
      {:error, _} -> %{}
    end
  end
```

- [ ] **Step 6: Compile and verify no dangling references**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly, zero warnings. If the compiler reports `undefined function load_all_data/2` or `undefined function read_json/1` inside `Pipeline`, you missed a call site — search pipeline.ex for `load_all_data` and `read_json` and fix the remaining references.

Run: `grep -n "load_all_data\|read_json\|compute_canonical_has_keys" lib/ccxt_extract/pipeline.ex`
Expected: zero results (all moved to DiscoveryLoader).

- [ ] **Step 7: Run full test suite**

Run: `mix test --quiet`
Expected: identical pass/fail count as the Task 1 Step 1 baseline. If any previously-passing test now fails, investigate before continuing — the move was not behavior-preserving.

- [ ] **Step 8: Run cached integration path**

Run: `mix test test/integration/cached/pipeline_cached_test.exs --quiet`
Expected: all tests pass.

- [ ] **Step 9: Verify byte-identical pipeline output**

Run:
```bash
mix ccxt_extract.pipeline --tier1 --output tmp/post_refactor_tier1
diff -r tmp/baseline_tier1 tmp/post_refactor_tier1
```
Expected: zero output from `diff` (files are byte-identical). `_manifest.json` may differ only in `extracted_at` if the fixture isn't stamped — check the diff output; if the only difference is `extracted_at`, that's acceptable. Any other difference means the refactor changed behavior.

- [ ] **Step 10: Commit**

```bash
git add lib/ccxt_extract/discovery_loader.ex lib/ccxt_extract/pipeline.ex
git commit -m "refactor: extract DiscoveryLoader from pipeline.ex

Moves ~500 lines of discovery-file I/O and validation out of
pipeline.ex into a new CcxtExtract.DiscoveryLoader module.
Pipeline drops from 1,122 to ~628 lines; DiscoveryLoader owns
the full data map shape (including canonical_has_keys).

Behavior-preserving: existing tests green, tier1 output
byte-identical to pre-refactor baseline.

REFACTOR.md Item 1."
```

---

### Task 3: Add DiscoveryLoader isolation tests

**Files:**
- Create: `test/ccxt_extract/discovery_loader_test.exs`

- [ ] **Step 1: Write the skeleton with a passing smoke test**

Create `test/ccxt_extract/discovery_loader_test.exs`:

```elixir
defmodule CcxtExtract.DiscoveryLoaderTest do
  @moduledoc """
  Isolation tests for DiscoveryLoader — exercise the loader's contract
  (shape of returned data, integrity stats) against synthetic fixtures
  under `tmp_dir`. No QuickBEAM/OXC, no real priv/discoveries data.
  """
  use ExUnit.Case, async: true

  alias CcxtExtract.DiscoveryLoader

  describe "read_json/1" do
    @tag :tmp_dir
    test "returns {:ok, decoded} for valid JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "valid.json")
      File.write!(path, ~s({"hello": "world"}))
      assert {:ok, %{"hello" => "world"}} = DiscoveryLoader.read_json(path)
    end

    @tag :tmp_dir
    test "returns {:error, {:missing_input, _}} for missing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.json")
      assert {:error, {:missing_input, detail}} = DiscoveryLoader.read_json(path)
      assert detail =~ "absent.json"
    end

    @tag :tmp_dir
    test "returns {:error, {:invalid_json, _}} for malformed JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.json")
      File.write!(path, "{not json")
      assert {:error, {:invalid_json, detail}} = DiscoveryLoader.read_json(path)
      assert detail =~ "bad.json"
    end
  end
end
```

Run: `mix test test/ccxt_extract/discovery_loader_test.exs --quiet`
Expected: 3 tests, 0 failures.

- [ ] **Step 2: Add load_all!/2 happy-path test**

Append to the `describe/do` block is not needed — add a new `describe` block to the same file, before the `end` that closes the module:

```elixir
  describe "load_all!/2 shape" do
    @tag :tmp_dir
    test "returns full data map with all expected keys", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: [],
        markets_succeeded: []
      )

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      expected_keys = ~w(exchanges describe load_markets classes methods_rest
                        methods_ws sign_methods handle_errors parse_methods
                        ws_methods interface_signatures pagination
                        unified_endpoints url_templates overrides
                        canonical_has_keys missing_files missing_entries
                        corrupt_entries orphan_entries id_mismatch_entries)a

      for key <- expected_keys do
        assert Map.has_key?(data, key), "expected key #{inspect(key)} in load_all! result"
      end
    end
  end
```

Also append the fixture helpers (copy the `write_minimal_fixtures/2` and `write_json/2` patterns from `test/ccxt_extract/pipeline_test.exs:1104-1155` — adjust `write_minimal_fixtures` to live inside this test module):

```elixir
  defp write_minimal_fixtures(dir, opts) do
    describe_exchanges = Keyword.get(opts, :describe_exchanges, [])
    markets_succeeded = Keyword.get(opts, :markets_succeeded, [])

    all_exchanges = [
      %{
        "id" => "fakex",
        "name" => "Fake Exchange",
        "certified" => false,
        "pro" => false,
        "version" => nil,
        "country" => [],
        "alias" => false,
        "referral" => nil
      }
    ]

    write_json(Path.join(dir, "exchanges.json"), %{"exchanges" => all_exchanges})
    write_json(Path.join(dir, "class_hierarchy.json"), %{"classes" => []})

    empty_global = %{"exchanges" => []}
    write_json(Path.join(dir, "methods_rest.json"), empty_global)
    write_json(Path.join(dir, "methods_ws.json"), empty_global)
    write_json(Path.join(dir, "sign_methods.json"), empty_global)
    write_json(Path.join(dir, "handle_errors.json"), empty_global)
    write_json(Path.join(dir, "parse_methods.json"), empty_global)
    write_json(Path.join(dir, "ws_methods.json"), empty_global)
    write_json(Path.join(dir, "interface_signatures.json"), empty_global)
    write_json(Path.join(dir, "pagination.json"), empty_global)
    write_json(Path.join(dir, "unified_endpoints.json"), empty_global)
    write_json(Path.join(dir, "url_templates.json"), empty_global)
    write_json(Path.join(dir, "overrides.json"), empty_global)

    write_json(Path.join(dir, "describe/_manifest.json"), %{"exchanges" => describe_exchanges})

    write_json(Path.join(dir, "load_markets/_manifest.json"), %{
      "succeeded" => markets_succeeded
    })
  end

  defp write_json(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
  end
```

Run: `mix test test/ccxt_extract/discovery_loader_test.exs --quiet`
Expected: 4 tests, 0 failures.

- [ ] **Step 3: Add integrity-stats tests**

Append to the test module, before the closing `end`:

```elixir
  describe "load_all!/2 integrity stats" do
    @tag :tmp_dir
    test "missing describe/_manifest.json records a missing_files entry", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir, describe_exchanges: [], markets_succeeded: [])
      # Remove the describe manifest we just wrote
      File.rm!(Path.join(tmp_dir, "describe/_manifest.json"))

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert "describe/_manifest.json" in data.missing_files
    end

    @tag :tmp_dir
    test "missing per-exchange describe file records missing_entries", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )
      # Manifest lists fakex but the per-exchange file is absent.

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert "describe/fakex.json" in data.missing_entries
    end

    @tag :tmp_dir
    test "corrupt JSON raises for a global file", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir, describe_exchanges: [], markets_succeeded: [])
      File.write!(Path.join(tmp_dir, "handle_errors.json"), "{not json")

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}

      assert_raise RuntimeError, ~r/Corrupt discovery artifact/, fn ->
        DiscoveryLoader.load_all!(tmp_dir, exchanges_json)
      end
    end

    @tag :tmp_dir
    test "id mismatch in per-exchange describe file is recorded", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      # Write a describe file whose top-level id disagrees with the manifest.
      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "other",
        "describe" => %{"id" => "other"}
      })

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert Enum.any?(data.id_mismatch_entries, &String.contains?(&1, "describe/fakex.json"))
    end
  end
```

Run: `mix test test/ccxt_extract/discovery_loader_test.exs --quiet`
Expected: 8 tests, 0 failures.

- [ ] **Step 4: Add compute_canonical_has_keys coverage**

Append to the test module, before the closing `end`:

```elixir
  describe "canonical_has_keys derivation" do
    @tag :tmp_dir
    test "computes union of has keys across loaded describe entries", %{tmp_dir: tmp_dir} do
      write_minimal_fixtures(tmp_dir,
        describe_exchanges: ["fakex"],
        markets_succeeded: []
      )

      write_json(Path.join(tmp_dir, "describe/fakex.json"), %{
        "id" => "fakex",
        "describe" => %{
          "id" => "fakex",
          "has" => %{"fetchTicker" => true, "fetchOHLCV" => false}
        }
      })

      exchanges_json = %{"exchanges" => [%{"id" => "fakex"}]}
      data = DiscoveryLoader.load_all!(tmp_dir, exchanges_json)

      assert MapSet.member?(data.canonical_has_keys, "fetchTicker")
      assert MapSet.member?(data.canonical_has_keys, "fetchOHLCV")
    end
  end
```

Run: `mix test test/ccxt_extract/discovery_loader_test.exs --quiet`
Expected: 9 tests, 0 failures.

- [ ] **Step 5: Run the full suite to confirm no collateral damage**

Run: `mix test --quiet`
Expected: same pass/fail count as Task 2 Step 7 plus 9 new passing tests in discovery_loader_test.exs.

- [ ] **Step 6: Commit**

```bash
git add test/ccxt_extract/discovery_loader_test.exs
git commit -m "test: DiscoveryLoader isolation tests

Covers read_json/1 error paths, load_all!/2 return shape,
integrity stats (missing/corrupt/id-mismatch), and
canonical_has_keys derivation. 9 tests, all green.

Fixtures use write_minimal_fixtures pattern from
pipeline_test.exs for consistency."
```

---

### Task 4: Update project documentation

**Files:**
- Modify: `REFACTOR.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Mark REFACTOR.md Item 1 as shipped**

In `REFACTOR.md`, change the Item 1 heading from:

```markdown
## Item 1: Extract DiscoveryLoader from pipeline.ex

**D: 3 / B: 5 — ROI: 1.67**
```

to:

```markdown
## ~~Item 1: Extract DiscoveryLoader from pipeline.ex~~ ✅

**D: 3 / B: 5 — ROI: 1.67** — **SHIPPED 2026-04-16**

Extracted `CcxtExtract.DiscoveryLoader` — ~500 lines of discovery-file
I/O, validation, and integrity-stats accumulation moved out of
pipeline.ex. Pipeline dropped from 1,122 to ~628 lines. Loader owns the
full data map shape including `canonical_has_keys`. 9 isolation tests
added. Output byte-identical to pre-refactor baseline.
```

- [ ] **Step 2: Remove the "What to extract" / "What stays" / "Verification checkpoints" / "Estimated scope" subsections for Item 1**

These were the implementation spec; now that the item is shipped the shipped-summary above replaces them. Delete those subsections from REFACTOR.md so Item 1's section is just the header above plus a horizontal rule before Item 2.

- [ ] **Step 3: Update the dependency-order paragraph at the top of REFACTOR.md**

Lines 7–9 currently read:

```markdown
**Dependency order:** Item 1 (DiscoveryLoader) should land before Item 3
(generic override merge) — 61b needs clean seams in pipeline.ex to wire into.
Item 2 (Schema.validate removal) is independent of both.
```

Replace with:

```markdown
**Dependency order:** Items 1 and 2 are shipped. Item 3 (generic override
merge / Task 61b) can now wire into the clean pipeline seams Item 1
produced. Item 8 (below) is independent.
```

- [ ] **Step 4: Add new Item 8 at the bottom of REFACTOR.md**

Append before the `## Deferred Items` section:

```markdown
## Item 8: Promote `read_json/1` to `CcxtExtract.Paths`

**D: 1 / B: 2 — ROI: 2.00**

`read_json/1` is duplicated across 7 modules: `discovery_loader.ex`,
`describe_key_analysis.ex`, `method_analysis.ex`, `summary.ex`,
`public_exchanges.ex`, `coverage_report.ex`, `family_analysis.ex`. Each
copy is the same 13-line `File.read/1` + `Jason.decode!/1` + `{:missing_input | :invalid_json}` tuple shape.

### Plan

Promote to `CcxtExtract.Paths.read_json/1` (or a new `CcxtExtract.JsonIO`
module) and delete the 7 private copies. Mechanical, single-pass. Do
this when next touching any of the 7 consumer modules so the cost is
amortized.

### Verification

`mix test --quiet` — no behavior change expected; every caller still
gets the same `{:ok, _}` / `{:error, {:missing_input | :invalid_json, _}}` shape.

---
```

- [ ] **Step 5: Update CHANGELOG.md**

In `CHANGELOG.md`, under `## [Unreleased]` (create the section if it does not exist), add:

```markdown
### Changed

- **Refactor: extract DiscoveryLoader from pipeline.ex** (REFACTOR.md
  Item 1). `CcxtExtract.Pipeline` drops from 1,122 to ~628 lines;
  `CcxtExtract.DiscoveryLoader` (new) owns all discovery-file I/O,
  validation, integrity-stats accumulation, and `canonical_has_keys`
  derivation. Public API: `DiscoveryLoader.load_all!/2` and
  `DiscoveryLoader.read_json/1`. 9 new isolation tests; pipeline
  output byte-identical to pre-refactor baseline.
```

- [ ] **Step 6: Verify the docs parse and build succeeds**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly.

Run: `mix test --quiet`
Expected: identical pass/fail count to Task 3 Step 5.

- [ ] **Step 7: Clean up baseline snapshot**

Run: `rm -rf tmp/baseline_tier1 tmp/post_refactor_tier1`

- [ ] **Step 8: Commit**

```bash
git add REFACTOR.md CHANGELOG.md
git commit -m "doc: mark REFACTOR.md Item 1 shipped, add Item 8

Item 1 (DiscoveryLoader extraction) complete — update the
shipped-summary and dependency-order note. Add Item 8 for
the future read_json/1 -> Paths promotion (7 duplicated
copies, D:1/B:2/ROI:2.00)."
```

---

## Self-Review Checklist

- [x] **Spec coverage.** Spec sections (new module, public API, private functions moved, what stays, call-site edits, verification checkpoints, deferred Item 8) each map to a task: Task 2 implements the move and wiring; Task 3 covers the new isolation tests from the spec's verification list; Task 4 covers the deferred Item 8 addition.
- [x] **Placeholder scan.** No TBDs, no "implement later", no "similar to Task N". Every code block shown is the actual code the engineer types.
- [x] **Type consistency.** Public API used consistently: `DiscoveryLoader.load_all!/2` and `DiscoveryLoader.read_json/1` throughout. Private helper names (`write_minimal_fixtures/2`, `write_json/2`) match the patterns copied from `pipeline_test.exs:1104-1155`.
- [x] **Line number references.** `pipeline.ex:418-428` and `pipeline.ex:580-1074` are explicit. `pipeline_test.exs:1104-1155` is explicit for the fixture helper source.
- [x] **Commit cadence.** Three commits: extract (Task 2), tests (Task 3), docs (Task 4). Each represents a coherent atomic change reviewable in isolation.
