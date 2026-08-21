//! CLI entry for Task 0A.2 profile-override negatives.
fn main() {
    raven_sqlcipher_profile_guard::reject_sqlcipher_profile_overrides();
    eprintln!("PASS: SQLCipher profile env is clean");
}
