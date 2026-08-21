"""Toolbox exposed to the agent brain: filesystem, shell, git and team memory."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .config import NodeConfig
from .memory import TeamMemory

MAX_READ_CHARS = 20_000
MAX_CMD_OUTPUT = 10_000


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
                    'description': 'Read a text file from the shared repo.',
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
                    'name': 'write_file',
                    'description': 'Create or overwrite a file in the shared repo.',
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
                    'name': 'git_status',
                    'description': 'Show git status of the shared repo.',
                    'parameters': {'type': 'object', 'properties': {}},
                },
            },
            {
                'type': 'function',
                'function': {
                    'name': 'git_commit',
                    'description': 'Commit all current changes with a message.',
                    'parameters': {
                        'type': 'object',
                        'properties': {'message': {'type': 'string'}},
                        'required': ['message'],
                    },
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
            tools.append(
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
                }
            )
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
            out.append(f'{rel}/' if p.is_dir() else str(rel))
            if len(out) >= 300:
                out.append('... (truncated)')
                break
        return '\n'.join(out) or '(empty)'

    async def tool_read_file(self, path: str) -> str:
        p = self._safe(path)
        if not p.is_file():
            return f'not found: {path}'
        text = p.read_text(encoding='utf-8', errors='replace')
        if len(text) > MAX_READ_CHARS:
            text = text[:MAX_READ_CHARS] + '\n... (truncated)'
        return text

    async def tool_write_file(self, path: str, content: str) -> str:
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
        return self.memory._git('status', '--short') or '(clean)'

    async def tool_git_commit(self, message: str) -> str:
        return self.memory.commit_all(message)

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
            self.memory.commit_all(f'chore(team-memory): fact by {self.config.name}')
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
