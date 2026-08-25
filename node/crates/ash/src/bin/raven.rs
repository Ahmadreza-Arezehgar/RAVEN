//! `raven` — install alias for the same Raven Node CLI as `ash`.
#[path = "../cli.rs"]
mod ash_cli;

fn main() {
    ash_cli::run();
}
