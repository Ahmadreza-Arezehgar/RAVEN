//! SQLCipher 4.17.0 lab linkage probe (Task 0A.2 foundation).
//!
//! Does **not** implement the full Raven open profile (Task 0A.4). It only
//! proves the linked provider responds as SQLCipher 4.17.0 with the OpenSSL
//! terminal codec path.

use rusqlite::Connection;

/// Exact cipher_version strings accepted for Task 0A.2 lab (no arbitrary prefix).
pub const EXPECTED_CIPHER_VERSION: &str = "4.17.0";
pub const EXPECTED_CIPHER_VERSION_COMMUNITY: &str = "4.17.0 community";

/// Exact SQLite baseline version embedded in SQLCipher 4.17.0.
pub const EXPECTED_SQLITE_VERSION: &str = "3.53.3";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SqlCipherLabLinkageReport {
    pub sqlite_libversion: String,
    pub cipher_version: String,
    pub cipher_provider: String,
    pub has_codec_compile_option: bool,
    pub has_temp_store_2: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum SqlCipherLabLinkageError {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("unexpected cipher_version: got {got:?}, expected exact {EXPECTED_CIPHER_VERSION:?} or {EXPECTED_CIPHER_VERSION_COMMUNITY:?}")]
    UnexpectedCipherVersion { got: String },
    #[error("unexpected sqlite_version: got {got:?}, expected exact {EXPECTED_SQLITE_VERSION:?}")]
    UnexpectedSqliteVersion { got: String },
    #[error("unexpected cipher_provider: got {got:?}, expected OpenSSL terminal provider")]
    UnexpectedCipherProvider { got: String },
    #[error("SQLITE_HAS_CODEC compile option not reported by sqlite_compileoption_used")]
    MissingCodecCompileOption,
    #[error("SQLITE_TEMP_STORE=2 compile option not reported")]
    MissingTempStore2,
    #[error("sqlite3_key symbol probe failed")]
    MissingKeySymbol,
}

/// Open an in-memory SQLCipher database with a disposable passphrase and report
/// provider identity. Fail-closed on version/provider mismatch.
pub fn probe_sqlcipher_lab_linkage() -> Result<SqlCipherLabLinkageReport, SqlCipherLabLinkageError>
{
    // Ensure the codec entry point is linked into this final image.
    {
        extern "C" {
            fn sqlite3_key(
                db: *mut std::ffi::c_void,
                pKey: *const std::ffi::c_void,
                nKey: std::ffi::c_int,
            ) -> std::ffi::c_int;
        }
        let addr = sqlite3_key as *const () as usize;
        if addr == 0 {
            return Err(SqlCipherLabLinkageError::MissingKeySymbol);
        }
    }

    let conn = Connection::open_in_memory()?;
    // SQLCipher requires key before other operations on a new DB.
    conn.pragma_update(None, "key", "raven-0a2-lab-only-passphrase")?;

    let sqlite_libversion: String =
        conn.query_row("SELECT sqlite_version()", [], |row| row.get(0))?;
    if sqlite_libversion != EXPECTED_SQLITE_VERSION {
        return Err(SqlCipherLabLinkageError::UnexpectedSqliteVersion {
            got: sqlite_libversion,
        });
    }

    let cipher_version: String = conn.query_row("PRAGMA cipher_version", [], |row| row.get(0))?;
    if cipher_version != EXPECTED_CIPHER_VERSION
        && cipher_version != EXPECTED_CIPHER_VERSION_COMMUNITY
    {
        return Err(SqlCipherLabLinkageError::UnexpectedCipherVersion {
            got: cipher_version,
        });
    }

    let cipher_provider: String = conn.query_row("PRAGMA cipher_provider", [], |row| row.get(0))?;
    // Terminal lab path is bundled-sqlcipher-vendored-openssl only.
    if cipher_provider != "openssl" {
        return Err(SqlCipherLabLinkageError::UnexpectedCipherProvider {
            got: cipher_provider,
        });
    }

    let has_codec_compile_option: bool = conn.query_row(
        "SELECT sqlite_compileoption_used('SQLITE_HAS_CODEC')",
        [],
        |row| row.get::<_, i64>(0),
    )? != 0;
    if !has_codec_compile_option {
        return Err(SqlCipherLabLinkageError::MissingCodecCompileOption);
    }

    let has_temp_store_2: bool = conn.query_row(
        "SELECT sqlite_compileoption_used('TEMP_STORE=2')",
        [],
        |row| row.get::<_, i64>(0),
    )? != 0
        || conn.query_row(
            "SELECT sqlite_compileoption_used('SQLITE_TEMP_STORE=2')",
            [],
            |row| row.get::<_, i64>(0),
        )? != 0;
    if !has_temp_store_2 {
        return Err(SqlCipherLabLinkageError::MissingTempStore2);
    }

    // Touch the DB so the codec path is exercised beyond pragma reads.
    conn.execute_batch(
        "CREATE TABLE raven_0a2_lab(id INTEGER PRIMARY KEY); INSERT INTO raven_0a2_lab(id) VALUES (1);",
    )?;

    Ok(SqlCipherLabLinkageReport {
        sqlite_libversion,
        cipher_version,
        cipher_provider,
        has_codec_compile_option,
        has_temp_store_2,
    })
}
