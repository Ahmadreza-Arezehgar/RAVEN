"""Append-only delta store — the conflict-free heart of team memory.

Every mutation is a uniquely-named file under `.team/deltas/<writer>/`, so
git merges NEVER collide even when dozens of agents push simultaneously.
Views (board / chat / journal / facts) are *projections* computed at read
time — the event-sourcing pattern recommended for multi-agent fleets.
"""

from __future__ import annotations

import json
import re
import time
import uuid


class DeltaStore:
    def __init__(self, memory, writer: str = 'system') -> None:
        self.memory = memory
        self.writer = re.sub(r'[^A-Za-z0-9_.-]', '_', writer or 'system')[:40]

    # ------------------------------------------------------------- write ---
    def write(self, kind: str, payload: dict):
        d = self._dir()
        d.mkdir(parents=True, exist_ok=True)
        rec = {'w': self.writer,
               'at': time.time(),
               'kind': kind,
               **payload}
        f = d / f'{kind}-{int(time.time() * 1000)}-{uuid.uuid4().hex[:6]}.json'
        f.write_text(json.dumps(rec, ensure_ascii=False), encoding='utf-8')
        return f

    # -------------------------------------------------------------- read ---
    def read(self, kind: str) -> list[dict]:
        base = self.memory.resolve_in_repo('.team/deltas')
        if not base.exists():
            return []
        out = []
        for d in base.iterdir():
            if not d.is_dir():
                continue
            for f in sorted(d.glob(f'{kind}-*.json')):
                try:
                    out.append(json.loads(f.read_text(encoding='utf-8')))
                except Exception:  # noqa: BLE001
                    continue
        out.sort(key=lambda r: (r.get('at', 0)))
        return out

    def latest_by(self, kind: str, key: str) -> list[dict]:
        """Last-write-wins projection grouped by `key` (e.g. task id)."""
        seen: dict[str, dict] = {}
        for rec in self.read(kind):
            k = str(rec.get(key, ''))
            if k:
                seen[k] = rec          # later timestamps overwrite earlier
        return list(seen.values())

    def _dir(self) -> Path:
        return self.memory.resolve_in_repo(f'.team/deltas/{self.writer}')
