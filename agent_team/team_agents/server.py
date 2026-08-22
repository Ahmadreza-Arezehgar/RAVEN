"""A2A server assembly: Agent Card + JSON-RPC routes + optional bearer auth."""

from __future__ import annotations

import asyncio
import hmac
import socket

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
    payload = {
        **rav.identity_card(),
        'policy': {
            'require_signed_tasks': cfg.require_signed_tasks,
            'trusted_peers': sorted(cfg.trusted_peers),
        },
    }
    mb = getattr(request.app.state, 'mailbox_info', None)
    if mb:
        payload['mailbox'] = mb
    return JSONResponse(payload)


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
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def _lifespan(a):
        _start_services(a)
        yield
        _stop_services(a)

    app = Starlette(routes=routes, lifespan=_lifespan)
    app.state.raven = identity
    app.state.config = config
    app.state.brain = brain
    if config.auth_token:
        app = BearerAuthMiddleware(app, config.auth_token)  # type: ignore[assignment]
    return app


# ------------------------------------------------- background services ----
def _start_services(app) -> None:
    """mDNS advertise + git store-and-forward relay poller."""
    import os
    import threading
    import time

    from . import discovery

    cfg: NodeConfig = app.state.config

    # --- mDNS (LAN discovery) — own thread: zeroconf is blocking -------
    def _mdns_worker():
        try:
            zc, infos = discovery.advertise(
                cfg.name.replace(' ', '-'), cfg.port,
                app.state.raven.address, cfg.advertised_host or '')
            app.state.zc, app.state.zc_infos = zc, infos
            if zc:
                print(f'* [{cfg.name}] mDNS advertised as _rdap._tcp '
                      f'(find me: ./rdap discover)', flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f'* [{cfg.name}] mDNS unavailable: {exc!r}', flush=True)

    threading.Thread(target=_mdns_worker, daemon=True,
                     name=f'mdns-{cfg.name}').start()

    # --- git relay + mesh mailbox worker thread (DTN-style always-on) ---
    def _relay_worker():
        import json as _json
        import os

        from . import mesh as mesh_mod
        from .raven_identity import verify_delegation
        from .relay import GitRelay

        interval = float(os.environ.get('RDAP_POLL', '20'))
        r = GitRelay(
            TeamMemory(cfg.repo_path, auto_commit=cfg.auto_commit_memory),
            app.state.raven,
            trusted_peers_file=cfg.trusted_peers_file or None,
            trusted_peers=cfg.trusted_peers,
        )
        # --- optional local swarm mailbox store (T3 transport) ----------
        store = None
        binp = None
        seen_file = r.memory.resolve_in_repo('.team/mesh-seen.json')
        try:
            binp = mesh_mod.find_swarm_bin()
            if binp:
                store = mesh_mod.serve_store(
                    binp, r.memory.resolve_in_repo('.team/mesh-store'))
                app.state.mailbox_info = {
                    'multiaddr': store['multiaddr'],
                    'peer_id': store['peer_id'],
                }
                print(f'* [{cfg.name}] mesh mailbox up '
                      f'{store["multiaddr"][:38]}…', flush=True)
                if not seen_file.exists():
                    seen_file.write_text('{}', encoding='utf-8')
        except Exception as exc:  # noqa: BLE001
            print(f'* [{cfg.name}] mesh mailbox unavailable: {exc!r}',
                  flush=True)

        def _drain_mesh() -> int:
            if not (store and binp):
                return 0
            seen = _json.loads(seen_file.read_text(encoding='utf-8'))
            my_addr = app.state.raven.address
            tag_hex = mesh_mod.store_tag(my_addr).hex()
            objs = mesh_mod.mailbox_get_all(
                binp,
                r.memory.resolve_in_repo('.team/mesh-client'),
                store['multiaddr'], store['peer_id'], tag_hex)
            n = 0
            for obj in objs:
                try:
                    tid, payload_text = mesh_mod.unwrap_body(obj)
                except Exception:  # noqa: BLE001
                    continue
                if tid in seen:
                    continue
                payload = _json.loads(payload_text)
                ok, why = verify_delegation(
                    payload.get('raven', {}), payload.get('text', ''),
                    trusted_peers=r.peers(), required=True)
                sender = payload.get('from', '?')
                text = payload.get('text', '')
                if not ok:
                    r.memory.log_event(cfg.name,
                                       f'mesh REJECT {tid}: {why}')
                else:
                    try:
                        res = loop.run_until_complete(
                            app.state.brain.run(text))
                    except Exception as exc:  # noqa: BLE001
                        res = f'{type(exc).__name__}: {exc}'
                    out = r._slot('outbox', sender)
                    (out / f'{tid}.json').write_text(_json.dumps({
                        'id': tid, 'kind': 'answer',
                        'from': my_addr, 'to': sender, 'text': res,
                        'via': 'mesh',
                    }), encoding='utf-8')
                    n += 1
                    r.memory.log_event(cfg.name, f'mesh✓ {tid} ← {sender[:14]}…')
                seen[tid] = True
            if n or objs:
                seen_file.write_text(_json.dumps(seen), encoding='utf-8')
            if n:
                r._commit_push(f'relay(mesh answers): {n}')
            return n

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        while True:
            time.sleep(interval)
            try:
                r.pull()
                n = loop.run_until_complete(r.process_inbox(app.state.brain.run))
                n += _drain_mesh()
                if n:
                    print(f'* [{cfg.name}] relay processed {n} offline task(s)',
                          flush=True)
            except Exception as exc:  # noqa: BLE001
                print(f'* [{cfg.name}] relay tick failed: {exc!r}', flush=True)

    t = threading.Thread(target=_relay_worker, daemon=True,
                         name=f'relay-{cfg.name}')
    t.start()


def _stop_services(app) -> None:
    from . import discovery

    discovery.stop_advertise(getattr(app.state, 'zc', None),
                             getattr(app.state, 'zc_infos', None))


def serve(config: NodeConfig) -> None:
    # bind FIRST so concurrent nodes can never race for the same port
    sock = None
    start = config.port
    for p in range(start, start + 20):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((config.host, p))
            s.listen(128)
            sock = s
            config.port = p
            break
        except OSError:
            s.close()
            continue
    if sock is None:
        raise RuntimeError(f'no free port in {start}..{start + 19}')

    app = build_app(config)
    rav: RavenIdentity = app.state.raven
    cfg: NodeConfig = app.state.config
    print(  # noqa: T201
        f'* [{cfg.name}] serving A2A on {cfg.host}:{cfg.port} '
        f'(public url: {cfg.resolved_public_url()}, repo: {cfg.repo_path}, '
        f'llm: {cfg.llm.provider}/{cfg.llm.model or "-"})',
        flush=True,
    )
    print(  # noqa: T201
        f'* [{cfg.name}] raven id {rav.address} ({rav.display_address}) '
        f'fp:{rav.fingerprint} signed-only={cfg.require_signed_tasks} '
        f'peers={len(cfg.trusted_peers)}',
        flush=True,
    )
    uvicorn.run(app, host=cfg.host, port=cfg.port, log_level='warning', fd=sock.fileno())
