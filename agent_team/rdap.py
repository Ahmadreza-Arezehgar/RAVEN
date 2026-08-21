#!/usr/bin/env python3
"""RDAP wizard — the only file you need.

    ./rdap init          set up this Mac's agent (asks your agent's name)
    ./rdap trust         register a teammate by pasting their INVITE line
    ./rdap start         run your agent node (auto IP/port)
    ./rdap ask "task"    delegate a signed task to a teammate

No flags needed for the happy path. Advanced flags still exist in
`python -m team_agents --help`.
"""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# all state lives under one folder so several agents can share one install
# (RDAP_HOME also makes multi-node testing on a single Mac trivial)
BASE = Path(os.environ.get('RDAP_HOME', str(HERE))).resolve()
STATE_FILE = BASE / 'rdap.json'
PEERS_FILE = BASE / 'peers.json'


# --------------------------------------------------------------- helpers --
def _load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except Exception:  # noqa: BLE001
        return default


def _save_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def state() -> dict:
    return _load_json(STATE_FILE, {})


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except Exception:  # noqa: BLE001
        return '127.0.0.1'
    finally:
        s.close()


def ensure_keys(repo: Path) -> tuple[str, str]:
    from team_agents.raven_identity import RavenIdentity

    idn = RavenIdentity.load_or_create(repo / '.team' / 'keys')
    return idn.address, idn.public_hex


def load_peers() -> dict:
    return _load_json(PEERS_FILE, {})


def save_peers(peers: dict) -> None:
    _save_json(PEERS_FILE, peers)


# ----------------------------------------------------------------- init --
def cmd_init(args) -> None:
    st = state()
    if st.get('name'):
        print(f'already initialized as "{st["name"]}". invite:\n{invite_line(st)}')
        return

    repo = BASE / 'team-repo'
    default_name = socket.gethostname().split('.')[0].lower()
    name = args.name or input(f'agent name [{default_name}]: ').strip() or default_name
    role = args.role or input('role (optional, enter to skip): ').strip()

    repo.mkdir(parents=True, exist_ok=True)
    (repo / '.gitignore').write_text('.team/keys/\n*.seed\n', encoding='utf-8')

    address, pub = ensure_keys(repo)

    st.update(name=name, role=role, repo=str(repo), address=address, public_key=pub)
    _save_json(STATE_FILE, st)

    print('\n✔ agent ready\n')
    print('Your INVITE — send this line to your teammates:')
    print(invite_line(st))


def invite_line(st: dict) -> str:
    return f'RDAP1 {st["name"]} {st["address"]} {st["public_key"]}'


# ---------------------------------------------------------------- trust --
def cmd_trust(args) -> None:
    line = args.invite
    if not line:
        print("paste teammate's INVITE line, then press enter:")
        line = input('> ').strip()

    parts = line.split()
    if len(parts) != 4 or parts[0] != 'RDAP1':
        sys.exit('invalid invite — expected: RDAP1 <name> <rvn1...> <64-hex pubkey>')
    _, tname, addr, pub = parts
    if not addr.startswith('rvn1q') or len(pub) != 64:
        sys.exit('invalid invite fields')

    peers = load_peers()
    peers[addr] = pub
    save_peers(peers)

    st = state()
    mates = st.setdefault('teammates', {})
    mate = mates.get(tname, {})
    mate.update(address=addr, public_key=pub, url=args.url or mate.get('url', ''))
    mates[tname] = mate
    _save_json(STATE_FILE, st)

    print(f'✔ "{tname}" trusted ({addr})')


# ---------------------------------------------------------------- start --
def cmd_start(args) -> None:
    from team_agents.config import NodeConfig, Skill, LLMConfig, load_trusted_peers
    from team_agents.server import serve

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')

    repo = Path(st.get('repo') or BASE / 'team-repo')
    peers_file = PEERS_FILE if PEERS_FILE.exists() else None
    peers = load_peers()
    cfg = NodeConfig(
        name=st['name'],
        role=st.get('role', ''),
        host='0.0.0.0',
        advertised_host=args.ip or lan_ip(),
        port=args.port or 9001,   # starting point; serve() bumps if busy
        repo_path=repo,
        allow_shell=bool(args.allow_shell),
        skills=[Skill(id='general', name='General tasks',
                      description='any delegated task')],
        llm=LLMConfig(provider=args.provider, model=args.model or ''),
        trusted_peers=(load_trusted_peers(peers_file) if peers_file else {}),
        require_signed_tasks=bool(peers) and not args.open,
    )
    serve(cfg)


# ------------------------------------------------------------------ ask --
def cmd_ask(args) -> None:
    import asyncio

    from team_agents.client import send_task
    from team_agents.raven_identity import RavenIdentity

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')

    mates = st.get('teammates', {})
    target_name, target = None, None
    if args.name:
        target = mates.get(args.name)
        target_name = args.name
        if not target or not target.get('url'):
            sys.exit(f'no url known for "{args.name}" — they must run `./rdap start` '
                     'and re-send their invite with URL, or pass --url here.')
    elif len(mates) == 1:
        target_name, target = next(iter(mates.items()))
    elif not mates:
        sys.exit('no teammates yet — run `./rdap trust` first')
    else:
        print('multiple teammates — pick one:')
        for i, nm in enumerate(mates, 1):
            print(f'  {i}. {nm}')
        pick = input('#? ').strip()
        target_name, target = list(mates.items())[int(pick) - 1]

    url = args.url or target.get('url')
    if not url:
        sys.exit(f'no url for {target_name} — pass --url http://<ip>:<port>')
    if args.url:
        target['url'] = args.url
        _save_json(STATE_FILE, st)

    idn = RavenIdentity.load_or_create(Path(st['repo']) / '.team' / 'keys')
    print(f'→ delegating to {target_name} ({url}) …')
    result = asyncio.run(send_task(url, args.text, identity=idn))
    print(result)


# ------------------------------------------------------------------ main --
def main() -> None:
    import argparse

    p = argparse.ArgumentParser(prog='rdap', description='RDAP wizard')
    sub = p.add_subparsers(dest='cmd', required=True)

    i = sub.add_parser('init', help='first-time setup of this agent')
    i.add_argument('--name', default='')
    i.add_argument('--role', default='')
    i.set_defaults(fn=cmd_init)

    t = sub.add_parser('trust', help="register a teammate's invite")
    t.add_argument('invite', nargs='?', help='RDAP1 … line (or leave empty to paste)')
    t.add_argument('--url', default='', help='their node url if you know it')
    t.set_defaults(fn=cmd_trust)

    s = sub.add_parser('start', help='serve this agent')
    s.add_argument('--port', type=int, default=0)
    s.add_argument('--ip', default='', help='override advertised ip')
    s.add_argument('--provider', default='echo', help='echo | openai')
    s.add_argument('--model', default='')
    s.add_argument('--allow-shell', action='store_true')
    s.add_argument('--open', action='store_true', help='accept unsigned tasks too')
    s.set_defaults(fn=cmd_start)

    a = sub.add_parser('ask', help='delegate a task to a teammate')
    a.add_argument('text')
    a.add_argument('--name', default='', help='which teammate (when several)')
    a.add_argument('--url', default='')
    a.set_defaults(fn=cmd_ask)

    args = p.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
