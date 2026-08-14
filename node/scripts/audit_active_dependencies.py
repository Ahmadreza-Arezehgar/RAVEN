#!/usr/bin/env python3
"""Audit RustSec advisories against Raven's resolved, buildable dependency graph.

`cargo audit` correctly audits every package recorded in Cargo.lock, including
optional dependencies which none of Raven's features can enable.  This wrapper
keeps that broad scan, then fails closed against Cargo's union of Raven's
all-feature/all-target graph.  A lock-only vulnerability is accepted only when
an exact, time-bounded review entry exists in `rustsec-inactive-advisories.json`.

The policy deliberately has no advisory-ID-only ignore.  If an excepted
package becomes buildable, changes version, expires, disappears, or a new
lock-only advisory appears, CI stops for a fresh review.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
NODE_ROOT = SCRIPT_DIR.parent
DEFAULT_POLICY = SCRIPT_DIR / "rustsec-inactive-advisories.json"
PACKAGE_LINE = re.compile(r"^([A-Za-z0-9_-]+) v([^\s]+)(?:\s|$)")
HARD_WARNING_KINDS = {"unsound", "yanked"}


class AuditFailure(RuntimeError):
    """A fail-closed audit or input error."""


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=NODE_ROOT,
        check=False,
        text=True,
        capture_output=True,
    )


def validate_cargo_audit_version() -> None:
    result = run(["cargo", "audit", "--version"])
    if result.returncode != 0:
        raise AuditFailure(
            "cargo-audit 0.22.2 is required but is not callable: "
            + result.stderr.strip()
        )
    fields = result.stdout.strip().split()
    if len(fields) < 2 or fields[1] != "0.22.2":
        raise AuditFailure(
            "cargo-audit must be exactly 0.22.2; got " + result.stdout.strip()
        )


def resolved_packages() -> set[tuple[str, str]]:
    result = run(
        [
            "cargo",
            "tree",
            "--locked",
            "--workspace",
            "--target",
            "all",
            "--all-features",
            "--format",
            "{p}",
            "--prefix",
            "none",
        ]
    )
    if result.returncode != 0:
        raise AuditFailure(
            "cargo tree could not resolve the all-feature/all-target graph:\n"
            + result.stderr.strip()
        )

    packages: set[tuple[str, str]] = set()
    for line in result.stdout.splitlines():
        match = PACKAGE_LINE.match(line)
        if match:
            packages.add((match.group(1), match.group(2)))
    if not packages:
        raise AuditFailure("cargo tree returned no parseable packages")
    return packages


def rustsec_report() -> dict[str, Any]:
    result = run(["cargo", "audit", "--json"])
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        detail = result.stderr.strip() or result.stdout[:500].strip()
        raise AuditFailure(f"cargo audit did not return valid JSON: {detail}") from error

    if not isinstance(report.get("vulnerabilities", {}).get("list"), list):
        raise AuditFailure("cargo audit JSON is missing vulnerabilities.list")
    # Exit 1 is cargo-audit's expected result when a vulnerability is found.
    if result.returncode not in (0, 1):
        raise AuditFailure(
            f"cargo audit exited unexpectedly ({result.returncode}): "
            + result.stderr.strip()
        )
    return report


def load_policy(path: Path) -> dict[tuple[str, str, str], dict[str, Any]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditFailure(f"cannot read advisory policy {path}: {error}") from error
    if document.get("schema") != 1:
        raise AuditFailure("inactive-advisory policy schema must be exactly 1")

    entries: dict[tuple[str, str, str], dict[str, Any]] = {}
    today = dt.date.today()
    for entry in document.get("inactive_vulnerability_exceptions", []):
        try:
            key = (
                entry["advisory_id"],
                entry["package"],
                entry["version"],
            )
            review_by = dt.date.fromisoformat(entry["review_by"])
            reason = entry["reason"].strip()
        except (KeyError, TypeError, ValueError, AttributeError) as error:
            raise AuditFailure(f"malformed inactive-advisory entry: {entry!r}") from error
        if key in entries:
            raise AuditFailure(f"duplicate inactive-advisory entry: {key}")
        if not reason:
            raise AuditFailure(f"inactive-advisory entry has no rationale: {key}")
        if review_by < today:
            raise AuditFailure(
                f"inactive-advisory review expired on {review_by.isoformat()}: {key}"
            )
        entries[key] = entry
    return entries


def package_key(record: dict[str, Any]) -> tuple[str, str]:
    package = record.get("package", {})
    try:
        return package["name"], package["version"]
    except (KeyError, TypeError) as error:
        raise AuditFailure(f"advisory record has no exact package/version: {record!r}") from error


def advisory_key(record: dict[str, Any]) -> tuple[str, str, str]:
    try:
        advisory_id = record["advisory"]["id"]
    except (KeyError, TypeError) as error:
        raise AuditFailure(f"vulnerability record has no advisory ID: {record!r}") from error
    name, version = package_key(record)
    return advisory_id, name, version


def classify(
    report: dict[str, Any],
    active: set[tuple[str, str]],
    policy: dict[tuple[str, str, str], dict[str, Any]],
) -> int:
    failures: list[str] = []
    reported_policy_keys: set[tuple[str, str, str]] = set()
    vulnerabilities = report["vulnerabilities"]["list"]

    for record in vulnerabilities:
        key = advisory_key(record)
        advisory_id, name, version = key
        if key in policy:
            reported_policy_keys.add(key)
        if (name, version) in active:
            failures.append(
                f"ACTIVE VULNERABILITY {advisory_id}: {name} v{version}"
            )
            continue
        entry = policy.get(key)
        if entry is None:
            failures.append(
                "UNREVIEWED LOCK-ONLY VULNERABILITY "
                f"{advisory_id}: {name} v{version}"
            )
            continue
        print(
            "reviewed lock-only advisory "
            f"{advisory_id}: {name} v{version} "
            f"(review by {entry['review_by']})"
        )

    stale = set(policy) - reported_policy_keys
    for advisory_id, name, version in sorted(stale):
        failures.append(
            "STALE INACTIVE-ADVISORY EXCEPTION "
            f"{advisory_id}: {name} v{version}"
        )

    warnings = report.get("warnings", {})
    if not isinstance(warnings, dict):
        raise AuditFailure("cargo audit JSON warnings field is not an object")
    for kind, records in sorted(warnings.items()):
        for record in records:
            name, version = package_key(record)
            graph_state = "active" if (name, version) in active else "lock-only"
            print(f"RustSec {kind} notice ({graph_state}): {name} v{version}")
            if graph_state == "active" and kind in HARD_WARNING_KINDS:
                failures.append(
                    f"ACTIVE {kind.upper()} RUSTSEC NOTICE: {name} v{version}"
                )

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1

    print(
        "active dependency audit passed: "
        f"{len(active)} exact package versions resolved; "
        f"{len(vulnerabilities)} reviewed lock-only vulnerabilities; "
        "0 active vulnerabilities"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policy",
        type=Path,
        default=DEFAULT_POLICY,
        help="exact lock-only advisory review file",
    )
    args = parser.parse_args()
    try:
        validate_cargo_audit_version()
        return classify(rustsec_report(), resolved_packages(), load_policy(args.policy))
    except AuditFailure as error:
        print(f"ERROR: dependency audit failed closed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
