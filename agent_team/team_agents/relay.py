"""Git store-and-forward relay: agents keep talking even when offline.

Tasks/results are signed JSON files in the shared repo:
    .team/inbox/<peer-rvn1-address>/<ts>-<id>.json       (tasks for that peer)
    .team/outbox/<sender-rvn1-address>/<task-id>.json    (answers back)

Mirrors RAVEN's DTN philosophy: HTTP (A2A) when reachable, durable git
transport otherwise — same repo both Macs already sync.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import stat
import tempfile
import threading
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

MAX_RELAY_ENVELOPE_BYTES = 256 * 1024
MAX_RELAY_TEXT_CHARS = 64 * 1024
MAX_RELAY_TEXT_BYTES = 192 * 1024
MAX_RELAY_ANSWER_BYTES = 48 * 1024
MAX_RELAY_FILES_PER_POLL = 256
MAX_RELAY_DIRECTORY_ENTRIES = 4096
MAX_RELAY_OUTCOMES = 384
MAX_RELAY_OUTCOME_DB_BYTES = 32 * 1024 * 1024


def _atomic_write_json(
    path: Path, value: dict, *, temporary_directory: Path
) -> None:
    """Durably publish a complete shared envelope, never a partial JSON file."""
    payload = (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode('utf-8')
    if len(payload) > MAX_RELAY_ENVELOPE_BYTES:
        raise ValueError('relay envelope exceeds the compiled byte limit')
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_directory.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=str(temporary_directory), prefix=f'.{path.name}.', suffix='.tmp'
    )
    temporary = Path(temporary_name)
    try:
        if os.name != 'nt':
            os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, 'wb') as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        if os.name != 'nt':
            try:
                directory_descriptor = os.open(path.parent, os.O_RDONLY)
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


def _bounded_answer_text(value: object) -> str:
    text = str(value)
    # Slice before encoding so even an unexpectedly huge model result cannot
    # make the byte-size check allocate an equally huge temporary buffer.
    bounded = text[:MAX_RELAY_TEXT_CHARS]
    encoded = bounded.encode('utf-8', errors='replace')
    normalized = encoded.decode('utf-8')
    if len(text) <= MAX_RELAY_TEXT_CHARS and len(encoded) <= MAX_RELAY_ANSWER_BYTES:
        return normalized
    suffix = '\n[relay output truncated to its durable byte limit]'
    budget = MAX_RELAY_ANSWER_BYTES - len(suffix.encode('utf-8'))
    prefix = encoded[:budget]
    return prefix.decode('utf-8', errors='ignore') + suffix


class RelayOutcomeStore:
    """Crash-durable at-most-once task invocation and cached signed outcome."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)
        if os.name != 'nt':
            path.parent.chmod(0o700)
        try:
            with self._connect() as database:
                database.execute('PRAGMA journal_mode=DELETE')
                database.execute('PRAGMA synchronous=FULL')
                database.execute('PRAGMA secure_delete=ON')
                database.execute(
                    'CREATE TABLE IF NOT EXISTS relay_outcomes ('
                    'signature_hash TEXT PRIMARY KEY, '
                    'expires_at INTEGER NOT NULL, '
                    "state TEXT NOT NULL CHECK(state IN ('processing','completed')), "
                    'reply_json TEXT)'
                )
                page_size = int(database.execute('PRAGMA page_size').fetchone()[0])
                max_pages = max(16, MAX_RELAY_OUTCOME_DB_BYTES // page_size)
                current_pages = int(
                    database.execute('PRAGMA page_count').fetchone()[0]
                )
                if current_pages > max_pages:
                    raise RuntimeError(
                        'relay outcome database exceeds its compiled byte limit'
                    )
            if os.name != 'nt':
                path.chmod(0o600)
        except sqlite3.Error as exc:
            raise RuntimeError(f'cannot initialize relay outcome database: {exc}') from exc

    def _connect(self) -> sqlite3.Connection:
        database = sqlite3.connect(self.path, timeout=5)
        try:
            page_size = int(database.execute('PRAGMA page_size').fetchone()[0])
            max_pages = max(16, MAX_RELAY_OUTCOME_DB_BYTES // page_size)
            database.execute(f'PRAGMA max_page_count={max_pages}')
            return database
        except Exception:
            database.close()
            raise

    @staticmethod
    def signature_hash(signature: str) -> str:
        try:
            encoded = signature.encode('ascii')
        except UnicodeEncodeError as exc:
            raise ValueError('relay signature must be ASCII') from exc
        return hashlib.sha256(encoded).hexdigest()

    def claim(
        self, signature: str, expires_at: int
    ) -> tuple[str, dict | None]:
        """Return ``new``, ``interrupted``, or a cached ``completed`` reply."""
        key = self.signature_hash(signature)
        now = int(time.time())
        try:
            with self._lock, self._connect() as database:
                database.execute('BEGIN IMMEDIATE')
                database.execute(
                    'DELETE FROM relay_outcomes WHERE expires_at <= ?', (now,)
                )
                row = database.execute(
                    'SELECT state, reply_json FROM relay_outcomes '
                    'WHERE signature_hash = ?',
                    (key,),
                ).fetchone()
                if row:
                    database.commit()
                    state = str(row[0])
                    if state == 'processing':
                        return 'interrupted', None
                    try:
                        reply = json.loads(str(row[1]))
                    except (TypeError, ValueError) as exc:
                        raise RuntimeError(
                            'cached relay outcome is corrupt; refusing replay'
                        ) from exc
                    if not isinstance(reply, dict):
                        raise RuntimeError(
                            'cached relay outcome has an invalid document type'
                        )
                    return 'completed', reply
                count = int(
                    database.execute('SELECT COUNT(*) FROM relay_outcomes').fetchone()[0]
                )
                if count >= MAX_RELAY_OUTCOMES:
                    database.rollback()
                    raise RuntimeError('relay outcome database reached its entry limit')
                database.execute(
                    'INSERT INTO relay_outcomes('
                    'signature_hash, expires_at, state, reply_json) '
                    "VALUES (?, ?, 'processing', NULL)",
                    (key, int(expires_at)),
                )
            return 'new', None
        except sqlite3.Error as exc:
            raise RuntimeError(f'relay outcome database unavailable: {exc}') from exc

    def complete(self, signature: str, expires_at: int, reply: dict) -> None:
        serialized = json.dumps(reply, ensure_ascii=False, separators=(',', ':'))
        if len(serialized.encode('utf-8')) > MAX_RELAY_ENVELOPE_BYTES:
            raise ValueError('cached relay outcome exceeds the compiled byte limit')
        key = self.signature_hash(signature)
        try:
            with self._lock, self._connect() as database:
                database.execute('BEGIN IMMEDIATE')
                database.execute(
                    'DELETE FROM relay_outcomes '
                    'WHERE expires_at <= ? AND signature_hash != ?',
                    (int(time.time()), key),
                )
                cursor = database.execute(
                    'UPDATE relay_outcomes SET expires_at = ?, '
                    "state = 'completed', reply_json = ? WHERE signature_hash = ?",
                    (int(expires_at), serialized, key),
                )
                if cursor.rowcount != 1:
                    database.rollback()
                    raise RuntimeError('relay outcome claim disappeared before completion')
        except sqlite3.Error as exc:
            raise RuntimeError(f'cannot persist relay outcome: {exc}') from exc


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
        self.outcomes = RelayOutcomeStore(
            self.memory.resolve_in_repo('.team/keys/relay-outcomes.sqlite3')
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
    @staticmethod
    def _validate_peer_component(peer_addr: str) -> str:
        if not isinstance(peer_addr, str) or not re.fullmatch(
            r'rvn1[0-9a-z]{20,124}', peer_addr
        ):
            raise ValueError('relay peer must be a canonical path-safe RVN address')
        return peer_addr

    def _slot(self, kind: str, peer_addr: str) -> Path:
        if kind not in {'inbox', 'outbox'}:
            raise ValueError('invalid relay slot kind')
        peer_addr = self._validate_peer_component(peer_addr)
        p = self.memory.resolve_in_repo(f'.team/{kind}/{peer_addr}')
        p.mkdir(parents=True, exist_ok=True)
        metadata = p.lstat()
        if p.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise ValueError('relay slot must be a real directory')
        return p

    def _write_envelope(self, path: Path, value: dict) -> None:
        temporary_directory = self.memory.resolve_in_repo(
            '.team/keys/relay-tmp'
        )
        temporary_directory.mkdir(parents=True, exist_ok=True)
        metadata = os.lstat(temporary_directory)
        if temporary_directory.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise ValueError('relay temporary path must be a real directory')
        if os.name != 'nt':
            temporary_directory.chmod(0o700)
        _atomic_write_json(
            path, value, temporary_directory=temporary_directory
        )

    @staticmethod
    def _validated_envelope(
        envelope: dict, expected_kind: str
    ) -> tuple[dict, str, str, str]:
        if not isinstance(envelope, dict):
            raise ValueError('relay envelope must be a JSON object')
        metadata = envelope.get('raven')
        if not isinstance(metadata, dict):
            raise ValueError('raven metadata must be a JSON object')
        sender = envelope.get('from')
        recipient = envelope.get('to')
        task_id = envelope.get('id')
        kind = envelope.get('kind')
        text = envelope.get('text')
        if not all(isinstance(value, str) for value in (
            sender, recipient, task_id, kind, text
        )):
            raise ValueError('relay envelope fields must be strings')
        for field_name, value in (
            ('sender', sender),
            ('recipient', recipient),
            ('task id', task_id),
            ('kind', kind),
            ('text', text),
        ):
            try:
                value.encode('utf-8')
            except UnicodeEncodeError as exc:
                raise ValueError(
                    f'relay {field_name} contains invalid Unicode'
                ) from exc
        if not sender or not recipient or not task_id:
            raise ValueError('relay sender, recipient, and task id are required')
        GitRelay._validate_peer_component(sender)
        GitRelay._validate_peer_component(recipient)
        if len(task_id) > 128:
            raise ValueError('relay task id exceeds the compiled limit')
        if not task_id.isprintable():
            raise ValueError('relay task id contains control characters')
        if kind != expected_kind:
            raise ValueError(f'outer kind must be {expected_kind}')
        try:
            encoded_text = text.encode('utf-8')
        except UnicodeEncodeError as exc:
            raise ValueError('relay text contains invalid Unicode') from exc
        if len(text) > MAX_RELAY_TEXT_CHARS or len(encoded_text) > MAX_RELAY_TEXT_BYTES:
            raise ValueError('relay text exceeds the compiled character limit')
        signature = metadata.get('signature')
        if not isinstance(signature, str) or not signature:
            raise ValueError('relay signature must be a non-empty string')
        RelayOutcomeStore.signature_hash(signature)
        return metadata, sender, task_id, text

    @staticmethod
    def _reply_filename(task_id: str) -> str:
        # Never use a peer-controlled task id as a path component. This also
        # avoids Windows reserved device names such as CON and NUL.
        return hashlib.sha256(task_id.encode('utf-8')).hexdigest() + '.json'

    def _reply_path(self, sender: str, task_id: str) -> Path:
        return self._slot('outbox', sender) / self._reply_filename(task_id)

    def _build_reply(self, task_id: str, sender: str, answer: str) -> dict:
        answer = _bounded_answer_text(answer)
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
            answer,
            recipient=sender,
            task_id=task_id,
            kind='answer',
            ttl_seconds=MAX_DELEGATION_TTL_SECONDS,
        )
        return reply

    def _read_slot(self, kind: str, peer_addr: str) -> list[dict]:
        slot = self._slot(kind, peer_addr)
        out: list[dict] = []
        try:
            entries = []
            with os.scandir(slot) as scanner:
                for entry in scanner:
                    if len(entries) >= MAX_RELAY_DIRECTORY_ENTRIES:
                        raise RuntimeError(
                            'relay slot exceeds its compiled directory-entry limit'
                        )
                    entries.append(entry)
            entries.sort(key=lambda entry: entry.name)
        except OSError as exc:
            raise RuntimeError(f'cannot scan relay slot: {exc}') from exc
        candidates = [
            entry for entry in entries if entry.name.endswith('.json')
        ][:MAX_RELAY_FILES_PER_POLL]
        for entry in candidates:
            path = Path(entry.path)
            try:
                metadata = entry.stat(follow_symlinks=False)
                if entry.is_symlink() or not stat.S_ISREG(metadata.st_mode):
                    raise ValueError('relay entry must be a regular file')
                if metadata.st_nlink != 1:
                    raise ValueError('relay entry must not have multiple hard links')
                if metadata.st_size > MAX_RELAY_ENVELOPE_BYTES:
                    raise ValueError('relay envelope exceeds the compiled byte limit')
                flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0)
                flags |= getattr(os, 'O_NOFOLLOW', 0)
                descriptor = os.open(path, flags)
                try:
                    opened = os.fstat(descriptor)
                    if (
                        not stat.S_ISREG(opened.st_mode)
                        or opened.st_nlink != 1
                        or (opened.st_dev, opened.st_ino)
                        != (metadata.st_dev, metadata.st_ino)
                    ):
                        raise ValueError('relay entry changed while being opened')
                    chunks = []
                    remaining = MAX_RELAY_ENVELOPE_BYTES + 1
                    while remaining > 0:
                        chunk = os.read(descriptor, min(65_536, remaining))
                        if not chunk:
                            break
                        chunks.append(chunk)
                        remaining -= len(chunk)
                    raw = b''.join(chunks)
                finally:
                    os.close(descriptor)
                if len(raw) > MAX_RELAY_ENVELOPE_BYTES:
                    raise ValueError('relay envelope changed beyond the byte limit')
                envelope = json.loads(raw.decode('utf-8'))
                if not isinstance(envelope, dict):
                    raise ValueError('relay envelope must be a JSON object')
                envelope['_file'] = path
                out.append(envelope)
            except Exception as exc:  # noqa: BLE001
                out.append({'_file': path, '_parse_error': str(exc)})
        return out

    def _commit_push(self, msg: str) -> bool:
        self.memory.require_shared_upstream()
        out = self.memory.commit_push(msg)
        return 'nothing to commit' not in out

    def pull(self) -> None:
        self.memory.require_shared_upstream()
        self.memory.pull_team()

    def _quarantine(self, envelope: dict, category: str, reason: str) -> None:
        """Preserve rejected transport evidence outside active inbox/outbox."""
        source = envelope.get('_file')
        if not isinstance(source, Path):
            return
        try:
            source_metadata = source.lstat()
        except FileNotFoundError:
            return
        dest_dir = self.memory.resolve_in_repo(f'.team/quarantine/{category}')
        dest_dir.mkdir(parents=True, exist_ok=True)
        directory_metadata = dest_dir.lstat()
        if dest_dir.is_symlink() or not stat.S_ISDIR(directory_metadata.st_mode):
            raise ValueError('relay quarantine path must be a real directory')
        # Never move a symlink, device, socket, or multiply-linked file into
        # shared Git state. Remove the active poison entry and record only safe
        # JSON evidence with a content-independent filename.
        oversized = (
            stat.S_ISREG(source_metadata.st_mode)
            and source_metadata.st_size > MAX_RELAY_ENVELOPE_BYTES
        )
        if (
            source.is_symlink()
            or not stat.S_ISREG(source_metadata.st_mode)
            or source_metadata.st_nlink != 1
            or oversized
        ):
            moved_to_private_quarantine = False
            if stat.S_ISDIR(source_metadata.st_mode) and not source.is_symlink():
                private_rejected = self.memory.resolve_in_repo(
                    '.team/keys/relay-rejected'
                )
                private_rejected.mkdir(parents=True, exist_ok=True)
                private_metadata = private_rejected.lstat()
                if (
                    private_rejected.is_symlink()
                    or not stat.S_ISDIR(private_metadata.st_mode)
                ):
                    raise ValueError(
                        'private relay rejection path must be a real directory'
                    )
                if os.name != 'nt':
                    private_rejected.chmod(0o700)
                private_dest = private_rejected / (
                    hashlib.sha256(os.fsencode(source.name)).hexdigest()
                    + '-'
                    + uuid.uuid4().hex
                )
                source.replace(private_dest)
                moved_to_private_quarantine = True
            else:
                source.unlink(missing_ok=True)
            safe_source_name = source.name.encode(
                'utf-8', errors='replace'
            ).decode('utf-8')[:255]
            safe_reason = str(reason).encode(
                'utf-8', errors='replace'
            ).decode('utf-8')[:1000]
            evidence_name = (
                'unsafe-'
                + hashlib.sha256(os.fsencode(source.name)).hexdigest()
                + '.reason.json'
            )
            self._write_envelope(
                dest_dir / evidence_name,
                {
                    'source_name': safe_source_name,
                    'reason': safe_reason,
                    'unsafe_file_type': not stat.S_ISREG(source_metadata.st_mode),
                    'oversized': oversized,
                    'observed_bytes': int(source_metadata.st_size),
                    'moved_to_private_quarantine': moved_to_private_quarantine,
                },
            )
            return
        dest = dest_dir / source.name
        if dest.exists():
            dest = dest_dir / f'{source.stem}-{uuid.uuid4().hex[:8]}{source.suffix}'
        source.replace(dest)
        moved_metadata = dest.lstat()
        if (
            dest.is_symlink()
            or not stat.S_ISREG(moved_metadata.st_mode)
            or moved_metadata.st_nlink != 1
        ):
            dest.unlink(missing_ok=True)
            raise ValueError('relay entry changed type while being quarantined')
        self._write_envelope(
            dest.with_suffix(dest.suffix + '.reason.json'),
            {
                'reason': str(reason).encode(
                    'utf-8', errors='replace'
                ).decode('utf-8')[:1000]
            },
        )

    # --------------------------------------------------------------- send --
    def send_task(self, peer_address: str, text: str) -> Path:
        # A local commit is not a transport. Verify a concrete tracking remote
        # before creating a file that the CLI might otherwise call "queued".
        self._validate_peer_component(peer_address)
        self._commit_push('relay: recover pending durable state')
        if (
            not isinstance(text, str)
            or len(text) > MAX_RELAY_TEXT_CHARS
            or len(text.encode('utf-8')) > MAX_RELAY_TEXT_BYTES
        ):
            raise ValueError('relay task text must be bounded text')
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
        self._write_envelope(f, envelope)
        self.memory.log_event(self.identity.address[:10],
                              f'relay→ {peer_address[:14]}… : {text[:60]}')
        self._commit_push(f'relay(task): {envelope["id"]} → {peer_address[:14]}…')
        return f

    # -------------------------------------------------------------- drain --
    def _revoked(self) -> set[str]:
        if self.revocations_file:
            return load_revocations(Path(self.revocations_file))
        return set()

    def inbox_for_me(self) -> list[dict]:
        return self._read_slot('inbox', self.identity.address)

    async def process_inbox(self, brain_run) -> int:
        """Verify + execute + answer each pending task. Returns count."""
        import inspect
        from .memory import exclusive_file_lock

        worker_lock = self.memory.resolve_in_repo(
            '.team/keys/relay-task-worker.lock'
        )
        with exclusive_file_lock(worker_lock, timeout=1.0):
            # A previous run may have durably written its reply/deletion and
            # then lost the network during push. Flush that state even when the
            # active inbox is now empty.
            self._commit_push('relay: recover pending durable state')
            done = 0
            rejected = 0
            for env in self.inbox_for_me():
                if env.get('_parse_error'):
                    reason = f'invalid JSON envelope: {env["_parse_error"]}'
                    self._quarantine(env, 'tasks', reason)
                    rejected += 1
                    continue
                try:
                    meta, sender, task_id, task_text = self._validated_envelope(
                        env, 'task'
                    )
                except ValueError as exc:
                    reason = f'invalid task envelope: {exc}'
                    self._quarantine(env, 'tasks', reason)
                    rejected += 1
                    continue
                # Compare untrusted transport fields before signature work.
                if sender != str(meta.get('sender', '')):
                    ok, reason = False, 'outer sender does not match signed sender'
                elif env['to'] != self.identity.address:
                    ok, reason = False, 'outer recipient mismatch'
                else:
                    ok, reason = verify_delegation(
                        meta,
                        task_text,
                        trusted_peers=self.peers(),
                        required=True,
                        revoked=self._revoked(),
                        replay=self.replay_cache,
                        expected_recipient=self.identity.address,
                        expected_task_id=task_id,
                        expected_kind='task',
                        consume_replay=False,
                    )
                if not ok:
                    self.memory.log_event(
                        self.identity.address[:10],
                        f'relay REJECT {task_id}: {reason}',
                    )
                    self._quarantine(env, 'tasks', reason)
                    rejected += 1
                    continue

                signature = meta['signature']
                outcome_state, reply = self.outcomes.claim(
                    signature, int(meta['expires_at'])
                )
                if outcome_state == 'interrupted':
                    answer = (
                        'relay execution was interrupted before a durable answer; '
                        'it was not automatically retried to avoid duplicate side effects'
                    )
                    reply = self._build_reply(task_id, sender, answer)
                    self.outcomes.complete(
                        signature, int(meta['expires_at']), reply
                    )
                elif outcome_state == 'new':
                    try:
                        result = brain_run(task_text)
                        if inspect.isawaitable(result):
                            result = await result
                        answer = str(result)
                    except Exception as exc:  # noqa: BLE001
                        answer = f'{type(exc).__name__}: {exc}'
                    reply = self._build_reply(task_id, sender, answer)
                    # Persist the signed outcome before deleting the task. A
                    # restart can re-materialize it without rerunning the brain.
                    self.outcomes.complete(
                        signature, int(meta['expires_at']), reply
                    )
                if not isinstance(reply, dict):
                    raise RuntimeError('relay outcome did not contain a reply')
                self._write_envelope(self._reply_path(sender, task_id), reply)
                env['_file'].unlink(missing_ok=True)
                done += 1
                self.memory.log_event(
                    self.identity.address[:10],
                    f'relay✓ {task_id} from {sender[:14]}…',
                )
                try:
                    from .chat import TeamChat

                    TeamChat(TeamMemory(
                        self.memory.repo_path, auto_commit=False
                    )).post(
                        self.identity.address[:12],
                        f'✅ {task_id}: {str(reply.get("text", ""))[:110]}',
                    )
                except Exception:  # noqa: BLE001
                    pass
            if done or rejected:
                self._commit_push(
                    f'relay: {done} task(s) processed, {rejected} quarantined'
                )
            return done

    def replies_for_me(self) -> list[dict]:
        return self._read_slot('outbox', self.identity.address)

    def take_replies(self) -> list[dict]:
        """Return verified replies without deleting them (at-least-once delivery)."""
        # This also pulls remote state and flushes an earlier acknowledged
        # deletion whose push failed. Replies remain present until ack_replies
        # is called *after* the CLI has displayed them.
        self._commit_push('relay: recover pending durable state')
        accepted = []
        rejected = 0
        acknowledged = 0
        for reply in self.replies_for_me():
            if reply.get('_parse_error'):
                reason = f'invalid JSON envelope: {reply["_parse_error"]}'
                self._quarantine(reply, 'replies', reason)
                rejected += 1
                continue
            try:
                meta, sender, task_id, reply_text = self._validated_envelope(
                    reply, 'answer'
                )
            except ValueError as exc:
                reason = f'invalid answer envelope: {exc}'
                self._quarantine(reply, 'replies', reason)
                rejected += 1
                continue
            if sender != str(meta.get('sender', '')):
                ok, reason = False, 'outer sender does not match signed sender'
            elif reply['to'] != self.identity.address:
                ok, reason = False, 'outer recipient mismatch'
            else:
                ok, reason = verify_delegation(
                    meta,
                    reply_text,
                    trusted_peers=self.peers(),
                    required=True,
                    revoked=self._revoked(),
                    replay=self.replay_cache,
                    expected_recipient=self.identity.address,
                    expected_task_id=task_id,
                    expected_kind='answer',
                    consume_replay=False,
                )
            if ok:
                signature = meta['signature']
                if self.replay_cache.seen(signature):
                    # This reply was displayed and acknowledged earlier; a
                    # stale/replayed Git copy can be removed without repeating it.
                    reply['_file'].unlink(missing_ok=True)
                    acknowledged += 1
                else:
                    reply['_verified_reply'] = True
                    accepted.append(reply)
            else:
                self._quarantine(reply, 'replies', reason)
                rejected += 1
                self.memory.log_event(
                    self.identity.address[:10],
                    f'relay answer REJECT {task_id}: {reason}',
                )
        if rejected or acknowledged:
            self._commit_push(
                f'relay: removed {acknowledged} acknowledged answer(s), '
                f'{rejected} quarantined'
            )
        return accepted

    def ack_replies(self, replies: list[dict]) -> None:
        """Acknowledge replies only after their caller has durably presented them."""
        acknowledged = 0
        for reply in replies:
            if not isinstance(reply, dict) or reply.get('_verified_reply') is not True:
                raise ValueError('cannot acknowledge an unverified relay reply')
            metadata = reply.get('raven')
            source = reply.get('_file')
            if not isinstance(metadata, dict) or not isinstance(source, Path):
                raise ValueError('verified relay reply lost its source metadata')
            signature = metadata.get('signature')
            expires_at = metadata.get('expires_at')
            if not isinstance(signature, str) or not isinstance(expires_at, int):
                raise ValueError('verified relay reply has invalid replay metadata')
            if not self.replay_cache.first_time(signature, expires_at=expires_at):
                if not self.replay_cache.seen(signature):
                    raise RuntimeError('relay reply acknowledgement cache is unavailable')
            source.unlink(missing_ok=True)
            acknowledged += 1
        if acknowledged:
            # If this push fails, the signature is already recorded and the
            # next poll safely finishes deleting any stale remote copy. The
            # caller has already displayed the answer, so this is at-least-once.
            self._commit_push(
                f'relay: acknowledge {acknowledged} displayed signed answer(s)'
            )
