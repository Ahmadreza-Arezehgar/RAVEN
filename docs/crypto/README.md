# Crypto docs (Sprint 0)

ATSAM addenda for Crypto Role #3. They bind existing protocol and vector sources; they do not implement crypto, lift the RVN1 production HOLD, or approve Hybrid Ratchet V2. Swift / `ios-native` citations are **OFF-MAIN**.

- [ATSAM threat assumptions V1](ATSAM_THREAT_ASSUMPTIONS_V1.md) — combiner, library matrix, HOLD, HR v2 claims/non-claims, profile split, RDAP/O6, revoke.
- [ATSAM KAT consumer matrix V1](ATSAM_KAT_CONSUMER_MATRIX_V1.md) — every file under `shared-vectors/rvn1/atsam/**`.
- [RDAP↔ATSAM boundary V1](RDAP_ATSAM_BOUNDARY_V1.md) — honesty note: no production ATSAM E2EE in RDAP today; carriers; identity split; ADR 0004 confidential path (M2 seal still future); forbidden claims.
