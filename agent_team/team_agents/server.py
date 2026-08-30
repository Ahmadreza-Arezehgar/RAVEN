"""A2A server assembly: Agent Card + JSON-RPC routes + optional bearer auth."""

from __future__ import annotations

import asyncio
import hmac
import math
import os
import socket

import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from a2a.auth.user import User
from a2a.server.agent_execution.active_task_registry import ActiveTaskRegistry
from a2a.server.context import ServerCallContext
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import (
    DefaultServerCallContextBuilder,
    create_agent_card_routes,
    create_jsonrpc_routes,
)
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentExtension,
    AgentInterface,
    AgentSkill,
)
from a2a.utils.signing import create_agent_card_signer

from .config import NodeConfig, validate_node_name
from .executor import TeamAgentExecutor
from .llm import build_brain
from .memory import TeamMemory
from .raven_identity import RavenIdentity, ReplayCache, verify_http_request
from .task_store import BoundedTaskStore
from .tools import ToolBox

MESH_EXTENSION_URI = 'https://raven.app/extensions/mesh-mailbox/v1'
CARD_KID_SUFFIX = '-card'
RAVEN_HTTP_HEADER_PREFIX = 'raven-request-'


class RavenPeerUser(User):
    """Authenticated A2A principal backed by a verified Raven device key."""

    def __init__(self, address: str, authenticated: bool = True) -> None:
        self.address = address
        self._authenticated = authenticated

    @property
    def is_authenticated(self) -> bool:
        return self._authenticated

    @property
    def user_name(self) -> str:
        return self.address


class RavenServerCallContextBuilder(DefaultServerCallContextBuilder):
    """Propagate only middleware-verified Raven ownership into the SDK."""

    def build(self, request: Request) -> ServerCallContext:
        context = super().build(request)
        owner = str(request.scope.get('state', {}).get('raven_owner', ''))
        if owner:
            authenticated = not owner.startswith('open:')
            context.user = RavenPeerUser(owner, authenticated=authenticated)
            context.tenant = owner
        return context


class OwnerScopedActiveTaskRegistry:
    """Keep the SDK's task-id-only live registry separate for every owner.

    The task store is owner scoped, but a2a-sdk's live ``ActiveTaskRegistry``
    is keyed only by task ID.  One registry per verified Raven principal keeps
    simultaneous task-ID collisions from joining another owner's
    producer, while retaining the SDK's normal lifecycle implementation.
    """

    def __init__(
        self,
        *,
        agent_executor,
        task_store,
        push_sender=None,
        max_owners: int,
    ) -> None:
        self.agent_executor = agent_executor
        self.task_store = task_store
        self.push_sender = push_sender
        self.max_owners = max_owners
        self._registries: dict[str, ActiveTaskRegistry] = {}
        self._lock = asyncio.Lock()
        self._closed = False

    @staticmethod
    def _owner(call_context: ServerCallContext) -> str:
        from a2a.utils.errors import InvalidParamsError

        owner = str(call_context.user.user_name)
        if not owner or len(owner.encode('utf-8')) > 1024:
            raise InvalidParamsError('invalid or oversized task owner')
        return owner

    async def get_or_create(self, task_id: str, call_context, **kwargs):
        from a2a.utils.errors import InvalidParamsError

        owner = self._owner(call_context)
        async with self._lock:
            if self._closed:
                raise RuntimeError('owner-scoped active task registry is closed')
            registry = self._registries.get(owner)
            if registry is None:
                if len(self._registries) >= self.max_owners:
                    raise InvalidParamsError('active task owner capacity exhausted')
                registry = ActiveTaskRegistry(
                    agent_executor=self.agent_executor,
                    task_store=self.task_store,
                    push_sender=self.push_sender,
                )
                self._registries[owner] = registry
        return await registry.get_or_create(
            task_id,
            call_context=call_context,
            **kwargs,
        )

    async def aclose(self) -> None:
        async with self._lock:
            if self._closed and not self._registries:
                return
            self._closed = True
            registries = list(self._registries.values())
            self._registries.clear()
        if registries:
            await asyncio.gather(
                *(registry.aclose() for registry in registries),
                return_exceptions=True,
            )


class RavenRequestHandler(DefaultRequestHandler):
    """Close SDK live-task lookups that otherwise bypass owner-scoped storage."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._active_task_registry = OwnerScopedActiveTaskRegistry(
            agent_executor=self.agent_executor,
            task_store=self.task_store,
            push_sender=self._push_sender,
            max_owners=max(1, int(getattr(self.task_store, 'max_count', 256))),
        )

    async def _authorize_cancellation(self, context: ServerCallContext) -> None:
        caller = str(context.user.user_name)
        if not caller:
            raise PermissionError('Raven cancellation authorization failed')
        if not self.agent_executor.require_signed:
            return
        peers, revoked = await asyncio.gather(
            asyncio.to_thread(self.agent_executor.current_peers),
            asyncio.to_thread(self.agent_executor.current_revocations),
        )
        if (
            not context.user.is_authenticated
            or caller not in peers
            or caller in revoked
        ):
            raise PermissionError('Raven cancellation authorization failed')

    async def on_cancel_task(self, params, context):
        from a2a.utils.errors import TaskNotFoundError
        from a2a.types import TaskState

        if await self.task_store.get(params.id, context) is None:
            raise TaskNotFoundError
        # Re-check live trust/revocation immediately before the SDK can cancel
        # a producer.  Authorization failures must not mutate task state.
        await self._authorize_cancellation(context)
        task = await super().on_cancel_task(params, context)
        if task is not None and task.status.state != TaskState.TASK_STATE_CANCELED:
            # a2a-sdk cancels its producer before invoking AgentExecutor.cancel;
            # under an unlucky queue-close race the executor's status event can
            # be dropped. Persist and return the terminal owner-scoped state so
            # cancellation can never report a still-working task.
            task.status.Clear()
            task.status.state = TaskState.TASK_STATE_CANCELED
            task.status.timestamp.GetCurrentTime()
            await self.task_store.save(task, context)
        return task

    async def on_subscribe_to_task(self, params, context):
        from a2a.utils.errors import TaskNotFoundError

        if await self.task_store.get(params.id, context) is None:
            raise TaskNotFoundError
        async for event in super().on_subscribe_to_task(params, context):
            yield event


class RavenRequestAuthenticator:
    """Verify request-level signatures before any SDK task lookup occurs."""

    _FIELDS = (
        'address', 'recipient', 'issued-at', 'expires-at', 'nonce',
        'algorithm', 'context', 'signature',
    )

    def __init__(
        self,
        config: NodeConfig,
        identity: RavenIdentity,
        executor: TeamAgentExecutor,
    ) -> None:
        self.config = config
        self.identity = identity
        self.executor = executor
        self.replay = ReplayCache(
            path=config.keys_dir / 'http-request-replay-cache.sqlite3'
        )

    def authenticate(
        self,
        headers: dict[str, str],
        *,
        method: str,
        target: str,
        body: bytes,
    ) -> tuple[bool, str, str]:
        present = any(name.startswith(RAVEN_HTTP_HEADER_PREFIX) for name in headers)
        if not present:
            return False, 'missing Raven request authorization', ''
        values: dict[str, object] = {}
        for field in self._FIELDS:
            value = headers.get(RAVEN_HTTP_HEADER_PREFIX + field, '')
            if not value or len(value.encode('utf-8')) > 4096:
                return True, 'incomplete Raven request authorization', ''
            values[field.replace('-', '_')] = value
        ok, reason, owner = verify_http_request(
            values,
            method=method,
            target=target,
            body=body,
            trusted_peers=self.executor.current_peers(),
            expected_recipient=self.identity.address,
            revoked=self.executor.current_revocations(),
            replay=self.replay,
        )
        return True, reason, owner if ok else ''


def _apply_security(card: AgentCard, enabled: bool) -> None:
    """Declare Bearer as the accepted auth scheme (OpenAPI-aligned)."""
    if not enabled:
        return
    scheme = card.security_schemes['bearer']
    scheme.http_auth_security_scheme.scheme = 'Bearer'
    req = card.security_requirements.add()
    req.schemes['bearer'].list.extend([])  # empty scope list = no scopes


def _sign_card(card: AgentCard, identity: RavenIdentity) -> AgentCard:
    """Attach a detached JWS (RFC 7515) signed with the node's Raven key."""
    signer = create_agent_card_signer(
        signing_key=identity.jwk_private(),
        protected_header={
            'kid': identity.fingerprint + CARD_KID_SUFFIX,
            'alg': 'EdDSA',
            'typ': 'JOSE',
        },
    )
    return signer(card)


def build_agent_card(config: NodeConfig, identity: RavenIdentity | None = None) -> AgentCard:
    description = config.role or f'{config.name} agent node'
    if not config.require_signed_tasks:
        description = f'⚠ OPEN MODE: accepts unsigned tasks ⚠ — {description}'
    card = AgentCard(
        name=config.name,
        description=description,
        version='1.1.0',
        supported_interfaces=[
            AgentInterface(
                url=config.resolved_public_url(),
                protocol_binding='JSONRPC',
                protocol_version='1.0',
            )
        ],
        capabilities=AgentCapabilities(
            streaming=True,
            extended_agent_card=True,
            extensions=[
                AgentExtension(
                    uri=MESH_EXTENSION_URI,
                    description=(
                        'EXPERIMENTAL PLAINTEXT DTN mailbox. Explicitly enabled; '
                        'not Raven E2EE and not a production transport.'
                    ),
                    required=False,
                )
            ] if config.enable_experimental_mailbox else [],
        ),
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
    _apply_security(card, bool(config.auth_token))
    if identity is not None:
        card = _sign_card(card, identity)
    return card


def build_extended_card(config: NodeConfig, identity: RavenIdentity) -> AgentCard:
    """Authenticated view: policy internals the public card must not leak."""
    ext = AgentCard(
        name=config.name,
        description=(
            f'{config.role or f"{config.name} agent node"} [extended] '
            f'llm={config.llm.provider}/{config.llm.model or "-"} '
            f'shell={"on" if config.allow_shell else "off"}'
        ),
        version='1.1.0',
        supported_interfaces=[
            AgentInterface(
                url=config.resolved_public_url(),
                protocol_binding='JSONRPC',
                protocol_version='1.0',
            )
        ],
        capabilities=AgentCapabilities(streaming=True),
        default_input_modes=['text/plain'],
        default_output_modes=['text/plain'],
        skills=[
            AgentSkill(id=s.id, name=s.name, description=s.description, tags=list(s.tags))
            for s in config.skills
        ],
    )
    _apply_security(ext, bool(config.auth_token))
    return _sign_card(ext, identity)


class BearerAuthMiddleware:
    """Keep the Agent Card public; protect every other HTTP route."""

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


class _RpcBodyTooLarge(Exception):
    pass


class RpcIngressLimitMiddleware:
    """Bound JSON-RPC bodies and in-flight work before the A2A SDK parses it.

    Limits are per server process.  The body is buffered only up to the
    configured cap, then replayed once to the downstream ASGI application.
    This also gives chunked requests the same bound as Content-Length requests.
    """

    def __init__(
        self,
        app,
        *,
        max_body_bytes: int,
        max_concurrent: int,
        body_timeout_seconds: float,
        queue_timeout_seconds: float,
        raven_authenticator: RavenRequestAuthenticator | None = None,
        require_raven_auth: bool = True,
    ) -> None:
        if max_body_bytes <= 0 or max_concurrent <= 0:
            raise ValueError('RPC ingress limits must be positive')
        if not math.isfinite(body_timeout_seconds) or body_timeout_seconds <= 0:
            raise ValueError('RPC body timeout must be finite and positive')
        if not math.isfinite(queue_timeout_seconds) or queue_timeout_seconds <= 0:
            raise ValueError('RPC queue timeout must be finite and positive')
        self.app = app
        self.max_body_bytes = max_body_bytes
        self.body_timeout_seconds = body_timeout_seconds
        self.queue_timeout_seconds = queue_timeout_seconds
        self.raven_authenticator = raven_authenticator
        self.require_raven_auth = require_raven_auth
        self._slots = asyncio.Semaphore(max_concurrent)

    @staticmethod
    async def _error(scope, receive, send, status: int, error: str) -> None:
        response = JSONResponse({'error': error}, status_code=status)
        await response(scope, receive, send)

    def _declared_length(self, scope) -> int | None:
        values = [
            value
            for name, value in scope.get('headers', [])
            if name.lower() == b'content-length'
        ]
        if not values:
            return None
        if len(values) != 1:
            raise ValueError('multiple content-length headers')
        raw = values[0]
        if not raw.isdigit():
            raise ValueError('invalid content-length header')
        return int(raw)

    async def _body(self, receive) -> bytes | None:
        async def collect() -> bytes | None:
            body = bytearray()
            while True:
                message = await receive()
                kind = message.get('type')
                if kind == 'http.disconnect':
                    return None
                if kind != 'http.request':
                    raise ValueError('unexpected ASGI request event')
                chunk = message.get('body', b'')
                if len(body) + len(chunk) > self.max_body_bytes:
                    raise _RpcBodyTooLarge
                body.extend(chunk)
                if not message.get('more_body', False):
                    return bytes(body)

        return await asyncio.wait_for(collect(), timeout=self.body_timeout_seconds)

    async def __call__(self, scope, receive, send):
        is_rpc = (
            scope.get('type') == 'http'
            and scope.get('path', '') == '/'
            and scope.get('method', '').upper() == 'POST'
        )
        if not is_rpc:
            await self.app(scope, receive, send)
            return

        try:
            declared = self._declared_length(scope)
        except ValueError:
            await self._error(scope, receive, send, 400, 'invalid content length')
            return
        if declared is not None and declared > self.max_body_bytes:
            await self._error(scope, receive, send, 413, 'request body too large')
            return

        try:
            await asyncio.wait_for(
                self._slots.acquire(), timeout=self.queue_timeout_seconds
            )
        except asyncio.TimeoutError:
            await self._error(scope, receive, send, 503, 'RPC capacity exhausted')
            return

        try:
            try:
                body = await self._body(receive)
            except _RpcBodyTooLarge:
                await self._error(scope, receive, send, 413, 'request body too large')
                return
            except asyncio.TimeoutError:
                await self._error(scope, receive, send, 408, 'request body timeout')
                return
            except ValueError:
                await self._error(scope, receive, send, 400, 'invalid request body')
                return
            if body is None:
                return

            if self.raven_authenticator is not None:
                raw_headers: dict[str, str] = {}
                duplicate_raven_header = False
                for name, value in scope.get('headers', []):
                    header_name = name.decode('latin-1').lower()
                    if (
                        header_name.startswith(RAVEN_HTTP_HEADER_PREFIX)
                        and header_name in raw_headers
                    ):
                        duplicate_raven_header = True
                    raw_headers[header_name] = value.decode('latin-1')
                if duplicate_raven_header:
                    await self._error(
                        scope,
                        receive,
                        send,
                        401,
                        'Raven request authorization failed',
                    )
                    return
                try:
                    raw_path = scope.get('raw_path') or scope.get(
                        'path', '/'
                    ).encode('ascii', errors='strict')
                    target = (
                        raw_path.decode('ascii', errors='strict')
                        if isinstance(raw_path, bytes)
                        else str(raw_path)
                    )
                    target.encode('ascii', errors='strict')
                    query = scope.get('query_string', b'')
                    if query:
                        target += '?' + query.decode('ascii', errors='strict')
                except (UnicodeDecodeError, UnicodeEncodeError):
                    await self._error(
                        scope, receive, send, 400, 'invalid request target'
                    )
                    return
                present, _reason, owner = await asyncio.to_thread(
                    self.raven_authenticator.authenticate,
                    raw_headers,
                    method=scope.get('method', 'POST'),
                    target=target,
                    body=body,
                )
                if not owner and (self.require_raven_auth or present):
                    await self._error(
                        scope,
                        receive,
                        send,
                        401,
                        'Raven request authorization failed',
                    )
                    return
                if not owner:
                    client = scope.get('client') or ('unknown', 0)
                    owner = f'open:{client[0]}'
                state = scope.get('state')
                if not isinstance(state, dict):
                    state = {}
                    scope['state'] = state
                state['raven_owner'] = owner

            delivered = False

            async def replay_receive():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {'type': 'http.request', 'body': body, 'more_body': False}
                return await receive()

            await self.app(scope, replay_receive, send)
        finally:
            self._slots.release()


async def health(request: Request) -> JSONResponse:
    return JSONResponse({'status': 'ok'})


async def raven_identity(request: Request) -> JSONResponse:
    rav: RavenIdentity = request.app.state.raven
    cfg: NodeConfig = request.app.state.config
    payload = {
        **rav.identity_card(),
        'card_kid': rav.fingerprint + CARD_KID_SUFFIX,
        'policy': {
            'require_signed_tasks': cfg.require_signed_tasks,
            'open_mode': not cfg.require_signed_tasks,
        },
        'experimental_plaintext_mailbox': cfg.enable_experimental_mailbox,
    }
    mb = getattr(request.app.state, 'mailbox_info', None)
    if mb:
        payload['mailbox'] = mb
    return JSONResponse(payload)


async def raven_activity(request: Request) -> JSONResponse:
    """Return bounded recent events only on explicitly authenticated nodes."""
    cfg: NodeConfig = request.app.state.config
    if not cfg.auth_token:
        # Event text can contain a prefix of an accepted task.  Signed-task mode
        # authenticates A2A writes; it does not authenticate an unrelated GET.
        # Keep monitoring disabled unless the operator configured transport auth.
        return JSONResponse(
            {'error': 'remote activity requires configured Bearer authentication'},
            status_code=403,
            headers={'Cache-Control': 'no-store'},
        )
    mem = request.app.state.memory
    try:
        limit = max(1, min(int(request.query_params.get('limit', 30)), 200))
    except ValueError:
        limit = 30
    try:
        # Filesystem projection is strictly bounded by TeamMemory, but it must
        # still run off the ASGI event loop so a slow disk cannot stall RPC work.
        events = await asyncio.wait_for(
            asyncio.to_thread(mem.recent_events, limit), timeout=3.0
        )
    except asyncio.TimeoutError:
        return JSONResponse(
            {'error': 'activity snapshot timed out'},
            status_code=503,
            headers={'Cache-Control': 'no-store'},
        )
    return JSONResponse(
        {'events': events},
        headers={'Cache-Control': 'no-store', 'Vary': 'Authorization'},
    )


def build_app(config: NodeConfig) -> Starlette:
    # Callers can mutate a dataclass after __post_init__; revalidate before its
    # name is used as an output/delta path component.
    config.name = validate_node_name(config.name)
    memory = TeamMemory(config.repo_path, auto_commit=config.auto_commit_memory)
    toolbox = ToolBox(config, memory)
    brain = build_brain(config, toolbox)
    identity = RavenIdentity.load_or_create(config.keys_dir)
    executor = TeamAgentExecutor(
        config,
        brain,
        memory,
        trusted_peers=config.trusted_peers,
        require_signed=config.require_signed_tasks,
        identity=identity,
    )
    card = build_agent_card(config, identity)
    ext_card = build_extended_card(config, identity)

    task_store = BoundedTaskStore(
        max_count=config.task_store_max_count,
        max_bytes=config.task_store_max_bytes,
        ttl_seconds=config.task_store_ttl_seconds,
    )
    handler = RavenRequestHandler(
        agent_executor=executor,
        task_store=task_store,
        agent_card=card,
        extended_agent_card=ext_card,
    )
    context_builder = RavenServerCallContextBuilder()
    routes = [
        *create_agent_card_routes(card),
        *create_jsonrpc_routes(
            handler,
            rpc_url='/',
            context_builder=context_builder,
        ),
        Route('/health', health, methods=['GET']),
        Route('/raven/identity', raven_identity, methods=['GET']),
        Route('/raven/activity', raven_activity, methods=['GET']),
    ]
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def _lifespan(a):
        _start_services(a)
        try:
            yield
        finally:
            _stop_services(a)
            await a.state.handler.aclose()

    app = Starlette(routes=routes, lifespan=_lifespan)
    app.state.raven = identity
    app.state.config = config
    app.state.brain = brain
    app.state.executor = executor
    app.state.handler = handler
    app.state.task_store = task_store
    app.state.memory = memory
    request_authenticator = RavenRequestAuthenticator(config, identity, executor)
    app.add_middleware(
        RpcIngressLimitMiddleware,
        max_body_bytes=config.max_rpc_body_bytes,
        max_concurrent=config.max_concurrent_rpc,
        body_timeout_seconds=config.rpc_body_timeout_seconds,
        queue_timeout_seconds=config.rpc_queue_timeout_seconds,
        raven_authenticator=request_authenticator,
        require_raven_auth=config.require_signed_tasks,
    )
    if config.auth_token:
        # Keep the Starlette object (and its state/lifespan) as the returned app;
        # wrapping it by assignment made ``serve`` crash on ``app.state``.  Add
        # this last so Bearer rejection stays outside body buffering/work slots.
        app.add_middleware(BearerAuthMiddleware, token=config.auth_token)
    return app


# ------------------------------------------------- background services ----
def _revocations(cfg: NodeConfig) -> set[str]:
    """Hot-reload revocations; configured policy failures are fatal/closed."""
    if not cfg.revocations_file:
        return set()
    from .raven_identity import load_revocations

    return load_revocations(cfg.revocations_file)


def _start_services(app) -> None:
    """mDNS advertise + git store-and-forward relay poller."""
    import os
    import math
    import threading
    import time

    from . import discovery

    cfg: NodeConfig = app.state.config
    stop_event = threading.Event()
    app.state.service_stop = stop_event
    try:
        relay_interval = float(os.environ.get('RDAP_POLL', '20'))
    except ValueError as exc:
        raise ValueError('RDAP_POLL must be a number of seconds') from exc
    if not math.isfinite(relay_interval) or not 1 <= relay_interval <= 3600:
        raise ValueError('RDAP_POLL must be between 1 and 3600 seconds')

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
        import hashlib
        import json as _json
        import os
        import stat

        from . import mesh as mesh_mod
        from .raven_identity import verify_delegation
        from .relay import GitRelay

        relay_memory = TeamMemory(
            cfg.repo_path, auto_commit=cfg.auto_commit_memory
        )
        try:
            relay_memory.require_shared_upstream()
        except Exception as exc:  # noqa: BLE001
            if not cfg.enable_experimental_mailbox:
                print(
                    f'* [{cfg.name}] Git relay idle (direct A2A remains active): '
                    f'{exc}',
                    flush=True,
                )
                return

        r = GitRelay(
            relay_memory,
            app.state.raven,
            trusted_peers_file=cfg.trusted_peers_file or None,
            trusted_peers=cfg.trusted_peers,
            revocations_file=cfg.revocations_file or None,
        )
        # --- optional local swarm mailbox store (T3 transport) ----------
        store = None
        binp = None
        seen_file = r.memory.resolve_in_repo('.team/mesh-seen.json')
        max_mesh_seen = 512

        def _load_mesh_seen() -> dict[str, int]:
            try:
                metadata = os.lstat(seen_file)
            except FileNotFoundError:
                return {}
            if (
                seen_file.is_symlink()
                or not stat.S_ISREG(metadata.st_mode)
                or metadata.st_nlink != 1
                or metadata.st_size > 128 * 1024
            ):
                raise RuntimeError('mesh seen cache is not a bounded regular file')
            flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0)
            flags |= getattr(os, 'O_NOFOLLOW', 0)
            descriptor = os.open(seen_file, flags)
            try:
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or opened.st_nlink != 1
                    or (opened.st_dev, opened.st_ino)
                    != (metadata.st_dev, metadata.st_ino)
                ):
                    raise RuntimeError('mesh seen cache changed during open')
                raw = os.read(descriptor, 128 * 1024 + 1)
            finally:
                os.close(descriptor)
            if len(raw) > 128 * 1024:
                raise RuntimeError('mesh seen cache exceeds its byte limit')
            parsed = _json.loads(raw.decode('utf-8'))
            if not isinstance(parsed, dict):
                raise RuntimeError('mesh seen cache must be a JSON object')
            cleaned = {}
            for key, value in parsed.items():
                if (
                    isinstance(key, str)
                    and len(key) == 64
                    and all(char in '0123456789abcdef' for char in key)
                    and isinstance(value, int)
                    and not isinstance(value, bool)
                    and value >= 0
                ):
                    cleaned[key] = value
            return dict(
                sorted(cleaned.items(), key=lambda item: (item[1], item[0]))[
                    -max_mesh_seen:
                ]
            )

        def _save_mesh_seen(seen: dict[str, int]) -> None:
            bounded = dict(
                sorted(seen.items(), key=lambda item: (item[1], item[0]))[
                    -max_mesh_seen:
                ]
            )
            r._write_envelope(seen_file, bounded)

        try:
            binp = mesh_mod.find_swarm_bin() if cfg.enable_experimental_mailbox else None
            if binp and cfg.enable_experimental_mailbox:
                print(
                    f'! [{cfg.name}] EXPERIMENTAL PLAINTEXT MAILBOX ENABLED; '
                    'payloads are not Raven E2EE',
                    flush=True,
                )
                store = mesh_mod.serve_store(
                    binp,
                    r.memory.resolve_in_repo('.team/mesh-store'),
                    cfg.advertised_host or '',
                )
                app.state.mailbox_proc = store['proc']
                app.state.mailbox_info = {
                    'multiaddr': store['multiaddr'],
                    'peer_id': store['peer_id'],
                }
                print(f'* [{cfg.name}] mesh mailbox up '
                      f'{store["multiaddr"][:38]}…', flush=True)
                seen = _load_mesh_seen()
                if not seen_file.exists():
                    _save_mesh_seen(seen)
        except Exception as exc:  # noqa: BLE001
            print(f'* [{cfg.name}] mesh mailbox unavailable: {exc!r}',
                  flush=True)

        def _drain_mesh() -> int:
            nonlocal store

            if not (store and binp):
                return 0
            seen = _load_mesh_seen()
            my_addr = app.state.raven.address
            tag_hex = mesh_mod.store_tag(my_addr).hex()
            client_dir = r.memory.resolve_in_repo('.team/mesh-client')
            try:
                objs = mesh_mod.mailbox_get_all(
                    binp, client_dir,
                    store['multiaddr'], store['peer_id'], tag_hex)
            except Exception as exc:  # noqa: BLE001
                msg = str(exc).lower()
                if 'refused' in msg or 'dial' in msg or 'timeout' in msg:
                    print(f'* [{cfg.name}] mesh store lost — restarting…',
                          flush=True)
                    try:
                        store['proc'].kill()
                    except Exception:  # noqa: BLE001
                        pass
                    time.sleep(1)
                    store = mesh_mod.serve_store(
                        binp,
                        r.memory.resolve_in_repo('.team/mesh-store'),
                        cfg.advertised_host or '')
                    app.state.mailbox_info = {
                        'multiaddr': store['multiaddr'],
                        'peer_id': store['peer_id'],
                    }
                    objs = mesh_mod.mailbox_get_all(
                        binp, client_dir,
                        store['multiaddr'], store['peer_id'], tag_hex)
                else:
                    raise
            n = 0
            for obj in objs:
                object_key = hashlib.sha256(obj).hexdigest()
                if object_key in seen:
                    continue
                try:
                    tid, payload_text = mesh_mod.unwrap_body(obj)
                    payload = _json.loads(payload_text)
                    meta, sender, tid, text = r._validated_envelope(
                        payload, 'task'
                    )
                except Exception:  # noqa: BLE001
                    seen[object_key] = int(time.time())
                    continue
                if sender != str(meta.get('sender', '')):
                    ok, why = False, 'outer sender does not match signed sender'
                elif str(payload.get('to', '')) != my_addr:
                    ok, why = False, 'outer recipient mismatch'
                else:
                    ok, why = verify_delegation(
                        meta, text,
                        trusted_peers=r.peers(), required=True,
                        revoked=_revocations(cfg),
                        replay=r.replay_cache,
                        expected_recipient=my_addr,
                        expected_task_id=tid,
                        expected_kind='task',
                        consume_replay=False,
                    )
                if not ok:
                    r.memory.log_event(cfg.name,
                                       f'mesh REJECT {tid}: {why}')
                else:
                    signature = str(meta['signature'])
                    outcome_state, reply = r.outcomes.claim(
                        signature, int(meta['expires_at'])
                    )
                    if outcome_state == 'interrupted':
                        reply = r._build_reply(
                            tid,
                            sender,
                            'mailbox execution was interrupted before a durable '
                            'answer; it was not automatically retried',
                        )
                        r.outcomes.complete(
                            signature, int(meta['expires_at']), reply
                        )
                    elif outcome_state == 'new':
                        try:
                            res = loop.run_until_complete(
                                app.state.brain.run(text)
                            )
                        except Exception as exc:  # noqa: BLE001
                            res = f'{type(exc).__name__}: {exc}'
                        reply = r._build_reply(tid, sender, str(res))
                        r.outcomes.complete(
                            signature, int(meta['expires_at']), reply
                        )
                    if not isinstance(reply, dict):
                        raise RuntimeError('mesh outcome did not contain a reply')
                    # ``tid`` is peer-signed, not locally chosen.  Keep it in
                    # the signed reply body, but never make it a path
                    # component (``../`` and Windows device names included).
                    r._write_envelope(r._reply_path(sender, tid), reply)
                    n += 1
                    r.memory.log_event(cfg.name, f'mesh✓ {tid} ← {sender[:14]}…')
                    try:
                        from .chat import TeamChat

                        TeamChat(r.memory).post(
                            cfg.name,
                            f'✅ {tid}: {str(reply.get("text", ""))[:110]}',
                        )
                    except Exception:  # noqa: BLE001
                        pass
                seen[object_key] = int(time.time())
            if n or objs:
                _save_mesh_seen(seen)
            if n:
                r._commit_push(f'relay(mesh answers): {n}')
            return n

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        while not stop_event.wait(relay_interval):
            try:
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
    stop = getattr(app.state, 'service_stop', None)
    if stop:
        stop.set()
    proc = getattr(app.state, 'mailbox_proc', None)
    if proc and proc.poll() is None:
        proc.terminate()


def serve(config: NodeConfig) -> None:
    # Bind the exact advertised port first.  Silent fallback made an invite for
    # port N advertise a node that actually moved to N+1 on startup.
    requested_port = config.port
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if os.name == 'nt' and hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    else:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((config.host, config.port))
        sock.listen(128)
        config.port = int(sock.getsockname()[1])
    except OSError as exc:
        sock.close()
        raise RuntimeError(
            f'configured port {requested_port} is unavailable; choose one explicit '
            'port and use it for both `rdap invite` and `rdap start`'
        ) from exc

    try:
        app = build_app(config)
        rav: RavenIdentity = app.state.raven
        cfg: NodeConfig = app.state.config
        print(  # noqa: T201
            f'* [{cfg.name}] serving A2A on {cfg.host}:{cfg.port} '
            f'(public url: {cfg.resolved_public_url()}, repo: {cfg.repo_path}, '
            f'llm: {cfg.llm.provider}/{cfg.llm.model or "-"})',
            flush=True,
        )
        if not cfg.require_signed_tasks:
            print(
                '! ! ! OPEN MODE: UNSIGNED TASKS ARE ACCEPTED. '
                'Any reachable client may invoke this agent. ! ! !',
                flush=True,
            )
        if cfg.enable_experimental_mailbox:
            print(
                '! EXPERIMENTAL PLAINTEXT MAILBOX explicitly enabled; '
                'do not treat it as confidential or production-ready.',
                flush=True,
            )
        print(  # noqa: T201
            f'* [{cfg.name}] raven id {rav.address} ({rav.display_address}) '
            f'fp:{rav.fingerprint} signed-only={cfg.require_signed_tasks} '
            f'peers={len(cfg.trusted_peers)}',
            flush=True,
        )

        # Pass the already-bound socket object through Uvicorn's public Server
        # API.  ``uvicorn.run(..., fd=...)`` reconstructs it with
        # ``socket.fromfd``, which is POSIX-only.  Supplying ``sockets`` keeps
        # the bind-before-run TOCTOU protection and lets Uvicorn use its native
        # Windows socket-sharing path when necessary.  Pin a single worker:
        # this in-process app/state cannot safely be multiplied by an ambient
        # WEB_CONCURRENCY setting.
        server = uvicorn.Server(
            uvicorn.Config(
                app,
                host=cfg.host,
                port=cfg.port,
                log_level='warning',
                workers=1,
                backlog=128,
            )
        )
        try:
            server.run(sockets=[sock])
        except KeyboardInterrupt:  # match the convenience uvicorn.run wrapper
            pass
    finally:
        # Uvicorn normally takes ownership once startup succeeds; close is
        # idempotent and also covers app/config/startup failures before that.
        sock.close()
