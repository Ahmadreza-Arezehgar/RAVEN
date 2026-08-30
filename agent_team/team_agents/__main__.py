"""CLI: run an agent node, inspect its raven identity, or delegate tasks.

    python -m team_agents serve --name raphael --port 9001 --repo <shared-repo>
    python -m team_agents id --keys-dir <repo>/.team/keys
    python -m team_agents send --url http://127.0.0.1:9001 --text "do X" \
        --keys-dir <sender-repo>/.team/keys
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .config import NodeConfig, load_trusted_peers
from .raven_identity import RavenIdentity


def _add_common(p: argparse.ArgumentParser) -> None:
    p.add_argument('--repo', default='.', help='shared team repo path')
    p.add_argument(
        '--peers',
        default='',
        help='JSON file of trusted peers {rvn1addr: pubhex} or {alias: {address, pubkey}}',
    )
    p.add_argument(
        '--require-signed', action='store_true',
        help='deprecated no-op: signed tasks are already required by default',
    )
    p.add_argument(
        '--open', action='store_true',
        help='DANGEROUS: explicitly accept unsigned tasks',
    )


def _apply_common(cfg: NodeConfig, args: argparse.Namespace) -> NodeConfig:
    cfg.repo_path = Path(args.repo).resolve()
    if args.peers:
        cfg.trusted_peers = load_trusted_peers(Path(args.peers))
    cfg.require_signed_tasks = not args.open
    return cfg


def cmd_serve(args: argparse.Namespace) -> None:
    from .server import serve

    from .config import LLMConfig, Skill, resolve_custom_llm_api_key

    cfg = NodeConfig.from_env()
    cfg.name = args.name or cfg.name
    cfg.role = args.role or ''
    cfg.host = args.host
    cfg.port = args.port
    if args.url:
        cfg.public_url = args.url
    if args.token or args.token_file:
        from .client import resolve_bearer_token

        cfg.auth_token = resolve_bearer_token(args.token, args.token_file)
    cfg.enable_experimental_mailbox = args.experimental_plaintext_mailbox
    if args.allow_shell:
        cfg.allow_shell = True
    for spec in args.skill or []:
        sid, name, desc = (spec.split(':', 2) + ['', ''])[:3]
        cfg.skills.append(Skill(id=sid, name=name or sid, description=desc))
    provider_overridden = bool(str(args.provider).strip())
    selected_provider = str(
        args.provider or cfg.llm.provider
    ).strip().lower()
    cfg.llm = LLMConfig(
        provider=selected_provider,
        model=(
            args.model
            or ('' if provider_overridden else cfg.llm.model)
        ),
        base_url=(
            args.base_url
            or ('' if provider_overridden else cfg.llm.base_url)
        ),
        _api_key=(
            resolve_custom_llm_api_key() if selected_provider == 'custom' else ''
        ),
    )
    _apply_common(cfg, args)
    serve(cfg)


def cmd_id(args: argparse.Namespace) -> None:
    identity = RavenIdentity.load_or_create(Path(args.keys_dir))
    print(json.dumps(identity.identity_card(), indent=2))


def cmd_send(args: argparse.Namespace) -> None:
    from .client import send_task

    identity = RavenIdentity.load_or_create(args.keys_dir) if args.keys_dir else None
    result = __import__('asyncio').run(
        send_task(
            args.url,
            args.text,
            identity=identity,
            expected_peer_address=args.peer_address,
            expected_peer_public_key=args.peer_public_key,
            token_file=args.token_file,
        )
    )
    print(result)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog='team_agents')
    sub = p.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('serve', help='run an A2A agent node')
    s.add_argument('--name', default='')
    s.add_argument('--role', default='')
    s.add_argument('--host', default='127.0.0.1')
    s.add_argument('--port', type=int, default=8081)
    s.add_argument('--url', default='', help='public url advertised in the agent card')
    s.add_argument('--token', default='', help='Bearer token (argv-visible; prefer env/file)')
    s.add_argument('--token-file', default='', help='read server Bearer token from file')
    s.add_argument(
        '--experimental-plaintext-mailbox', action='store_true',
        help='DANGEROUS/EXPERIMENTAL: enable non-confidential mailbox adapter',
    )
    s.add_argument('--allow-shell', action='store_true')
    s.add_argument('--skill', action='append', default=[], help='id:name:description')
    s.add_argument(
        '--provider', default='',
        help='echo | openai | groq | openrouter | ollama | custom',
    )
    s.add_argument('--model', default='')
    s.add_argument('--base-url', default='')
    _add_common(s)
    s.set_defaults(fn=cmd_serve)

    i = sub.add_parser('id', help='print raven identity for a keys dir')
    i.add_argument('--keys-dir', required=True)
    i.set_defaults(fn=cmd_id)

    d = sub.add_parser('send', help='delegate a task to a teammate node')
    d.add_argument('--url', required=True)
    d.add_argument('--text', required=True)
    d.add_argument('--keys-dir', required=True)
    d.add_argument('--peer-address', required=True)
    d.add_argument('--peer-public-key', required=True)
    d.add_argument('--token-file', default='', help='Bearer token file')
    d.set_defaults(fn=cmd_send)
    return p


def main() -> None:
    args = build_parser().parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
