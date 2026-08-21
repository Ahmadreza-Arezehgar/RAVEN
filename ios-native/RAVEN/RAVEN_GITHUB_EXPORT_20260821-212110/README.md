# RAVEN GitHub export

Repository: `Raven-offline-messenger/RAVEN`

Exported: 2026-08-21 (Europe/Madrid)

This package contains the GitHub-hosted state that was readable at export time. It deliberately excludes unpushed and uncommitted files from the local working copy.

## Contents

- `git/RAVEN.git/`: bare mirror of all Git refs exposed by GitHub.
- `git/RAVEN-complete.bundle`: verified, self-contained Git bundle with complete history.
- `git/refs.txt`: exported refs and commit IDs.
- `git/commit-history.tsv`: compact human-readable commit history.
- `source/RAVEN-main-source.zip`: source snapshot of the default `main` branch.
- `github-metadata/`: repository, branches, commits, pull requests, review/timeline data, comments, Actions workflows/runs/jobs/artifact metadata, labels, milestones, contributors, releases, and tags as JSON.
- `actions-logs/`: downloadable GitHub Actions logs. Logs for run `22509842491` had already expired on GitHub (HTTP 410); its metadata and job data are still included.
- `release-assets/`: empty because the repository had no releases or release assets.
- `SHA256SUMS`: integrity hashes for package contents.

## Snapshot summary

- Default branch: `main`
- Branches: 2
- Git commits: 128
- Tags: 0
- Issues: 0
- Pull requests: 3
- Actions workflows: 3
- Actions runs: 12
- Actions jobs: 64
- Release assets: 0
- Git LFS-tracked files: 0

## Restore or inspect

Clone the complete bundle:

```sh
git clone git/RAVEN-complete.bundle RAVEN-restored
```

Verify the bundle:

```sh
git bundle verify git/RAVEN-complete.bundle
```

Verify all packaged files:

```sh
shasum -a 256 -c SHA256SUMS
```

GitHub secrets, deleted/expired server data, private security advisories, organization-level settings, and other data not exposed by the account/API are not exportable through this package.
