# clients/

Reference consumers of the ccxt_extract JSON output, organized by language.

## Layout

```
clients/
├── elixir/
│   └── ccxt_client/    # independent git repo (github.com/ZenHive/ccxt_client)
└── rust/
    └── <tbd>/          # placeholder for Rust client
```

## Nested-but-separate model

Each client lives at `clients/<lang>/<project>/` and is **its own git repository**. The
ccxt_extract `.gitignore` excludes `clients/*/*/` so nested repos stay independent —
they have their own history, branches, and remotes.

Why nested:
- One workspace for extractor + consumers (easier cross-repo changes during development)
- Consumers can read emitted JSON directly via relative paths in examples/scripts
- Filesystem proximity without monorepo entanglement

Why separate:
- Each client ships on its own release cadence
- Consumers in other languages can clone ccxt_extract alone (without pulling client code)
- Client repos have their own CI, issues, and contributors

## Adding a new client

1. Create `clients/<lang>/<project>/` (with its own `git init` or clone)
2. Consume JSON from `priv/output/` or via `mix ccxt_extract.pipeline --output clients/<lang>/<project>/<path>`
3. No changes needed to ccxt_extract's `.gitignore` — `clients/*/*/` already covers it

## Consuming the JSON

The canonical output lives at `priv/output/<exchange>.json` (one file per exchange).
Consumers read these files at compile time (Elixir macros, Rust `build.rs`,
Python codegen) or runtime (`json.load`). No AST walking required — see
[CONSUMER_CONTRACT.md](../CONSUMER_CONTRACT.md).
