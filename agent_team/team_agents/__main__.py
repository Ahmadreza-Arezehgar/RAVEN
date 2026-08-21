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
        '--require-signed', action='store_true', help='reject tasks without a valid signature'
    )


def _apply_common(cfg: NodeConfig, args: argparse.Namespace) -> NodeConfig:
    cfg.repo_path = Path(args.repo).resolve()
    if args.peers:
        cfg.trusted_peers = load_trusted_peers(Path(args.peers))
    cfg.require_signed_tasks = args.require_signed
    return cfg


def cmd_serve(args: argparse.Namespace) -> None:
    from .server import serve

    from .config import LLMConfig, Skill

    cfg = NodeConfig.from_env()
    cfg.name = args.name or cfg.name
    cfg.role = args.role or ''
    cfg.host = args.host
    cfg.port = args.port
    if args.url:
        cfg.public_url = args.url
    if args.token:
        cfg.auth_token = args.token
    if args.allow_shell:
        cfg.allow_shell = True
    for spec in args.skill or []:
        sid, name, desc = (spec.split(':', 2) + ['', ''])[:3]
        cfg.skills.append(Skill(id=sid, name=name or sid, description=desc))
    cfg.llm = LLMConfig(
        provider=args.provider,
        model=args.model or '',
        base_url=args.base_url or LLMConfig.base_url,
    )
    _apply_common(cfg, args)
    serve(cfg)


def cmd_id(args: argparse.Namespace) -> None:
    identity = RavenIdentity.load_or_create(Path(args.keys_dir))
    print(json.dumps(identity.identity_card(), indent=2))


def cmd_send(args: argparse.Namespace) -> None:
    from .client import send_task

    identity = RavenIdentity.load_or_create(args.keys_dir) if args.keys_dir else None
    result = __import__('asyncio').run(send_task(args.url, args.text, identity=identity))
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
    s.add_argument('--token', default='', help='bearer token (transport auth)')
    s.add_argument('--allow-shell', action='store_true')
    s.add_argument('--skill', action='append', default=[], help='id:name:description')
    s.add_argument('--provider', default='echo', help='openai | echo')
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
    d.add_argument('--keys-dir', default='')
    d.set_defaults(fn=cmd_send)
    return p


def main() -> None:
    args = build_parser().parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
