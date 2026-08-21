"""Node configuration loading (YAML + environment variable expansion)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


@dataclass
class LLMConfig:
    provider: str = 'echo'  # 'openai' (any OpenAI-compatible endpoint) or 'echo'
    model: str = 'gpt-4o-mini'
    base_url: str = 'https://api.openai.com/v1'
    api_key_env: str = 'OPENAI_API_KEY'
    max_steps: int = 12
    temperature: float = 0.2

    def api_key(self) -> str:
        return os.environ.get(self.api_key_env, '')


@dataclass
class SkillConfig:
    id: str
    name: str
    description: str = ''
    tags: list[str] = field(default_factory=list)


def _expand(value: Any) -> Any:
    """Recursively expand ${ENV_VARS} inside strings of parsed YAML."""
    if isinstance(value, str):
        return os.path.expandvars(os.path.expanduser(value))
    if isinstance(value, list):
        return [_expand(v) for v in value]
    if isinstance(value, dict):
        return {k: _expand(v) for k, v in value.items()}
    return value


@dataclass
class NodeConfig:
    name: str
    role: str = ''
    host: str = '0.0.0.0'
    port: int = 9101
    # URL other devices use to reach this node. For two real machines use the
    # LAN IP or Tailscale hostname, e.g. http://my-laptop.tail1234.ts.net/
    public_url: str = ''
    auth_token: str | None = None
    repo_path: Path = Path('./shared_repo')
    allow_shell: bool = False
    auto_commit_memory: bool = True
    skills: list[SkillConfig] = field(default_factory=list)
    llm: LLMConfig = field(default_factory=LLMConfig)

    def resolved_public_url(self) -> str:
        return self.public_url or f'http://127.0.0.1:{self.port}/'

    @classmethod
    def load(cls, path: str | Path) -> 'NodeConfig':
        raw = _expand(yaml.safe_load(Path(path).read_text(encoding='utf-8')))
        llm_raw = raw.pop('llm', {}) or {}
        skills_raw = raw.pop('skills', []) or []
        repo_path = Path(raw.pop('repo_path', './shared_repo'))
        cfg = cls(
            name=raw['name'],
            role=raw.get('role', ''),
            host=raw.get('host', '0.0.0.0'),
            port=int(raw.get('port', 9101)),
            public_url=raw.get('public_url', ''),
            auth_token=raw.get('auth_token') or None,
            repo_path=repo_path,
            allow_shell=bool(raw.get('allow_shell', False)),
            auto_commit_memory=bool(raw.get('auto_commit_memory', True)),
            skills=[
                SkillConfig(
                    id=s['id'],
                    name=s.get('name', s['id']),
                    description=s.get('description', ''),
                    tags=list(s.get('tags', [])),
                )
                for s in skills_raw
            ],
            llm=LLMConfig(**llm_raw),
        )
        return cfg
