"""Delegating client: send Raven-signed tasks to teammate A2A nodes."""

from __future__ import annotations

import asyncio
import uuid

import httpx

import a2a.client.client as a2a_client_mod
from a2a.client import A2ACardResolver, ClientConfig, ClientFactory
from a2a.types import Role

from .raven_identity import RavenIdentity, sign_delegation


def _response_text(response) -> str:
    """Pull the best human-readable text out of a StreamResponse."""
    task = getattr(response, 'task', None)
    if task is not None and getattr(task, 'id', ''):
        texts: list[str] = []
        for artifact in getattr(task, 'artifacts', None) or []:
            for part in artifact.parts or []:
                t = getattr(part, 'text', None)
                if t:
                    texts.append(t)
        status = task.status
        msg_text = ''
        message = getattr(status, 'message', None)
        if message is not None:
            for part in message.parts or []:
                t = getattr(part, 'text', None)
                if t:
                    msg_text = t
        try:
            from a2a.types import TaskState

            state_name = (
                TaskState.Name(status.state) if isinstance(status.state, int) else str(status.state)
            )
        except Exception:  # noqa: BLE001
            state_name = str(getattr(status, 'state', '?'))
        head = f'task {task.id[:8]} → {state_name.removeprefix("TASK_STATE_").lower()}'
        if msg_text:
            head += f' | {msg_text}'
        return '\n'.join([head, *texts])
    message = getattr(response, 'message', None)
    if message is not None and getattr(message, 'parts', None):
        for part in message.parts or []:
            t = getattr(part, 'text', None)
            if t:
                return t
    return '(empty response)'


async def send_task(
    url: str,
    text: str,
    *,
    identity: RavenIdentity | None = None,
    timeout: float = 180.0,
) -> str:
    base_url = url.rstrip('/') + '/'
    async with httpx.AsyncClient(timeout=timeout) as http:
        card = await A2ACardResolver(httpx_client=http, base_url=base_url).get_agent_card()
        factory = ClientFactory(ClientConfig(streaming=False, polling=False))
        client = factory.create(card)
        try:
            message = a2a_client_mod.SendMessageRequest().message.__class__()
            message.message_id = uuid.uuid4().hex
            message.role = Role.Value('ROLE_USER')
            part = message.parts.add()
            part.text = text
            if identity is not None:
                block = sign_delegation(identity, text)
                for key, value in block.items():
                    message.metadata[f'raven.{key}'] = str(value)
            request = a2a_client_mod.SendMessageRequest(message=message)

            pieces: list[str] = []
            async for response in client.send_message(request):
                pieces.append(_response_text(response))
            return '\n'.join(pieces) or '(empty response)'
        finally:
            await client.close()


async def _send_many(urls: list[str], text: str, identity) -> list[str]:
    results = await asyncio.gather(
        *(send_task(u, text, identity=identity) for u in urls), return_exceptions=True
    )
    out = []
    for url, res in zip(urls, results):
        out.append(f'== {url}\n{res if not isinstance(res, BaseException) else repr(res)}')
    return out


def main() -> None:  # pragma: no cover - CLI entry
    import argparse

    p = argparse.ArgumentParser(description='Raven-signed A2A delegation client')
    p.add_argument('--url', action='append', required=True, help='teammate node URL (repeatable)')
    p.add_argument('--text', required=True, help='task text to delegate')
    p.add_argument('--keys-dir', default='', help='sender raven keys dir')
    args = p.parse_args()

    identity = RavenIdentity.load_or_create(args.keys_dir) if args.keys_dir else None
    results = asyncio.run(_send_many(args.url, args.text, identity))
    print('\n\n'.join(results))


if __name__ == '__main__':
    main()
