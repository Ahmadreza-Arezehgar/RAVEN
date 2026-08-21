"""Agent brains: OpenAI-compatible tool-calling loop + keyless echo brain."""

from __future__ import annotations

import asyncio
import json
import re
import time
import uuid
from typing import Protocol

import httpx

from .config import LLMConfig, NodeConfig
from .memory import TeamMemory
from .tools import ToolBox


class Brain(Protocol):
    async def run(self, task_text: str) -> str: ...


SYSTEM_PROMPT = """You are "{name}", one agent inside a small distributed team of AI agents.
Your role: {role}

The shared project lives in a git repo on this machine; teammates work on the SAME repo
on OTHER machines and sync through git. You coordinate through the `.team/` directory:
- read/write files with your tools (paths are relative to the repo root)
- keep the task board (board_set_task) up to date as you progress
- log important events (log_event) so others can follow what you did
- store durable discoveries with remember_fact
- claim files before editing (claim_file) and release them when done

Rules:
1. First inspect state: board_read, read_facts, list_files — avoid redoing teammates' work.
2. Do the task with the minimum set of steps.
3. Always finish by calling `final_answer` exactly once with a concise report.
"""


class OpenAIBrain:
    """ReAct-style tool loop against any OpenAI-compatible /chat/completions API."""

    def __init__(
        self,
        config: NodeConfig,
        llm: LLMConfig,
        toolbox: ToolBox,
        cancel_event: asyncio.Event | None = None,
    ) -> None:
        self.config = config
        self.llm = llm
        self.toolbox = toolbox
        self.cancel_event = cancel_event or asyncio.Event()

    async def _chat(self, client: httpx.AsyncClient, messages: list[dict]) -> dict:
        r = await client.post(
            f'{self.llm.base_url.rstrip("/")}/chat/completions',
            headers={'Authorization': f'Bearer {self.llm.api_key()}'},
            json={
                'model': self.llm.model,
                'messages': messages,
                'tools': self.toolbox.schemas(),
                'temperature': self.llm.temperature,
            },
            timeout=180,
        )
        r.raise_for_status()
        return r.json()['choices'][0]['message']

    async def run(self, task_text: str) -> str:
        messages: list[dict] = [
            {
                'role': 'system',
                'content': SYSTEM_PROMPT.format(
                    name=self.config.name, role=self.config.role
                ),
            },
            {'role': 'user', 'content': task_text},
        ]
        async with httpx.AsyncClient() as client:
            for step in range(self.llm.max_steps):
                if self.cancel_event.is_set():
                    return 'CANCELLED'
                msg = await self._chat(client, messages)
                tool_calls = msg.get('tool_calls') or []
                if not tool_calls:
                    # model answered in plain text — accept it as the answer
                    return msg.get('content') or ''
                messages.append(
                    {
                        'role': 'assistant',
                        'content': msg.get('content'),
                        'tool_calls': tool_calls,
                    }
                )
                for call in tool_calls:
                    fn = call['function']['name']
                    try:
                        args = json.loads(call['function'].get('arguments') or '{}')
                    except json.JSONDecodeError:
                        args = {}
                    result = await self.toolbox.dispatch(fn, args)
                    messages.append(
                        {
                            'role': 'tool',
                            'tool_call_id': call['id'],
                            'content': result[:8000],
                        }
                    )
                    if fn == 'final_answer' and self.toolbox.final_answer is not None:
                        return self.toolbox.final_answer
        raise RuntimeError(
            f'max_steps={self.llm.max_steps} reached without a final answer'
        )


class EchoBrain:
    """Deterministic no-key brain used for demos and end-to-end tests.

    It "does the work" by writing a notes file named after the task into the
    shared repo, updating the board/journal, then reporting back. Good enough
    to prove multi-device wiring without spending tokens.
    """

    def __init__(self, config: NodeConfig, memory: TeamMemory) -> None:
        self.config = config
        self.memory = memory

    async def run(self, task_text: str) -> str:
        slug = re.sub(r'[^a-z0-9]+', '-', task_text.lower()).strip('-')[:40] or 'task'
        relpath = f'.team/outputs/{self.config.name}/{slug}-{uuid.uuid4().hex[:6]}.md'
        content = (
            f'# Task output\n\n- node: {self.config.name}\n'
            f'- time: {time.strftime("%Y-%m-%d %H:%M:%S")}\n\n'
            f'## Task\n\n{task_text}\n\n'
            f'## Result\n\n{self.config.role or self.config.name} processed this '
            f'task deterministically (echo mode). No LLM key was configured.\n'
        )
        p = self.memory.resolve_in_repo(relpath)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding='utf-8')
        self.memory.log_event(self.config.name, f'echo-completed task → {relpath}')
        self.memory.set_task(task_text[:80], owner=self.config.name, status='done')
        return (
            f'[echo:{self.config.name}] completed task. Output written to {relpath}. '
            f'Task summary: {task_text[:120]}'
        )


def build_brain(
    config: NodeConfig,
    toolbox: ToolBox,
    cancel_event: asyncio.Event | None = None,
) -> Brain:
    if config.llm.provider == 'openai':
        return OpenAIBrain(config, config.llm, toolbox, cancel_event)
    return EchoBrain(config, toolbox.memory)
