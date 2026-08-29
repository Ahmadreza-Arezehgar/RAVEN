"""Git-backed shared team memory: board, journal, facts and file locks.

All state lives under `<repo>/.team/` so teammates on other machines sync
through plain git — no server, no database.
"""

from __future__ import annotations

import errno
import json
import math
import os
import re
import stat
import subprocess
import threading
import time
import unicodedata
import uuid
from contextlib import contextmanager
from pathlib import Path

from .deltas import DeltaStore

try:  # POSIX
    import fcntl as _fcntl
except ImportError:  # pragma: no cover - exercised by the Windows/import smoke
    _fcntl = None

try:  # Windows
    import msvcrt as _msvcrt
except ImportError:  # pragma: no cover - normal on POSIX
    _msvcrt = None


GIT_LOCK_TIMEOUT_SECONDS = 10.0
LOCK_POLL_SECONDS = 0.05
MAX_AUTOMATIC_SYNC_COMMITS = 256
DISABLED_HOOKS_PATH = '.team/.automatic-git-hooks-disabled'
MAX_RECENT_EVENT_WRITERS = 128
MAX_RECENT_EVENT_DIRECTORY_ENTRIES = 4096
MAX_RECENT_EVENT_ENTRIES_PER_WRITER = 512
MAX_RECENT_EVENT_FILES = 2048
MAX_RECENT_EVENT_FILE_BYTES = 16 * 1024
MAX_RECENT_EVENT_TOTAL_BYTES = 2 * 1024 * 1024
MAX_RECENT_EVENTS_LIMIT = 200
MAX_RECENT_EVENT_TEXT_CHARS = 400
_LOCAL_LOCKS_GUARD = threading.Lock()
_LOCAL_LOCKS: dict[str, threading.Lock] = {}

# Automatic Git operations are deliberately restricted to durable team data.
# In particular, `.team/keys`, replay databases, mesh stores and `.gitlock`
# are local security/runtime state and must never be swept into a relay commit.
TEAM_SHARED_FILES = frozenset({
    '.team/BOARD.md',
    '.team/GOAL.md',
    '.team/facts.md',
    '.team/journal.md',
})
TEAM_SHARED_DIRS = (
    '.team/deltas',
    '.team/inbox',
    '.team/locks',
    '.team/outbox',
    '.team/outputs',
    '.team/quarantine',
)
TEAM_SHARED_PATHS = tuple(sorted(TEAM_SHARED_FILES)) + TEAM_SHARED_DIRS


class FileLockError(RuntimeError):
    """The cross-process memory lock could not be used safely."""


class FileLockUnavailable(FileLockError):
    """No supported OS locking primitive is available."""


class FileLockTimeout(TimeoutError, FileLockError):
    """The lock stayed busy until its bounded acquisition deadline."""


class TeamGitError(RuntimeError):
    """An automatic Git operation could not complete without leaving its scope."""


def _is_link_or_reparse(metadata: os.stat_result) -> bool:
    return stat.S_ISLNK(metadata.st_mode) or bool(
        getattr(metadata, 'st_reparse_tag', 0)
    )


def _same_file_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (
        left.st_dev == right.st_dev
        and left.st_ino == right.st_ino
        and stat.S_IFMT(left.st_mode) == stat.S_IFMT(right.st_mode)
    )


def _same_regular_snapshot(left: os.stat_result, right: os.stat_result) -> bool:
    return (
        _same_file_identity(left, right)
        and stat.S_ISREG(right.st_mode)
        and not _is_link_or_reparse(right)
        and right.st_nlink == 1
        and left.st_size == right.st_size
        and left.st_mtime_ns == right.st_mtime_ns
        and left.st_ctime_ns == right.st_ctime_ns
    )


def _read_stable_regular_file(
    path: Path,
    expected: os.stat_result,
    byte_budget: int,
) -> tuple[bytes | None, int]:
    """Read one bounded file, rejecting links, hardlinks and path swaps.

    The second return value is the number of bytes actually read, including
    bytes from a file that is later rejected. Callers can therefore enforce a
    truthful aggregate read budget even for malformed or racing files.
    """
    if (
        byte_budget <= 0
        or _is_link_or_reparse(expected)
        or not stat.S_ISREG(expected.st_mode)
        or expected.st_nlink != 1
        or expected.st_size < 0
        or expected.st_size > MAX_RECENT_EVENT_FILE_BYTES
        # Reserve one byte to detect a file that grew after the directory stat.
        or expected.st_size + 1 > byte_budget
    ):
        return None, 0

    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0)
    flags |= getattr(os, 'O_CLOEXEC', 0)
    flags |= getattr(os, 'O_NOFOLLOW', 0)
    flags |= getattr(os, 'O_NONBLOCK', 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        return None, 0

    consumed = 0
    try:
        opened = os.fstat(fd)
        try:
            before = os.lstat(path)
        except OSError:
            return None, 0
        if not (
            _same_regular_snapshot(expected, opened)
            and _same_regular_snapshot(expected, before)
        ):
            return None, 0

        read_cap = min(MAX_RECENT_EVENT_FILE_BYTES + 1, byte_budget)
        data = bytearray()
        while len(data) < read_cap:
            chunk = os.read(fd, read_cap - len(data))
            if not chunk:
                break
            data.extend(chunk)
        consumed = len(data)

        try:
            after_fd = os.fstat(fd)
            after_path = os.lstat(path)
        except OSError:
            return None, consumed
        if not (
            len(data) == expected.st_size
            and _same_regular_snapshot(expected, after_fd)
            and _same_regular_snapshot(expected, after_path)
        ):
            return None, consumed
        return bytes(data), consumed
    except OSError:
        return None, consumed
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def _sanitize_event_text(value: str) -> str:
    """Return terminal-safe, character-bounded event text."""
    clean: list[str] = []
    for character in value:
        if len(clean) >= MAX_RECENT_EVENT_TEXT_CHARS:
            break
        if unicodedata.category(character) in {'Cc', 'Cf', 'Cs'}:
            clean.append(' ')
        else:
            clean.append(character)
    return ''.join(clean)


def _local_lock_for(path: Path) -> threading.Lock:
    key = os.path.normcase(os.path.abspath(os.fspath(path)))
    with _LOCAL_LOCKS_GUARD:
        lock = _LOCAL_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            _LOCAL_LOCKS[key] = lock
        return lock


def _open_lock_file(path: Path):
    """Open a stable regular lock file without following symlinks where supported."""
    if path.is_symlink():
        raise FileLockError(f'lock path must not be a symlink: {path}')
    # O_APPEND makes concurrent first-use initialization safe on Windows: if
    # two processes both observe an empty file, a late sentinel write lands
    # after byte zero rather than colliding with the other process's mandatory
    # byte-zero lock.
    flags = os.O_RDWR | os.O_CREAT | os.O_APPEND | getattr(os, 'O_BINARY', 0)
    flags |= getattr(os, 'O_CLOEXEC', 0)
    flags |= getattr(os, 'O_NOFOLLOW', 0)
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as exc:
        raise FileLockError(f'cannot open lock file {path}: {exc}') from exc
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise FileLockError(f'lock path must be a regular file: {path}')
        try:
            path_metadata = os.lstat(path)
        except OSError as exc:
            raise FileLockError(f'cannot verify lock path {path}: {exc}') from exc
        if stat.S_ISLNK(path_metadata.st_mode) or getattr(
            path_metadata, 'st_reparse_tag', 0
        ):
            raise FileLockError(f'lock path must not be a symlink/reparse point: {path}')
        # Detect a final-component swap between the pre-open symlink check and
        # os.open on platforms without O_NOFOLLOW (notably Windows).
        if (metadata.st_dev, metadata.st_ino) != (
            path_metadata.st_dev,
            path_metadata.st_ino,
        ):
            raise FileLockError(f'lock path changed while opening: {path}')
        handle = os.fdopen(fd, 'r+b', buffering=0)
        fd = -1
        # msvcrt locks byte ranges and cannot lock beyond an empty file.  A
        # persistent sentinel byte also keeps every process on the same inode.
        if metadata.st_size == 0:
            handle.write(b'\0')
            handle.flush()
        handle.seek(0)
        return handle
    finally:
        if fd >= 0:
            os.close(fd)


def _try_os_lock(handle) -> bool:
    if _fcntl is not None:
        try:
            _fcntl.flock(handle.fileno(), _fcntl.LOCK_EX | _fcntl.LOCK_NB)
            return True
        except OSError as exc:
            if exc.errno in {errno.EACCES, errno.EAGAIN}:
                return False
            raise FileLockError(f'POSIX file lock failed: {exc}') from exc
    if _msvcrt is not None:
        handle.seek(0)
        try:
            _msvcrt.locking(handle.fileno(), _msvcrt.LK_NBLCK, 1)
            return True
        except OSError as exc:
            # CPython reports sharing/lock violations as EACCES/EAGAIN or
            # winerror 33/36 depending on the Windows runtime.
            if exc.errno in {errno.EACCES, errno.EAGAIN, errno.EDEADLK} or getattr(
                exc, 'winerror', None
            ) in {33, 36}:
                return False
            raise FileLockError(f'Windows file lock failed: {exc}') from exc
    raise FileLockUnavailable('neither fcntl nor msvcrt locking is available')


def _unlock_os_file(handle) -> None:
    try:
        if _fcntl is not None:
            _fcntl.flock(handle.fileno(), _fcntl.LOCK_UN)
            return
        if _msvcrt is not None:
            handle.seek(0)
            _msvcrt.locking(handle.fileno(), _msvcrt.LK_UNLCK, 1)
            return
    except OSError as exc:
        raise FileLockError(f'file unlock failed: {exc}') from exc
    raise FileLockUnavailable('neither fcntl nor msvcrt locking is available')


@contextmanager
def _exclusive_file_lock(
    path: str | Path,
    *,
    timeout: float = GIT_LOCK_TIMEOUT_SECONDS,
    poll_interval: float = LOCK_POLL_SECONDS,
):
    """Acquire a bounded thread/process lock or raise without entering."""
    if timeout < 0:
        raise ValueError('lock timeout must be non-negative')
    if poll_interval <= 0:
        raise ValueError('lock poll interval must be positive')
    if _fcntl is None and _msvcrt is None:
        raise FileLockUnavailable('neither fcntl nor msvcrt locking is available')

    # Keep the final path component unresolved so _open_lock_file can reject a
    # symlink instead of silently following it.
    lock_path = Path(os.path.abspath(os.fspath(path)))
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + timeout
    local_lock = _local_lock_for(lock_path)
    remaining = max(0.0, deadline - time.monotonic())
    if not local_lock.acquire(timeout=remaining):
        raise FileLockTimeout(f'timed out after {timeout:.3f}s waiting for {lock_path}')

    handle = None
    acquired = False
    try:
        handle = _open_lock_file(lock_path)
        while True:
            if _try_os_lock(handle):
                acquired = True
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise FileLockTimeout(
                    f'timed out after {timeout:.3f}s waiting for {lock_path}'
                )
            time.sleep(min(poll_interval, remaining))
        yield
    finally:
        try:
            if acquired and handle is not None:
                _unlock_os_file(handle)
        finally:
            try:
                if handle is not None:
                    handle.close()
            finally:
                local_lock.release()

BOARD_HEADER = """# Team Board

| id | title | owner | status | notes |
|----|-------|-------|--------|-------|
"""

JOURNAL_HEADER = '# Team Journal\n'
FACTS_HEADER = '# Team Facts\n'


def _ts() -> str:
    return time.strftime('%Y-%m-%d %H:%M:%S')


def _cell(text: str) -> str:
    return str(text).replace('|', '\\|')


class TeamMemory:
    def __init__(self, repo_path: str | Path, auto_commit: bool = True) -> None:
        self.repo_path = Path(repo_path).resolve()
        self.auto_commit = auto_commit
        self.team_dir = self.repo_path / '.team'
        self.board_md = self.team_dir / 'BOARD.md'
        self.journal_md = self.team_dir / 'journal.md'
        self.facts_md = self.team_dir / 'facts.md'
        self.locks_dir = self.team_dir / 'locks'

    # ------------------------------------------------------------ layout --
    def ensure_layout(self) -> None:
        if os.path.lexists(self.team_dir):
            metadata = os.lstat(self.team_dir)
            if _is_link_or_reparse(metadata) or not stat.S_ISDIR(metadata.st_mode):
                raise FileLockError(
                    f'team state directory must be a real directory: '
                    f'{self.team_dir}'
                )
        self.team_dir.mkdir(parents=True, exist_ok=True)
        for directory in (self.team_dir / 'outputs', self.locks_dir):
            if os.path.lexists(directory):
                metadata = os.lstat(directory)
                if _is_link_or_reparse(metadata) or not stat.S_ISDIR(
                    metadata.st_mode
                ):
                    raise FileLockError(
                        f'team layout path must be a real directory: {directory}'
                    )
            else:
                directory.mkdir()
        for path, header in (
            (self.board_md, BOARD_HEADER),
            (self.journal_md, JOURNAL_HEADER),
            (self.facts_md, FACTS_HEADER),
        ):
            if os.path.lexists(path):
                metadata = os.lstat(path)
                if _is_link_or_reparse(metadata) or not stat.S_ISREG(
                    metadata.st_mode
                ):
                    raise FileLockError(
                        f'team layout path must be a regular file: {path}'
                    )
            else:
                path.write_text(header, encoding='utf-8')
        self._validate_operational_team_paths()

    def resolve_in_repo(self, relpath: str) -> Path:
        p = (self.repo_path / relpath).resolve()
        if p != self.repo_path and self.repo_path not in p.parents:
            raise ValueError(f'path escapes repo: {relpath}')
        return p

    # --------------------------------------------------------------- git --
    def _git_result(self, *args: str, timeout: float = 60) -> subprocess.CompletedProcess:
        """Run Git without a shell, retrying only bounded index contention."""
        for attempt in range(6):
            try:
                r = subprocess.run(
                    ('git', '-C', str(self.repo_path), *args),
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                )
            except subprocess.TimeoutExpired as exc:
                raise TeamGitError(
                    f'git {args[0] if args else "command"} timed out after {timeout}s'
                ) from exc
            if r.returncode == 0:
                return r
            err = (r.stderr or '') + (r.stdout or '')
            if 'index.lock' in err:
                time.sleep(0.15 * (attempt + 1))
                continue
            return r
        raise TeamGitError('git index stayed locked after bounded retries')

    def _git_checked(self, *args: str, timeout: float = 60) -> str:
        r = self._git_result(*args, timeout=timeout)
        if r.returncode != 0:
            detail = ((r.stderr or '') + (r.stdout or '')).strip()[-1200:]
            command = args[0] if args else 'command'
            raise TeamGitError(f'git {command} failed ({r.returncode}): {detail}')
        return (r.stdout + r.stderr).strip()

    def _git(self, *args: str) -> str:
        """Best-effort read helper retained for status/UI callers."""
        try:
            return self._git_checked(*args)
        except TeamGitError:
            return ''

    def _is_git_repo(self) -> bool:
        try:
            r = self._git_result('rev-parse', '--is-inside-work-tree')
            top = self._git_result('rev-parse', '--show-toplevel')
        except TeamGitError:
            return False
        if r.returncode != 0 or top.returncode != 0 or r.stdout.strip() != 'true':
            return False
        return os.path.normcase(str(Path(top.stdout.strip()).resolve())) == os.path.normcase(
            str(self.repo_path)
        )

    def _has_remote(self) -> bool:
        return bool(self._git_checked('remote').strip())

    def _disabled_hooks_path(self) -> str:
        path = self.repo_path / DISABLED_HOOKS_PATH
        if os.path.lexists(path):
            raise TeamGitError(
                f'reserved automatic Git hooks path must not exist: '
                f'{DISABLED_HOOKS_PATH}'
            )
        return DISABLED_HOOKS_PATH

    def _validate_operational_team_paths(self) -> None:
        """Reject links, reparse points and special files in writable team state."""
        for relative in TEAM_SHARED_PATHS:
            path = self.repo_path / relative
            if not os.path.lexists(path):
                continue
            try:
                metadata = os.lstat(path)
            except OSError as exc:
                raise TeamGitError(f'cannot inspect team path {relative}: {exc}') from exc
            if _is_link_or_reparse(metadata):
                raise TeamGitError(
                    f'operational team path must not be a symlink/reparse point: '
                    f'{relative}'
                )
            if relative in TEAM_SHARED_FILES:
                if not stat.S_ISREG(metadata.st_mode):
                    raise TeamGitError(
                        f'operational team path must be a regular file: {relative}'
                    )
                continue
            if not stat.S_ISDIR(metadata.st_mode):
                raise TeamGitError(
                    f'operational team path must be a directory: {relative}'
                )

            def walk_error(exc: OSError) -> None:
                raise TeamGitError(
                    f'cannot recursively inspect team path {relative}: {exc}'
                ) from exc

            for root, directories, files in os.walk(
                path, topdown=True, onerror=walk_error, followlinks=False
            ):
                for names, expect_directory in ((directories, True), (files, False)):
                    for name in names:
                        child = Path(root) / name
                        try:
                            child_metadata = os.lstat(child)
                        except OSError as exc:
                            raise TeamGitError(
                                f'team path changed during validation: {child}: {exc}'
                            ) from exc
                        valid_kind = (
                            stat.S_ISDIR(child_metadata.st_mode)
                            if expect_directory
                            else stat.S_ISREG(child_metadata.st_mode)
                        )
                        if _is_link_or_reparse(child_metadata) or not valid_kind:
                            raise TeamGitError(
                                f'operational team tree contains a link, reparse '
                                f'point or special file: '
                                f'{child.relative_to(self.repo_path)}'
                            )

    @staticmethod
    def is_shared_team_path(path: str) -> bool:
        """Return whether an index path is permitted in an automatic commit."""
        normalized = path.replace('\\', '/')
        while normalized.startswith('./'):
            normalized = normalized[2:]
        if normalized in TEAM_SHARED_FILES:
            return True
        return any(
            normalized == prefix or normalized.startswith(prefix + '/')
            for prefix in TEAM_SHARED_DIRS
        )

    def _validate_tree_team_entries(self, revision: str) -> None:
        """Validate Git modes/types before an automatic checkout or push."""
        raw = self._git_checked(
            'ls-tree', '-r', '-t', '-z', '--full-tree', revision,
            '--', *TEAM_SHARED_PATHS,
        )
        for record in raw.split('\0'):
            if not record:
                continue
            metadata, separator, path = record.partition('\t')
            fields = metadata.split()
            if not separator or len(fields) != 3:
                raise TeamGitError(
                    f'cannot parse Git tree metadata for revision {revision}'
                )
            mode, object_type, _object_id = fields
            regular_blob = (
                mode in {'100644', '100755'}
                and object_type == 'blob'
                and (
                    path in TEAM_SHARED_FILES
                    or any(path.startswith(prefix + '/') for prefix in TEAM_SHARED_DIRS)
                )
            )
            ordinary_tree = (
                mode == '040000'
                and object_type == 'tree'
                and (
                    path == '.team'
                    or any(
                        path == prefix or path.startswith(prefix + '/')
                        for prefix in TEAM_SHARED_DIRS
                    )
                )
            )
            if not (regular_blob or ordinary_tree):
                raise TeamGitError(
                    f'automatic Git scope rejects tree entry {path!r} '
                    f'(mode={mode}, type={object_type})'
                )

    def _active_team_pathspecs(self) -> tuple[str, ...]:
        """Select existing or previously tracked paths from the strict allowlist."""
        tracked_raw = self._git_checked('ls-files', '-z', '--', *TEAM_SHARED_PATHS)
        tracked = tuple(name for name in tracked_raw.split('\0') if name)
        active = []
        for pathspec in TEAM_SHARED_PATHS:
            path = self.repo_path / pathspec
            if os.path.lexists(path):
                metadata = os.lstat(path)
                if stat.S_ISLNK(metadata.st_mode) or getattr(
                    metadata, 'st_reparse_tag', 0
                ):
                    raise TeamGitError(
                        f'automatic Git scope must not be a symlink/reparse point: '
                        f'{pathspec}'
                    )
            prefix = pathspec.rstrip('/') + '/'
            has_worktree_entry = path.is_file() or (
                path.is_dir()
                and any(
                    child.is_file() or child.is_symlink()
                    for child in path.rglob('*')
                )
            )
            if has_worktree_entry or any(
                name == pathspec or name.startswith(prefix) for name in tracked
            ):
                active.append(pathspec)
        return tuple(active)

    def _commit_team_unlocked(self, message: str) -> str:
        """Commit only allowlisted shared state, preserving every other index entry."""
        active = self._active_team_pathspecs()
        if not active:
            return '(nothing to commit)'
        status = self._git_checked(
            'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', *active
        )
        if not status:
            return '(nothing to commit)'

        self._git_checked('add', '-A', '--', *active)
        staged = self._git_result('diff', '--cached', '--quiet', '--', *active)
        if staged.returncode == 0:
            return '(nothing to commit)'
        if staged.returncode != 1:
            detail = ((staged.stderr or '') + (staged.stdout or '')).strip()[-1200:]
            raise TeamGitError(f'cannot inspect staged team state: {detail}')

        out = self._git_checked(
            '-c', 'commit.gpgSign=false',
            '-c', f'core.hooksPath={self._disabled_hooks_path()}',
            'commit', '--only', '--no-verify',
            '-m', message, '--', *active,
        )
        self._validate_tree_team_entries('HEAD')
        self._validate_operational_team_paths()
        return out or '(team state committed)'

    def _range_is_team_only(self, revision_range: str) -> None:
        """Reject a fetched/pushed history range containing any non-team path."""
        revisions = self._git_checked(
            'rev-list', '--reverse', revision_range, '--'
        ).splitlines()
        if len(revisions) > MAX_AUTOMATIC_SYNC_COMMITS:
            raise TeamGitError(
                f'automatic sync refuses {len(revisions)} commits; '
                f'limit is {MAX_AUTOMATIC_SYNC_COMMITS}'
            )
        for revision in revisions:
            self._validate_tree_team_entries(revision)
            raw = self._git_checked(
                'diff-tree', '--root', '-m', '--no-commit-id', '--name-only',
                '-r', '-z', '--no-renames', revision, '--',
            )
            outside = [
                path for path in raw.split('\0')
                if path and not self.is_shared_team_path(path)
            ]
            if outside:
                shown = ', '.join(outside[:5])
                raise TeamGitError(
                    'automatic sync refused non-.team history paths: ' + shown
                )

    def _configured_upstream(self) -> tuple[str, str]:
        branch_result = self._git_result('symbolic-ref', '--quiet', '--short', 'HEAD')
        branch = branch_result.stdout.strip()
        if branch_result.returncode != 0 or not branch:
            raise TeamGitError(
                'automatic sync requires an attached local branch'
            )
        remote_result = self._git_result(
            'config', '--get-all', f'branch.{branch}.remote'
        )
        remotes = remote_result.stdout.splitlines() if remote_result.returncode == 0 else []
        merge_result = self._git_result(
            'config', '--get-all', f'branch.{branch}.merge'
        )
        merge_refs = (
            merge_result.stdout.splitlines() if merge_result.returncode == 0 else []
        )
        if len(remotes) != 1 or len(merge_refs) != 1:
            raise TeamGitError(
                'automatic sync requires exactly one configured upstream remote/ref'
            )
        remote, merge_ref = remotes[0], merge_refs[0]
        configured_remotes = set(self._git_checked('remote').splitlines())
        if (
            remote == '.'
            or remote not in configured_remotes
            or remote.startswith('-')
            or any(ord(character) < 32 for character in remote)
        ):
            raise TeamGitError(f'unsafe or non-network upstream remote: {remote!r}')
        ref_check = self._git_result('check-ref-format', merge_ref)
        if (
            ref_check.returncode != 0
            or not merge_ref.startswith('refs/heads/')
        ):
            raise TeamGitError(f'unsafe upstream merge ref: {merge_ref!r}')
        return remote, merge_ref

    def _is_ancestor(self, older: str, newer: str) -> bool:
        r = self._git_result('merge-base', '--is-ancestor', older, newer)
        if r.returncode not in (0, 1):
            detail = ((r.stderr or '') + (r.stdout or '')).strip()[-1200:]
            raise TeamGitError(f'cannot compare Git histories: {detail}')
        return r.returncode == 0

    def _fetch_unlocked(self, remote: str, merge_ref: str) -> tuple[str, str]:
        # Fetch changes only object/ref state.  It never rewrites the worktree
        # or temporarily stashes user changes.
        temporary_ref = f'refs/raven-automatic-sync/{uuid.uuid4().hex}'
        output = self._git_checked(
            '-c', f'core.hooksPath={self._disabled_hooks_path()}',
            'fetch', '--no-tags', remote, f'{merge_ref}:{temporary_ref}'
        )
        try:
            remote_head = self._git_checked(
                'rev-parse', '--verify', f'{temporary_ref}^{{commit}}'
            )
        finally:
            self._git_checked(
                '-c', f'core.hooksPath={self._disabled_hooks_path()}',
                'update-ref', '-d', temporary_ref,
            )
        return output, remote_head

    def _pull_team_ff_only_unlocked(self) -> str:
        if not self._has_remote():
            return '(no remote)'
        remote, merge_ref = self._configured_upstream()
        fetched, upstream_head = self._fetch_unlocked(remote, merge_ref)
        head = self._git_checked('rev-parse', 'HEAD')
        if head == upstream_head:
            return fetched or '(already up-to-date)'
        if self._is_ancestor(head, upstream_head):
            self._range_is_team_only(f'{head}..{upstream_head}')
            merged = self._git_checked(
                '-c', 'merge.autostash=false',
                '-c', f'core.hooksPath={self._disabled_hooks_path()}',
                'merge', '--ff-only', '--no-stat',
                upstream_head,
            )
            self._validate_operational_team_paths()
            return '\n'.join(note for note in (fetched, merged) if note)
        if self._is_ancestor(upstream_head, head):
            return fetched or '(local branch ahead)'
        raise TeamGitError(
            'automatic sync refuses divergent history; reconcile it explicitly'
        )

    def _push_team_unlocked(self) -> str:
        if not self._has_remote():
            return '(no remote)'
        remote, merge_ref = self._configured_upstream()
        _fetched, upstream_head = self._fetch_unlocked(remote, merge_ref)
        head = self._git_checked('rev-parse', 'HEAD')
        if head == upstream_head:
            return '(already up-to-date)'
        if not self._is_ancestor(upstream_head, head):
            raise TeamGitError(
                'remote advanced or diverged during automatic sync; retry after '
                'explicit reconciliation'
            )
        self._range_is_team_only(f'{upstream_head}..{head}')
        return self._git_checked(
            '-c', f'core.hooksPath={self._disabled_hooks_path()}',
            'push', '--porcelain', '--no-verify', '--no-all', '--no-mirror',
            '--no-tags', '--no-follow-tags', '--no-prune',
            remote, f'HEAD:{merge_ref}',
        )

    @contextmanager
    def _git_lock(self, timeout: float = GIT_LOCK_TIMEOUT_SECONDS):
        """Serialize mutating git sections or fail closed after ``timeout``."""
        self.ensure_layout()
        with _exclusive_file_lock(self.team_dir / '.gitlock', timeout=timeout):
            self._validate_operational_team_paths()
            yield

    def commit_team(self, message: str) -> str:
        """Create one local commit containing only allowlisted `.team` state."""
        if not self._is_git_repo():
            return '(not a git repo)'
        with self._git_lock():
            return self._commit_team_unlocked(message)

    def commit_push(self, message: str) -> str:
        """Safely fast-forward, commit allowlisted team state, then push."""
        if not self._is_git_repo():
            return '(not a git repo)'
        with self._git_lock():
            notes = []
            if self._has_remote():
                notes.append(self._pull_team_ff_only_unlocked())
            notes.append(self._commit_team_unlocked(message))
            if self._has_remote():
                notes.append(self._push_team_unlocked())
        return '\n'.join(note for note in notes if note)

    def pull_team(self) -> str:
        """Fetch and fast-forward only after proving incoming history is team-only."""
        if not self._is_git_repo():
            return '(not a git repo)'
        with self._git_lock():
            return self._pull_team_ff_only_unlocked()

    def commit_staged(self, message: str, *, explicitly_authorized: bool = False) -> str:
        """Commit the existing index only; never stage files implicitly.

        This is the high-risk, agent-facing Git tool.  It is unavailable unless
        the node operator explicitly enables the shell/tool capability.
        """
        if not explicitly_authorized:
            raise PermissionError('git_commit requires explicit allow_shell authorization')
        if not self._is_git_repo():
            return '(not a git repo)'
        with self._git_lock():
            staged_names = self._git_checked(
                'diff', '--cached', '--name-only', '--no-renames', '-z',
                '--diff-filter=ACDMRTUXB',
            )
            staged_paths = [path for path in staged_names.split('\0') if path]
            if not staged_paths:
                return '(nothing staged; git_commit never stages files automatically)'
            unsafe_local = [
                path for path in staged_paths
                if (path == '.team' or path.startswith('.team/'))
                and not self.is_shared_team_path(path)
            ]
            if unsafe_local:
                raise TeamGitError(
                    'refusing to commit local/private .team paths: '
                    + ', '.join(unsafe_local[:5])
                )
            return self._git_checked(
                '-c', 'commit.gpgSign=false',
                '-c', f'core.hooksPath={self._disabled_hooks_path()}',
                'commit', '--no-verify', '-m', message,
            )

    def sync(self) -> str:
        """Fail-closed, `.team`-scoped Git sync across machines."""
        if not self.auto_commit:
            return '(auto_commit disabled)'
        return self.commit_push(f'chore(team-memory): sync at {_ts()}')

    # ----------------------------------------------------------- journal --
    def log_event(self, agent: str, text: str) -> None:
        """Journal as append-only deltas — conflict-free at any team size."""
        self.ensure_layout()
        self._delta(agent).write('event', {'text': str(text)[:400]})

    def journal_entries(self, limit: int = 100) -> list[dict]:
        return [e for e in self._delta('system').read('event')][-limit:]

    def recent_events(self, limit: int = 50) -> list[dict]:
        """Return a bounded, terminal-safe projection of recent events.

        This reader intentionally does not call :meth:`ensure_layout`: that
        method validates all operational team paths recursively, which would
        make this monitoring endpoint attacker-controlled and unbounded.
        """
        if isinstance(limit, bool) or not isinstance(limit, int):
            requested = 50
        else:
            requested = max(0, min(limit, MAX_RECENT_EVENTS_LIMIT))
        if requested == 0:
            return []

        base = self.team_dir / 'deltas'
        try:
            team_metadata = os.lstat(self.team_dir)
            base_metadata = os.lstat(base)
        except OSError:
            return []
        if (
            _is_link_or_reparse(team_metadata)
            or not stat.S_ISDIR(team_metadata.st_mode)
            or _is_link_or_reparse(base_metadata)
            or not stat.S_ISDIR(base_metadata.st_mode)
        ):
            return []

        accepted: list[tuple[float, str, str, dict]] = []
        directory_entries = 0
        writers = 0
        files = 0
        bytes_read = 0
        stop_scan = False

        try:
            with os.scandir(base) as writer_entries:
                while (
                    writers < MAX_RECENT_EVENT_WRITERS
                    and directory_entries < MAX_RECENT_EVENT_DIRECTORY_ENTRIES
                ):
                    try:
                        writer_entry = next(writer_entries)
                    except StopIteration:
                        break
                    directory_entries += 1

                    writer_name = writer_entry.name
                    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,40}', writer_name):
                        continue
                    try:
                        writer_metadata = writer_entry.stat(follow_symlinks=False)
                        current_base = os.lstat(base)
                    except OSError:
                        continue
                    if (
                        _is_link_or_reparse(writer_metadata)
                        or not stat.S_ISDIR(writer_metadata.st_mode)
                        or not _same_file_identity(base_metadata, current_base)
                        or _is_link_or_reparse(current_base)
                    ):
                        continue

                    writers += 1
                    writer_path = Path(writer_entry.path)
                    writer_entry_count = 0
                    try:
                        with os.scandir(writer_path) as event_entries:
                            while (
                                writer_entry_count
                                < MAX_RECENT_EVENT_ENTRIES_PER_WRITER
                                and directory_entries
                                < MAX_RECENT_EVENT_DIRECTORY_ENTRIES
                                and files < MAX_RECENT_EVENT_FILES
                            ):
                                try:
                                    event_entry = next(event_entries)
                                except StopIteration:
                                    break
                                writer_entry_count += 1
                                directory_entries += 1

                                if not (
                                    event_entry.name.startswith('event-')
                                    and event_entry.name.endswith('.json')
                                ):
                                    continue
                                files += 1

                                try:
                                    event_metadata = event_entry.stat(
                                        follow_symlinks=False
                                    )
                                    current_writer = os.lstat(writer_path)
                                except OSError:
                                    continue
                                if (
                                    _is_link_or_reparse(event_metadata)
                                    or not stat.S_ISREG(event_metadata.st_mode)
                                    or not _same_file_identity(
                                        writer_metadata, current_writer
                                    )
                                    or _is_link_or_reparse(current_writer)
                                ):
                                    continue

                                remaining = (
                                    MAX_RECENT_EVENT_TOTAL_BYTES - bytes_read
                                )
                                payload, consumed = _read_stable_regular_file(
                                    Path(event_entry.path),
                                    event_metadata,
                                    remaining,
                                )
                                bytes_read += consumed
                                if payload is None:
                                    if bytes_read >= MAX_RECENT_EVENT_TOTAL_BYTES:
                                        stop_scan = True
                                        break
                                    continue

                                try:
                                    record = json.loads(payload.decode('utf-8'))
                                except (UnicodeDecodeError, ValueError, RecursionError):
                                    continue
                                if not isinstance(record, dict):
                                    continue
                                timestamp = record.get('at')
                                if (
                                    isinstance(timestamp, bool)
                                    or not isinstance(timestamp, (int, float))
                                    or record.get('kind') != 'event'
                                    or record.get('w') != writer_name
                                    or not isinstance(record.get('text'), str)
                                ):
                                    continue
                                try:
                                    sort_timestamp = float(timestamp)
                                except (OverflowError, TypeError, ValueError):
                                    continue
                                if not math.isfinite(sort_timestamp):
                                    continue

                                projected = {
                                    'w': writer_name,
                                    'at': sort_timestamp,
                                    'kind': 'event',
                                    'text': _sanitize_event_text(record['text']),
                                }
                                accepted.append((
                                    sort_timestamp,
                                    writer_name,
                                    event_entry.name,
                                    projected,
                                ))
                    except OSError:
                        pass

                    if files >= MAX_RECENT_EVENT_FILES:
                        stop_scan = True

                    if stop_scan:
                        break
        except OSError:
            pass

        accepted.sort(key=lambda item: item[:3], reverse=True)
        return [item[3] for item in accepted[:requested]]

    # ------------------------------------------------------------- board --
    def read_board(self) -> str:
        """BOARD.md is a *projection* of task deltas — deterministic on all
        machines, regenerated from the same delta set."""
        self.ensure_layout()
        rows = self._parse_board_rows()
        lines = '\n'.join(
            f"| {r['id']} | {_cell(r['title'])} | {_cell(r['owner'])} "
            f"| {_cell(r['status'])} | {_cell(r['notes'])} |"
            for r in rows)
        return BOARD_HEADER + (lines + '\n' if lines else '')

    def _delta(self, writer: str) -> DeltaStore:
        return DeltaStore(self, writer)

    def set_task(
        self,
        title: str,
        task_id: str | None = None,
        owner: str = '',
        status: str = 'open',
        notes: str = '',
    ) -> dict:
        self.ensure_layout()
        existing = {r['id'] for r in self._parse_board_rows()}
        if task_id is None:
            n = len(existing) + 1
            # random suffix → concurrent writers can never allocate the same id
            task_id = f't-{n}-{uuid.uuid4().hex[:4]}'
        row = {
            'id': task_id,
            'title': title,
            'owner': owner,
            'status': status,
            'notes': notes,
        }
        self._delta(owner or 'system').write('task', row)
        # regenerate the human-readable projection
        self.board_md.write_text(self.read_board(), encoding='utf-8')
        if self.auto_commit:
            self.commit_team(
                f'chore(board): {task_id} → {row["status"]} '
                f'by {owner or "system"}'
            )
        return row

    def _parse_board_rows(self) -> list[dict]:
        """Project all task deltas — last-write-wins per id, stable order."""
        tasks: list[dict] = []
        seen: set[str] = set()
        for rec in self._delta('system').read('task'):
            tid = str(rec.get('id', ''))
            if not tid:
                continue
            row = {
                'id': tid,
                'title': rec.get('title', ''),
                'owner': rec.get('owner', ''),
                'status': rec.get('status', 'open'),
                'notes': rec.get('notes', ''),
            }
            if tid in seen:
                for i, r in enumerate(tasks):
                    if r['id'] == tid:
                        tasks[i] = row
                        break
            else:
                seen.add(tid)
                tasks.append(row)
        return tasks

    # ------------------------------------------------------------- facts --
    def remember_fact(self, text: str) -> None:
        self.ensure_layout()
        self._delta('system').write('fact', {'text': text.strip()})

    def read_facts(self) -> str:
        self.ensure_layout()
        lines = []
        for rec in self._delta('system').read('fact'):
            bullet = f'- {str(rec.get("text", "")).strip()}'
            if bullet not in lines:
                lines.append(bullet)
        return FACTS_HEADER + '\n'.join(lines) + ('\n' if lines else '')

    # ------------------------------------------------------------- locks --
    @staticmethod
    def _lock_name(path: str) -> str:
        return re.sub(r'[^A-Za-z0-9_.-]+', '_', path) + '.lock'

    def claim_file(self, path: str, owner: str) -> str:
        self.ensure_layout()
        lock = self.locks_dir / self._lock_name(path)
        if lock.exists():
            current = lock.read_text(encoding='utf-8').split('\n', 1)[0].strip()
            if current == owner:
                return f'ok (already yours): {path}'
            return f'BUSY: {path} claimed by {current}'
        lock.write_text(f'{owner}\nclaimed_at: {_ts()}\n', encoding='utf-8')
        if self.auto_commit:
            self.commit_team(f'chore(locks): {owner} claims {path}')
        return f'ok: claimed {path}'

    def release_file(self, path: str, owner: str) -> str:
        lock = self.locks_dir / self._lock_name(path)
        if not lock.exists():
            return f'not locked: {path}'
        current = lock.read_text(encoding='utf-8').split('\n', 1)[0].strip()
        if current != owner:
            return f'DENIED: {path} belongs to {current}'
        lock.unlink()
        if self.auto_commit:
            self.commit_team(f'chore(locks): {owner} releases {path}')
        return f'ok: released {path}'
