"""Git-backed shared team memory: board, journal, facts and file locks.

All state lives under `<repo>/.team/` so teammates on other machines sync
through plain git — no server, no database.
"""

from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path

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


def _unescape(text: str) -> str:
    return text.replace('\\|', '|')


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
        try:
            r = subprocess.run(
                ('git', '-C', str(self.repo_path), *args),
                capture_output=True,
                text=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired:
            return ''
        if r.returncode != 0:
            return ''
        return (r.stdout + r.stderr).strip()

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
        self.ensure_layout()
        with self.journal_md.open('a', encoding='utf-8') as fh:
            fh.write(f'- {_ts()} [{agent}] {text}\n')

    # ------------------------------------------------------------- board --
    def read_board(self) -> str:
        self.ensure_layout()
        return self.board_md.read_text(encoding='utf-8')

    def set_task(
        self,
        title: str,
        task_id: str | None = None,
        owner: str = '',
        status: str = 'open',
        notes: str = '',
    ) -> dict:
        self.ensure_layout()
        rows = self._parse_board_rows()
        if task_id is None:
            task_id = f't-{len(rows) + 1}'
            while any(r['id'] == task_id for r in rows):
                task_id += 'x'
        row = {
            'id': task_id,
            'title': title,
            'owner': owner,
            'status': status,
            'notes': notes,
        }
        for i, existing in enumerate(rows):
            if existing['id'] == task_id:
                merged = {**existing, **{k: v for k, v in row.items() if v}}
                rows[i] = merged
                row = merged
                break
        else:
            rows.append(row)
        lines = (
            '\n'.join(
                f"| {r['id']} | {_cell(r['title'])} | {_cell(r['owner'])} "
                f"| {_cell(r['status'])} | {_cell(r['notes'])} |"
                for r in rows
            )
            + '\n'
        )
        self.board_md.write_text(BOARD_HEADER + lines, encoding='utf-8')
        if self.auto_commit:
            self.commit_all(f'chore(board): {task_id} → {row["status"]} by {owner or "system"}')
        return row

    def _parse_board_rows(self) -> list[dict]:
        rows: list[dict] = []
        # split on unescaped pipes so titles containing '|' survive round-trips
        for line in self.board_md.read_text(encoding='utf-8').splitlines():
            if not line.startswith('|'):
                continue
            cells = [
                _unescape(c.strip()) for c in re.split(r'(?<!\\)\|', line.strip('|'))
            ]
            if len(cells) != 5 or cells[0] in ('id', '') or set(cells[0]) <= {'-'}:
                continue
            rows.append(
                {
                    'id': cells[0],
                    'title': cells[1],
                    'owner': cells[2],
                    'status': cells[3],
                    'notes': cells[4],
                }
            )
        return rows

    # ------------------------------------------------------------- facts --
    def remember_fact(self, text: str) -> None:
        self.ensure_layout()
        body = self.facts_md.read_text(encoding='utf-8').splitlines()
        bullet = f'- {text.strip()}'
        if bullet in body:
            return
        body.append(bullet)
        self.facts_md.write_text('\n'.join(body) + '\n', encoding='utf-8')

    def read_facts(self) -> str:
        self.ensure_layout()
        return self.facts_md.read_text(encoding='utf-8')

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
