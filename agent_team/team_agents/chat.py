"""Group-chat layer for the agent team — shared thread + unified goal.

State lives in the shared repo so every machine sees the same conversation:
    .team/GOAL.md      — the single mission everyone works toward
    .team/chat/log.md  — append-only group transcript

Patterns borrowed from AutoGen group-chat & CrewAI role-goal design:
user posts `@agent do X` (or `@all`) — mentioned agents get the task routed
through the transport ladder; everything lands in one visible thread.
"""

from __future__ import annotations

import re
import time
from pathlib import Path

from .memory import TeamMemory

MAX_CHAT_LINES = 500


class TeamChat:
    def __init__(self, memory: TeamMemory) -> None:
        self.memory = memory
        self.goal_md = self.memory.resolve_in_repo('.team/GOAL.md')
        self.chat_md = self.memory.resolve_in_repo('.team/chat/log.md')

    # -------------------------------------------------------------- layout --
    def ensure(self) -> None:
        self.memory.ensure_layout()
        self.chat_md.parent.mkdir(parents=True, exist_ok=True)
        if not self.goal_md.exists():
            self.goal_md.parent.mkdir(parents=True, exist_ok=True)
            self.goal_md.write_text(
                '# TEAM GOAL\n\n(not set — every agent works independently)\n',
                encoding='utf-8')
        if not self.chat_md.exists():
            self.chat_md.write_text('# Team Chat\n', encoding='utf-8')

    # --------------------------------------------------------------- goal ---
    def set_goal(self, text: str) -> None:
        self.ensure()
        header = '# TEAM GOAL\n\n'
        body = (text.strip() or '(not set — every agent works independently)')
        self.goal_md.write_text(f'{header}{body}\n', encoding='utf-8')
        if self.memory.auto_commit:
            self.memory.commit_all('chore(goal): update team mission')

    def get_goal(self) -> str:
        try:
            raw = self.goal_md.read_text(encoding='utf-8')
            return '\n'.join(
                l for l in raw.splitlines() if not l.startswith('# ')
            ).strip()
        except Exception:  # noqa: BLE001
            return ''

    # --------------------------------------------------------------- chat ---
    def post(self, sender: str, text: str) -> None:
        """Append one message to the shared thread."""
        self.ensure()
        clean = text.replace('\n', ' ')
        with self.chat_md.open('a', encoding='utf-8') as fh:
            fh.write(f'- {time.strftime("%H:%M:%S")} **{sender}**: {clean}\n')
        self._trim()
        if self.memory.auto_commit:
            self.memory.commit_all(f'chat: {sender}')

    def tail(self, n: int = 30) -> str:
        self.ensure()
        lines = self.chat_md.read_text(encoding='utf-8').splitlines()[1:]
        return '\n'.join(lines[-n:]) or '(empty)'

    def _trim(self) -> None:
        lines = self.chat_md.read_text(encoding='utf-8').splitlines()
        if len(lines) > MAX_CHAT_LINES:
            keep = [lines[0]] + lines[-(MAX_CHAT_LINES - 1):]
            self.chat_md.write_text('\n'.join(keep) + '\n', encoding='utf-8')


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
