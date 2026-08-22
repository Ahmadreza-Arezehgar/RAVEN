"""RDAP mesh carrier — rides the real Raven swarm offline mailbox.

Transport tiers served here:
  T3  libp2p mailbox PUT  — task lands in the *recipient's* store; they drain
                            it whenever they come online (no git, no internet
                            reachability beyond the libp2p path).

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
    """RVN1 envelope whose opaque ciphertext carries our signed task JSON."""
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


def serve_store(bin_path: Path, data_dir: Path) -> dict:
    """Start a persistent mailbox store. Returns handle with proc/addr/peer."""
    data_dir.mkdir(parents=True, exist_ok=True)
    addr_file = data_dir / 'mailbox.multiaddr'
    peer_file = data_dir / 'mailbox.peer-id'
    proc = subprocess.Popen(
        [str(bin_path), '--allow-experimental-mailbox', 'serve',
         '--data-dir', str(data_dir), '--listen', '/ip4/127.0.0.1/tcp/0',
         '--write-multiaddr', str(addr_file), '--write-peer-id', str(peer_file)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for _ in range(200):
        if addr_file.exists() and peer_file.exists():
            return {
                'proc': proc,
                'multiaddr': addr_file.read_text().strip(),
                'peer_id': peer_file.read_text().strip(),
            }
        if proc.poll() is not None:
            raise RuntimeError('mailbox store exited immediately')
        time.sleep(0.05)
    proc.kill()
    raise RuntimeError('mailbox store did not publish its address')


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
    out = _run(bin_path, ['get', '--peer', store_multiaddr,
                          '--peer-id', store_peer_id,
                          '--store-tag-hex', tag_hex], client_dir)
    objs = []
    for line in out.splitlines():
        if line.startswith('object_hex='):
            objs.append(bytes.fromhex(line.split('=', 1)[1].strip()))
    return objs
