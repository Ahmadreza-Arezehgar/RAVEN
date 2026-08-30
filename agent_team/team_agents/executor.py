"""Bridge between the A2A task lifecycle and our agent brain."""

from __future__ import annotations

import asyncio
import logging
import uuid
from pathlib import Path

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.types import Part, Task, TaskState, TaskStatus

from .config import NodeConfig
from .llm import Brain
from .memory import TeamMemory
from .raven_identity import RavenIdentity, ReplayCache, sign_delegation, verify_delegation

logger = logging.getLogger(__name__)

RAVEN_META_KEYS = (
    'sender', 'recipient', 'task_id', 'kind', 'issued_at', 'expires_at',
    'signature', 'algorithm', 'context', 'nonce',
)


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
        require_signed: bool = True,
        identity: RavenIdentity | None = None,
    ) -> None:
        self.config = config
        self.brain = brain
        self.memory = memory
        self.trusted_peers = trusted_peers or {}
        self.require_signed = require_signed
        self.identity = identity
        self.replay = ReplayCache(path=config.replay_cache_path)
        self._cancel_events: dict[tuple[str, str], asyncio.Event] = {}

    def current_peers(self) -> dict[str, str]:
        """Hot-reload trust list so new teammates work without restart."""
        f = self.config.trusted_peers_file
        if f:
            from .config import load_trusted_peers

            return load_trusted_peers(Path(f))
        return self.trusted_peers

    def current_revocations(self) -> set[str]:
        """Hot-reload revoked RVN1 addresses."""
        f = self.config.revocations_file
        if f:
            from .raven_identity import load_revocations

            return load_revocations(Path(f))
        return set()

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        task = context.current_task
        task_id = context.task_id or (task.id if task else uuid.uuid4().hex)
        message = getattr(context, 'message', None)
        signed_task_id = str(getattr(message, 'message_id', '') or '')
        context_id = (
            context.context_id or (task.context_id if task else None) or uuid.uuid4().hex
        )
        updater = TaskUpdater(event_queue, task_id=task_id, context_id=context_id)

        # Authentication is deliberately the first request-dependent operation.
        # In particular, do not append the task text to team memory, touch Git, or
        # register work/cancellation state until the delegation has been verified.
        # A configured trust/revocation-policy failure is also an auth failure and
        # must follow the same mutation-free rejection path.
        try:
            wire_text = context.get_user_input()
            if not isinstance(wire_text, str):
                raise TypeError('A2A user input must be text')
            meta = extract_raven_meta(context)

            def authorize() -> tuple[bool, str]:
                transport_owner = str(context.call_context.user.user_name)
                # Reject a forwarded envelope before signature verification
                # records it in the once-only replay cache. Otherwise another
                # trusted peer that sees Alice's signed body could consume the
                # signature under Bob's HTTP principal and deny Alice's request.
                if meta and transport_owner != str(meta.get('sender', '')):
                    return False, 'transport/delegation sender mismatch'
                ok, reason = verify_delegation(
                    meta,
                    wire_text,
                    trusted_peers=self.current_peers(),
                    required=self.require_signed,
                    revoked=self.current_revocations(),
                    replay=self.replay,
                    expected_recipient=self.identity.address if self.identity else '',
                    expected_task_id=signed_task_id,
                    expected_kind='task',
                )
                return ok, reason

            ok, reason = await asyncio.to_thread(authorize)
        except Exception:  # noqa: BLE001
            # Do not reflect policy internals or attacker-controlled input.  More
            # importantly, this request path must not write TeamMemory/Git or a
            # per-request exception log that can itself become a disk-DoS sink.
            ok, reason = False, 'delegation authorization unavailable'

        if not ok:
            # Emit one terminal Task so SDK dispatchers finish cleanly. The
            # bounded store deliberately does not retain rejected tasks, nor
            # overwrite a prior valid task if an attacker reuses its ID.
            rejection = updater.new_agent_message(
                [Part(text=f'raven delegation rejected: {reason}')]
            )
            await event_queue.enqueue_event(
                Task(
                    id=task_id,
                    context_id=context_id,
                    status=TaskStatus(
                        state=TaskState.TASK_STATE_REJECTED,
                        message=rejection,
                    ),
                )
            )
            return

        # Whitespace is part of the signed wire payload. Normalize only after
        # successful verification so client and server hash identical bytes.
        text = wire_text.strip()

        if task is None:
            task = Task(
                id=task_id,
                context_id=context_id,
                status=TaskStatus(state=TaskState.TASK_STATE_SUBMITTED),
            )
            await event_queue.enqueue_event(task)

        cancel_event = asyncio.Event()
        owner = str(context.call_context.user.user_name)
        self._cancel_events[(owner, task_id)] = cancel_event
        if signed_task_id:
            self._cancel_events[(owner, signed_task_id)] = cancel_event

        try:
            await updater.submit()
            await updater.start_work()
            await asyncio.to_thread(
                self.memory.log_event,
                self.config.name,
                f'incoming task: {text[:120]}',
            )
            if meta:
                await asyncio.to_thread(
                    self.memory.log_event,
                    self.config.name,
                    f'delegation verified: {meta["sender"]}',
                )

            await updater.update_status(
                TaskState.TASK_STATE_WORKING,
                message=updater.new_agent_message(
                    [Part(text='delegation verified — running brain…')]
                ),
            )
            answer = await self.brain.run(text, cancel_event=cancel_event)
            reply_metadata = None
            if meta and self.identity is not None:
                reply = sign_delegation(
                    self.identity,
                    answer,
                    recipient=str(meta['sender']),
                    task_id=signed_task_id,
                    kind='answer',
                )
                reply_metadata = {f'raven.{key}': str(value) for key, value in reply.items()}
            await updater.add_artifact(
                [Part(text=answer)], name='result', metadata=reply_metadata
            )
            await updater.complete()
            await asyncio.to_thread(
                self.memory.log_event,
                self.config.name,
                f'task done: {task_id[:8]}',
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception('agent task failed')
            await asyncio.to_thread(
                self.memory.log_event,
                self.config.name,
                f'task FAILED ({task_id[:8]}): {exc}',
            )
            await updater.failed(
                message=updater.new_agent_message(
                    [Part(text=f'{type(exc).__name__}: {exc}')]
                )
            )
        finally:
            self._cancel_events.pop((owner, task_id), None)
            if signed_task_id:
                self._cancel_events.pop((owner, signed_task_id), None)
            # Only authenticated work is allowed to move shared state across
            # machines.  Rejections return before entering this try/finally.
            try:
                await asyncio.to_thread(self.memory.sync)
            except Exception:  # noqa: BLE001
                pass

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        task = context.current_task
        caller = str(context.call_context.user.user_name)
        if (
            not caller
            or (
                self.require_signed
                and not context.call_context.user.is_authenticated
            )
        ):
            raise PermissionError('Raven cancellation authorization failed')
        candidates = [
            str(context.task_id or ''),
            str(task.id if task else ''),
            str(getattr(getattr(context, 'message', None), 'message_id', '') or ''),
        ]
        for candidate in candidates:
            event = self._cancel_events.get((caller, candidate))
            if event is not None:
                event.set()
                break
        if task is None:
            raise ValueError('cannot cancel a missing task')
        # a2a-sdk cancels/closes its producer queue before invoking this hook.
        # RavenRequestHandler persists and returns the terminal canceled Task
        # after the SDK has drained, avoiding a racy event enqueue here.
