// Task 0A.2 — Release hold for durable SQLCipher lab feature.
use std::env;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_FULL_BRAID_DURABLE_LAB");

    let durable_lab = env::var("CARGO_FEATURE_FULL_BRAID_DURABLE_LAB").is_ok();
    let profile = env::var("PROFILE").unwrap_or_default();
    if let Ok(target) = env::var("TARGET") {
        println!("cargo:rustc-env=RAVEN_BUILD_TARGET={target}");
    }
    println!("cargo:rustc-env=RAVEN_BUILD_PROFILE={profile}");

    if durable_lab && profile == "release" {
        // Exact diagnostic required by Task 0A.2 stop-line / CI.
        panic!("FULL_BRAID_SQLCIPHER_NOT_APPROVED");
    }

    if durable_lab {
        println!("cargo:rerun-if-env-changed=RAVEN_EXPECT_SQLCIPHER_4_17_0");
        println!(
            "cargo:warning=full-braid-durable-lab requires RAVEN_EXPECT_SQLCIPHER_4_17_0=1 in the environment for libsqlite3-sys-raven"
        );
    }
}
