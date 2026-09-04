# O7 supply-chain backlog — SBOM, signing, SLSA

**Status:** backlog only. Nothing in this document is implemented, and nothing
here authorizes placeholder CI.

**Owners:** [@Raven-ASHCO/release](https://github.com/orgs/Raven-ASHCO/teams/release)
(Release Engineering / #19). Security Board (#17) is the mandatory second on
release/signing (R3; no self-merge). See
[`docs/engineering/baseline-freeze/approval-matrix.md`](engineering/baseline-freeze/approval-matrix.md).

**Related:** ninety-day outcome O7 in
[`docs/engineering/baseline-freeze/ninety-day-outcomes.md`](engineering/baseline-freeze/ninety-day-outcomes.md);
packaging rows in [`docs/MASTER_ENGINEERING_CHECKLIST.md`](MASTER_ENGINEERING_CHECKLIST.md)
§52; operator signing in [`docs/SIGNING_NOTARIZATION_CHECKLIST.md`](SIGNING_NOTARIZATION_CHECKLIST.md).

This note records supply-chain work that remains after Dependabot version
updates. It is not a performance baseline and does not close O7.

---

## Current state (do not over-claim)

| Capability | Today |
|------------|--------|
| Dependency version PRs | `.github/dependabot.yml` (cargo `/node`, GitHub Actions `/`, pip `/protocol/reference`) |
| GitHub repo security settings | Vulnerability alerts, Dependabot **security** updates, secret scanning, and push protection are enabled in repository settings (DevSecOps). Those are org/repo toggles, not this file. |
| SBOM in CI | `raven-serverless.yml` always writes `cargo tree` to `node/target/sbom/raven-cargo-tree.txt` and **requires** that file to be non-empty. CycloneDX (`cargo cyclonedx`) is **best-effort**: install and generate are swallowed (`|| true` / optional echo). A missing `.cdx.json` does **not** fail the job. |
| Release artifacts | `scripts/release/build_unsigned.sh` produces an **unsigned** layout. No release workflow publishes signed binaries or attestations. |
| Full Braid Task 0A “provenance” | Lab jobs that check **SQLCipher 4.17 packaging provenance** (`full-braid-task0a-provenance` → `node/scripts/full_braid_task0a_ci_gate.sh provenance`). See [non-equivalence](#full-braid-task-0a-provenance-is-not-slsa). |

---

## Entry criteria (must be true before any of the work below)

Do **not** implement SBOM fail-closed, cosign/sigstore, or SLSA jobs until all
of the following are true:

1. **A real release pipeline exists** — versioned tags, a designated release
   workflow, and published artifacts that humans actually ship (not only
   `workflow_dispatch` CI green / unsigned `dist/` layouts).
2. **Owners are `@Raven-ASHCO/release`** — that team reviews and merges the
   implementation; signing keys / OIDC / Fulcio identity are under release
   custody, not an ad-hoc Actions secret.
3. **Security Board second** on the R3 release/signing change (approval matrix).
4. **No fake jobs** — a step that prints “signed” or uploads an empty
   attestation while Cosign/SLSA is missing is worse than no job. Do not add
   `|| true` signing, stub `cosign sign` with dummy keys, or a “SLSA” badge
   that only echoes the Task 0A lab gate.

Until those hold, keep this document as the backlog and leave CI as-is.

---

## Backlog

### 1. SBOM fail-closed

**Goal:** every release (and the CI job that claims an SBOM) fails if CycloneDX
generation does not produce a non-empty SBOM for the crates we ship.

**Today:** CycloneDX is optional. `cargo install cargo-cyclonedx … || true` and
`cargo cyclonedx … || true` / “cyclonedx optional” mean the Linux job can go
green with only `raven-cargo-tree.txt`.

**When implementing (after entry criteria):**

- Pin `cargo-cyclonedx` (or the chosen generator) and fail the job if install
  or generate fails. Remove the current `|| true` / “cyclonedx optional” paths.
- Require a non-empty CycloneDX document for at least the release crates
  (`raven-core`, `ash`, `raven-node`, `raven-swarm` as applicable).
- Attach the SBOM to the **release** artifact set, not only a CI `upload-artifact`.
- Do not treat `cargo tree` text as a substitute for a machine-readable SBOM
  once the fail-closed bar is claimed.

### 2. Cosign / Sigstore signing

**Goal:** release artifacts (binaries, SBOM, checksums) are signed with
[Sigstore](https://www.sigstore.dev/) / `cosign` via keyless OIDC (or a
documented hardware-backed key) so verifiers can check identity without
Raven inventing a second PKI.

**Today:** no Cosign, no Sigstore, no GitHub artifact attestations in this
repo. Platform code-signing (Apple Developer ID / Windows Authenticode) is a
separate operator checklist and is also not automated.

**When implementing (after entry criteria):**

- Sign the real release objects only. Identity must be the release workflow’s
  OIDC subject (or the release team’s key), not a developer PAT.
- Publish verification instructions next to the artifacts.
- Do **not** add a CI job that “signs” with a repo-generated throwaway key,
  commits a dummy `.sig`, or marks the step optional with `|| true`.

### 3. SLSA provenance

**Goal:** published artifacts come with [SLSA](https://slsa.dev/) provenance
(build attestation) that names the source repo, commit, workflow, and
builder — generated by a real release builder, not a unit-test job.

**Today:** no SLSA generator, no `actions/attest-build-provenance` (or
equivalent) on a release path.

**When implementing (after entry criteria):**

- Attach provenance to the same artifacts Cosign signs.
- Record the intended SLSA level and the builder (e.g. GitHub Actions
  reusable workflow / official slsa-github-generator) **after** the release
  pipeline exists.
- Consumers must be able to verify provenance independently of “CI was green.”

---

## Full Braid Task 0A “provenance” is not SLSA

The workflow job `full-braid-task0a-provenance` and
`node/scripts/sqlcipher_4_17_provenance_selftest.sh` prove **SQLCipher 4.17
source/packaging provenance** for Full Braid lab work (Task 0A.1). That is a
dependency-vendor integrity gate.

It is **not**:

- SLSA build provenance for Raven release artifacts
- a Sigstore/Cosign signature
- an SBOM
- authorization to start Task 0B, production Full Braid, or a release

Do not rename, badge, or document those lab jobs as SLSA. Do not skip the
SLSA backlog because Task 0A is green.

---

## Explicit non-goals for this chore

- Do not implement fake signing or SLSA jobs in this PR or as “coverage.”
- Do not change wire protocols, Cargo features, or CI path filters.
- Do not touch branch protection or required checks.
- Do not add `gomod` (or other) Dependabot ecosystems until those manifests
  exist on `main`.
