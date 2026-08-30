"""Agent brains: OpenAI-compatible tool-calling loop + keyless echo brain."""

from __future__ import annotations

import asyncio
import json
import re
import time
import uuid
from typing import Protocol

import httpx

from .config import LLMConfig, NodeConfig, validate_node_name
from .memory import TeamMemory
from .tools import ToolBox


def _team_goal(memory) -> str:
    """Unified mission every task must serve (from .team/GOAL.md)."""
    try:
        # Use the same bounded, no-follow, single-link reader as the chat UI.
        # A repository-controlled GOAL.md must not turn model-prompt assembly
        # into an unbounded read or a symlink escape.
        from .chat import TeamChat

        return TeamChat(memory).get_goal()
    except Exception:  # noqa: BLE001
        return ''


class Brain(Protocol):
    async def run(
        self, task_text: str, *, cancel_event: asyncio.Event | None = None
    ) -> str: ...


SYSTEM_PROMPT = """You are "{name}", one agent inside a small distributed team of AI agents.
Your role: {role}

The shared project lives in a git repo on this machine; teammates work on the SAME repo
on OTHER machines and sync through git. You coordinate through the `.team/` directory:
- inspect non-sensitive project files with read-only tools (paths are relative to
  the repo root); keys, credentials, env files, Git internals, private runtime
  state, and symlink/reparse aliases are outside your authority
- modify project files only when the operator-enabled `write_file` tool is present
- keep the task board (board_set_task) up to date as you progress
- log important events (log_event) so others can follow what you did
- store durable discoveries with remember_fact
- claim files before editing (claim_file) and release them when done

Rules:
1. First inspect state: board_read, read_facts, list_files — avoid redoing teammates' work.
2. Do the task with the minimum set of steps.
3. Always finish by calling `final_answer` exactly once with a concise report.
4. Never use an operator-enabled shell to bypass `read_file` sensitive-path denials.
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
        headers = {}
        api_key = self.llm.api_key()
        if api_key:
            headers['Authorization'] = f'Bearer {api_key}'
        r = await client.post(
            f'{self.llm.base_url.rstrip("/")}/chat/completions',
            headers=headers,
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

    async def run(
        self, task_text: str, *, cancel_event: asyncio.Event | None = None
    ) -> str:
        task_cancel = cancel_event or self.cancel_event
        goal = (
            await asyncio.to_thread(_team_goal, self.toolbox.memory)
            if self.toolbox
            else ''
        )
        system_content = SYSTEM_PROMPT.format(
            name=self.config.name, role=self.config.role
        )
        if goal:
            system_content += (
                f'\n\nTEAM GOAL — every action you take must serve this '
                f'shared mission:\n{goal}'
            )
        messages: list[dict] = [
            {
                'role': 'system',
                'content': system_content,
            },
            {'role': 'user', 'content': task_text},
        ]
        async with httpx.AsyncClient() as client:
            for step in range(self.llm.max_steps):
                if task_cancel.is_set():
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
                    if (
                        fn == 'final_answer'
                        and result == 'final answer accepted; you may stop now'
                    ):
                        # The answer belongs to this exact tool invocation. It is
                        # never written to the process-wide ToolBox shared by
                        # concurrent A2A tasks.
                        return args['answer']
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

    async def run(
        self, task_text: str, *, cancel_event: asyncio.Event | None = None
    ) -> str:
        if cancel_event is not None and cancel_event.is_set():
            return 'CANCELLED'
        return await asyncio.to_thread(self._run_blocking, task_text)

    def _run_blocking(self, task_text: str) -> str:
        """Filesystem/team-memory echo work, kept off the ASGI event loop."""
        node_name = validate_node_name(self.config.name)
        goal = _team_goal(self.memory)
        if goal:
            task_text = f'[Team mission: {goal}]\n\n{task_text}'
        slug = re.sub(r'[^a-z0-9]+', '-', task_text.lower()).strip('-')[:40] or 'task'
        relpath = f'.team/outputs/{node_name}/{slug}-{uuid.uuid4().hex[:6]}.md'
        content = (
            f'# Task output\n\n- node: {node_name}\n'
            f'- time: {time.strftime("%Y-%m-%d %H:%M:%S")}\n\n'
            f'## Task\n\n{task_text}\n\n'
            f'## Result\n\n{self.config.role or node_name} processed this '
            f'task deterministically (echo mode). No LLM key was configured.\n'
        )
        p = self.memory.resolve_in_repo(relpath)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding='utf-8')
        self.memory.log_event(node_name, f'echo-completed task → {relpath}')
        self.memory.set_task(task_text[:80], owner=node_name, status='done')
        return (
            f'[echo:{node_name}] completed task. Output written to {relpath}. '
            f'Task summary: {task_text[:120]}'
        )


def build_brain(
    config: NodeConfig,
    toolbox: ToolBox,
    cancel_event: asyncio.Event | None = None,
) -> Brain:
    if config.llm.provider in {'openai', 'groq', 'openrouter', 'ollama', 'custom'}:
        return OpenAIBrain(config, config.llm, toolbox, cancel_event)
    return EchoBrain(config, toolbox.memory)
