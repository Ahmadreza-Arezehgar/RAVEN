"""Node configuration: identity, network, LLM backend and trust policy."""

from __future__ import annotations

import json
import math
import os
import stat
from dataclasses import dataclass, field
from pathlib import Path


DEFAULT_TASK_STORE_MAX_COUNT = 256
DEFAULT_TASK_STORE_MAX_BYTES = 8 * 1024 * 1024
DEFAULT_TASK_STORE_TTL_SECONDS = 60 * 60
HARD_TASK_STORE_MAX_COUNT = 4096
HARD_TASK_STORE_MAX_BYTES = 64 * 1024 * 1024
HARD_TASK_STORE_TTL_SECONDS = 24 * 60 * 60


def read_secret_file(path: str | Path) -> str:
    """Read a regular, non-symlink secret file with strict POSIX mode."""
    secret_path = Path(path)
    if secret_path.is_symlink():
        raise ValueError(f'secret path must not be a symlink: {secret_path}')
    flags = os.O_RDONLY
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    fd = os.open(secret_path, flags)
    with os.fdopen(fd, 'r', encoding='utf-8') as handle:
        metadata = os.fstat(handle.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f'secret path must be a regular file: {secret_path}')
        if os.name != 'nt' and metadata.st_mode & 0o077:
            raise PermissionError(f'secret file permissions must be 0600: {secret_path}')
        value = handle.read().strip()
    if not value:
        raise ValueError(f'secret file is empty: {secret_path}')
    return value


@dataclass
class LLMConfig:
    """Backend for the agent brain.

    provider='openai' → any OpenAI-compatible /chat/completions endpoint.
    anything else     → deterministic EchoBrain (no key needed).
    """

    provider: str = 'echo'
    model: str = ''
    base_url: str = 'https://api.openai.com/v1'
    temperature: float = 0.2
    max_steps: int = 12
    _api_key: str = ''

    def api_key(self) -> str:
        return self._api_key or os.environ.get('OPENAI_API_KEY', '') or os.environ.get(
            'LLM_API_KEY', ''
        )


@dataclass
class Skill:
    id: str
    name: str
    description: str = ''
    tags: tuple[str, ...] = ()

    def as_card(self) -> dict:
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'tags': list(self.tags),
        }


@dataclass
class NodeConfig:
    """Everything one A2A agent node needs to run."""

    # identity
    name: str = 'node-1'
    role: str = ''

    # network
    host: str = '127.0.0.1'          # bind address
    advertised_host: str = ''        # ip/url shown to peers (defaults to host)
    port: int = 8081
    public_url: str = ''
    max_rpc_body_bytes: int = 256 * 1024
    max_concurrent_rpc: int = 16
    rpc_body_timeout_seconds: float = 15.0
    rpc_queue_timeout_seconds: float = 0.25
    task_store_max_count: int = DEFAULT_TASK_STORE_MAX_COUNT
    task_store_max_bytes: int = DEFAULT_TASK_STORE_MAX_BYTES
    task_store_ttl_seconds: float = DEFAULT_TASK_STORE_TTL_SECONDS

    # shared team repo (git-backed memory)
    repo_path: Path = field(default_factory=lambda: Path('.'))
    auto_commit_memory: bool = True

    # transport auth (optional bearer token on top of raven signatures)
    auth_token: str = ''

    # capabilities
    allow_shell: bool = False
    skills: list[Skill] = field(default_factory=list)

    # brain
    llm: LLMConfig = field(default_factory=LLMConfig)

    # raven protocol trust policy: rvn1 address -> ed25519 pubkey hex
    trusted_peers: dict[str, str] = field(default_factory=dict)
    trusted_peers_file: str = ''     # live-reloaded each request when set
    require_signed_tasks: bool = True
    revocations_file: str = ''       # JSON list of revoked rvn1 addresses
    enable_experimental_mailbox: bool = False

    def __post_init__(self) -> None:
        if (
            isinstance(self.task_store_max_count, bool)
            or not isinstance(self.task_store_max_count, int)
            or not 0 < self.task_store_max_count <= HARD_TASK_STORE_MAX_COUNT
        ):
            raise ValueError(
                f'task_store_max_count must be 1..{HARD_TASK_STORE_MAX_COUNT}'
            )
        if (
            isinstance(self.task_store_max_bytes, bool)
            or not isinstance(self.task_store_max_bytes, int)
            or not 0 < self.task_store_max_bytes <= HARD_TASK_STORE_MAX_BYTES
        ):
            raise ValueError(
                f'task_store_max_bytes must be 1..{HARD_TASK_STORE_MAX_BYTES}'
            )
        if (
            isinstance(self.task_store_ttl_seconds, bool)
            or not isinstance(self.task_store_ttl_seconds, (int, float))
            or not math.isfinite(self.task_store_ttl_seconds)
            or not 1 <= self.task_store_ttl_seconds <= HARD_TASK_STORE_TTL_SECONDS
        ):
            raise ValueError(
                f'task_store_ttl_seconds must be finite and 1..'
                f'{HARD_TASK_STORE_TTL_SECONDS}'
            )

    def resolved_public_url(self) -> str:
        if self.public_url:
            return self.public_url.rstrip('/')
        shown = self.advertised_host or self.host
        return f'http://{shown}:{self.port}'

    @property
    def keys_dir(self) -> Path:
        return Path(self.repo_path).resolve() / '.team' / 'keys'

    @property
    def replay_cache_path(self) -> Path:
        return self.keys_dir / 'replay-cache.sqlite3'

    # ------------------------------------------------------------- loaders --
    @classmethod
    def from_env(cls) -> 'NodeConfig':
        auth_token = os.environ.get('TEAM_AUTH_TOKEN', '')
        token_file = os.environ.get('TEAM_AUTH_TOKEN_FILE', '')
        if not auth_token and token_file:
            auth_token = read_secret_file(token_file)
        cfg = cls(
            name=os.environ.get('TEAM_NODE_NAME', cls.name),
            role=os.environ.get('TEAM_NODE_ROLE', ''),
            host=os.environ.get('TEAM_HOST', cls.host),
            port=int(os.environ.get('TEAM_PORT', str(cls.port))),
            public_url=os.environ.get('TEAM_PUBLIC_URL', ''),
            max_rpc_body_bytes=int(
                os.environ.get('TEAM_MAX_RPC_BODY_BYTES', str(cls.max_rpc_body_bytes))
            ),
            max_concurrent_rpc=int(
                os.environ.get('TEAM_MAX_CONCURRENT_RPC', str(cls.max_concurrent_rpc))
            ),
            rpc_body_timeout_seconds=float(
                os.environ.get(
                    'TEAM_RPC_BODY_TIMEOUT_SECONDS',
                    str(cls.rpc_body_timeout_seconds),
                )
            ),
            rpc_queue_timeout_seconds=float(
                os.environ.get(
                    'TEAM_RPC_QUEUE_TIMEOUT_SECONDS',
                    str(cls.rpc_queue_timeout_seconds),
                )
            ),
            task_store_max_count=int(
                os.environ.get(
                    'TEAM_TASK_STORE_MAX_COUNT',
                    str(cls.task_store_max_count),
                )
            ),
            task_store_max_bytes=int(
                os.environ.get(
                    'TEAM_TASK_STORE_MAX_BYTES',
                    str(cls.task_store_max_bytes),
                )
            ),
            task_store_ttl_seconds=float(
                os.environ.get(
                    'TEAM_TASK_STORE_TTL_SECONDS',
                    str(cls.task_store_ttl_seconds),
                )
            ),
            repo_path=Path(os.environ.get('TEAM_REPO', '.')),
            auth_token=auth_token,
            allow_shell=os.environ.get('TEAM_ALLOW_SHELL', '') == '1',
            auto_commit_memory=os.environ.get('TEAM_AUTO_COMMIT', '1') == '1',
            llm=LLMConfig(
                provider=os.environ.get('TEAM_LLM_PROVIDER', 'echo'),
                model=os.environ.get('TEAM_LLM_MODEL', ''),
                base_url=os.environ.get(
                    'TEAM_LLM_BASE_URL', LLMConfig.base_url
                ),
            ),
            # Secure by default.  TEAM_REQUIRE_SIGNED=0 is an explicit open-mode
            # override retained for scripted deployments.
            require_signed_tasks=os.environ.get('TEAM_REQUIRE_SIGNED', '1') != '0',
            enable_experimental_mailbox=(
                os.environ.get('RDAP_ENABLE_EXPERIMENTAL_PLAINTEXT_MAILBOX', '') == '1'
            ),
        )
        peers_file = os.environ.get('TEAM_TRUSTED_PEERS', '')
        if peers_file:
            cfg.trusted_peers = load_trusted_peers(Path(peers_file))
        cfg.revocations_file = os.environ.get('TEAM_REVOCATIONS', '')
        return cfg


def load_trusted_peers(path: Path) -> dict[str, str]:
    """Accepts {"addr": "pubhex"} or {"alias": {"address": ..., "pubkey": ...}}."""
    from .raven_identity import validate_address_public_key

    raw = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(raw, dict):
        raise ValueError('trusted peers file must contain a JSON object')
    peers: dict[str, str] = {}
    for key, val in raw.items():
        if isinstance(val, dict):
            address, public_key = str(val['address']), str(val['pubkey'])
        else:
            address, public_key = str(key), str(val)
        validate_address_public_key(address, public_key)
        previous = peers.get(address)
        if previous is not None and previous.lower() != public_key.lower():
            raise ValueError(f'conflicting public keys for {address}')
        peers[address] = public_key.lower()
    return peers
