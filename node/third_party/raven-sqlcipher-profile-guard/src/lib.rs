//! Fail-closed SQLCipher profile env guard (Task 0A.2).
//!
//! Shared by `libsqlite3-sys-raven` build.rs and the standalone
//! `raven-sqlcipher-profile-guard` binary so negatives can assert the
//! diagnostic without racing `openssl-sys` (which also reads `CFLAGS`).

use std::env;

/// Reject host env that can retarget the frozen SQLCipher 4.17.0 codec profile.
/// Panics with a stable diagnostic substring: `forbidden SQLCipher profile override`
/// or `LIBSQLITE3_FLAGS is forbidden`.
pub fn reject_sqlcipher_profile_overrides() {
    if env::var_os("LIBSQLITE3_FLAGS").is_some() {
        panic!(
            "LIBSQLITE3_FLAGS is forbidden for Raven SQLCipher 4.17.0 lab builds (fail-closed profile)"
        );
    }

    reject_openssl_provider_overrides();

    let forbidden_substrings = [
        "PBKDF2",
        "SQLITE_TEMP_STORE",
        "SQLITE_HAS_CODEC",
        "SQLITE_EXTRA_INIT",
        "SQLITE_EXTRA_SHUTDOWN",
        "SQLCIPHER_CRYPTO",
        "SQLITE_THREADSAFE",
        "FAST_PBKDF2",
    ];

    for (key, val) in env::vars() {
        let key_up = key.to_ascii_uppercase();
        let is_cflag_like = key_up == "CFLAGS"
            || key_up == "CXXFLAGS"
            || key_up == "CPPFLAGS"
            || key_up.ends_with("_CFLAGS")
            || key_up.ends_with("_CXXFLAGS")
            || key_up.ends_with("_CPPFLAGS")
            || key_up.starts_with("CFLAGS_")
            || key_up.starts_with("CXXFLAGS_")
            || key_up.starts_with("CPPFLAGS_");
        let is_compiler_cmd = key_up == "CC"
            || key_up == "CXX"
            || key_up == "HOST_CC"
            || key_up == "HOST_CXX"
            || key_up.ends_with("_CC")
            || key_up.ends_with("_CXX")
            || key_up.starts_with("CC_")
            || key_up.starts_with("CXX_");

        if !is_cflag_like && !is_compiler_cmd {
            continue;
        }

        // Response files and forced includes can smuggle arbitrary -D macros.
        if val.contains('@')
            || val
                .split_whitespace()
                .any(|t| t == "-include" || t.starts_with("-include"))
        {
            panic!(
                "forbidden SQLCipher profile override in {key}: response-file (@) or -include not allowed"
            );
        }

        if is_compiler_cmd {
            // CC/CXX must be a bare compiler path. Injected argv (e.g.
            // CC='clang -DPBKDF2_ITER=1') is a profile bypass.
            let parts: Vec<&str> = val.split_whitespace().collect();
            if parts.len() > 1 {
                for part in parts.iter().skip(1) {
                    if part.starts_with('-') || part.starts_with('@') {
                        panic!(
                            "forbidden SQLCipher profile override in {key}: compiler command must not include arguments (got {val:?})"
                        );
                    }
                }
            }
            if val.contains("-D")
                || val.contains("-U")
                || val.contains("-include")
                || val.contains('@')
            {
                panic!(
                    "forbidden SQLCipher profile override in {key}: embedded compiler flags not allowed (got {val:?})"
                );
            }
        }

        let val_up = val.to_ascii_uppercase();
        for needle in forbidden_substrings {
            if val_up.contains(needle) {
                panic!(
                    "forbidden SQLCipher profile override in {key}: contains {needle} (value rejected)"
                );
            }
        }
    }
}

/// Reject env that can swap the frozen openssl-src provider for system OpenSSL.
///
/// Stable diagnostic substring: `forbidden OpenSSL provider override`.
pub fn reject_openssl_provider_overrides() {
    for (key, _val) in env::vars() {
        let key_up = key.to_ascii_uppercase();
        if key_up == "OPENSSL_NO_VENDOR" || key_up.ends_with("_OPENSSL_NO_VENDOR") {
            panic!(
                "forbidden OpenSSL provider override in {key}: OPENSSL_NO_VENDOR is forbidden for Raven SQLCipher lab (require vendored openssl-src)"
            );
        }
        if key_up == "OPENSSL_DIR"
            || key_up == "OPENSSL_LIB_DIR"
            || key_up == "OPENSSL_INCLUDE_DIR"
            || key_up.ends_with("_OPENSSL_DIR")
            || key_up.ends_with("_OPENSSL_LIB_DIR")
            || key_up.ends_with("_OPENSSL_INCLUDE_DIR")
        {
            panic!(
                "forbidden OpenSSL provider override in {key}: external OPENSSL_* path overrides are forbidden for Raven SQLCipher lab"
            );
        }
    }
}

/// Require `openssl-sys` to have actually vendored via openssl-src.
/// Call only from `bundled-sqlcipher-vendored-openssl` builds after deps ran.
pub fn require_dep_openssl_vendored() {
    match env::var("DEP_OPENSSL_VENDORED") {
        Ok(v) if v == "1" => {}
        other => panic!(
            "forbidden OpenSSL provider override: DEP_OPENSSL_VENDORED must be 1 for Raven SQLCipher lab (got {other:?}); system/dynamic OpenSSL is forbidden"
        ),
    }
}

/// Emit `cargo:rerun-if-env-changed` lines for profile-sensitive variables.
pub fn emit_cargo_rerun_if_env_changed() {
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=CXX");
    println!("cargo:rerun-if-env-changed=HOST_CC");
    println!("cargo:rerun-if-env-changed=HOST_CXX");
    println!("cargo:rerun-if-env-changed=CPPFLAGS");
    println!("cargo:rerun-if-env-changed=CFLAGS");
    println!("cargo:rerun-if-env-changed=CXXFLAGS");
    println!("cargo:rerun-if-env-changed=LIBSQLITE3_FLAGS");
    println!("cargo:rerun-if-env-changed=OPENSSL_NO_VENDOR");
    println!("cargo:rerun-if-env-changed=OPENSSL_DIR");
    println!("cargo:rerun-if-env-changed=OPENSSL_LIB_DIR");
    println!("cargo:rerun-if-env-changed=OPENSSL_INCLUDE_DIR");
}
