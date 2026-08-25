"""Git store-and-forward relay: agents keep talking even when offline.

Tasks/results are signed JSON files in the shared repo:
    .team/inbox/<peer-rvn1-address>/<ts>-<id>.json       (tasks for that peer)
    .team/outbox/<sender-rvn1-address>/<task-id>.json    (answers back)

Mirrors RAVEN's DTN philosophy: HTTP (A2A) when reachable, durable git
transport otherwise — same repo both Macs already sync.
"""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path

from .memory import TeamMemory
from .raven_identity import RavenIdentity, sign_delegation, verify_delegation


class GitRelay:
    def __init__(self, memory: TeamMemory, identity: RavenIdentity,
                 trusted_peers_file=None, trusted_peers: dict | None = None) -> None:
        self.memory = memory
        self.identity = identity
        self.peers_file = trusted_peers_file
        self.static_peers = trusted_peers or {}

    # ------------------------------------------------------------- peers --
    def peers(self) -> dict[str, str]:
        if self.peers_file and Path(self.peers_file).exists():
            try:
                from .config import load_trusted_peers

                return load_trusted_peers(Path(self.peers_file))
            except Exception:  # noqa: BLE001
                pass
        return self.static_peers

    def addr_by_name(self) -> dict[str, str]:
        """peer name → address, from the wizard state if available."""
        st = {}
        sf = self.memory.repo_path.parent / 'rdap.json'
        if not sf.exists():
            sf = Path.home() / 'rdap' / 'rdap.json'
        try:
            raw = json.loads(sf.read_text(encoding='utf-8'))
            st = {name: m.get('address', '')
                  for name, m in raw.get('teammates', {}).items()}
        except Exception:  # noqa: BLE001
            pass
        return st

    # ------------------------------------------------------------ helpers --
    def _slot(self, kind: str, peer_addr: str) -> Path:
        p = self.memory.resolve_in_repo(f'.team/{kind}/{peer_addr}')
        p.mkdir(parents=True, exist_ok=True)
        return p

    def _commit_push(self, msg: str) -> bool:
        out = self.memory.commit_push(msg)
        return 'nothing to commit' not in out

    def pull(self) -> None:
        if self.memory._git('remote'):
            self.memory._git('pull', '--rebase', '--autostash')

    # --------------------------------------------------------------- send --
    def send_task(self, peer_address: str, text: str) -> Path:
        block = sign_delegation(self.identity, text)
        envelope = {
            'id': uuid.uuid4().hex[:12],
            'kind': 'task',
            'from': self.identity.address,
            'to': peer_address,
            'text': text,
            'raven': block,
            'at': time.strftime('%Y-%m-%d %H:%M:%S'),
        }
        slot = self._slot('inbox', peer_address)
        f = slot / f"{time.strftime('%Y%m%d-%H%M%S')}-{envelope['id']}.json"
        f.write_text(json.dumps(envelope, indent=2), encoding='utf-8')
        self.memory.log_event(self.identity.address[:10],
                              f'relay→ {peer_address[:14]}… : {text[:60]}')
        self.pull()
        self._commit_push(f'relay(task): {envelope["id"]} → {peer_address[:14]}…')
        return f

    # -------------------------------------------------------------- drain --
    def inbox_for_me(self) -> list[dict]:
        slot = self._slot('inbox', self.identity.address)
        out = []
        for f in sorted(slot.glob('*.json')):
            try:
                env = json.loads(f.read_text(encoding='utf-8'))
                env['_file'] = f
                out.append(env)
            except Exception:  # noqa: BLE001
                continue
        return out

    async def process_inbox(self, brain_run) -> int:
        """Verify + execute + answer each pending task. Returns count."""
        import inspect

        done = 0
        for env in self.inbox_for_me():
            ok, reason = verify_delegation(
                env.get('raven', {}), env.get('text', ''),
                trusted_peers=self.peers(), required=True,
            )
            sender = env.get('from', '?')
            if not ok:
                self.memory.log_event(self.identity.address[:10],
                                      f'relay REJECT {env.get("id")}: {reason}')
                env['_file'].unlink(missing_ok=True)
                continue
            try:
                res = brain_run(env.get('text', ''))
                if inspect.isawaitable(res):
                    res = await res
                answer = res
            except Exception as exc:  # noqa: BLE001
                answer = f'{type(exc).__name__}: {exc}'
            reply = {
                'id': env.get('id'),
                'kind': 'answer',
                'from': self.identity.address,
                'to': sender,
                'text': answer,
                'at': time.strftime('%Y-%m-%d %H:%M:%S'),
            }
            out = self._slot('outbox', sender)
            (out / f"{env.get('id')}.json").write_text(
                json.dumps(reply, indent=2), encoding='utf-8')
            env['_file'].unlink(missing_ok=True)
            done += 1
            self.memory.log_event(self.identity.address[:10],
                                  f'relay✓ {env.get("id")} from {sender[:14]}…')
            try:
                from .chat import TeamChat

                TeamChat(self.memory).post(
                    self.identity.address[:12],
                    f'✅ {env.get("id")}: {str(answer)[:110]}')
            except Exception:  # noqa: BLE001
                pass
        if done:
            self._commit_push(f'relay(answer): {done} task(s) processed')
        return done

    def replies_for_me(self) -> list[dict]:
        slot = self._slot('outbox', self.identity.address)
        out = []
        for f in sorted(slot.glob('*.json')):
            try:
                env = json.loads(f.read_text(encoding='utf-8'))
                env['_file'] = f
                out.append(env)
            except Exception:  # noqa: BLE001
                continue
        return out

    def take_replies(self) -> list[dict]:
        reps = self.replies_for_me()
        self.pull()  # answers may live on the other machine until pulled
        reps = self.replies_for_me()
        for r in reps:
            r['_file'].unlink(missing_ok=True)
        if reps:
            self._commit_push(f'relay: collected {len(reps)} answer(s)')
        return reps
