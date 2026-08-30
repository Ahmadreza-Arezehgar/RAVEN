"""Delegating client: send Raven-signed tasks to teammate A2A nodes."""

from __future__ import annotations

import asyncio
import json
import os
import uuid
from pathlib import Path
from urllib.parse import unquote, urlsplit

import httpx
import jwt
from jwt import PyJWK

import a2a.client.client as a2a_client_mod
from a2a.client import ClientConfig, ClientFactory
from a2a.types import Role
from a2a.utils.signing import create_signature_verifier

from .raven_identity import (
    RavenIdentity,
    ReplayCache,
    fingerprint_for_public_key,
    sign_delegation,
    sign_http_request,
    validate_address_public_key,
    verify_delegation,
)
from .config import read_secret_file


class CardVerificationError(RuntimeError):
    """Agent card/reply is missing or does not match the pinned peer."""


class UnsafeBearerTransportError(ValueError):
    """A Bearer credential would leave over an unauthenticated network path."""


class PublicDocumentTooLarge(ValueError):
    """A remote card/identity document exceeded the public metadata cap."""


MAX_PUBLIC_DOCUMENT_BYTES = 256 * 1024


def _declared_public_size(headers: httpx.Headers, limit: int) -> None:
    raw = headers.get('content-length')
    if raw is None:
        return
    try:
        declared = int(raw)
    except ValueError as exc:
        raise ValueError('remote document has invalid Content-Length') from exc
    if declared < 0 or declared > limit:
        raise PublicDocumentTooLarge('remote document exceeds the metadata byte limit')


async def get_bounded_json_async(
    client: httpx.AsyncClient,
    url: str,
    *,
    max_bytes: int = MAX_PUBLIC_DOCUMENT_BYTES,
):
    """Fetch and parse one bounded JSON document without unbounded buffering."""
    data = bytearray()
    async with client.stream('GET', url) as response:
        response.raise_for_status()
        _declared_public_size(response.headers, max_bytes)
        async for chunk in response.aiter_bytes():
            if len(data) + len(chunk) > max_bytes:
                raise PublicDocumentTooLarge(
                    'remote document exceeds the metadata byte limit'
                )
            data.extend(chunk)
    return json.loads(data)


def get_bounded_json(
    client: httpx.Client,
    url: str,
    *,
    max_bytes: int = MAX_PUBLIC_DOCUMENT_BYTES,
):
    """Synchronous counterpart used by the RDAP trust/ping wizard."""
    data = bytearray()
    with client.stream('GET', url) as response:
        response.raise_for_status()
        _declared_public_size(response.headers, max_bytes)
        for chunk in response.iter_bytes():
            if len(data) + len(chunk) > max_bytes:
                raise PublicDocumentTooLarge(
                    'remote document exceeds the metadata byte limit'
                )
            data.extend(chunk)
    return json.loads(data)


RAVEN_HTTP_HEADER_PREFIX = 'Raven-Request-'


class RavenHttpAuth(httpx.Auth):
    """Bind every A2A RPC request to one pinned Raven sender/recipient pair."""

    requires_request_body = True

    def __init__(self, identity: RavenIdentity, recipient: str) -> None:
        self.identity = identity
        self.recipient = recipient

    def auth_flow(self, request):
        raw_path = request.url.raw_path
        target = raw_path.decode('ascii') if isinstance(raw_path, bytes) else str(raw_path)
        block = sign_http_request(
            self.identity,
            recipient=self.recipient,
            method=request.method,
            target=target,
            body=request.content,
        )
        for key, value in block.items():
            request.headers[RAVEN_HTTP_HEADER_PREFIX + key.replace('_', '-').title()] = str(
                value
            )
        yield request


def resolve_bearer_token(token: str = '', token_file: str | Path = '') -> str:
    """Resolve an outbound peer credential, never an inbound server secret."""
    if token:
        return token
    path = str(token_file or os.environ.get('RDAP_BEARER_TOKEN_FILE', ''))
    if path:
        return read_secret_file(path)
    return os.environ.get('RDAP_BEARER_TOKEN', '')


def _canonical_endpoint(url: str) -> tuple[str, str, int, str]:
    """Return a comparison key for an HTTP(S) endpoint or raise."""
    raw = str(url)
    if not raw or raw != raw.strip():
        raise ValueError('endpoint URL must be non-empty with no outer whitespace')
    decoded = unquote(raw)
    if '\\' in decoded or any(
        char.isspace() or ord(char) < 32 or ord(char) == 127 for char in decoded
    ):
        raise ValueError('endpoint URL contains unsafe whitespace/control characters')
    try:
        parsed = urlsplit(raw)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as exc:
        raise ValueError(f'malformed endpoint URL: {exc}') from exc
    scheme = parsed.scheme.lower()
    if scheme not in {'http', 'https'}:
        raise ValueError('endpoint URL scheme must be http or https')
    if not parsed.netloc or not hostname:
        raise ValueError('endpoint URL must include a hostname')
    if parsed.username is not None or parsed.password is not None:
        raise ValueError('endpoint URL credentials are not allowed')
    if '%' in parsed.netloc:
        raise ValueError('percent-encoding is not allowed in the endpoint authority')
    if parsed.query or parsed.fragment:
        raise ValueError('endpoint URL query strings/fragments are not allowed')
    segments = unquote(parsed.path).split('/')
    if any(segment in {'.', '..'} for segment in segments):
        raise ValueError('endpoint URL path traversal is not allowed')
    effective_port = port if port is not None else (443 if scheme == 'https' else 80)
    return scheme, hostname.lower(), effective_port, parsed.path.rstrip('/')


def require_secure_bearer_transport(url: str, token: str) -> None:
    """Forbid every outbound Bearer credential over plaintext HTTP."""
    scheme, _hostname, _port, _path = _canonical_endpoint(url)
    if not token or scheme == 'https':
        return
    raise UnsafeBearerTransportError(
        'refusing outbound Bearer credential over HTTP, including loopback; '
        'use HTTPS or run the signed Raven flow without Bearer'
    )


def verify_card_signature(
    card,
    *,
    expected_address: str,
    expected_public_key: str,
    expected_url: str = '',
    algorithms: list[str] | None = None,
) -> str:
    """Verify a card only against an already-pinned Raven identity."""
    sigs = getattr(card, 'signatures', None)
    if not sigs:
        raise CardVerificationError('agent card has no signature')
    public_key = validate_address_public_key(expected_address, expected_public_key)
    fingerprint = fingerprint_for_public_key(expected_public_key)
    expected_kid = fingerprint + '-card'
    protected = jwt.utils.base64url_decode(sigs[0].protected.encode()).decode()
    header = json.loads(protected)
    if header.get('alg') != 'EdDSA':
        raise CardVerificationError(f'card uses unexpected alg {header.get("alg")!r}')
    if header.get('kid') != expected_kid:
        raise CardVerificationError(
            f'card kid {header.get("kid")!r} != identity kid {expected_kid!r}'
        )
    jwk = PyJWK.from_dict({
        'kty': 'OKP',
        'crv': 'Ed25519',
        'x': jwt.utils.base64url_encode(public_key).decode(),
        'alg': 'EdDSA',
    })
    verifier = create_signature_verifier(
        key_provider=lambda kid, jku: jwk,
        algorithms=algorithms or ['EdDSA'],
    )
    verifier(card)
    if expected_url:
        expected_endpoint = _canonical_endpoint(expected_url)
        signed_endpoints = {
            _canonical_endpoint(str(interface.url))
            for interface in card.supported_interfaces
        }
        if expected_endpoint not in signed_endpoints:
            raise CardVerificationError(
                'signed Agent Card does not advertise the contacted endpoint'
            )
    return fingerprint


def verify_agent_card_document(
    document: dict,
    *,
    expected_address: str,
    expected_public_key: str,
    expected_url: str,
):
    """Parse and verify an Agent Card JSON document against an existing pin."""
    from a2a.client.card_resolver import parse_agent_card

    card = parse_agent_card(document)
    verify_card_signature(
        card,
        expected_address=expected_address,
        expected_public_key=expected_public_key,
        expected_url=expected_url,
    )
    return card


def _scalar(value) -> object:
    which = getattr(value, 'WhichOneof', None)
    if which is not None and callable(which):
        kind = value.WhichOneof('kind')
        return getattr(value, kind) if kind else ''
    return value


def _metadata_dict(raw) -> dict[str, object]:
    return {str(k): _scalar(v) for k, v in dict(raw or {}).items()}


def _signed_reply_artifacts(response):
    task = getattr(response, 'task', None)
    if task is None:
        return
    for artifact in getattr(task, 'artifacts', None) or []:
        text = ''.join(
            str(getattr(part, 'text', '') or '') for part in (artifact.parts or [])
        )
        metadata = _metadata_dict(getattr(artifact, 'metadata', None))
        raven = {
            key.split('.', 1)[1]: value
            for key, value in metadata.items()
            if key.startswith('raven.')
        }
        if text or raven:
            yield text, raven


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
    expected_peer_address: str,
    expected_peer_public_key: str,
    bearer_token: str = '',
    token_file: str | Path = '',
    timeout: float = 180.0,
) -> str:
    if identity is None:
        raise ValueError('a sender Raven identity is required')
    validate_address_public_key(expected_peer_address, expected_peer_public_key)
    token = resolve_bearer_token(bearer_token, token_file)
    require_secure_bearer_transport(url, token)
    headers = {'Authorization': f'Bearer {token}'} if token else None
    base_url = url.rstrip('/') + '/'
    # Fetch the public card without credentials.  Only after its signature and
    # advertised endpoint match the existing Raven pin may a Bearer token be
    # attached to RPC traffic.
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(timeout, connect=10.0),
        trust_env=False,
    ) as public_http:
        card_document = await get_bounded_json_async(
            public_http,
            base_url + '.well-known/agent-card.json',
        )
        card = verify_agent_card_document(
            card_document,
            expected_address=expected_peer_address,
            expected_public_key=expected_peer_public_key,
            expected_url=url,
        )
        fp = fingerprint_for_public_key(expected_peer_public_key)
    for interface in card.supported_interfaces:
        require_secure_bearer_transport(str(interface.url), token)
    print(f'* card signature verified (kid fingerprint: {fp[:16]}…)', flush=True)

    async with httpx.AsyncClient(
        timeout=httpx.Timeout(timeout, connect=10.0),
        headers=headers,
        auth=RavenHttpAuth(identity, expected_peer_address),
        trust_env=False,
    ) as http:
        # share OUR long-timeout client with the SDK transport — local LLMs
        # can take minutes on first load
        factory = ClientFactory(ClientConfig(streaming=False, polling=False,
                                             httpx_client=http))
        client = factory.create(card)
        try:
            message = a2a_client_mod.SendMessageRequest().message.__class__()
            message_id = uuid.uuid4().hex
            message.message_id = message_id
            message.role = Role.Value('ROLE_USER')
            part = message.parts.add()
            part.text = text
            block = sign_delegation(
                identity,
                text,
                recipient=expected_peer_address,
                task_id=message_id,
            )
            for key, value in block.items():
                message.metadata[f'raven.{key}'] = str(value)
            request = a2a_client_mod.SendMessageRequest(message=message)

            pieces: list[str] = []
            verified_reply = False
            seen_signatures: set[str] = set()
            reply_replay = ReplayCache()
            async for response in client.send_message(request):
                for answer, reply_meta in _signed_reply_artifacts(response) or ():
                    signature = str(reply_meta.get('signature', ''))
                    if signature in seen_signatures:
                        continue
                    seen_signatures.add(signature)
                    ok, why = verify_delegation(
                        reply_meta,
                        answer,
                        trusted_peers={
                            expected_peer_address: expected_peer_public_key,
                        },
                        required=True,
                        replay=reply_replay,
                        expected_recipient=identity.address,
                        expected_task_id=message_id,
                        expected_kind='answer',
                    )
                    if not ok:
                        raise CardVerificationError(f'agent reply rejected: {why}')
                    verified_reply = True
                    # Status/message text is transport metadata and is not
                    # covered by the Raven delegation signature.  In
                    # particular, plain HTTP is allowed on trusted LANs, so
                    # never mix that mutable text into the trusted result.
                    pieces.append(answer)
            if not verified_reply:
                raise CardVerificationError('agent returned no Raven-signed result artifact')
            return '\n'.join(pieces) or '(empty response)'
        finally:
            await client.close()


async def _send_many(
    urls: list[str], text: str, identity, peer_address: str, peer_public_key: str,
    token_file: str,
) -> list[str]:
    results = await asyncio.gather(
        *(
            send_task(
                u,
                text,
                identity=identity,
                expected_peer_address=peer_address,
                expected_peer_public_key=peer_public_key,
                token_file=token_file,
            )
            for u in urls
        ),
        return_exceptions=True,
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
    p.add_argument('--keys-dir', required=True, help='sender Raven keys dir')
    p.add_argument('--peer-address', required=True, help='pinned recipient RVN address')
    p.add_argument('--peer-public-key', required=True, help='pinned recipient Ed25519 key')
    p.add_argument(
        '--token-file', default='',
        help='read Bearer token from this file (or RDAP_BEARER_TOKEN[_FILE])',
    )
    args = p.parse_args()

    identity = RavenIdentity.load_or_create(args.keys_dir) if args.keys_dir else None
    results = asyncio.run(
        _send_many(
            args.url,
            args.text,
            identity,
            args.peer_address,
            args.peer_public_key,
            args.token_file,
        )
    )
    print('\n\n'.join(results))


if __name__ == '__main__':
    main()
