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
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# all state lives under one folder so several agents can share one install
# (RDAP_HOME also makes multi-node testing on a single Mac trivial)
BASE = Path(os.environ.get('RDAP_HOME', str(HERE))).resolve()
STATE_FILE = BASE / 'rdap.json'
PEERS_FILE = BASE / 'peers.json'

# open-source-first brain catalog
MODEL_MENU = [
    ('llama3.2',      'Llama 3.2 (3B, fast)',              'ollama'),
    ('llama3.1',      'Llama 3.1 (8B)',                    'ollama'),
    ('qwen2.5-coder', 'Qwen2.5-Coder (7B, code)',           'ollama'),
    ('deepseek-r1',   'DeepSeek-R1 (8B, reasoning)',        'ollama'),
    ('gemma2',        'Gemma 2 (9B, Google)',               'ollama'),
    ('mistral',       'Mistral (7B)',                       'ollama'),
]
CLOUD_MENU = [
    ('groq/llama-3.3-70b-versatile',  'Groq · Llama 3.3 70B (fast, free tier)',
     'https://api.groq.com/openai/v1', 'GROQ_API_KEY'),
    ('openrouter/llama-3.3-70b-instruct:free', 'OpenRouter · Llama 3.3 70B free',
     'https://openrouter.ai/api/v1', 'OPENROUTER_API_KEY'),
    ('gpt-4o-mini',                   'OpenAI · gpt-4o-mini (proprietary)',
     'https://api.openai.com/v1', 'OPENAI_API_KEY'),
]


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


def rvn_display(address: str) -> str:
    try:
        from raven_protocol import address as rvn_address

        return rvn_address.to_display(address)
    except Exception:  # noqa: BLE001
        return ''


def load_peers() -> dict:
    return _load_json(PEERS_FILE, {})


def save_peers(peers: dict) -> None:
    _save_json(PEERS_FILE, peers)


# ----------------------------------------------------------------- init --
def cmd_init(args) -> None:
    import team_agents.ui as ui

    st = state()
    if st.get('name'):
        ui.ok(f'already initialized as "{st["name"]}"')
        print(ui.dim('invite: ') + invite_line(st))
        return

    repo = BASE / 'team-repo'
    default_name = socket.gethostname().split('.')[0].lower()
    name = args.name or input(f'agent name [{default_name}]: ').strip() or default_name
    if args.role or not sys.stdin.isatty():
        role = args.role
    else:
        role = input('role (optional, enter to skip): ').strip()

    print(ui.dim('* generating raven identity…'))
    repo.mkdir(parents=True, exist_ok=True)
    (repo / '.gitignore').write_text(
        '.team/keys/\n*.seed\n'
        '.team/mesh-client/\n.team/mesh-store/\n.team/mesh-seen.json\n',
        encoding='utf-8')
    if not (repo / '.git').exists():
        import subprocess as _sp

        _sp.run(['git', 'init', '-q'], cwd=repo, check=False)
        _sp.run(['git', 'add', '-A'], cwd=repo, check=False)
        _sp.run(['git', 'commit', '-q', '-m', 'init team memory',
                 '--allow-empty'], cwd=repo, check=False)

    address, pub = ensure_keys(repo)

    # internet capability shapes which brains we offer later
    if args.internet is not None:
        has_net = args.internet
    elif sys.stdin.isatty():
        ans = input('does this Mac have internet access? [Y/n]: ').strip().lower()
        has_net = ans not in ('n', 'no')
    else:
        has_net = True   # assume online when run from scripts
    st['internet'] = has_net

    st.update(name=name, role=role, repo=str(repo), address=address, public_key=pub)
    _save_json(STATE_FILE, st)

    ui.box([
        ('identity ', address),
        ('display  ', rvn_display(address)),
        ('keys     ', str(Path(repo) / '.team' / 'keys')),
        ('online   ', 'yes' if has_net else 'local-only'),
    ], title=f'{name} is ready')
    print(f'\n{ui.bold("share this invite with teammates:")}')
    print(ui.cyan(invite_line(st)))
    if not st.get('llm'):
        print("\npick a brain now:  ./rdap model")


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

    # if a url is known, pull their live identity — captures mesh mailbox info
    if args.url:
        try:
            import httpx

            idn = httpx.get(args.url.rstrip('/') + '/raven/identity',
                            timeout=6).json()
            if idn.get('mailbox'):
                mate['mailbox'] = idn['mailbox']
                print(f"  +mesh captured ({idn['mailbox']['multiaddr'][:34]}…)")
        except Exception:  # noqa: BLE001
            print('  (identity fetch failed — mailbox info skipped)')

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
    # always wire the live peers file — trust list may grow while running
    peers_now = load_trusted_peers(PEERS_FILE) if PEERS_FILE.exists() else {}
    saved_llm = st.get('llm', {})
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
        llm=LLMConfig(
            provider=args.provider or saved_llm.get('provider', 'echo'),
            model=args.model or saved_llm.get('model', ''),
            base_url=(args.base_url
                      or saved_llm.get('base_url')
                      or LLMConfig.base_url),
        ),
        trusted_peers=peers_now,
        trusted_peers_file=str(PEERS_FILE),
        require_signed_tasks=bool(peers_now) and not args.open,
    )
    if args.poll:
        os.environ['RDAP_POLL'] = str(args.poll)
    serve(cfg)


def cmd_model(args) -> None:
    """Show/save which brain this agent uses."""
    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')

    # ---- interactive menu ------------------------------------------------
    if not args.provider and not args.list:
        has_net = st.get('internet', True)
        print(f"brain for '{st['name']}'"
              + ('' if has_net else '  (offline mode — local models only)'))
        options: list[tuple[str, str, str, str]] = []
        print('\n— open-source, runs locally (Ollama) —')
        for i, (model, label, _) in enumerate(MODEL_MENU, 1):
            print(f'  {i:2}) {label}')
            options.append(('openai', model, 'http://localhost:11434/v1', ''))
        if has_net:
            print('— hosted —')
            for key, label, base_url, envkey in CLOUD_MENU:
                print(f'  {len(options) + 1:2}) {label}')
                options.append(('openai', key, base_url, envkey))
        pick = input('\n#? (enter to keep current): ').strip()
        if not pick:
            return cmd_model(type('A', (), {'provider': '', 'model': '',
                                            'base_url': '', 'list': False})())
        try:
            provider, model, base_url, envkey = options[int(pick) - 1]
        except (ValueError, IndexError):
            sys.exit('bad choice')
        if envkey:
            import os

            if not os.environ.get(envkey) and not os.environ.get('LLM_API_KEY'):
                print(f'⚠ set {envkey} before starting: export {envkey}=…')
        args.provider, args.model, args.base_url = provider, model, base_url

    if args.list:
        for _, label, *_ in MODEL_MENU:
            print(' local:', label)
        for _, label, *_ in CLOUD_MENU:
            print(' cloud:', label)
        return

    st['llm'] = {
        'provider': args.provider,
        'model': args.model or '',
        'base_url': args.base_url or LLMConfig.base_url,
    }
    _save_json(STATE_FILE, st)
    print(f"✔ {st['name']} will now think with "
          f"{st['llm']['provider']}/{st['llm']['model'] or '-'}"
          f"{' @ ' + st['llm']['base_url'] if st['llm']['base_url'] else ''}")
    print('restart the node (`./rdap start`) to apply.')


def cmd_invite(args) -> None:
    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    line = invite_line(st)
    url = ''
    mates = st.get('teammates', {})
    if args.port:
        url = f'http://{lan_ip()}:{args.port}'
        line += f' {url}'
    print(line)


def cmd_discover(args) -> None:
    """Find nearby RDAP agents on this LAN via mDNS and optionally trust one."""
    from team_agents.discovery import browse

    print('→ scanning LAN for RDAP agents (_rdap._tcp) …')
    me = state().get('address')
    nodes = [n for n in browse(timeout=args.timeout) if n.get('addr') != me]
    if not nodes:
        print('none found (other than you). is the other node running?')
        return
    for i, n in enumerate(nodes, 1):
        print(f"  {i}) {n['name']:20} {n['url']}  {n['addr'][:18]}…")
    if not args.trust:
        print('\ntrust one:  ./rdap discover --trust <number>')
        return
    idx = int(args.trust) - 1 if args.trust != 'all' else None
    targets = [nodes[idx]] if idx is not None else nodes
    import httpx

    st = state()
    peers = load_peers()
    for n in targets:
        try:
            idn = httpx.get(n['url'] + '/raven/identity', timeout=6).json()
        except Exception as exc:  # noqa: BLE001
            print(f"✗ {n['name']}: identity fetch failed ({exc!r})")
            continue
        addr, pub = idn['address'], idn['public_key']
        peers[addr] = pub
        save_peers(peers)
        mates = st.setdefault('teammates', {})
        mates[n['name']] = {'address': addr, 'public_key': pub,
                            'url': n['url'], 'mailbox': idn.get('mailbox')}
        print(f"✔ trusted {n['name']} ({addr[:18]}…) @ {n['url']}   [TOFU]"
              + ('  +mesh' if idn.get('mailbox') else ''))
    _save_json(STATE_FILE, st)


def cmd_mesh_build(args) -> None:
    """Build the Raven swarm mailbox binary once (needs Rust/cargo)."""
    from team_agents.mesh import build_swarm_bin, find_swarm_bin

    existing = find_swarm_bin()
    if existing and not args.force:
        print('✔ already built:', existing)
        return
    print('* building raven-swarm mailbox (first build takes a few minutes)…')
    print('✔ built:', build_swarm_bin())


def cmd_goal(args) -> None:
    """Set THE unified mission every agent works toward."""
    from team_agents.chat import TeamChat
    from team_agents.memory import TeamMemory

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    chat = TeamChat(TeamMemory(Path(st.get('repo') or BASE / 'team-repo')))
    if args.text:
        chat.set_goal(args.text)
        chat.post(st['name'], f'📌 set the TEAM GOAL')
    print('TEAM GOAL:', chat.get_goal() or '(not set)')
    print('every delegated task is now framed by this mission.')


def cmd_say(args) -> None:
    """Group-chat: `@agent task` routes it; `@all` fans out to everyone."""
    import asyncio

    from team_agents.client import send_task
    from team_agents.chat import TeamChat, parse_mentions
    from team_agents.memory import TeamMemory
    from team_agents.raven_identity import RavenIdentity, sign_delegation

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    mates = st.get('teammates', {})
    repo = Path(st.get('repo') or BASE / 'team-repo')

    mentions = parse_mentions(args.text, list(mates))
    chat = TeamChat(TeamMemory(repo))
    chat.ensure()
    idn = RavenIdentity.load_or_create(repo / '.team' / 'keys')

    # always visible in the shared thread (synced via git)
    chat.post(st['name'], args.text)

    if not mentions:
        print('✔ posted to team chat (no @mention — nobody tasked). '
              'use @name or @all inside the message.')
        return

    if mentions == ['@all']:
        targets = list(mates.items())
    else:
        unknown = [m for m in mentions if m not in mates]
        if unknown:
            sys.exit(f'unknown teammate(s): {", ".join(unknown)}')
        targets = [(n, mates[n]) for n in mentions]

    def _sign(text: str):
        tid = uuid.uuid4().hex[:12]
        payload = {'id': tid, 'kind': 'task', 'from': idn.address,
                   'to': '', 'text': text,
                   'raven': sign_delegation(idn, text)}
        return tid, json.dumps(payload, ensure_ascii=False)

    binp = None
    try:
        from team_agents.mesh import find_swarm_bin
        binp = find_swarm_bin()
    except Exception:  # noqa: BLE001
        pass

    for tname, target in targets:
        peer_addr = target.get('address', '')
        url = target.get('url') or args.url
        sent = False

        if not args.relay and url:
            info = _probe(url)
            if info is not None:
                mb = info.get('mailbox')
                if mb and target.get('mailbox') != mb:
                    target['mailbox'] = mb
                    _save_json(STATE_FILE, st)
                try:
                    result = asyncio.run(send_task(url, args.text,
                                                   identity=idn, timeout=120))
                    chat.post(tname, f'✅ done: {result.splitlines()[0][:100]}')
                    ui.ok(f'[direct] {tname}: ' + result.splitlines()[0][:110])
                    sent = True
                except Exception as exc:  # noqa: BLE001
                    ui.err(f'[direct] {tname}: {exc!r}'[:120])

        if not sent and binp and target.get('mailbox') and peer_addr:
            try:
                from team_agents.mesh import make_task_object, mailbox_put

                tid, payload_text = _sign(args.text)
                mailbox_put(binp, repo / '.team' / 'mesh-client',
                            target['mailbox']['multiaddr'],
                            target['mailbox']['peer_id'],
                            make_task_object(payload_text.encode(), peer_addr))
                chat.post(tname, f'📬 task {tid} waiting in your raven box')
                ui.ok(f"[mesh] task {tid} waiting in {tname}'s raven box")
                sent = True
            except Exception as exc:  # noqa: BLE001
                ui.err(f'[mesh] {tname}: ' + str(exc)[:100])

        if not sent and peer_addr:
            from team_agents.relay import GitRelay

            r = GitRelay(TeamMemory(repo), idn,
                         trusted_peers_file=(str(PEERS_FILE)
                                             if PEERS_FILE.exists() else None),
                         trusted_peers=load_peers())
            tid, _ = _sign(args.text)
            f = r.send_task(peer_addr, args.text)
            chat.post(tname, f'📮 task {tid} parked in git relay')
            ui.warn(f'[git] task parked for {tname} → collect with ./rdap replies')


def cmd_chat(args) -> None:
    """Show the shared team thread and current goal."""
    from team_agents.chat import TeamChat
    from team_agents.memory import TeamMemory

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    chat = TeamChat(TeamMemory(Path(st.get('repo') or BASE / 'team-repo')))
    goal = chat.get_goal()
    if goal:
        print(f'🎯 GOAL: {goal}\n')
    print(chat.tail(args.lines))


def cmd_replies(args) -> None:
    """Collect offline answers that arrived through the git relay."""
    from team_agents.memory import TeamMemory
    from team_agents.raven_identity import RavenIdentity
    from team_agents.relay import GitRelay

    st = state()
    repo = Path(st.get('repo') or BASE / 'team-repo')
    idn = RavenIdentity.load_or_create(repo / '.team' / 'keys')
    r = GitRelay(TeamMemory(repo), idn,
                 trusted_peers_file=str(PEERS_FILE) if PEERS_FILE.exists() else None,
                 trusted_peers=load_peers())
    reps = r.take_replies()
    if not reps:
        print('(no offline answers yet)')
        return
    for rep in reps:
        print(f"← [{rep.get('at')}] {rep.get('from','?')[:16]}…:")
        print(f"   {rep.get('text','')}\n")


# ------------------------------------------------------------------ ask --
def _probe(url: str, seconds: float = 6.0):
    """Quick reachability + identity check. Returns identity dict or None."""
    import httpx

    base = url.rstrip('/') + '/'
    try:
        with httpx.Client(timeout=httpx.Timeout(seconds, connect=4.0)) as c:
            c.get(base + 'health').raise_for_status()
            return c.get(base + 'raven/identity').json()
    except Exception:  # noqa: BLE001
        return None


def cmd_ping(args) -> None:
    url = args.url
    print(f'→ probing {url} …')
    info = _probe(url)
    if not info:
        print('✗ node unreachable. checklist:')
        print('  1. is `./rdap start` running on the other Mac?')
        print('  2. macOS Firewall there: System Settings ▸ Network ▸ Firewall '
              '→ allow Python (or turn firewall off while testing)')
        print('  3. both Macs on the same Wi-Fi/LAN?')
        sys.exit(1)
    pol = info.get('policy', {})
    print(f'✔ alive: {info["display"]}')
    print(f'  signed-only={pol.get("require_signed_tasks")} '
          f'peers={len(pol.get("trusted_peers", []))}')


def cmd_ask(args) -> None:
    import asyncio

    import team_agents.ui as ui

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
        if not target:
            sys.exit(f'unknown teammate "{args.name}" — run `./rdap trust` first')
        if not (target.get('url') or args.url) and not args.relay \
                and not target.get('mailbox'):
            sys.exit(f'no url known for "{args.name}" — re-run `./rdap trust` '
                     'with --url, or use --relay to go offline')
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

    url = args.url or (target or {}).get('url', '')
    if args.url and target is not None:
        target['url'] = args.url
        _save_json(STATE_FILE, st)
    peer_addr = (target or {}).get('address', '')
    repo = Path(st.get('repo') or BASE / 'team-repo')
    idn = RavenIdentity.load_or_create(repo / '.team' / 'keys')

    # ---------------- RDAP Transport Manager ladder -----------------------
    # T1 direct A2A · T2/T3 raven-swarm mailbox · T4 git relay
    def _sign_payload() -> tuple[str, str]:
        from team_agents.raven_identity import sign_delegation

        tid = uuid.uuid4().hex[:12]
        payload = {
            'id': tid, 'kind': 'task', 'from': idn.address,
            'to': peer_addr, 'text': args.text,
            'raven': sign_delegation(idn, args.text),
        }
        return tid, json.dumps(payload, ensure_ascii=False)

    if not args.relay and url:
        print(ui.dim(ARROW + f' checking {target_name} at {url} …'))
        info = _probe(url)
        if info is not None:
            mb = info.get('mailbox')
            if mb and target is not None and target.get('mailbox') != mb:
                target['mailbox'] = mb          # remember for future fallback
                _save_json(STATE_FILE, st)
            print(f'✔ {target_name} alive — sending task …')
            result = asyncio.run(send_task(url, args.text,
                                           identity=idn, timeout=90))
            print(result)
            return
        ui.err('[direct] unreachable')

    # T3 — raven swarm offline mailbox (task lands in THEIR store)
    if not args.git_only:
        from team_agents.mesh import find_swarm_bin, make_task_object, mailbox_put

        binp = find_swarm_bin()
        mb = (target or {}).get('mailbox')
        if binp and mb and peer_addr:
            try:
                tid, payload_text = _sign_payload()
                obj_hex = make_task_object(payload_text.encode(), peer_addr)
                mailbox_put(binp, repo / '.team' / 'mesh-client',
                            mb['multiaddr'], mb['peer_id'], obj_hex)
                print(f'✔ [T3 mesh-mailbox] queued {tid} into '
                      f"{target_name}'s Raven store")
                print('   they drain it automatically; collect answers:')
                print('   ./rdap replies')
                return
            except Exception as exc:  # noqa: BLE001
                print(f'✗ [T3] mesh put failed ({exc!r}) — falling to git …')

    # T4 — git relay
    use_relay = True
    if not args.relay and not args.git_only and sys.stdin.isatty():
        ans = input(f'{target_name} unreachable — queue via git relay? '
                    '[Y/n]: ').strip().lower()
        use_relay = ans not in ('n', 'no')
    if not use_relay or not peer_addr:
        sys.exit(f'✗ no transport reached {target_name}.'
                 + ('' if url else ' (no url known — pass --url)'))
    from team_agents.memory import TeamMemory
    from team_agents.relay import GitRelay

    r = GitRelay(TeamMemory(repo), idn,
                 trusted_peers_file=(str(PEERS_FILE)
                                     if PEERS_FILE.exists() else None),
                 trusted_peers=load_peers())
    tid, payload_text = _sign_payload()
    f = r.send_task(peer_addr, args.text)
    print(f'✔ [T4 git-relay] queued {f.relative_to(repo)}')
    print('   collect answers later with:  ./rdap replies')


# ------------------------------------------------------------------ main --
from team_agents.ui import ARROW, dim  # noqa: F401


def _menu() -> None:
    """Friendly dashboard when ./rdap is run with no arguments."""
    import team_agents.ui as ui

    st = state()
    if not st.get('name'):
        print(ui.bold('\n  Welcome to RDAP — agents that never lose connection\n'))
        print('  1. set up this agent      ' + ui.cyan('./rdap init --name you'))
        print('  2. pick a brain           ' + ui.cyan('./rdap model'))
        print('\n  then: start the node and say hi to teammates.')
        return

    goal = ''
    try:
        from team_agents.chat import TeamChat
        from team_agents.memory import TeamMemory

        chat = TeamChat(TeamMemory(Path(st.get('repo') or BASE / 'team-repo')))
        goal = chat.get_goal()
    except Exception:  # noqa: BLE001
        pass
    mates = list(st.get('teammates', {}))

    from team_agents import __version__

    ui.box([
        ('agent   ', f"{st['name']}" + (f" · {st['role']}" if st.get('role') else '')),
        ('raven id', st.get('address', '?')),
        ('goal    ', (goal[:38] + '…') if len(goal) > 40 else (goal or 'not set')),
        ('team    ', ', '.join(mates) if mates else 'nobody yet'),
        ('version ', f'v{__version__}'),
    ], title='RDAP')

    print()
    for cmd, desc, ex in (
        ('start', 'run your agent', './rdap start'),
        ('ask', 'delegate a task', './rdap ask "@name do X"'),
        ('say', 'group chat', './rdap say "@all hi"'),
        ('chat', 'read the shared thread', './rdap chat'),
        ('status', "what's happening", './rdap status'),
    ):
        print(f'  {bold(cmd.ljust(8))} {dim(desc.ljust(26))} {cyan(ex)}')
    print()

def cmd_status(args) -> None:
    """One-glance dashboard: who am I, goal, team, transports."""
    import team_agents.ui as ui

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    goal = ''
    try:
        from team_agents.chat import TeamChat
        from team_agents.memory import TeamMemory

        chat = TeamChat(TeamMemory(Path(st.get('repo') or BASE / 'team-repo')))
        goal = chat.get_goal()
    except Exception:  # noqa: BLE001
        pass
    mates = st.get('teammates', {})
    from team_agents.mesh import find_swarm_bin

    ui.box([
        ('agent   ', f"{st['name']}" + (f" · {st['role']}" if st.get('role') else '')),
        ('raven id', st.get('address', '?')),
        ('goal    ', (goal[:40] + '…') if len(goal) > 44 else (goal or 'not set')),
        ('team    ', ', '.join(mates) if mates else 'nobody yet'),
        ('mesh    ', 'ready' if find_swarm_bin() else 'not built (./rdap mesh-build)'),
        ('repo    ', str(st.get('repo', ''))),
    ], title='RDAP status')


def cmd_board(args) -> None:
    """Show the shared task board (projection of task deltas)."""
    import team_agents.ui as ui
    from team_agents.memory import TeamMemory

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    m = TeamMemory(Path(st.get('repo') or BASE / 'team-repo'))
    rows = m._parse_board_rows()
    if not rows:
        print(ui.dim('board is empty — agents add tasks with board_set_task'))
        return
    for r in rows:
        icon = {'done': ui.green('●'), 'in_progress': ui.cyan('◐'),
                'blocked': ui.red('○')}.get(r['status'], ui.dim('○'))
        print(f"  {icon} {ui.bold(r['id']):<14} {r['title'][:44]:<46} "
              f"{ui.dim(r['owner'])} {ui.dim(r['status'])}")


def main() -> None:
    import argparse

    if len(sys.argv) == 1:
        return _menu()

    p = argparse.ArgumentParser(prog='rdap', description='RDAP wizard')
    sub = p.add_subparsers(dest='cmd', required=True)

    i = sub.add_parser('init', help='first-time setup of this agent')
    i.add_argument('--name', default='')
    i.add_argument('--role', default='')
    i.add_argument('--internet', action=argparse.BooleanOptionalAction, default=None,
                   help='skip the internet question with --internet/--no-internet')
    i.set_defaults(fn=cmd_init)

    t = sub.add_parser('trust', help="register a teammate's invite")
    t.add_argument('invite', nargs='?', help='RDAP1 … line (or leave empty to paste)')
    t.add_argument('--url', default='', help='their node url if you know it')
    t.set_defaults(fn=cmd_trust)

    s = sub.add_parser('start', help='serve this agent')
    s.add_argument('--port', type=int, default=0)
    s.add_argument('--ip', default='', help='override advertised ip')
    s.add_argument('--provider', default='', help='echo | openai (overrides saved)')
    s.add_argument('--model', default='')
    s.add_argument('--base-url', default='', help='OpenAI-compatible endpoint')
    s.add_argument('--allow-shell', action='store_true')
    s.add_argument('--poll', type=int, default=0,
                   help='mesh/git drain interval seconds (default 20)')
    s.add_argument('--open', action='store_true', help='accept unsigned tasks too')
    s.set_defaults(fn=cmd_start)

    m = sub.add_parser('model', help='choose this agent\'s brain (LLM)')
    m.add_argument('provider', nargs='?', default='', help='openai | echo')
    m.add_argument('model', nargs='?', default='')
    m.add_argument('--base-url', default='',
                   help='e.g. http://localhost:11434/v1 for Ollama')
    m.add_argument('--list', action='store_true', help='just list catalog')
    m.set_defaults(fn=cmd_model)

    a = sub.add_parser('ask', help='delegate a task to a teammate')
    a.add_argument('text')
    a.add_argument('--name', default='', help='which teammate (when several)')
    a.add_argument('--url', default='')
    a.add_argument('--relay', action='store_true',
                   help='skip live attempt, queue via git relay directly')
    a.add_argument('--git-only', action='store_true',
                   help='skip mesh mailbox, use git relay as the fallback')
    a.set_defaults(fn=cmd_ask)

    g = sub.add_parser('ping', help='check whether a teammate node is reachable')
    g.add_argument('url', help='http://<ip>:<port>')
    g.set_defaults(fn=cmd_ping)

    v = sub.add_parser('invite', help='print your invite line (add --port for url)')
    v.add_argument('--port', type=int, default=0)
    v.set_defaults(fn=cmd_invite)

    d = sub.add_parser('discover', help='find nearby agents on this LAN (mDNS)')
    d.add_argument('--timeout', type=float, default=4.0)
    d.add_argument('--trust', default='', help="number from list, or 'all'")
    d.set_defaults(fn=cmd_discover)

    rr = sub.add_parser('replies', help='collect offline answers from git relay')
    rr.set_defaults(fn=cmd_replies)

    gl = sub.add_parser('goal', help='set THE unified mission for all agents')
    gl.add_argument('text', nargs='?', default='')
    gl.set_defaults(fn=cmd_goal)

    sy = sub.add_parser('say', help='group chat: @agent task | @all broadcast')
    sy.add_argument('text', help='e.g. "@raphael build the login API"')
    sy.add_argument('--url', default='')
    sy.add_argument('--relay', action='store_true')
    sy.set_defaults(fn=cmd_say)

    ch = sub.add_parser('chat', help='show the shared team thread')
    ch.add_argument('--lines', type=int, default=30)
    ch.set_defaults(fn=cmd_chat)

    stt = sub.add_parser('status', help='one-glance dashboard')
    stt.set_defaults(fn=cmd_status)

    bd = sub.add_parser('board', help='show the shared task board')
    bd.set_defaults(fn=cmd_board)

    mb = sub.add_parser('mesh-build',
                        help='build the Raven swarm mailbox binary (Rust)')
    mb.add_argument('--force', action='store_true')
    mb.set_defaults(fn=cmd_mesh_build)

    args = p.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
