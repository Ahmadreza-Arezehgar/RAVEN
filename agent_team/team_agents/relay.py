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
from .raven_identity import (
    MAX_DELEGATION_TTL_SECONDS,
    RavenIdentity,
    ReplayCache,
    load_revocations,
    sign_delegation,
    verify_delegation,
)


class GitRelay:
    def __init__(self, memory: TeamMemory, identity: RavenIdentity,
                 trusted_peers_file=None, trusted_peers: dict | None = None,
                 revocations_file: str | None = None) -> None:
        self.memory = memory
        self.identity = identity
        self.peers_file = trusted_peers_file
        self.static_peers = trusted_peers or {}
        self.revocations_file = revocations_file or ''
        self.replay_cache = ReplayCache(
            path=self.memory.resolve_in_repo('.team/keys/replay-cache.sqlite3')
        )

    # ------------------------------------------------------------- peers --
    def peers(self) -> dict[str, str]:
        if self.peers_file:
            from .config import load_trusted_peers

            return load_trusted_peers(Path(self.peers_file))
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
        self.memory.pull_team()

    def _quarantine(self, envelope: dict, category: str, reason: str) -> None:
        """Preserve rejected transport evidence outside active inbox/outbox."""
        source = envelope.get('_file')
        if not isinstance(source, Path) or not source.exists():
            return
        dest_dir = self.memory.resolve_in_repo(f'.team/quarantine/{category}')
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / source.name
        if dest.exists():
            dest = dest_dir / f'{source.stem}-{uuid.uuid4().hex[:8]}{source.suffix}'
        source.replace(dest)
        dest.with_suffix(dest.suffix + '.reason.txt').write_text(
            str(reason)[:1000] + '\n', encoding='utf-8'
        )

    # --------------------------------------------------------------- send --
    def send_task(self, peer_address: str, text: str) -> Path:
        task_id = uuid.uuid4().hex[:12]
        block = sign_delegation(
            self.identity,
            text,
            recipient=peer_address,
            task_id=task_id,
            ttl_seconds=MAX_DELEGATION_TTL_SECONDS,
        )
        envelope = {
            'id': task_id,
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
    def _revoked(self) -> set[str]:
        if self.revocations_file:
            return load_revocations(Path(self.revocations_file))
        return set()

    def inbox_for_me(self) -> list[dict]:
        slot = self._slot('inbox', self.identity.address)
        out = []
        for f in sorted(slot.glob('*.json')):
            try:
                env = json.loads(f.read_text(encoding='utf-8'))
                env['_file'] = f
                out.append(env)
            except Exception as exc:  # noqa: BLE001
                out.append({'_file': f, '_parse_error': str(exc)})
        return out

    async def process_inbox(self, brain_run) -> int:
        """Verify + execute + answer each pending task. Returns count."""
        import inspect

        done = 0
        rejected = 0
        for env in self.inbox_for_me():
            if env.get('_parse_error'):
                reason = f'invalid JSON envelope: {env["_parse_error"]}'
                self._quarantine(env, 'tasks', reason)
                rejected += 1
                continue
            meta = env.get('raven', {})
            sender = str(env.get('from', ''))
            task_id = str(env.get('id', ''))
            # Compare the untrusted transport envelope before replay insertion.
            # Otherwise a tampered outer field could consume a valid signature
            # and prevent the intact task from being accepted later.
            if sender != str(meta.get('sender', '')):
                ok, reason = False, 'outer sender does not match signed sender'
            elif str(env.get('to', '')) != self.identity.address:
                ok, reason = False, 'outer recipient mismatch'
            elif str(env.get('kind', '')) != 'task':
                ok, reason = False, 'outer kind mismatch'
            else:
                ok, reason = verify_delegation(
                    meta, env.get('text', ''),
                    trusted_peers=self.peers(), required=True,
                    revoked=self._revoked(),
                    replay=self.replay_cache,
                    expected_recipient=self.identity.address,
                    expected_task_id=task_id,
                    expected_kind='task',
                )
            if not ok:
                self.memory.log_event(self.identity.address[:10],
                                      f'relay REJECT {env.get("id")}: {reason}')
                self._quarantine(env, 'tasks', reason)
                rejected += 1
                continue
            try:
                res = brain_run(env.get('text', ''))
                if inspect.isawaitable(res):
                    res = await res
                answer = res
            except Exception as exc:  # noqa: BLE001
                answer = f'{type(exc).__name__}: {exc}'
            reply = {
                'id': task_id,
                'kind': 'answer',
                'from': self.identity.address,
                'to': sender,
                'text': answer,
                'at': time.strftime('%Y-%m-%d %H:%M:%S'),
            }
            reply['raven'] = sign_delegation(
                self.identity,
                str(answer),
                recipient=sender,
                task_id=task_id,
                kind='answer',
                ttl_seconds=MAX_DELEGATION_TTL_SECONDS,
            )
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
        if done or rejected:
            self._commit_push(
                f'relay: {done} task(s) processed, {rejected} quarantined'
            )
        return done

    def replies_for_me(self) -> list[dict]:
        slot = self._slot('outbox', self.identity.address)
        out = []
        for f in sorted(slot.glob('*.json')):
            try:
                env = json.loads(f.read_text(encoding='utf-8'))
                env['_file'] = f
                out.append(env)
            except Exception as exc:  # noqa: BLE001
                out.append({'_file': f, '_parse_error': str(exc)})
        return out

    def take_replies(self) -> list[dict]:
        self.pull()  # answers may live on the other machine until pulled
        accepted = []
        rejected = 0
        for reply in self.replies_for_me():
            if reply.get('_parse_error'):
                reason = f'invalid JSON envelope: {reply["_parse_error"]}'
                self._quarantine(reply, 'replies', reason)
                rejected += 1
                continue
            meta = reply.get('raven', {})
            sender = str(reply.get('from', ''))
            task_id = str(reply.get('id', ''))
            if sender != str(meta.get('sender', '')):
                ok, reason = False, 'outer sender does not match signed sender'
            elif str(reply.get('to', '')) != self.identity.address:
                ok, reason = False, 'outer recipient mismatch'
            elif str(reply.get('kind', '')) != 'answer':
                ok, reason = False, 'outer kind mismatch'
            else:
                ok, reason = verify_delegation(
                    meta,
                    str(reply.get('text', '')),
                    trusted_peers=self.peers(),
                    required=True,
                    revoked=self._revoked(),
                    replay=self.replay_cache,
                    expected_recipient=self.identity.address,
                    expected_task_id=task_id,
                    expected_kind='answer',
                )
            if ok:
                reply['_file'].unlink(missing_ok=True)
                accepted.append(reply)
            else:
                self._quarantine(reply, 'replies', reason)
                rejected += 1
                self.memory.log_event(
                    self.identity.address[:10],
                    f'relay answer REJECT {task_id}: {reason}',
                )
        if accepted or rejected:
            self._commit_push(
                f'relay: collected {len(accepted)} signed answer(s), '
                f'{rejected} quarantined'
            )
        return accepted
