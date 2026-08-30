"""EXPERIMENTAL PLAINTEXT RDAP carrier over the Raven mailbox harness.

Transport tiers served here:
  T3  libp2p mailbox PUT  — task lands in the *recipient's* store; they drain
                            it whenever they come online (no git, no internet
                            reachability beyond the libp2p path).

This adapter is deliberately disabled unless the operator opts in.  Its task
JSON is signed but not encrypted; using an RVN1 field named
``message_ciphertext`` does not make the JSON confidential.

Wire formats are byte-exact with RAVEN:
  envelope : raven_protocol.envelope.Envelope/pack  (RVN1, opaque body)
  store    : RSO1 wrapper used by raven-swarm-mailbox-experimental
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import shutil
import struct
import subprocess
import time
import uuid
from pathlib import Path

BIN_NAME = 'raven-swarm-mailbox-experimental'
MAX_MAILBOX_PAGES = 64
MAX_MAILBOX_OBJECTS = 64
MAX_MAILBOX_TOTAL_BYTES = 64 * 1024 * 1024
# raven-swarm: MAX_ENVELOPE_LEN + the 59-byte RSO1 prefix + 64-byte custody sig.
MAX_MAILBOX_OBJECT_BYTES = 1_048_576 + 59 + 64
CANDIDATE_DIRS = (
    Path(os.environ.get('RDAP_HOME', str(Path.home() / 'rdap'))) / 'bin',
    Path(__file__).resolve().parents[2] / 'node' / 'target' / 'debug',
)


def find_swarm_bin() -> Path | None:
    env = os.environ.get('RDAP_SWARM_BIN')
    if env and Path(env).exists():
        return Path(env)
    for d in CANDIDATE_DIRS:
        p = d / BIN_NAME
        if p.exists():
            return p
    return None


def _rdap_base() -> Path:
    return Path(os.environ.get('RDAP_HOME', str(Path.home() / 'rdap')))


def _node_sources() -> Path:
    """Locate (or clone) the RAVEN node sources containing raven-swarm."""
    local = Path(__file__).resolve().parents[2] / 'node'
    if (local / 'Cargo.toml').exists():
        return local
    base = _rdap_base()
    dst = base / 'raven-src'
    if not (dst / 'node' / 'Cargo.toml').exists():
        print('* cloning RAVEN sources (shallow)…')
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ['git', 'clone', '--depth', '1',
             'https://github.com/Ahmadreza-Arezehgar/RAVEN.git', str(dst)],
            check=True,
        )
    return dst / 'node'


def build_swarm_bin(node_dir: Path | None = None) -> Path:
    node_dir = Path(node_dir) if node_dir else _node_sources()
    subprocess.run(
        ['cargo', 'build', '-q', '-p', 'raven-swarm',
         '--features', 'experimental-offline-mailbox',
         '--bin', BIN_NAME],
        cwd=node_dir, check=True,
    )
    built = node_dir / 'target' / 'debug' / BIN_NAME
    if not built.exists():
        raise RuntimeError('cargo reported success but binary is missing')
    # stage where find_swarm_bin() looks for it
    bin_dir = _rdap_base() / 'bin'
    bin_dir.mkdir(parents=True, exist_ok=True)
    dest = bin_dir / BIN_NAME
    shutil.copy2(built, dest)
    return dest


# ------------------------------------------------------------- wire bits --
def store_tag(peer_address: str) -> bytes:
    return hashlib.sha256(b'rdap-task:' + peer_address.encode()).digest()[:16]


def envelope_for(body: bytes, peer_address: str, ttl_hours: float = 24) -> bytes:
    """RVN1 envelope whose ciphertext field carries *plaintext* signed JSON."""
    from raven_protocol.envelope import Envelope, pack

    now = int(time.time() * 1000)
    env = Envelope(
        env_type=4,                      # 4 = application/opaque in reference
        flags=2,
        message_id=uuid.uuid4().bytes,
        routing_tag=store_tag(peer_address),
        dest_device_hint=0,
        created_at=now,
        expires_at=now + int(ttl_hours * 3600 * 1000),
        hop_limit=4,
        replication_budget=2,
        anti_replay_nonce=secrets.token_bytes(12),
        ratchet_header_ciphertext=b'',
        message_ciphertext=body,
        sender_authentication=b'\x00' * 64,   # E2E auth lives INSIDE body sig
    )
    return pack(env)


def wrap_rso1(envelope: bytes, peer_address: str, message_id: bytes) -> bytes:
    """RSO1 wrapper — message_id MUST match the inner RVN1 envelope's."""
    tag = store_tag(peer_address)
    created = int(time.time() * 1000)
    expires = created + 24 * 3600 * 1000
    return b''.join([
        b'RSO1', b'\x01', tag, message_id,
        struct.pack('>Q', created), struct.pack('>Q', expires),
        struct.pack('>H', 0), struct.pack('>I', len(envelope)), envelope,
    ])


def make_task_object(body: bytes, peer_address: str) -> str:
    """One-shot: signed task JSON → hex StoreObject ready for mailbox PUT."""
    from raven_protocol.envelope import Envelope, pack

    now = int(time.time() * 1000)
    msg_id = uuid.uuid4().bytes
    env = pack(Envelope(
        env_type=4, flags=2,
        message_id=msg_id,
        routing_tag=store_tag(peer_address),
        dest_device_hint=0,
        created_at=now,
        expires_at=now + 24 * 3600 * 1000,
        hop_limit=4,
        replication_budget=2,
        anti_replay_nonce=secrets.token_bytes(12),
        ratchet_header_ciphertext=b'',
        message_ciphertext=body,
        sender_authentication=b'\x00' * 64,
    ))
    return wrap_rso1(env, peer_address, msg_id).hex()


def unwrap_body(object_bytes: bytes) -> tuple[str, str]:
    """Return (task_id, json_text) from an RSO1 object."""
    if object_bytes[:4] != b'RSO1':
        raise ValueError('not an RSO1 object')
    u32 = struct.calcsize('>I')
    off = 4 + 1 + 16 + 16 + 8 + 8 + 2
    (env_len,) = struct.unpack_from('>I', object_bytes, off)
    env = object_bytes[off + u32: off + u32 + env_len]
    from raven_protocol.envelope import unpack

    decoded = unpack(env)
    if decoded is None:
        raise ValueError('bad RVN1 envelope in store object')
    payload = json.loads(decoded.message_ciphertext.decode('utf-8'))
    return str(payload.get('id', '')), json.dumps(payload, ensure_ascii=False)


# ------------------------------------------------------------ CLI driver --
def _run(bin_path: Path, args: list[str], data_dir: Path) -> str:
    cmd = [str(bin_path), '--allow-experimental-mailbox', *args,
           '--data-dir', str(data_dir)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(f'mesh {" ".join(args[:1])} failed: '
                           f'{r.stderr.strip() or r.stdout.strip()}')
    return r.stdout


def serve_store(bin_path: Path, data_dir: Path,
                advertise_ip: str = '') -> dict:
    """Start a persistent mailbox store reachable from other machines."""
    import socket

    addr_file = data_dir / 'mailbox.multiaddr'
    peer_file = data_dir / 'mailbox.peer-id'
    # NOTE: log must live OUTSIDE the data dir — a stray file inside makes
    # the store's continuity check treat the profile as corrupted
    log_file = data_dir.parent / 'mesh-store.log'

    def _spawn() -> subprocess.Popen:
        data_dir.mkdir(parents=True, exist_ok=True)
        # stale files would make _wait() return instantly with OLD addresses
        for f in (addr_file, peer_file):
            f.unlink(missing_ok=True)
        log_fh = open(log_file, 'ab')
        return subprocess.Popen(
            [str(bin_path), '--allow-experimental-mailbox', 'serve',
             '--data-dir', str(data_dir), '--listen', '/ip4/0.0.0.0/tcp/0',
             '--write-multiaddr', str(addr_file),
             '--write-peer-id', str(peer_file)],
            stdout=log_fh, stderr=log_fh,
        )

    def _wait(p: subprocess.Popen) -> None:
        for _ in range(200):
            if addr_file.exists() and peer_file.exists():
                return
            if p.poll() is not None:
                raise RuntimeError('mailbox store exited immediately')
            time.sleep(0.05)
        p.kill()
        raise RuntimeError('mailbox store did not publish its address')

    proc = _spawn()
    try:
        _wait(proc)
    except RuntimeError:
        if proc.poll() is None:
            proc.kill()
        # Mailbox rows may be the only copy of an offline task.  A generic
        # startup failure must never turn into an implicit state reset.
        raise RuntimeError(
            f'mailbox startup failed; state preserved at {data_dir}; '
            f'inspect {log_file}'
        ) from None

    ma = addr_file.read_text().strip()
    # store binds wildcard but may report 127.0.0.1/0.0.0.0 — publish the
    # LAN-dialable address instead
    parts = ma.split('/p2p/', 1)
    head, peer_part = parts[0], ('/p2p/' + parts[1] if len(parts) == 2 else '')
    pm = head.split('/')
    if len(pm) >= 5 and pm[2] in ('127.0.0.1', '0.0.0.0'):
        ip = advertise_ip
        if not ip:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                s.connect(('8.8.8.8', 80))
                ip = s.getsockname()[0]
            finally:
                s.close()
        pm[2] = ip
        ma = '/'.join(pm) + peer_part
    return {
        'proc': proc,
        'multiaddr': ma,
        'peer_id': peer_file.read_text().strip(),
    }


def mailbox_put(bin_path: Path, client_dir: Path, store_multiaddr: str,
                store_peer_id: str, object_hex: str) -> None:
    client_dir.mkdir(parents=True, exist_ok=True)
    out = _run(bin_path, ['put', '--peer', store_multiaddr,
                          '--peer-id', store_peer_id,
                          '--object-hex', object_hex], client_dir)
    if 'stored=1' not in out:
        raise RuntimeError(f'unexpected put output: {out!r}')


def mailbox_get_all(bin_path: Path, client_dir: Path, store_multiaddr: str,
                    store_peer_id: str, tag_hex: str) -> list[bytes]:
    client_dir.mkdir(parents=True, exist_ok=True)
    objects: list[bytes] = []
    total_bytes = 0
    after = ''
    seen_cursors: set[str] = set()
    for _page in range(MAX_MAILBOX_PAGES):
        args = [
            'get', '--peer', store_multiaddr,
            '--peer-id', store_peer_id,
            '--store-tag-hex', tag_hex,
        ]
        if after:
            args.extend(['--after-hex', after])
        out = _run(bin_path, args, client_dir)
        next_cursor = None
        for line in out.splitlines():
            if line.startswith('object_hex='):
                encoded = line.split('=', 1)[1].strip()
                if (
                    len(encoded) % 2
                    or len(encoded) > MAX_MAILBOX_OBJECT_BYTES * 2
                ):
                    raise RuntimeError('mailbox object exceeds the wire byte limit')
                try:
                    decoded = bytes.fromhex(encoded)
                except ValueError as exc:
                    raise RuntimeError('mailbox returned a non-hex object') from exc
                if len(objects) >= MAX_MAILBOX_OBJECTS:
                    raise RuntimeError('mailbox object count exceeds the store limit')
                if len(decoded) > MAX_MAILBOX_TOTAL_BYTES - total_bytes:
                    raise RuntimeError('mailbox objects exceed the store byte limit')
                objects.append(decoded)
                total_bytes += len(decoded)
            elif line.startswith('next_cursor='):
                next_cursor = line.split('=', 1)[1].strip()
        if next_cursor is None:
            raise RuntimeError('mailbox page omitted its continuation cursor')
        if next_cursor == 'end':
            return objects
        if len(next_cursor) != 64:
            raise RuntimeError(f'invalid mailbox cursor: {next_cursor!r}')
        try:
            bytes.fromhex(next_cursor)
        except ValueError as exc:
            raise RuntimeError('mailbox returned a non-hex cursor') from exc
        if next_cursor in seen_cursors:
            raise RuntimeError('mailbox cursor cycle detected')
        seen_cursors.add(next_cursor)
        after = next_cursor
    raise RuntimeError('mailbox pagination exceeded the compiled page limit')
