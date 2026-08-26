"""Git-backed shared team memory: board, journal, facts and file locks.

All state lives under `<repo>/.team/` so teammates on other machines sync
through plain git — no server, no database.
"""

from __future__ import annotations

import fcntl
import re
import subprocess
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from .deltas import DeltaStore

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
        self.team_dir.mkdir(parents=True, exist_ok=True)
        (self.team_dir / 'outputs').mkdir(exist_ok=True)
        self.locks_dir.mkdir(exist_ok=True)
        for path, header in (
            (self.board_md, BOARD_HEADER),
            (self.journal_md, JOURNAL_HEADER),
            (self.facts_md, FACTS_HEADER),
        ):
            if not path.exists():
                path.write_text(header, encoding='utf-8')

    def resolve_in_repo(self, relpath: str) -> Path:
        p = (self.repo_path / relpath).resolve()
        if p != self.repo_path and self.repo_path not in p.parents:
            raise ValueError(f'path escapes repo: {relpath}')
        return p

    # --------------------------------------------------------------- git --
    def _git(self, *args: str) -> str:
        """Run git with automatic retry on index.lock contention."""
        for attempt in range(6):
            try:
                r = subprocess.run(
                    ('git', '-C', str(self.repo_path), *args),
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
            except subprocess.TimeoutExpired:
                return ''
            if r.returncode == 0:
                return (r.stdout + r.stderr).strip()
            err = (r.stderr or '') + (r.stdout or '')
            if 'index.lock' in err:
                time.sleep(0.15 * (attempt + 1))
                continue
            return ''
        return ''

    @contextmanager
    def _git_lock(self):
        """Serialize mutating git sections across threads/processes."""
        self.ensure_layout()
        f = open(self.team_dir / '.gitlock', 'w')
        try:
            fcntl.flock(f, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)
            f.close()

    def commit_push(self, message: str) -> str:
        """Locked commit + push with one rebase-retry (concurrent pushes)."""
        with self._git_lock():
            out = self.commit_all(message)
        if not self._git('remote'):
            return out
        pushed = self._git('push')
        if not pushed and 'Everything up-to-date' not in pushed:
            self._git('pull', '--rebase', '--autostash')
            pushed = self._git('push')
        return out

    def commit_all(self, message: str) -> str:
        if not (self.repo_path / '.git').exists():
            return '(not a git repo)'
        self._git('add', '-A')
        out = self._git('commit', '-m', message)
        return out or '(nothing to commit)'

    def sync(self) -> str:
        """Best-effort git sync of the shared memory across machines."""
        if not self.auto_commit:
            return '(auto_commit disabled)'
        if not (self.repo_path / '.git').exists():
            return '(not a git repo)'
        if not self._git('remote'):
            return '(no remote)'
        notes = [self.commit_all(f'chore(team-memory): sync at {_ts()}')]
        pull = self._git('pull', '--rebase', '--autostash')
        if pull:
            notes.append(pull)
        push = self._git('push')
        if push:
            notes.append(push)
        return '\n'.join(notes)

    # ----------------------------------------------------------- journal --
    def log_event(self, agent: str, text: str) -> None:
        """Journal as append-only deltas — conflict-free at any team size."""
        self.ensure_layout()
        self._delta(agent).write('event', {'text': str(text)[:400]})

    def journal_entries(self, limit: int = 100) -> list[dict]:
        return [e for e in self._delta('system').read('event')][-limit:]

    def recent_events(self, limit: int = 50) -> list[dict]:
        """Every agent's events, newest first — powers live monitoring."""
        import json

        self.ensure_layout()
        out: list[dict] = []
        base = self.resolve_in_repo('.team/deltas')
        if base.exists():
            for d in base.iterdir():
                if not d.is_dir():
                    continue
                for f in sorted(d.glob('event-*.json')):
                    try:
                        out.append(json.loads(f.read_text(encoding='utf-8')))
                    except Exception:  # noqa: BLE001
                        continue
        out.sort(key=lambda r: r.get('at', 0), reverse=True)
        return out[:limit]

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
            self.commit_all(f'chore(board): {task_id} → {row["status"]} by {owner or "system"}')
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
            self.commit_all(f'chore(locks): {owner} claims {path}')
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
            self.commit_all(f'chore(locks): {owner} releases {path}')
        return f'ok: released {path}'
