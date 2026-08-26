"""Node configuration: identity, network, LLM backend and trust policy."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path


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
    require_signed_tasks: bool = False
    revocations_file: str = ''       # JSON list of revoked rvn1 addresses

    def resolved_public_url(self) -> str:
        if self.public_url:
            return self.public_url.rstrip('/')
        shown = self.advertised_host or self.host
        return f'http://{shown}:{self.port}'

    @property
    def keys_dir(self) -> Path:
        return Path(self.repo_path).resolve() / '.team' / 'keys'

    # ------------------------------------------------------------- loaders --
    @classmethod
    def from_env(cls) -> 'NodeConfig':
        cfg = cls(
            name=os.environ.get('TEAM_NODE_NAME', cls.name),
            role=os.environ.get('TEAM_NODE_ROLE', ''),
            host=os.environ.get('TEAM_HOST', cls.host),
            port=int(os.environ.get('TEAM_PORT', str(cls.port))),
            public_url=os.environ.get('TEAM_PUBLIC_URL', ''),
            repo_path=Path(os.environ.get('TEAM_REPO', '.')),
            auth_token=os.environ.get('TEAM_AUTH_TOKEN', ''),
            allow_shell=os.environ.get('TEAM_ALLOW_SHELL', '') == '1',
            auto_commit_memory=os.environ.get('TEAM_AUTO_COMMIT', '1') == '1',
            llm=LLMConfig(
                provider=os.environ.get('TEAM_LLM_PROVIDER', 'echo'),
                model=os.environ.get('TEAM_LLM_MODEL', ''),
                base_url=os.environ.get(
                    'TEAM_LLM_BASE_URL', LLMConfig.base_url
                ),
            ),
            require_signed_tasks=os.environ.get('TEAM_REQUIRE_SIGNED', '') == '1',
        )
        peers_file = os.environ.get('TEAM_TRUSTED_PEERS', '')
        if peers_file:
            cfg.trusted_peers = load_trusted_peers(Path(peers_file))
        cfg.revocations_file = os.environ.get('TEAM_REVOCATIONS', '')
        return cfg


def load_trusted_peers(path: Path) -> dict[str, str]:
    """Accepts {"addr": "pubhex"} or {"alias": {"address": ..., "pubkey": ...}}."""
    raw = json.loads(path.read_text(encoding='utf-8'))
    peers: dict[str, str] = {}
    for key, val in raw.items():
        if isinstance(val, dict):
            peers[val['address']] = val['pubkey']
        else:
            peers[key] = str(val)
    return peers
