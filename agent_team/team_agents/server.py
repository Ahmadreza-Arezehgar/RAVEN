"""A2A server assembly: Agent Card + JSON-RPC routes + optional bearer auth."""

from __future__ import annotations

import asyncio
import hmac

import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
)

from .config import NodeConfig
from .executor import TeamAgentExecutor
from .llm import build_brain
from .memory import TeamMemory
from .raven_identity import RavenIdentity
from .tools import ToolBox


def build_agent_card(config: NodeConfig) -> AgentCard:
    return AgentCard(
        name=config.name,
        description=config.role or f'{config.name} agent node',
        version='1.0.0',
        supported_interfaces=[
            AgentInterface(
                url=config.resolved_public_url(),
                protocol_binding='JSONRPC',
                protocol_version='1.0',
            )
        ],
        capabilities=AgentCapabilities(streaming=False),
        default_input_modes=['text/plain'],
        default_output_modes=['text/plain'],
        skills=[
            AgentSkill(
                id=s.id,
                name=s.name,
                description=s.description,
                tags=list(s.tags),
            )
            for s in config.skills
        ],
    )


class BearerAuthMiddleware:
    """ASGI middleware: Agent Card stays public; RPC requires Bearer token."""

    def __init__(self, app, token: str) -> None:
        self.app = app
        self.token = token.encode()

    async def __call__(self, scope, receive, send):
        if scope['type'] == 'http' and not scope.get(
            'path', ''
        ).startswith('/.well-known/agent-card'):
            headers = {k.lower(): v for k, v in scope.get('headers', [])}
            provided = headers.get(b'authorization', b'')
            expected = b'Bearer ' + self.token
            if not hmac.compare_digest(provided, expected):
                resp = JSONResponse({'error': 'unauthorized'}, status_code=401)
                await resp(scope, receive, send)
                return
        await self.app(scope, receive, send)


async def health(request: Request) -> JSONResponse:
    return JSONResponse({'status': 'ok'})


async def raven_identity(request: Request) -> JSONResponse:
    rav: RavenIdentity = request.app.state.raven
    cfg: NodeConfig = request.app.state.config
    return JSONResponse(
        {
            **rav.identity_card(),
            'policy': {
                'require_signed_tasks': cfg.require_signed_tasks,
                'trusted_peers': sorted(cfg.trusted_peers),
            },
        }
    )


def build_app(config: NodeConfig) -> Starlette:
    memory = TeamMemory(config.repo_path, auto_commit=config.auto_commit_memory)
    toolbox = ToolBox(config, memory)
    cancel_event = asyncio.Event()
    brain = build_brain(config, toolbox, cancel_event)
    executor = TeamAgentExecutor(
        config,
        brain,
        memory,
        trusted_peers=config.trusted_peers,
        require_signed=config.require_signed_tasks,
        cancel_event=cancel_event,
    )
    card = build_agent_card(config)
    identity = RavenIdentity.load_or_create(config.keys_dir)

    handler = DefaultRequestHandler(
        agent_executor=executor,
        task_store=InMemoryTaskStore(),
        agent_card=card,
    )
    routes = [
        *create_agent_card_routes(card),
        *create_jsonrpc_routes(handler, rpc_url='/'),
        Route('/health', health, methods=['GET']),
        Route('/raven/identity', raven_identity, methods=['GET']),
    ]
    app = Starlette(routes=routes)
    app.state.raven = identity
    app.state.config = config
    if config.auth_token:
        app = BearerAuthMiddleware(app, config.auth_token)  # type: ignore[assignment]
    return app


def serve(config: NodeConfig) -> None:
    app = build_app(config)
    rav: RavenIdentity = app.state.raven
    config = app.state.config
    print(  # noqa: T201
        f'* [{config.name}] serving A2A on {config.host}:{config.port} '
        f'(public url: {config.resolved_public_url()}, repo: {config.repo_path}, '
        f'llm: {config.llm.provider}/{config.llm.model or "-"})'
    )
    print(  # noqa: T201
        f'* [{config.name}] raven id {rav.address} ({rav.display_address}) '
        f'fp:{rav.fingerprint} signed-only={config.require_signed_tasks} '
        f'peers={len(config.trusted_peers)}'
    )
    uvicorn.run(app, host=config.host, port=config.port, log_level='warning')
