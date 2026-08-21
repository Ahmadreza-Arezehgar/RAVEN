"""Git-synced shared memory for a collaborating agent team.

Layout inside the shared repo:

    <repo>/.team/
        board.json     task board (machine readable)
        BOARD.md       human/agent readable mirror of the board
        facts.md       durable learned facts
        claims.json    advisory file locks ("who is editing what")
        journal/work.log  append-only activity log
"""

from __future__ import annotations

import json
import subprocess
import time
import uuid
from pathlib import Path


def now_iso() -> str:
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


class TeamMemory:
    def __init__(self, repo_path: str | Path, auto_commit: bool = True) -> None:
        self.repo_path = Path(repo_path).expanduser().resolve()
        if not self.repo_path.exists():
            raise FileNotFoundError(f'repo_path does not exist: {self.repo_path}')
        self.auto_commit = auto_commit
        self.root = self.repo_path / '.team'
        self.journal_dir = self.root / 'journal'
        self.board_file = self.root / 'board.json'
        self.board_md = self.root / 'BOARD.md'
        self.facts_file = self.root / 'facts.md'
        self.claims_file = self.root / 'claims.json'
        self.work_log = self.journal_dir / 'work.log'

    # ------------------------------------------------------------- layout --
    def ensure_layout(self) -> None:
        self.journal_dir.mkdir(parents=True, exist_ok=True)
        if not self.board_file.exists():
            self._write_json(self.board_file, [])
        if not self.claims_file.exists():
            self._write_json(self.claims_file, {})
        if not self.facts_file.exists():
            self.facts_file.write_text(
                '# Team Facts\n\nDurable facts discovered by team agents.\n',
                encoding='utf-8',
            )
        if not self.board_md.exists():
            self._render_board()

    # ------------------------------------------------------------ helpers --
    @staticmethod
    def _write_json(path: Path, data: object) -> None:
        tmp = path.with_suffix(path.suffix + f'.tmp{uuid.uuid4().hex[:6]}')
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')
        tmp.replace(path)

    def _read_json(self, path: Path, default: object) -> object:
        try:
            return json.loads(path.read_text(encoding='utf-8'))
        except (FileNotFoundError, json.JSONDecodeError):
            return default

    def resolve_in_repo(self, relpath: str) -> Path:
        """Resolve `relpath` inside the repo; refuse escapes."""
        p = (self.repo_path / relpath).resolve()
        if p != self.repo_path and self.repo_path not in p.parents:
            raise ValueError(f'path escapes repo: {relpath}')
        return p

    # --------------------------------------------------------------- git ---
    def _git(self, *args: str, check: bool = False) -> str:
        r = subprocess.run(
            ['git', *args], cwd=self.repo_path, capture_output=True, text=True
        )
        if check and r.returncode != 0:
            raise RuntimeError(f'git {" ".join(args)} failed: {r.stderr.strip()}')
        return (r.stdout + r.stderr).strip()

    def has_remote(self) -> bool:
        return bool(self._git('remote').strip())

    def commit_all(self, message: str) -> str:
        """Stage everything and commit. Returns a status string."""
        if not message:
            message = 'chore(agent): update shared state'
        self._git('add', '-A')
        dirty = self._git('status', '--porcelain')
        if not dirty:
            return 'nothing to commit'
        self._git('commit', '-m', message)
        return f'committed: {message}'

    def sync(self) -> str:
        """pull --rebase then push. Best effort; returns a report."""
        report: list[str] = []
        if not self.has_remote():
            return 'no git remote configured; sync skipped'
        pull = self._git('pull', '--rebase', '--autostash')
        report.append(f'pull: {pull.splitlines()[-1] if pull else "ok"}')
        push = self._git('push', 'origin', 'HEAD')
        report.append(f'push: {push.splitlines()[-1] if push else "ok"}')
        return ' | '.join(report)

    # -------------------------------------------------------------- board --
    def read_board(self) -> list[dict]:
        return list(self._read_json(self.board_file, []))  # type: ignore[arg-type]

    def set_task(
        self,
        title: str,
        *,
        task_id: str | None = None,
        owner: str = '',
        status: str = 'open',
        notes: str = '',
    ) -> dict:
        board = self.read_board()
        if task_id:
            for t in board:
                if t['id'] == task_id:
                    t.update(
                        title=title or t['title'],
                        owner=owner or t.get('owner', ''),
                        status=status,
                        notes=notes or t.get('notes', ''),
                        updated=now_iso(),
                    )
                    self._save_board(board)
                    return t
            raise KeyError(f'task not found: {task_id}')
        task = {
            'id': f'task-{uuid.uuid4().hex[:8]}',
            'title': title,
            'owner': owner,
            'status': status,
            'notes': notes,
            'created': now_iso(),
            'updated': now_iso(),
        }
        board.append(task)
        self._save_board(board)
        return task

    def _save_board(self, board: list[dict]) -> None:
        self.ensure_layout()
        self._write_json(self.board_file, board)
        self._render_board()
        if self.auto_commit:
            self.commit_all('chore(team-memory): update board')

    def _render_board(self) -> None:
        lines = ['# Team Task Board', '']
        for t in self.read_board():
            lines.append(
                f"- [{t.get('status', '?')}] **{t.get('id')}** {t.get('title')} "
                f"(owner: {t.get('owner') or '-'}, updated: {t.get('updated')})"
            )
            if t.get('notes'):
                lines.append(f"  - note: {t['notes']}")
        self.board_md.write_text('\n'.join(lines) + '\n', encoding='utf-8')

    # ------------------------------------------------------------ journal --
    def log_event(self, node: str, text: str) -> None:
        self.ensure_layout()
        line = f'{now_iso()} [{node}] {text}\n'
        with self.work_log.open('a', encoding='utf-8') as fh:
            fh.write(line)

    def read_journal_tail(self, n: int = 40) -> str:
        try:
            lines = self.work_log.read_text(encoding='utf-8').splitlines()
        except FileNotFoundError:
            return '(empty journal)'
        return '\n'.join(lines[-n:])

    # --------------------------------------------------------------- facts -
    def remember_fact(self, text: str) -> None:
        self.ensure_layout()
        with self.facts_file.open('a', encoding='utf-8') as fh:
            fh.write(f'- ({now_iso()}) {text}\n')

    def read_facts(self) -> str:
        try:
            return self.facts_file.read_text(encoding='utf-8')
        except FileNotFoundError:
            return '(no facts yet)'

    # -------------------------------------------------------------- claims -
    def claim_file(self, path: str, owner: str) -> str:
        claims = self._read_json(self.claims_file, {})  # type: ignore[arg-type]
        assert isinstance(claims, dict)
        holder = claims.get(path)
        if holder and holder != owner:
            return f'DENIED: {path} is claimed by {holder}'
        claims[path] = owner
        self._write_json(self.claims_file, claims)
        if self.auto_commit:
            self.commit_all(f'chore(team-memory): {owner} claims {path}')
        return f'OK: {owner} claimed {path}'

    def release_file(self, path: str, owner: str) -> str:
        claims = self._read_json(self.claims_file, {})  # type: ignore[arg-type]
        assert isinstance(claims, dict)
        holder = claims.get(path)
        if holder and holder != owner:
            return f'DENIED: {path} belongs to {holder}'
        claims.pop(path, None)
        self._write_json(self.claims_file, claims)
        if self.auto_commit:
            self.commit_all(f'chore(team-memory): {owner} releases {path}')
        return f'OK: released {path}'
