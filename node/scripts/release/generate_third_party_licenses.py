#!/usr/bin/env python3
"""Generate a fail-closed, target-specific Cargo license/notice bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


CARGO_ABOUT_VERSION = "0.9.1"
MAX_NOTICE_BYTES = 1_048_576
MAX_TOTAL_NOTICE_BYTES = 16 * 1_048_576
PACKAGE_LINE = re.compile(r"^(?P<name>\S+) v(?P<version>\S+)")
ROOT_LICENSE_PRIVATE_PACKAGES = {("raven-sqlcipher-profile-guard", "0.1.0")}


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"ERROR: {message}")


def run(command: list[str], *, cwd: Path) -> str:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
    except FileNotFoundError:
        fail(f"required command is missing: {command[0]}")
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout, file=sys.stderr, end="")
        if error.stderr:
            print(error.stderr, file=sys.stderr, end="")
        fail(f"command failed ({error.returncode}): {' '.join(command)}")
    return completed.stdout


def active_packages(manifest: Path, target: str, node_root: Path) -> set[tuple[str, str]]:
    tree = run(
        [
            "cargo",
            "tree",
            "--quiet",
            "--frozen",
            "--manifest-path",
            str(manifest),
            "--target",
            target,
            "--edges",
            "normal,build",
            "--prefix",
            "none",
            "--format",
            "{p}",
            "-p",
            "ash",
            "-p",
            "raven-node",
            "-p",
            "raven-swarm",
        ],
        cwd=node_root,
    )
    packages: set[tuple[str, str]] = set()
    for line in tree.splitlines():
        match = PACKAGE_LINE.match(line)
        if match:
            packages.add((match.group("name"), match.group("version")))
    if not packages or not {"ash", "raven-node", "raven-swarm"}.issubset(
        {name for name, _ in packages}
    ):
        fail("Cargo tree did not contain all three release package roots")
    return packages


def append_separate_notices(
    output: Path,
    manifest: Path,
    target: str,
    node_root: Path,
    license_text: str,
    cargo_about_packages: set[tuple[str, str]],
) -> tuple[int, int]:
    packages = active_packages(manifest, target, node_root)
    metadata_text = run(
        [
            "cargo",
            "metadata",
            "--frozen",
            "--format-version",
            "1",
            "--filter-platform",
            target,
            "--manifest-path",
            str(manifest),
        ],
        cwd=node_root,
    )
    metadata = json.loads(metadata_text)

    required_license_entries: set[tuple[str, str]] = set()
    private_active: set[tuple[str, str]] = set()
    for package in metadata.get("packages", []):
        key = (package["name"], package["version"])
        if key not in packages:
            continue
        if package.get("publish") == []:
            private_active.add(key)
        else:
            required_license_entries.add(key)
    unexpected_private = private_active - ROOT_LICENSE_PRIVATE_PACKAGES
    if unexpected_private:
        rendered = ", ".join(
            f"{name} {version}" for name, version in sorted(unexpected_private)
        )
        fail(f"unreviewed private active packages were ignored by cargo-about: {rendered}")
    missing = sorted(
        key for key in required_license_entries if key not in cargo_about_packages
    )
    if missing:
        rendered = ", ".join(f"{name} {version}" for name, version in missing)
        fail(f"cargo-about JSON omitted active release packages: {rendered}")
    missing_from_text = sorted(
        key
        for key in required_license_entries
        if f"- {key[0]} {key[1]}\n" not in license_text
    )
    if missing_from_text:
        rendered = ", ".join(
            f"{name} {version}" for name, version in missing_from_text
        )
        fail(f"rendered license bundle omitted active release packages: {rendered}")

    candidates: list[tuple[str, str, str, str, bytes]] = []
    total_bytes = 0
    for package in metadata.get("packages", []):
        key = (package["name"], package["version"])
        if key not in packages:
            continue
        package_dir = Path(package["manifest_path"]).parent
        if not package_dir.is_dir():
            fail(f"dependency source directory is missing for {key[0]} {key[1]}")
        for entry in sorted(package_dir.iterdir(), key=lambda path: path.name.casefold()):
            folded = entry.name.casefold()
            if not (folded.startswith("notice") or folded.startswith("copyright")):
                continue
            if entry.is_symlink() or not entry.is_file():
                fail(f"dependency notice is not a regular file: {entry}")
            size = entry.stat().st_size
            if size > MAX_NOTICE_BYTES:
                fail(f"dependency notice exceeds {MAX_NOTICE_BYTES} bytes: {entry}")
            content = entry.read_bytes()
            try:
                content.decode("utf-8")
            except UnicodeDecodeError:
                fail(f"dependency notice is not UTF-8: {entry}")
            total_bytes += len(content)
            if total_bytes > MAX_TOTAL_NOTICE_BYTES:
                fail("combined dependency notices exceed the safety limit")
            digest = hashlib.sha256(content).hexdigest()
            candidates.append((key[0], key[1], entry.name, digest, content))

    # Identical registry/path copies are emitted once. A same-named file with
    # different content remains visible via its digest instead of being hidden.
    unique: dict[tuple[str, str, str, str], bytes] = {}
    for name, version, filename, digest, content in candidates:
        unique[(name, version, filename, digest)] = content

    with output.open("ab") as destination:
        destination.write(b"\n\nBEGIN SEPARATE DEPENDENCY NOTICES\n")
        destination.write(b"=================================\n")
        if not unique:
            destination.write(b"No separate NOTICE/COPYRIGHT files were present.\n")
        for (name, version, filename, digest), content in sorted(unique.items()):
            header = (
                f"\n--- {name} {version} / {filename} / sha256:{digest} ---\n"
            ).encode("utf-8")
            destination.write(header)
            destination.write(content)
            if not content.endswith(b"\n"):
                destination.write(b"\n")
        destination.write(b"END SEPARATE DEPENDENCY NOTICES\n")
    return len(unique), len(packages)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-path", required=True, type=Path)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    manifest = args.manifest_path.resolve()
    node_root = manifest.parent
    output = args.output.resolve()
    config = script_dir / "about.toml"
    template = script_dir / "about.hbs"

    if not manifest.is_file() or manifest.name != "Cargo.toml":
        fail(f"invalid Cargo manifest: {manifest}")
    if not config.is_file() or not template.is_file():
        fail("cargo-about configuration/template is missing")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.target):
        fail("target triple contains unsafe characters")
    if output.exists() or output.is_symlink():
        fail(f"refusing to replace existing output: {output}")
    if not output.parent.is_dir() or output.parent.is_symlink():
        fail(f"output parent must be a real directory: {output.parent}")

    version = run(["cargo", "about", "--version"], cwd=node_root).strip()
    expected = f"cargo-about {CARGO_ABOUT_VERSION}"
    if version != expected:
        fail(f"cargo-about version mismatch: expected {expected!r}, got {version!r}")

    # cargo-about evaluates a conservative virtual-workspace superset. Fetch
    # the release roots, then materialize that full target-filtered workspace
    # graph at its Cargo.lock pins. All resolution after this point is frozen so
    # network metadata cannot change the generated bundle.
    run(
        [
            "cargo",
            "fetch",
            "--locked",
            "--manifest-path",
            str(manifest),
            "--target",
            args.target,
        ],
        cwd=node_root,
    )
    # Without `--target`, Cargo fetches target-specific sources for every
    # platform. cargo-about 0.9.1 opens license files before its target filter
    # has eliminated every non-target package, so this second locked fetch is
    # required for a genuinely fresh CARGO_HOME (for example Windows CI).
    run(
        [
            "cargo",
            "fetch",
            "--locked",
            "--manifest-path",
            str(manifest),
        ],
        cwd=node_root,
    )
    run(
        [
            "cargo",
            "metadata",
            "--locked",
            "--format-version",
            "1",
            "--filter-platform",
            args.target,
            "--manifest-path",
            str(manifest),
        ],
        cwd=node_root,
    )

    with tempfile.TemporaryDirectory(
        prefix=".raven-third-party-", dir=output.parent
    ) as temporary:
        generated = Path(temporary) / "THIRD_PARTY_LICENSES_AND_NOTICES.txt"
        structured = Path(temporary) / "cargo-about.json"
        run(
            [
                "cargo",
                "about",
                "generate",
                "--manifest-path",
                str(manifest),
                "--frozen",
                "--target",
                args.target,
                "--fail",
                "--config",
                str(config),
                "--format",
                "json",
                "--output-file",
                str(structured),
            ],
            cwd=node_root,
        )
        if structured.is_symlink() or not structured.is_file():
            fail("cargo-about did not create a regular JSON coverage file")
        if structured.stat().st_size > 64 * 1_048_576:
            fail("cargo-about JSON coverage file exceeds the safety limit")
        try:
            structured_data = json.loads(structured.read_text(encoding="utf-8"))
            structured_crates = structured_data["crates"]
            cargo_about_packages = {
                (entry["package"]["name"], entry["package"]["version"])
                for entry in structured_crates
            }
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            fail(f"cargo-about JSON coverage data is malformed: {error}")
        if not cargo_about_packages:
            fail("cargo-about JSON coverage data contains no packages")
        run(
            [
                "cargo",
                "about",
                "generate",
                "--manifest-path",
                str(manifest),
                "--frozen",
                "--target",
                args.target,
                "--fail",
                "--config",
                str(config),
                "--output-file",
                str(generated),
                str(template),
            ],
            cwd=node_root,
        )
        if generated.is_symlink() or not generated.is_file():
            fail("cargo-about did not create a regular output file")
        initial = generated.read_text(encoding="utf-8")
        if (
            len(initial) < 1_024
            or not initial.startswith("RAVEN THIRD-PARTY LICENSES AND NOTICES\n")
            or "Used by:\n" not in initial
        ):
            fail("cargo-about output is unexpectedly empty or malformed")
        notice_count, active_count = append_separate_notices(
            generated,
            manifest,
            args.target,
            node_root,
            initial,
            cargo_about_packages,
        )
        final_size = generated.stat().st_size
        if final_size < len(initial):
            fail("dependency notice generation truncated its license output")
        os.replace(generated, output)

    print(
        f"THIRD_PARTY_LICENSES_OK target={args.target} "
        f"active_packages={active_count} separate_notices={notice_count} "
        f"bytes={output.stat().st_size}"
    )


if __name__ == "__main__":
    main()
