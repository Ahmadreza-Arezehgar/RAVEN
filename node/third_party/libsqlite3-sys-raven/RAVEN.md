# RAVEN libsqlite3-sys fork (Task 0A.2)

Local audited fork of **libsqlite3-sys 0.38.2** (`links = "sqlite3"`).

## What changed vs upstream

- Package version: `0.38.2+raven.sqlcipher.4.17.0`
- `sqlcipher/sqlite3.c` and `sqlcipher/sqlite3.h` replaced with Task 0A.1 frozen SQLCipher **4.17.0** amalgamation
- `sqlcipher/manifest` + `sqlcipher/manifest.uuid` copied for build-time SHA pins
- Build script fail-closed checks when `bundled-sqlcipher*` is selected:
  - `RAVEN_EXPECT_SQLCIPHER_4_17_0=1` required
  - Exact SHA-256 pins for `sqlite3.c` / `sqlite3.h` / `manifest` / `manifest.uuid`
  - Confirms SQLCipher codec defines are scheduled

## What did not change

- Ordinary `sqlite3/` amalgamation path (default bundled SQLite)
- `links = "sqlite3"`
- Upstream MIT license for the Rust/build scaffolding
- Binding API surface (no unnecessary rewrite)

## Provenance

See `../../sqlcipher-4.17.0/PROVENANCE.md` and `sqlcipher/SQLCIPHER_LICENSE`.

OpenSSL for `bundled-sqlcipher-vendored-openssl` is pinned via openssl-src as recorded in Task 0A.1 (`300.6.1+3.6.3` / OpenSSL 3.6.3).
