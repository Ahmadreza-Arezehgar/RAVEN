"""Group-chat layer for the agent team — shared thread + unified goal.

State lives in the shared repo so every machine sees the same conversation:
    .team/GOAL.md      — the single mission everyone works toward
    .team/chat/log.md  — append-only group transcript

Patterns borrowed from AutoGen group-chat & CrewAI role-goal design:
user posts `@agent do X` (or `@all`) — mentioned agents get the task routed
through the transport ladder; everything lands in one visible thread.
"""

from __future__ import annotations

import os
import re
import stat
import time
from pathlib import Path

from .deltas import DeltaStore
from .memory import TeamMemory, _atomic_write_shared_text, _sanitize_event_text

MAX_GOAL_BYTES = 64 * 1024
MAX_CHAT_TAIL_LINES = 100

class TeamChat:
    def __init__(self, memory: TeamMemory, writer: str = 'user') -> None:
        self.memory = memory
        self.delta = DeltaStore(memory, writer)
        self.goal_md = self.memory.repo_path / '.team' / 'GOAL.md'

    # -------------------------------------------------------------- layout --
    def ensure(self) -> None:
        self.memory.ensure_layout()
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0)
        descriptor = -1
        try:
            descriptor = os.open(self.goal_md, flags, 0o644)
            with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
                descriptor = -1
                handle.write(
                    '# TEAM GOAL\n\n(not set — every agent works independently)\n'
                )
                handle.flush()
                os.fsync(handle.fileno())
        except FileExistsError:
            pass
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        metadata = os.lstat(self.goal_md)
        if self.goal_md.is_symlink() or not stat.S_ISREG(metadata.st_mode):
            raise ValueError('team goal path must be a regular file')

    # --------------------------------------------------------------- goal ---
    def set_goal(self, text: str) -> None:
        self.ensure()
        header = '# TEAM GOAL\n\n'
        body = (text.strip() or '(not set — every agent works independently)')
        rendered = f'{header}{body}\n'
        if len(rendered.encode('utf-8')) > MAX_GOAL_BYTES:
            raise ValueError('team goal exceeds the compiled byte limit')
        with self.memory._git_lock():
            is_git = self.memory.auto_commit and self.memory._is_git_repo()
            if is_git and self.memory._has_remote():
                self.memory._pull_team_ff_only_unlocked()
            _atomic_write_shared_text(self.goal_md, rendered)
            if is_git:
                self.memory._commit_team_unlocked(
                    'chore(goal): update team mission'
                )
                if self.memory._has_remote():
                    self.memory._push_team_unlocked()

    def get_goal(self) -> str:
        try:
            metadata = os.lstat(self.goal_md)
            if (
                self.goal_md.is_symlink()
                or not stat.S_ISREG(metadata.st_mode)
                or metadata.st_nlink != 1
                or metadata.st_size > MAX_GOAL_BYTES
            ):
                return ''
            flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0)
            flags |= getattr(os, 'O_NOFOLLOW', 0)
            descriptor = os.open(self.goal_md, flags)
            try:
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or opened.st_nlink != 1
                    or (opened.st_dev, opened.st_ino)
                    != (metadata.st_dev, metadata.st_ino)
                ):
                    return ''
                raw = os.read(descriptor, MAX_GOAL_BYTES + 1)
            finally:
                os.close(descriptor)
            if len(raw) > MAX_GOAL_BYTES:
                return ''
            decoded = raw.decode('utf-8')
            return '\n'.join(
                line for line in decoded.splitlines() if not line.startswith('# ')
            ).strip()
        except Exception:  # noqa: BLE001
            return ''

    # --------------------------------------------------------------- chat ---
    def post(self, sender: str, text: str) -> None:
        """Append one message as a delta — unique file, zero git conflicts."""
        self.ensure()
        safe_sender = _sanitize_event_text(str(sender))
        safe_text = _sanitize_event_text(str(text).replace('\n', ' '))
        with self.memory._git_lock():
            is_git = self.memory.auto_commit and self.memory._is_git_repo()
            if is_git and self.memory._has_remote():
                self.memory._pull_team_ff_only_unlocked()
            self.delta.write(
                'chat', {'sender': safe_sender, 'text': safe_text}
            )
            if is_git:
                self.memory._commit_team_unlocked(f'chat: {safe_sender}')
                if self.memory._has_remote():
                    self.memory._push_team_unlocked()

    def tail(self, n: int = 30) -> str:
        self.ensure()
        if isinstance(n, bool) or not isinstance(n, int):
            raise ValueError('chat line count must be an integer')
        n = max(1, min(n, MAX_CHAT_TAIL_LINES))
        recs = self.delta.read('chat')[-n:]
        if not recs:
            return '(empty)'

        def display_time(value: object) -> str:
            try:
                return time.strftime('%H:%M:%S', time.localtime(float(value)))
            except (OverflowError, OSError, TypeError, ValueError):
                return '??:??:??'

        return '\n'.join(
            f"- {display_time(r.get('at', 0))} "
            f"**{_sanitize_event_text(str(r.get('sender', '?')))}**: "
            f"{_sanitize_event_text(str(r.get('text', '')))}"
            for r in recs)


def parse_mentions(text: str, known: list[str]) -> list[str]:
    """Return teammate names @mentioned (plus 'all' if @all/@team used)."""
    found: list[str] = []
    for m in re.finditer(r'@([\w.-]+)', text):
        tag = m.group(1).lower()
        if tag in ('all', 'team', 'everyone'):
            found = ['@all']
            break
        match = next((k for k in known if k.lower() == tag), None)
        if match and match not in found:
            found.append(match)
    return found
