# SQLCipher bindgen provenance (RAVEN Task 0A.2)

| Item | Value |
|---|---|
| Source header | `sqlcipher/sqlite3.h` (Task 0A.1 frozen, SQLite baseline **3.53.3**) |
| Output | `sqlcipher/bindgen_bundled_version.rs` |
| bindgen | **0.72.1** (libsqlite3-sys build-dep) |
| Flags | `LIBSQLITE3_SYS_BUNDLING=1`, clang `-DSQLITE_HAS_CODEC` |
| SHA-256 | `d902e5fb9fd91ae8b7dd8babe5d46717b239190ec987d551b6a7c446edaacdb7` |

Regenerate only via an audited one-shot that builds this crate with
`bundled-sqlcipher-vendored-openssl,buildtime_bindgen` and copies
`OUT_DIR/bindgen.rs` over this file, then updates the SHA pin in `build.rs`.
