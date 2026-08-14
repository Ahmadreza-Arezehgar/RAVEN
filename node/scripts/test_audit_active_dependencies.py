#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import importlib.util
import io
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("audit_active_dependencies.py")
MODULE_SPEC = importlib.util.spec_from_file_location("audit_active_dependencies", MODULE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("cannot load active dependency audit module")
audit = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(audit)


def vulnerability(advisory_id: str = "RUSTSEC-TEST-0001") -> dict:
    return {
        "advisory": {"id": advisory_id},
        "package": {"name": "demo", "version": "1.2.3"},
    }


def report(*, vulnerabilities: list[dict] | None = None, warnings: dict | None = None) -> dict:
    return {
        "vulnerabilities": {"list": vulnerabilities or []},
        "warnings": warnings or {},
    }


class ActiveDependencyAuditPolicyTests(unittest.TestCase):
    def classify(self, value: dict, active: set, policy: dict) -> int:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            return audit.classify(value, active, policy)

    def test_active_vulnerability_fails_even_when_exception_exists(self) -> None:
        key = ("RUSTSEC-TEST-0001", "demo", "1.2.3")
        policy = {key: {"review_by": "2099-01-01"}}
        self.assertEqual(
            self.classify(report(vulnerabilities=[vulnerability()]), {key[1:]}, policy),
            1,
        )

    def test_unreviewed_lock_only_vulnerability_fails(self) -> None:
        self.assertEqual(
            self.classify(report(vulnerabilities=[vulnerability()]), set(), {}), 1
        )

    def test_exact_reviewed_lock_only_vulnerability_passes(self) -> None:
        key = ("RUSTSEC-TEST-0001", "demo", "1.2.3")
        policy = {key: {"review_by": "2099-01-01"}}
        self.assertEqual(
            self.classify(report(vulnerabilities=[vulnerability()]), set(), policy), 0
        )

    def test_stale_exception_fails(self) -> None:
        key = ("RUSTSEC-TEST-0001", "demo", "1.2.3")
        policy = {key: {"review_by": "2099-01-01"}}
        self.assertEqual(self.classify(report(), set(), policy), 1)

    def test_active_unsound_notice_fails(self) -> None:
        package = {"package": {"name": "demo", "version": "1.2.3"}}
        self.assertEqual(
            self.classify(
                report(warnings={"unsound": [package]}),
                {("demo", "1.2.3")},
                {},
            ),
            1,
        )

    def test_active_unmaintained_notice_remains_visible_but_nonfatal(self) -> None:
        package = {"package": {"name": "demo", "version": "1.2.3"}}
        self.assertEqual(
            self.classify(
                report(warnings={"unmaintained": [package]}),
                {("demo", "1.2.3")},
                {},
            ),
            0,
        )


if __name__ == "__main__":
    unittest.main()
