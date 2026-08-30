"""Append-only delta store — the conflict-free heart of team memory.

Every mutation is a uniquely-named file under `.team/deltas/<writer>/`, so
git merges NEVER collide even when dozens of agents push simultaneously.
Views (board / chat / journal / facts) are *projections* computed at read
time — the event-sourcing pattern recommended for multi-agent fleets.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import stat
import tempfile
import time
import uuid
from pathlib import Path

MAX_DELTA_WRITERS = 512
MAX_DELTA_DIRECTORY_ENTRIES = 16_384
MAX_DELTA_FILES = 8192
MAX_DELTA_FILE_BYTES = 256 * 1024
MAX_DELTA_TOTAL_BYTES = 16 * 1024 * 1024
MAX_DELTA_FUTURE_SKEW_SECONDS = 24 * 60 * 60


class DeltaStore:
    def __init__(self, memory, writer: str = 'system') -> None:
        self.memory = memory
        raw_writer = str(writer or 'system')
        safe_writer = re.sub(r'[^A-Za-z0-9_.-]', '_', raw_writer)[:40]
        windows_stem = safe_writer.split('.', 1)[0].upper()
        reserved = {
            'CON', 'PRN', 'AUX', 'NUL',
            *(f'COM{number}' for number in range(1, 10)),
            *(f'LPT{number}' for number in range(1, 10)),
        }
        if (
            safe_writer != raw_writer
            or not safe_writer
            or safe_writer in {'.', '..'}
            or windows_stem in reserved
        ):
            safe_writer = (
                'writer-' + hashlib.sha256(raw_writer.encode('utf-8')).hexdigest()[:24]
            )
        self.writer = safe_writer

    # ------------------------------------------------------------- write ---
    def write(self, kind: str, payload: dict):
        if not isinstance(kind, str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', kind):
            raise ValueError('delta kind must be a bounded lowercase identifier')
        if not isinstance(payload, dict):
            raise TypeError('delta payload must be a JSON object')
        d = self._dir()
        d.mkdir(parents=True, exist_ok=True)
        directory_metadata = os.lstat(d)
        if d.is_symlink() or not stat.S_ISDIR(directory_metadata.st_mode):
            raise ValueError('delta writer path must be a real directory')
        rec = {
            **payload,
            'w': self.writer,
            'at': time.time(),
            'kind': kind,
        }
        encoded = (json.dumps(rec, ensure_ascii=False) + '\n').encode('utf-8')
        if len(encoded) > MAX_DELTA_FILE_BYTES:
            raise ValueError('delta exceeds the compiled file-size limit')
        f = d / f'{kind}-{int(time.time() * 1000)}-{uuid.uuid4().hex[:6]}.json'
        private_tmp = self.memory.resolve_in_repo('.team/keys/delta-tmp')
        private_tmp.mkdir(parents=True, exist_ok=True)
        private_metadata = os.lstat(private_tmp)
        if private_tmp.is_symlink() or not stat.S_ISDIR(private_metadata.st_mode):
            raise ValueError('delta temporary path must be a real directory')
        if os.name != 'nt':
            private_tmp.chmod(0o700)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=str(private_tmp), prefix='.delta-', suffix='.tmp'
        )
        temporary = Path(temporary_name)
        try:
            if os.name != 'nt':
                os.fchmod(descriptor, 0o644)
            with os.fdopen(descriptor, 'wb') as handle:
                descriptor = -1
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, f)
            if os.name != 'nt':
                try:
                    directory_descriptor = os.open(d, os.O_RDONLY)
                    try:
                        os.fsync(directory_descriptor)
                    finally:
                        os.close(directory_descriptor)
                except OSError:
                    pass
        except Exception:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
            raise
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        return f

    # -------------------------------------------------------------- read ---
    def read(self, kind: str) -> list[dict]:
        if not isinstance(kind, str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', kind):
            return []
        base = self.memory.repo_path / '.team' / 'deltas'
        try:
            base_metadata = os.lstat(base)
        except OSError:
            return []
        if base.is_symlink() or not stat.S_ISDIR(base_metadata.st_mode):
            return []
        accepted: list[tuple[float, str, str, dict]] = []
        latest_accepted_timestamp = time.time() + MAX_DELTA_FUTURE_SKEW_SECONDS
        entries_seen = 0
        files_seen = 0
        bytes_read = 0
        try:
            writer_entries = []
            with os.scandir(base) as writer_scanner:
                for writer_entry in writer_scanner:
                    if len(writer_entries) >= MAX_DELTA_WRITERS:
                        # Never expose an arbitrary filesystem-order prefix.
                        return []
                    writer_entries.append(writer_entry)
            writer_entries.sort(key=lambda entry: entry.name)
        except OSError:
            return []
        for writer_entry in writer_entries:
            entries_seen += 1
            if entries_seen > MAX_DELTA_DIRECTORY_ENTRIES:
                break
            try:
                if not writer_entry.is_dir(follow_symlinks=False):
                    continue
                writer_metadata = writer_entry.stat(follow_symlinks=False)
                if not stat.S_ISDIR(writer_metadata.st_mode):
                    continue
                remaining_entries = max(
                    0, MAX_DELTA_DIRECTORY_ENTRIES - entries_seen
                )
                file_entries = []
                with os.scandir(writer_entry.path) as file_scanner:
                    for file_entry in file_scanner:
                        if len(file_entries) >= remaining_entries:
                            # A partial prefix can starve a later valid delta;
                            # fail closed instead of returning a misleading
                            # projection.
                            return []
                        file_entries.append(file_entry)
                file_entries.sort(key=lambda entry: entry.name)
            except OSError:
                continue
            for file_entry in file_entries:
                entries_seen += 1
                if entries_seen > MAX_DELTA_DIRECTORY_ENTRIES:
                    break
                if not (
                    file_entry.name.startswith(f'{kind}-')
                    and file_entry.name.endswith('.json')
                ):
                    continue
                if (
                    files_seen >= MAX_DELTA_FILES
                    or bytes_read >= MAX_DELTA_TOTAL_BYTES
                ):
                    return []
                try:
                    metadata = file_entry.stat(follow_symlinks=False)
                    if (
                        not stat.S_ISREG(metadata.st_mode)
                        or metadata.st_nlink != 1
                        or metadata.st_size > MAX_DELTA_FILE_BYTES
                    ):
                        continue
                    if metadata.st_size > MAX_DELTA_TOTAL_BYTES - bytes_read:
                        return []
                    flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0)
                    flags |= getattr(os, 'O_NOFOLLOW', 0)
                    descriptor = os.open(file_entry.path, flags)
                    try:
                        opened = os.fstat(descriptor)
                        if (
                            not stat.S_ISREG(opened.st_mode)
                            or opened.st_nlink != 1
                            or (opened.st_dev, opened.st_ino)
                            != (metadata.st_dev, metadata.st_ino)
                        ):
                            continue
                        chunks = []
                        remaining = MAX_DELTA_FILE_BYTES + 1
                        while remaining > 0:
                            chunk = os.read(descriptor, min(65_536, remaining))
                            if not chunk:
                                break
                            chunks.append(chunk)
                            remaining -= len(chunk)
                        raw = b''.join(chunks)
                    finally:
                        os.close(descriptor)
                    files_seen += 1
                    bytes_read += len(raw)
                    if len(raw) > MAX_DELTA_FILE_BYTES:
                        continue
                    record = json.loads(raw.decode('utf-8'))
                    if not isinstance(record, dict):
                        continue
                    timestamp = record.get('at')
                    if (
                        isinstance(timestamp, bool)
                        or not isinstance(timestamp, (int, float))
                        or not math.isfinite(float(timestamp))
                        or float(timestamp) < 0
                        or float(timestamp) > latest_accepted_timestamp
                        or record.get('kind') != kind
                        or not isinstance(record.get('w'), str)
                    ):
                        continue
                    accepted.append((
                        float(timestamp),
                        writer_entry.name,
                        file_entry.name,
                        record,
                    ))
                except (
                    OSError,
                    OverflowError,
                    UnicodeDecodeError,
                    ValueError,
                    RecursionError,
                ):
                    continue
            if entries_seen > MAX_DELTA_DIRECTORY_ENTRIES:
                break
        accepted.sort(key=lambda item: item[:3])
        return [item[3] for item in accepted]

    def latest_by(self, kind: str, key: str) -> list[dict]:
        """Last-write-wins projection grouped by `key` (e.g. task id)."""
        seen: dict[str, dict] = {}
        for rec in self.read(kind):
            k = str(rec.get(key, ''))
            if k:
                seen[k] = rec          # later timestamps overwrite earlier
        return list(seen.values())

    def _dir(self) -> Path:
        base = self.memory.repo_path / '.team' / 'deltas'
        base.mkdir(parents=True, exist_ok=True)
        metadata = os.lstat(base)
        if base.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise ValueError('delta base path must be a real directory')
        return base / self.writer
