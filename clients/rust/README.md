# Rust client (placeholder)

Reserved for a Rust consumer of ccxt_extract JSON. Not yet implemented.

Expected layout when it lands:

```
clients/rust/<crate-name>/
├── .git/            # independent git repo
├── Cargo.toml
├── build.rs         # reads ../../priv/output/*.json at build time
└── src/
```

Design notes live in [../../CONSUMER_CONTRACT.md](../../CONSUMER_CONTRACT.md).
