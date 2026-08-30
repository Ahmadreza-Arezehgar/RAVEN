"""Race-safe bounded in-memory A2A task store.

The upstream SDK's in-memory store intentionally has no retention bound.  This
implementation preserves the SDK's owner scoping, copying, filtering and
pagination contract while enforcing global count, serialized-byte and TTL
limits for the server process.
"""

from __future__ import annotations

import asyncio
import time

from collections.abc import Callable
from dataclasses import dataclass

from a2a.server.context import ServerCallContext
from a2a.server.owner_resolver import OwnerResolver, resolve_user_scope
from a2a.server.tasks import TaskStore
from a2a.types import ListTasksRequest, ListTasksResponse, Task, TaskState
from a2a.utils.constants import DEFAULT_LIST_TASKS_PAGE_SIZE
from a2a.utils.errors import InvalidParamsError
from a2a.utils.task import decode_page_token, encode_page_token


MAX_OWNER_KEY_BYTES = 1024
MAX_TASK_ID_KEY_BYTES = 4096
_ENTRY_OVERHEAD_BYTES = 512
_TERMINAL_STATES = frozenset({
    TaskState.TASK_STATE_COMPLETED,
    TaskState.TASK_STATE_CANCELED,
    TaskState.TASK_STATE_FAILED,
    TaskState.TASK_STATE_REJECTED,
})


class TaskStoreCapacityError(RuntimeError):
    """A task cannot fit without evicting active work."""


@dataclass(frozen=True)
class _Entry:
    task: Task
    updated_at: float
    size: int


def _copy_task(task: Task) -> Task:
    copied = Task()
    copied.CopyFrom(task)
    return copied


class BoundedTaskStore(TaskStore):
    """Globally bounded, owner-scoped, copy-on-read/write A2A task store.

    Rejected tasks are never retained, and expired entries are removed on every
    operation. When space is needed, the oldest terminal history is evicted.
    Active tasks are never evicted to admit new work; capacity exhaustion
    therefore fails closed.
    """

    def __init__(
        self,
        *,
        max_count: int,
        max_bytes: int,
        ttl_seconds: float,
        owner_resolver: OwnerResolver = resolve_user_scope,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if max_count <= 0 or max_bytes <= 0 or ttl_seconds <= 0:
            raise ValueError('task-store limits must be positive')
        self.max_count = max_count
        self.max_bytes = max_bytes
        self.ttl_seconds = ttl_seconds
        self.owner_resolver = owner_resolver
        self._clock = clock
        self._entries: dict[tuple[str, str], _Entry] = {}
        self._total_bytes = 0
        self._lock = asyncio.Lock()

    def _owner(self, context: ServerCallContext) -> str:
        owner = str(self.owner_resolver(context))
        if len(owner.encode('utf-8')) > MAX_OWNER_KEY_BYTES:
            raise InvalidParamsError('oversized task owner')
        return owner

    @staticmethod
    def _terminal(task: Task) -> bool:
        return task.status.state in _TERMINAL_STATES

    @staticmethod
    def _rejected(task: Task) -> bool:
        return task.status.state == TaskState.TASK_STATE_REJECTED

    @staticmethod
    def _size(task: Task, owner: str) -> int:
        return task.ByteSize() + len(owner.encode('utf-8')) + _ENTRY_OVERHEAD_BYTES

    def _remove_locked(self, key: tuple[str, str]) -> None:
        entry = self._entries.pop(key, None)
        if entry is not None:
            self._total_bytes -= entry.size

    def _prune_expired_locked(self, now: float) -> None:
        expired = [
            key
            for key, entry in self._entries.items()
            if self._terminal(entry.task)
            and now - entry.updated_at >= self.ttl_seconds
        ]
        for key in expired:
            self._remove_locked(key)

    def _evictions_for_locked(
        self,
        key: tuple[str, str],
        incoming_size: int,
    ) -> list[tuple[str, str]]:
        existing = self._entries.get(key)
        projected_count = len(self._entries) + (0 if existing else 1)
        projected_bytes = self._total_bytes - (existing.size if existing else 0)
        projected_bytes += incoming_size
        if projected_count <= self.max_count and projected_bytes <= self.max_bytes:
            return []

        candidates = sorted(
            (
                (entry.updated_at, other_key)
                for other_key, entry in self._entries.items()
                if other_key != key and self._terminal(entry.task)
            ),
            key=lambda item: (item[0], item[1]),
        )
        victims: list[tuple[str, str]] = []
        for _, victim in candidates:
            entry = self._entries[victim]
            victims.append(victim)
            projected_count -= 1
            projected_bytes -= entry.size
            if projected_count <= self.max_count and projected_bytes <= self.max_bytes:
                return victims
        raise TaskStoreCapacityError(
            'task store capacity exhausted by active or oversized work'
        )

    async def save(self, task: Task, context: ServerCallContext) -> None:
        owner = self._owner(context)
        task_id = str(task.id)
        if not task_id or len(task_id.encode('utf-8')) > MAX_TASK_ID_KEY_BYTES:
            raise InvalidParamsError('invalid or oversized task id')
        key = (owner, task_id)
        if self._rejected(task):
            # Rejected traffic has no history value and is attacker-amplifiable.
            # Do not retain it, and crucially do not replace an existing valid
            # task when an invalid request reuses that task ID.
            async with self._lock:
                self._prune_expired_locked(self._clock())
                existing = self._entries.get(key)
                if existing is not None and self._rejected(existing.task):
                    self._remove_locked(key)
            return
        copied = _copy_task(task)
        size = self._size(copied, owner)
        if size > self.max_bytes:
            raise TaskStoreCapacityError('task exceeds the task-store byte limit')
        now = self._clock()
        async with self._lock:
            self._prune_expired_locked(now)
            victims = self._evictions_for_locked(key, size)
            for victim in victims:
                self._remove_locked(victim)
            self._remove_locked(key)
            self._entries[key] = _Entry(copied, now, size)
            self._total_bytes += size

    async def get(
        self, task_id: str, context: ServerCallContext
    ) -> Task | None:
        owner = self._owner(context)
        if len(task_id.encode('utf-8')) > MAX_TASK_ID_KEY_BYTES:
            raise InvalidParamsError('oversized task id')
        async with self._lock:
            self._prune_expired_locked(self._clock())
            entry = self._entries.get((owner, task_id))
            return _copy_task(entry.task) if entry is not None else None

    async def list(
        self,
        params: ListTasksRequest,
        context: ServerCallContext,
    ) -> ListTasksResponse:
        owner = self._owner(context)
        async with self._lock:
            self._prune_expired_locked(self._clock())
            tasks = [
                _copy_task(entry.task)
                for (entry_owner, _), entry in self._entries.items()
                if entry_owner == owner
            ]

        if params.context_id:
            tasks = [task for task in tasks if task.context_id == params.context_id]
        if params.status:
            tasks = [task for task in tasks if task.status.state == params.status]
        if params.HasField('status_timestamp_after'):
            threshold = params.status_timestamp_after.ToJsonString()
            tasks = [
                task
                for task in tasks
                if task.HasField('status')
                and task.status.HasField('timestamp')
                and task.status.timestamp.ToJsonString() >= threshold
            ]

        tasks.sort(
            key=lambda task: (
                task.status.HasField('timestamp')
                if task.HasField('status')
                else False,
                task.status.timestamp.ToJsonString()
                if task.HasField('status') and task.status.HasField('timestamp')
                else '',
                task.id,
            ),
            reverse=True,
        )
        total_size = len(tasks)
        start_idx = 0
        if params.page_token:
            start_task_id = decode_page_token(params.page_token)
            for index, task in enumerate(tasks):
                if task.id == start_task_id:
                    start_idx = index
                    break
            else:
                raise InvalidParamsError(f'Invalid page token: {params.page_token}')
        page_size = params.page_size or DEFAULT_LIST_TASKS_PAGE_SIZE
        if page_size <= 0:
            raise InvalidParamsError('page size must be positive')
        end_idx = start_idx + min(page_size, self.max_count)
        next_page_token = (
            encode_page_token(tasks[end_idx].id) if end_idx < total_size else None
        )
        return ListTasksResponse(
            next_page_token=next_page_token,
            tasks=tasks[start_idx:end_idx],
            total_size=total_size,
            page_size=min(page_size, self.max_count),
        )

    async def delete(self, task_id: str, context: ServerCallContext) -> None:
        owner = self._owner(context)
        async with self._lock:
            self._prune_expired_locked(self._clock())
            self._remove_locked((owner, task_id))

    async def stats(self) -> dict[str, int]:
        """Return bounded aggregate counters for health checks and tests."""
        async with self._lock:
            self._prune_expired_locked(self._clock())
            return {
                'count': len(self._entries),
                'bytes': self._total_bytes,
                'owners': len({owner for owner, _ in self._entries}),
            }
