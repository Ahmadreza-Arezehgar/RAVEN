"""Toolbox exposed to the agent brain: filesystem, shell, git and team memory."""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
from pathlib import Path

from .config import NodeConfig
from .memory import TeamMemory

MAX_READ_CHARS = 20_000
MAX_CMD_OUTPUT = 10_000

_PRIVATE_COMPONENTS = frozenset({
    '.git',
    '.ssh',
    '.gnupg',
    '.aws',
    '.azure',
    '.kube',
    '.terraform',
    '.secrets',
    '.credentials',
    'secrets',
    'credentials',
})
_PRIVATE_TEAM_PREFIXES = ('keys', 'mesh-client', 'mesh-seen', 'mesh-store', 'replay-cache')
_PRIVATE_EXACT_NAMES = frozenset({
    '.envrc',
    '.git-credentials',
    '.netrc',
    '.npmrc',
    '.pypirc',
    '.dockercfg',
    'auth.json',
    'authorized_keys',
    'id_dsa',
    'id_ecdsa',
    'id_ed25519',
    'id_rsa',
    'mesh-seen.json',
    'replay-cache.sqlite3',
})
_PRIVATE_SUFFIXES = (
    '.env',
    '.jks',
    '.kdbx',
    '.key',
    '.keystore',
    '.p12',
    '.pem',
    '.pfx',
    '.seed',
    '.tfstate',
    '.tfstate.backup',
)
_SECRET_CONFIG_SUFFIXES = frozenset({
    '', '.cfg', '.conf', '.csv', '.ini', '.json', '.toml', '.txt', '.yaml', '.yml'
})
_SECRET_NAME_TOKENS = frozenset({
    'apikey',
    'credential',
    'credentials',
    'key',
    'password',
    'passwd',
    'private',
    'privatekey',
    'secret',
    'secrets',
    'token',
    'vault',
})


class ToolBox:
    def __init__(self, config: NodeConfig, memory: TeamMemory) -> None:
        self.config = config
        self.memory = memory
        self.final_answer: str | None = None
        memory.ensure_layout()

    # ------------------------------------------------------------ schemas --
    def schemas(self) -> list[dict]:
        tools = [
            {
                'type': 'function',
                'function': {
                    'name': 'list_files',
                    'description': (
                        'List files in the shared project repo. Paths are '
                        'relative to repo root.'
                    ),
                    'parameters': {
                        'type': 'object',
                        'properties': {
                            'subpath': {'type': 'string', 'default': '.'}
                        },
                        'required': [],
                    },
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'read_file',
                    'description': (
                        'Read a non-sensitive text file from the shared repo. '
                        'Keys, credentials, env files, Git internals, private '
                        'runtime state and symlink/reparse paths are denied.'
                    ),
                    'parameters': {
                        'type': 'object',
                        'properties': {'path': {'type': 'string'}},
                        'required': ['path'],
                    },
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'git_status',
                    'description': 'Show git status of the shared repo.',
                    'parameters': {'type': 'object', 'properties': {}},
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'board_read',
                    'description': 'Read the team task board (.team/BOARD.md).',
                    'parameters': {'type': 'object', 'properties': {}},
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'board_set_task',
                    'description': (
                        'Create a task on the team board, or update one by id.'
                    ),
                    'parameters': {
                        'type': 'object',
                        'properties': {
                            'title': {'type': 'string'},
                            'task_id': {'type': 'string'},
                            'status': {
                                'type': 'string',
                                'enum': ['open', 'in_progress', 'blocked', 'done'],
                            },
                            'notes': {'type': 'string'},
                        },
                        'required': ['title'],
                    },
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'log_event',
                    'description': 'Append an event to the shared team journal.',
                    'parameters': {
                        'type': 'object',
                        'properties': {'text': {'type': 'string'}},
                        'required': ['text'],
                    },
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'remember_fact',
                    'description': 'Store a durable fact for future agents.',
                    'parameters': {
                        'type': 'object',
                        'properties': {'text': {'type': 'string'}},
                        'required': ['text'],
                    },
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'read_facts',
                    'description': 'Read all stored team facts.',
                    'parameters': {'type': 'object', 'properties': {}},
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'claim_file',
                    'description': (
                        'Advisory lock: announce you are editing a file so other '
                        'agents stay away from it.'
                    ),
                    'parameters': {
                        'type': 'object',
                        'properties': {'path': {'type': 'string'}},
                        'required': ['path'],
                    },
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'release_file',
                    'description': 'Release a previously claimed file.',
                    'parameters': {
                        'type': 'object',
                        'properties': {'path': {'type': 'string'}},
                        'required': ['path'],
                    },
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'final_answer',
                    'description': (
                        'MUST be called exactly once at the end with your final '
                        'answer / report for the delegating agent.'
                    ),
                    'parameters': {
                        'type': 'object',
                        'properties': {'answer': {'type': 'string'}},
                        'required': ['answer'],
                    },
                },
            },
        ]
        if self.config.allow_shell:
            tools.extend([
                {
                    'type': 'function',
                    'function': {
                        'name': 'write_file',
                        'description': (
                            'High-risk operator-enabled action: create or '
                            'overwrite a file in the shared project repo.'
                        ),
                        'parameters': {
                            'type': 'object',
                            'properties': {
                                'path': {'type': 'string'},
                                'content': {'type': 'string'},
                            },
                            'required': ['path', 'content'],
                        },
                    },
                },
                {
                    'type': 'function',
                    'function': {
                        'name': 'run_command',
                        'description': (
                            'Run a shell command inside the shared repo (cwd=repo).'
                        ),
                        'parameters': {
                            'type': 'object',
                            'properties': {
                                'command': {'type': 'string'},
                                'timeout': {'type': 'integer', 'default': 60},
                            },
                            'required': ['command'],
                        },
                    },
                },
                {
                    'type': 'function',
                    'function': {
                        'name': 'git_commit',
                        'description': (
                            'High-risk operator-enabled action: commit only changes '
                            'that are already staged in Git. This tool never stages '
                            'files and refuses private .team runtime state.'
                        ),
                        'parameters': {
                            'type': 'object',
                            'properties': {'message': {'type': 'string'}},
                            'required': ['message'],
                        },
                    },
                },
            ])
        return tools

    # ----------------------------------------------------------- dispatch --
    async def dispatch(self, name: str, args: dict) -> str:
        handler = getattr(self, f'tool_{name}', None)
        if handler is None:
            return f'ERROR unknown tool: {name}'
        try:
            return await handler(**args)
        except Exception as exc:  # surface tool errors to the LLM
            return f'ERROR: {exc!r}'

    # --------------------------------------------------------------- fs ----
    def _safe(self, relpath: str) -> Path:
        return self.memory.resolve_in_repo(relpath)

    @staticmethod
    def _sensitive_path(parts: tuple[str, ...]) -> bool:
        lowered = tuple(part.casefold() for part in parts)
        if any(part in _PRIVATE_COMPONENTS for part in lowered):
            return True
        for index, part in enumerate(lowered[:-1]):
            if part == '.team' and lowered[index + 1].startswith(
                _PRIVATE_TEAM_PREFIXES
            ):
                return True
        name = lowered[-1] if lowered else ''
        if (
            name == '.env'
            or name.startswith('.env.')
            or name.endswith('.env')
            or '.env.' in name
        ):
            return True
        if name in _PRIVATE_EXACT_NAMES or name.startswith(('id_rsa.', 'id_ed25519.')):
            return True
        if name.endswith(_PRIVATE_SUFFIXES):
            return True
        if any(f'{suffix}.' in name for suffix in _PRIVATE_SUFFIXES):
            return True

        suffix = Path(name).suffix
        stem = name[:-len(suffix)] if suffix else name
        tokens = set(filter(None, re.split(r'[._-]+', stem)))
        obvious_secret_name = bool(tokens & _SECRET_NAME_TOKENS) or {
            'service', 'account'
        }.issubset(tokens)
        return suffix in _SECRET_CONFIG_SUFFIXES and obvious_secret_name

    def _safe_read(self, relpath: str) -> Path:
        """Resolve a readable non-sensitive regular path without symlink hops."""
        raw = Path(relpath)
        unsafe_syntax = any(
            part == '..'
            or '\x00' in part
            or ':' in part  # NTFS alternate data streams / drive-like aliases
            or '~' in part  # Windows 8.3 aliases can disguise denied names
            or part != part.rstrip(' .')
            for part in raw.parts
        )
        if raw.is_absolute() or not raw.parts or unsafe_syntax:
            raise PermissionError('read denied by sensitive-path policy')
        logical_parts = tuple(part for part in raw.parts if part not in ('', '.'))
        if not logical_parts or self._sensitive_path(logical_parts):
            raise PermissionError('read denied by sensitive-path policy')

        # Reject every symlink/reparse hop, even if its current target happens
        # to be inside the repository. This removes aliases that could disguise
        # a denied secret and avoids treating a later target swap as authorized.
        candidate = self.memory.repo_path
        for part in logical_parts:
            candidate /= part
            if os.path.lexists(candidate):
                metadata = os.lstat(candidate)
                if stat.S_ISLNK(metadata.st_mode) or getattr(
                    metadata, 'st_reparse_tag', 0
                ):
                    raise PermissionError('read denied for symlink/reparse path')

        resolved = self._safe(str(raw))
        resolved_parts = resolved.relative_to(self.memory.repo_path).parts
        if self._sensitive_path(resolved_parts):
            raise PermissionError('read denied by sensitive-path policy')
        return resolved

    async def tool_list_files(self, subpath: str = '.') -> str:
        base = self._safe(subpath)
        if not base.exists():
            return f'not found: {subpath}'
        skip = {'.git', '.team', '__pycache__', '.venv', 'node_modules'}
        out = []
        for p in sorted(base.rglob('*')):
            if any(part in skip for part in p.parts):
                continue
            rel = p.relative_to(self.memory.repo_path)
            metadata = os.lstat(p)
            if (
                self._sensitive_path(rel.parts)
                or stat.S_ISLNK(metadata.st_mode)
                or getattr(metadata, 'st_reparse_tag', 0)
            ):
                continue
            out.append(f'{rel}/' if p.is_dir() else str(rel))
            if len(out) >= 300:
                out.append('... (truncated)')
                break
        return '\n'.join(out) or '(empty)'

    async def tool_read_file(self, path: str) -> str:
        p = self._safe_read(path)
        flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0)
        flags |= getattr(os, 'O_NOFOLLOW', 0)
        try:
            fd = os.open(p, flags)
        except FileNotFoundError:
            return f'not found: {path}'
        with os.fdopen(fd, 'r', encoding='utf-8', errors='replace') as handle:
            metadata = os.fstat(handle.fileno())
            path_metadata = os.lstat(p)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_ISLNK(path_metadata.st_mode)
                or getattr(path_metadata, 'st_reparse_tag', 0)
                or (metadata.st_dev, metadata.st_ino)
                != (path_metadata.st_dev, path_metadata.st_ino)
                or metadata.st_nlink != 1
            ):
                raise PermissionError('read denied for unsafe file identity')
            text = handle.read(MAX_READ_CHARS + 1)
        if len(text) > MAX_READ_CHARS:
            text = text[:MAX_READ_CHARS] + '\n... (truncated)'
        return text

    async def tool_write_file(self, path: str, content: str) -> str:
        if not self.config.allow_shell:
            return (
                'ERROR: project file writes disabled on this node '
                '(allow_shell=false)'
            )
        p = self._safe(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding='utf-8')
        self.memory.log_event(self.config.name, f'wrote {path} ({len(content)} bytes)')
        return f'wrote {len(content)} bytes to {path}'

    # ------------------------------------------------------------- shell ---
    async def tool_run_command(self, command: str, timeout: int = 60) -> str:
        if not self.config.allow_shell:
            return 'ERROR: shell disabled on this node (allow_shell=false)'
        r = subprocess.run(
            command,
            shell=True,
            cwd=self.memory.repo_path,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        out = (r.stdout + r.stderr)[:MAX_CMD_OUTPUT]
        return f'exit={r.returncode}\n{out}'

    # --------------------------------------------------------------- git ---
    async def tool_git_status(self) -> str:
        return self.memory._git_checked('status', '--short') or '(clean)'

    async def tool_git_commit(self, message: str) -> str:
        return self.memory.commit_staged(
            message, explicitly_authorized=self.config.allow_shell
        )

    # -------------------------------------------------------------- team ---
    async def tool_board_read(self) -> str:
        self.memory.ensure_layout()
        return self.memory.board_md.read_text(encoding='utf-8')

    async def tool_board_set_task(
        self,
        title: str,
        task_id: str | None = None,
        status: str = 'open',
        notes: str = '',
    ) -> str:
        t = self.memory.set_task(
            title, task_id=task_id, owner=self.config.name, status=status, notes=notes
        )
        return json.dumps(t)

    async def tool_log_event(self, text: str) -> str:
        self.memory.log_event(self.config.name, text)
        return 'logged'

    async def tool_remember_fact(self, text: str) -> str:
        self.memory.remember_fact(text)
        if self.config.auto_commit_memory:
            self.memory.commit_team(f'chore(team-memory): fact by {self.config.name}')
        return 'stored'

    async def tool_read_facts(self) -> str:
        return self.memory.read_facts()

    async def tool_claim_file(self, path: str) -> str:
        return self.memory.claim_file(path, owner=self.config.name)

    async def tool_release_file(self, path: str) -> str:
        return self.memory.release_file(path, owner=self.config.name)

    async def tool_final_answer(self, answer: str) -> str:
        self.final_answer = answer
        return 'final answer recorded; you may stop now'
    'key',
    'privatekey',
