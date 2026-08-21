"""Bridge between the A2A task lifecycle and our agent brain."""

from __future__ import annotations

import asyncio
import logging
import uuid

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.types import Part, Task, TaskState, TaskStatus

from .config import NodeConfig
from .llm import Brain
from .memory import TeamMemory
from .raven_identity import verify_delegation

logger = logging.getLogger(__name__)

RAVEN_META_KEYS = ('sender', 'timestamp', 'signature', 'algorithm', 'context')


def _scalar(value) -> object:
    """Flatten proto Struct Values / plain python values to plain python."""
    which = getattr(value, 'WhichOneof', None)
    if which is not None and callable(which):
        try:
            kind = value.WhichOneof('kind')
        except Exception:  # noqa: BLE001
            return value
        return getattr(value, kind) if kind else ''
    return value


def extract_raven_meta(context: RequestContext) -> dict:
    md = {}
    message = getattr(context, 'message', None)
    raw = getattr(message, 'metadata', None) or {}
    for key, value in dict(raw).items():
        short = key.split('.', 1)[1] if key.startswith('raven.') else None
        if short in RAVEN_META_KEYS:
            md[short] = _scalar(value)
    return md


class TeamAgentExecutor(AgentExecutor):
    def __init__(
        self,
        config: NodeConfig,
        brain: Brain,
        memory: TeamMemory,
        trusted_peers: dict[str, str] | None = None,
        require_signed: bool = False,
        cancel_event: asyncio.Event | None = None,
    ) -> None:
        self.config = config
        self.brain = brain
        self.memory = memory
        self.trusted_peers = trusted_peers or {}
        self.require_signed = require_signed
        self._cancel = cancel_event or asyncio.Event()

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        self._cancel.clear()
        task = context.current_task
        task_id = context.task_id or (task.id if task else uuid.uuid4().hex)
        context_id = (
            context.context_id or (task.context_id if task else None) or uuid.uuid4().hex
        )
        updater = TaskUpdater(event_queue, task_id=task_id, context_id=context_id)

        if task is None:
            task = Task(
                id=task_id,
                context_id=context_id,
                status=TaskStatus(state=TaskState.TASK_STATE_SUBMITTED),
            )
            await event_queue.enqueue_event(task)

        text = context.get_user_input().strip()
        self.memory.log_event(self.config.name, f'incoming task: {text[:120]}')

        try:
            await updater.submit()
            await updater.start_work()

            # ---- RVN1 delegation auth ---------------------------------
            meta = extract_raven_meta(context)
            ok, reason = verify_delegation(
                meta,
                text,
                trusted_peers=self.trusted_peers,
                required=self.require_signed,
            )
            if not ok:
                sender = meta.get('sender', '?')
                self.memory.log_event(
                    self.config.name, f'REJECTED task {task_id[:8]} from {sender}: {reason}'
                )
                await updater.failed(
                    message=updater.new_agent_message(
                        [Part(text=f'raven delegation rejected: {reason}')]
                    )
                )
                return
            if meta:
                self.memory.log_event(
                    self.config.name, f'delegation verified: {meta["sender"]}'
                )

            answer = await self.brain.run(text)
            await updater.add_artifact([Part(text=answer)], name='result')
            await updater.complete()
            self.memory.log_event(self.config.name, f'task done: {task_id[:8]}')
        except Exception as exc:  # noqa: BLE001
            logger.exception('agent task failed')
            self.memory.log_event(
                self.config.name, f'task FAILED ({task_id[:8]}): {exc}'
            )
            await updater.failed(
                message=updater.new_agent_message(
                    [Part(text=f'{type(exc).__name__}: {exc}')]
                )
            )
        finally:
            # keep the shared state moving across machines
            try:
                self.memory.sync()
            except Exception:  # noqa: BLE001
                pass

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        self._cancel.set()
