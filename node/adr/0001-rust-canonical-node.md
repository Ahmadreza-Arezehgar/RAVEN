# ADR 0001 — Canonical node language: Rust

**Status:** Accepted  
**Date:** 2026-08-12

## Decision

`raven-core` + `raven-node` are the canonical cross-platform Raven Node implementation in **Rust**.

## Rationale

- Single binary story for Windows / macOS / Linux
- Memory-safe parsers for untrusted envelope bytes
- Fits checklist recommendation and existing `node/` workspace

## Consequences

- iOS/Android remain first-class clients with vector parity; they are not the headless daemon.
- Go `Libp2pBridge` may remain as a mobile helper until Rust InternetTransport reaches feature parity.
