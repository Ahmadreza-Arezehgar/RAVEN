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

import argparse
import json
import os
import socket
import sys
import time
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
    import tempfile

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        dir=str(path.parent), prefix=f'.{path.name}.', suffix='.tmp'
    )
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(json.dumps(data, indent=2) + '\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        if os.name != 'nt':
            try:
                directory_fd = os.open(path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            except OSError:
                # Some filesystems do not support directory fsync; the atomic
                # replace itself has already succeeded.
                pass
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


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
    if not PEERS_FILE.exists():
        return {}
    from team_agents.config import load_trusted_peers

    return load_trusted_peers(PEERS_FILE)


def save_peers(peers: dict) -> None:
    from team_agents.raven_identity import validate_address_public_key

    for address, public_key in peers.items():
        validate_address_public_key(str(address), str(public_key))
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
    try:
        _validate_mate_name(name)
    except ValueError as exc:
        sys.exit(f'invalid agent name: {exc}')
    if args.role or not sys.stdin.isatty():
        role = args.role
    else:
        role = input('role (optional, enter to skip): ').strip()

    print(ui.dim('* generating raven identity…'))
    repo.mkdir(parents=True, exist_ok=True)
    (repo / '.gitignore').write_text(
        '.team/keys/\n*.seed\n'
        '.team/mesh-client/\n.team/mesh-store/\n.team/mesh-seen.json\n'
        '.team/replay-cache.sqlite3*\n',
        encoding='utf-8')
    if not (repo / '.git').exists():
        import subprocess as _sp

        _sp.run(['git', 'init', '-q'], cwd=repo, check=False)
        _sp.run(['git', 'add', '-A'], cwd=repo, check=False)
        _sp.run(['git', 'commit', '-q', '-m', 'init team memory',
                 '--allow-empty'], cwd=repo, check=False)

    address, pub = ensure_keys(repo)
    # A configured trust policy must fail closed if it later disappears.  Give
    # fresh (and pre-policy) wizard homes an explicit, valid empty policy so a
    # new node can still start cleanly before its first teammate is invited.
    if not PEERS_FILE.exists():
        _save_json(PEERS_FILE, {})

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


def _validated_node_url(value: str) -> str:
    """Return a normalized HTTP(S) node base URL with no userinfo."""
    from urllib.parse import unquote, urlsplit, urlunsplit

    raw = str(value)
    if not raw or raw != raw.strip():
        raise ValueError('URL must be non-empty and have no surrounding whitespace')
    decoded = unquote(raw)
    if '\\' in decoded or any(
        char.isspace() or ord(char) < 32 or ord(char) == 127 for char in decoded
    ):
        raise ValueError('URL contains whitespace, control characters, or backslashes')
    try:
        parsed = urlsplit(raw)
        hostname = parsed.hostname
        # Accessing .port performs its validation (range and numeric syntax).
        parsed.port
    except ValueError as exc:
        raise ValueError(f'malformed URL authority: {exc}') from exc
    if parsed.scheme.lower() not in {'http', 'https'}:
        raise ValueError('URL scheme must be http or https')
    if not parsed.netloc or not hostname:
        raise ValueError('URL must include a hostname')
    if parsed.username is not None or parsed.password is not None:
        raise ValueError('URL credentials are not allowed')
    if '%' in parsed.netloc:
        raise ValueError('percent-encoding is not allowed in the URL authority')
    if parsed.query or parsed.fragment:
        raise ValueError('URL query strings and fragments are not allowed')
    decoded_segments = unquote(parsed.path).split('/')
    if any(segment in {'.', '..'} for segment in decoded_segments):
        raise ValueError('URL path traversal segments are not allowed')
    path = parsed.path.rstrip('/')
    return urlunsplit((parsed.scheme.lower(), parsed.netloc, path, '', ''))


def _resolve_server_auth_token(token_file: str = '') -> str:
    """Resolve only this node's inbound Bearer credential."""
    from team_agents.config import read_secret_file

    path = str(token_file or os.environ.get('TEAM_AUTH_TOKEN_FILE', ''))
    if path:
        return read_secret_file(path)
    return os.environ.get('TEAM_AUTH_TOKEN', '')


def _reject_multi_peer_bearer(
    token: str,
    targets: dict[str, dict],
    operation: str,
) -> None:
    """Never reuse one outbound peer credential across distinct identities."""
    if not token:
        return
    identities = {
        (
            str(mate.get('address', '')),
            str(mate.get('public_key', '')).lower(),
        )
        if mate.get('address') and mate.get('public_key')
        else ('unresolved-name', str(name))
        for name, mate in targets.items()
    }
    if len(identities) > 1:
        sys.exit(
            f'{operation} refuses to reuse one Bearer credential across multiple '
            "peers; target one teammate at a time with that peer's --token-file"
        )


def _normalized_mate_name(value: str) -> str:
    return str(value).casefold().replace('-', '').replace('_', '').replace(' ', '')


def _validate_mate_name(value: str) -> str:
    import re

    name = str(value)
    if not name or re.fullmatch(r'[\w.-]+', name) is None:
        raise ValueError('name must contain only letters, numbers, dot, dash, or underscore')
    key = _normalized_mate_name(name)
    if not key or key in {'all', 'team', 'everyone'}:
        raise ValueError('name is empty after normalization or is a reserved group mention')
    return key


def _mate_name_collisions(mates: dict[str, dict], name: str) -> list[str]:
    key = _normalized_mate_name(name)
    return sorted(
        existing
        for existing in mates
        if existing != name and _normalized_mate_name(existing) == key
    )


def _ensure_unambiguous_mates(mates: dict[str, dict]) -> None:
    groups: dict[str, list[str]] = {}
    for name in mates:
        groups.setdefault(_normalized_mate_name(name), []).append(name)
    ambiguous = [sorted(names) for names in groups.values() if len(names) > 1]
    if ambiguous:
        rendered = '; '.join(', '.join(names) for names in ambiguous)
        sys.exit(
            'ambiguous saved teammate aliases; remove/re-trust duplicates before '
            f'routing tasks: {rendered}'
        )


def _terminal_safe(value: object, limit: int = 80) -> str:
    """Bound and strip terminal controls/bidi marks from untrusted discovery text."""
    import unicodedata

    return ''.join(
        char
        for char in str(value)
        if char.isprintable() and not unicodedata.category(char).startswith('C')
    )[:limit]


# ---------------------------------------------------------------- trust --
def cmd_trust(args) -> None:
    from team_agents.raven_identity import validate_address_public_key

    line = args.invite
    if not line:
        print("paste teammate's INVITE line, then press enter:")
        line = input('> ').strip()

    parts = line.split()
    if len(parts) not in {4, 5} or parts[0] != 'RDAP1':
        sys.exit(
            'invalid invite — expected: RDAP1 <name> <rvn1...> '
            '<64-hex pubkey> [http(s)://host:port]'
        )
    _, tname, addr, pub = parts[:4]
    try:
        _validate_mate_name(tname)
        validate_address_public_key(addr, pub)
    except ValueError as exc:
        sys.exit(f'invalid invite: {exc}')

    st = state()
    mates = st.setdefault('teammates', {})
    collisions = _mate_name_collisions(mates, tname)
    if collisions:
        sys.exit(
            f'teammate name "{tname}" conflicts with saved alias(es) '
            f'{", ".join(collisions)}; trust was not stored'
        )

    invite_url = ''
    cli_url = ''
    try:
        if len(parts) == 5:
            invite_url = _validated_node_url(parts[4])
        if getattr(args, 'url', ''):
            cli_url = _validated_node_url(args.url)
    except ValueError as exc:
        sys.exit(f'invalid teammate URL: {exc}')
    if invite_url and cli_url and invite_url != cli_url:
        sys.exit('invite URL conflicts with --url; trust was not stored')
    verified_url = cli_url or invite_url

    # A supplied endpoint is part of the trust decision: verify its live Raven
    # identity against the invite pin before writing either peers.json or state.
    idn = None
    if verified_url:
        try:
            idn = _probe(
                verified_url,
                expected_address=addr,
                expected_public_key=pub,
                token_file=getattr(args, 'token_file', ''),
                raise_errors=True,
            )
        except Exception as exc:  # noqa: BLE001
            sys.exit(f'live identity verification failed; trust was not stored: {exc}')
        if idn is None:
            sys.exit('live identity verification failed; trust was not stored')

    mate = dict(mates.get(tname, {}))
    old_address = str(mate.get('address', ''))
    same_identity = (
        mate.get('address') == addr
        and str(mate.get('public_key', '')).lower() == pub.lower()
    )
    if not same_identity:
        mate.pop('mailbox', None)
    mate.update(address=addr, public_key=pub)
    if verified_url:
        mate['url'] = verified_url
    elif not same_identity:
        mate['url'] = ''
    if (
        verified_url
        and getattr(args, 'experimental_plaintext_mailbox', False)
        and idn
        and idn.get('mailbox')
    ):
        mate['mailbox'] = idn['mailbox']
        print(
            '  ! EXPERIMENTAL PLAINTEXT mailbox captured '
            f"({idn['mailbox']['multiaddr'][:34]}…)"
        )

    peers = load_peers()
    final_peers = dict(peers)
    old_still_referenced = any(
        name != tname and str(saved.get('address', '')) == old_address
        for name, saved in mates.items()
    )
    if old_address and old_address != addr and not old_still_referenced:
        final_peers.pop(old_address, None)
    final_peers[addr] = pub

    # Cross-file updates cannot be one filesystem transaction.  Revoke only
    # the identities changing in this operation first, then publish the UI
    # state, and finally enable the new peer.  Every interruption point is
    # therefore fail-closed rather than leaving a hidden authorized identity.
    visible_before = {
        str(saved.get('address', '')) for saved in mates.values()
        if saved.get('address')
    }
    safe_peers = dict(peers)
    if old_address and old_address != addr and not old_still_referenced:
        safe_peers.pop(old_address, None)
    if addr not in visible_before:
        safe_peers.pop(addr, None)

    mates[tname] = mate
    safe_written = safe_peers != peers
    if safe_written:
        save_peers(safe_peers)
    try:
        _save_json(STATE_FILE, st)
    except Exception:
        if safe_written:
            try:
                save_peers(peers)
            except Exception:  # noqa: BLE001
                pass  # changed identities remain denied if rollback also fails
        raise
    save_peers(final_peers)

    if verified_url:
        print(f'  ✔ live identity verified at {verified_url}')
    print(f'✔ "{tname}" trusted ({addr})')


# ---------------------------------------------------------------- start --
def cmd_start(args) -> None:
    from team_agents.config import NodeConfig, Skill, LLMConfig, load_trusted_peers
    from team_agents.server import serve

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')

    repo = Path(st.get('repo') or BASE / 'team-repo')
    from team_agents.raven_identity import validate_address_public_key

    # One-time migration for wizard homes created before peers.json became a
    # mandatory hot-reloaded policy file.  Runtime loss after this point is not
    # recreated by the server and therefore remains fail-closed.
    if not PEERS_FILE.exists():
        _save_json(PEERS_FILE, {})
    local_address, local_public_key = ensure_keys(repo)
    try:
        validate_address_public_key(local_address, local_public_key)
    except ValueError as exc:
        sys.exit(f'local Raven identity is invalid: {exc}')
    if st.get('address') and st['address'] != local_address:
        sys.exit('saved RDAP address does not match the local private key')
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
        require_signed_tasks=not args.open,
        auth_token=_resolve_server_auth_token(args.token_file),
        enable_experimental_mailbox=args.experimental_plaintext_mailbox,
    )
    if args.poll:
        os.environ['RDAP_POLL'] = str(args.poll)
    if args.open:
        print('! ! ! OPEN MODE EXPLICITLY ENABLED: unsigned LAN tasks will execute ! ! !')
    if args.experimental_plaintext_mailbox:
        print('! EXPERIMENTAL PLAINTEXT MAILBOX ENABLED — no Raven E2EE/confidentiality')
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

    if getattr(args, 'token_file', ''):
        sys.exit(
            'discover never sends Bearer credentials to untrusted TOFU endpoints; '
            'exchange `./rdap invite` lines and use `./rdap trust ... '
            '--token-file <peer-token>` instead'
    )
    print('→ scanning LAN for RDAP agents (_rdap._tcp) …')
    me = state().get('address')
    nodes = []
    for discovered in browse(timeout=args.timeout):
        if discovered.get('addr') == me:
            continue
        try:
            safe_name = str(discovered.get('name', ''))
            _validate_mate_name(safe_name)
            safe_url = _validated_node_url(str(discovered.get('url', '')))
        except ValueError:
            print('  ! ignored an unsafe mDNS advertisement')
            continue
        node = dict(discovered)
        node['name'] = safe_name
        node['url'] = safe_url
        node['_display_addr'] = _terminal_safe(node.get('addr', ''), 24)
        nodes.append(node)
    if not nodes:
        print('none found (other than you). is the other node running?')
        return
    for i, n in enumerate(nodes, 1):
        print(
            f"  {i}) {n['name']:20} {n['url']}  "
            f"{n['_display_addr'][:18]}…"
        )
    if not args.trust:
        print('\ntrust one:  ./rdap discover --trust <number>')
        return
    if str(args.trust).casefold() == 'all':
        targets = nodes
    else:
        try:
            selection = int(args.trust)
        except (TypeError, ValueError):
            sys.exit("--trust must be a listed number or 'all'")
        if not 1 <= selection <= len(nodes):
            sys.exit(f'--trust selection must be between 1 and {len(nodes)}')
        targets = [nodes[selection - 1]]
    import httpx

    st = state()
    peers = load_peers()
    from team_agents.client import verify_agent_card_document
    from team_agents.raven_identity import validate_address_public_key

    def public_get(url: str):
        # RDAP node URLs are direct endpoints.  In particular, never let a
        # process-wide HTTP_PROXY turn a loopback/LAN request into a credential
        # or TOFU-boundary crossing.
        with httpx.Client(timeout=6, trust_env=False) as public_client:
            return public_client.get(url)

    for n in targets:
        node_name = str(n.get('name', ''))
        try:
            _validate_mate_name(node_name)
            collisions = _mate_name_collisions(
                st.setdefault('teammates', {}), node_name
            )
            if collisions:
                raise ValueError(
                    f'name conflicts with saved alias(es) {", ".join(collisions)}'
                )
        except ValueError as exc:
            print(f'✗ {node_name or "(unnamed)"}: unsafe teammate name ({exc})')
            continue
        try:
            node_url = _validated_node_url(str(n['url']))
            response = public_get(node_url + '/raven/identity')
            if response.status_code in {401, 403}:
                raise PermissionError(
                    'identity requires auth; use a signed invite and manual `rdap trust`'
                )
            response.raise_for_status()
            idn = response.json()
        except Exception as exc:  # noqa: BLE001
            print(f'✗ {node_name}: identity fetch failed ({exc!r})')
            continue
        addr, pub = str(idn.get('address', '')), str(idn.get('public_key', ''))
        try:
            validate_address_public_key(addr, pub)
            if n.get('addr') and n['addr'] != addr:
                raise ValueError('mDNS address differs from HTTP identity')
        except ValueError as exc:
            print(f'✗ {node_name}: invalid identity binding ({exc})')
            continue
        existing_mate = st.setdefault('teammates', {}).get(node_name, {})
        if existing_mate and (
            str(existing_mate.get('address', '')) != addr
            or str(existing_mate.get('public_key', '')).lower() != pub.lower()
        ):
            print(
                f'✗ {node_name}: saved identity changed; exchange a signed invite '
                'and use manual `rdap trust` for an authenticated rotation'
            )
            continue
        try:
            card_response = public_get(node_url + '/.well-known/agent-card.json')
            card_response.raise_for_status()
            verify_agent_card_document(
                card_response.json(),
                expected_address=addr,
                expected_public_key=pub,
                expected_url=node_url,
            )
        except Exception as exc:  # noqa: BLE001
            print(f'✗ {node_name}: signed Agent Card verification failed ({exc!r})')
            continue
        mates = st.setdefault('teammates', {})
        mates[node_name] = {'address': addr, 'public_key': pub, 'url': node_url}
        if args.experimental_plaintext_mailbox and idn.get('mailbox'):
            mates[node_name]['mailbox'] = idn['mailbox']
        # Publish visible state before enabling a new inbound peer.  A crash
        # between these writes is inconvenient but remains authorization-safe.
        _save_json(STATE_FILE, st)
        peers[addr] = pub
        save_peers(peers)
        print(f"✔ trusted {node_name} ({addr[:18]}…) @ {node_url}   [TOFU]"
              + ('  !experimental-plaintext-mailbox'
                 if args.experimental_plaintext_mailbox and idn.get('mailbox') else ''))


def cmd_mesh_build(args) -> None:
    """Build the disabled-by-default plaintext mailbox experiment."""
    from team_agents.mesh import build_swarm_bin, find_swarm_bin

    existing = find_swarm_bin()
    if existing and not args.force:
        print('✔ already built:', existing)
        return
    print('! building EXPERIMENTAL PLAINTEXT mailbox; this is not Raven E2EE')
    print('* first Rust build can take a few minutes…')
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
    import team_agents.ui as ui

    from team_agents.client import resolve_bearer_token, send_task
    from team_agents.chat import TeamChat, parse_mentions
    from team_agents.memory import TeamMemory
    from team_agents.raven_identity import (
        MAX_DELEGATION_TTL_SECONDS,
        RavenIdentity,
        sign_delegation,
    )

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    mates = st.get('teammates', {})
    repo = Path(st.get('repo') or BASE / 'team-repo')

    _ensure_unambiguous_mates(mates)
    mentions = parse_mentions(args.text, list(mates))
    targets: list[tuple[str, dict]] = []
    if mentions:
        if mentions == ['@all']:
            targets = list(mates.items())
        else:
            unknown = [m for m in mentions if m not in mates]
            if unknown:
                sys.exit(f'unknown teammate(s): {", ".join(unknown)}')
            targets = [(n, mates[n]) for n in mentions]
        direct_targets = {
            name: mate
            for name, mate in targets
            if not args.relay and (mate.get('url') or args.url)
        }
        if direct_targets:
            _reject_multi_peer_bearer(
                resolve_bearer_token(token_file=args.token_file),
                direct_targets,
                'say fan-out',
            )

    chat = TeamChat(TeamMemory(repo))
    chat.ensure()
    idn = RavenIdentity.load_or_create(repo / '.team' / 'keys')

    # Always visible in the shared thread (synced via git), but only after
    # recipient and credential policy validation succeeds.
    chat.post(st['name'], args.text)

    if not mentions:
        print('✔ posted to team chat (no @mention — nobody tasked). '
              'use @name or @all inside the message.')
        return

    def _sign(text: str, peer_address: str):
        tid = uuid.uuid4().hex[:12]
        payload = {'id': tid, 'kind': 'task', 'from': idn.address,
                   'to': peer_address, 'text': text,
                   'raven': sign_delegation(
                       idn, text, recipient=peer_address, task_id=tid,
                       ttl_seconds=MAX_DELEGATION_TTL_SECONDS)}
        return tid, json.dumps(payload, ensure_ascii=False)

    binp = None
    try:
        from team_agents.mesh import find_swarm_bin
        binp = find_swarm_bin()
    except Exception:  # noqa: BLE001
        pass

    for tname, target in targets:
        peer_addr = target.get('address', '')
        peer_pub = target.get('public_key', '')
        url = target.get('url') or args.url
        sent = False

        if not args.relay and url:
            try:
                info = _probe(
                    url,
                    expected_address=peer_addr,
                    expected_public_key=peer_pub,
                    token_file=args.token_file,
                )
            except Exception as exc:
                from team_agents.client import UnsafeBearerTransportError

                if isinstance(exc, UnsafeBearerTransportError):
                    sys.exit(f'refusing direct Bearer transport: {exc}')
                raise
            if info is not None:
                mb = info.get('mailbox')
                if args.experimental_plaintext_mailbox and mb \
                        and target.get('mailbox') != mb:
                    target['mailbox'] = mb
                    _save_json(STATE_FILE, st)
                try:
                    result = asyncio.run(send_task(
                        url,
                        args.text,
                        identity=idn,
                        expected_peer_address=peer_addr,
                        expected_peer_public_key=peer_pub,
                        token_file=args.token_file,
                        timeout=120,
                    ))
                    chat.post(tname, f'✅ done: {result.splitlines()[0][:100]}')
                    ui.ok(f'[direct] {tname}: ' + result.splitlines()[0][:110])
                    sent = True
                except Exception as exc:  # noqa: BLE001
                    ui.err(f'[direct] {tname}: {exc!r}'[:120])

        if (not sent and args.experimental_plaintext_mailbox and binp
                and target.get('mailbox') and peer_addr):
            ui.warn('EXPERIMENTAL PLAINTEXT mailbox in use; task is not confidential')
            try:
                from team_agents.mesh import make_task_object, mailbox_put

                tid, payload_text = _sign(args.text, peer_addr)
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
            f = r.send_task(peer_addr, args.text)
            tid = json.loads(f.read_text(encoding='utf-8'))['id']
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
def _probe(
    url: str,
    seconds: float = 6.0,
    *,
    expected_address: str,
    expected_public_key: str,
    token_file: str = '',
    raise_errors: bool = False,
):
    """Verify a pinned signed card and live identity before trusting an endpoint."""
    import httpx
    from team_agents.client import (
        UnsafeBearerTransportError,
        require_secure_bearer_transport,
        resolve_bearer_token,
        verify_agent_card_document,
    )
    from team_agents.raven_identity import (
        fingerprint_for_public_key,
        validate_address_public_key,
    )

    try:
        node_url = _validated_node_url(url)
        base = node_url.rstrip('/') + '/'
        expected_key = validate_address_public_key(
            expected_address, expected_public_key
        ).hex()
        token = resolve_bearer_token(token_file=token_file)
        require_secure_bearer_transport(node_url, token)

        # Agent Cards are public: never expose Bearer before the signed card
        # proves this endpoint belongs to the already-pinned Raven identity.
        direct_timeout = httpx.Timeout(seconds, connect=4.0)
        with httpx.Client(timeout=direct_timeout, trust_env=False) as public_client:
            card_response = public_client.get(
                base + '.well-known/agent-card.json'
            )
        card_response.raise_for_status()
        verify_agent_card_document(
            card_response.json(),
            expected_address=expected_address,
            expected_public_key=expected_public_key,
            expected_url=node_url,
        )

        headers = {'Authorization': f'Bearer {token}'} if token else None
        with httpx.Client(
            timeout=direct_timeout,
            headers=headers,
            trust_env=False,
        ) as c:
            c.get(base + 'health').raise_for_status()
            identity_response = c.get(base + 'raven/identity')
            identity_response.raise_for_status()
            ident = identity_response.json()
            if not isinstance(ident, dict):
                raise ValueError('remote identity response is not a JSON object')
            if str(ident.get('address', '')) != expected_address:
                raise ValueError('remote Raven address does not match the invite pin')
            if str(ident.get('public_key', '')).lower() != expected_key:
                raise ValueError('remote public key does not match the invite pin')
            fingerprint = fingerprint_for_public_key(expected_key)
            if str(ident.get('fingerprint', '')) != fingerprint:
                raise ValueError('remote fingerprint does not match the pinned key')
            if str(ident.get('card_kid', '')) != fingerprint + '-card':
                raise ValueError('remote card key id does not match the pinned key')
            return ident
    except UnsafeBearerTransportError:
        # This is a local policy violation, not ordinary reachability failure.
        raise
    except Exception:  # noqa: BLE001
        if raise_errors:
            raise
        return None


def cmd_ping(args) -> None:
    from team_agents.client import resolve_bearer_token

    st = state()
    requested_name = str(getattr(args, 'name', '') or '')
    token_file = str(getattr(args, 'token_file', '') or '')
    explicit_address = str(getattr(args, 'peer_address', '') or '')
    explicit_public_key = str(getattr(args, 'peer_public_key', '') or '')

    def ping_one(name: str, url: str, address: str, public_key: str) -> bool:
        if not url:
            print(f'✗ {name}: no url')
            return False
        if not address or not public_key:
            print(f'✗ {name}: trusted Raven identity pin is incomplete')
            return False
        print(f'→ probing {name} at {url} …')
        try:
            info = _probe(
                url,
                expected_address=address,
                expected_public_key=public_key,
                token_file=token_file,
            )
        except Exception as exc:
            from team_agents.client import UnsafeBearerTransportError

            if isinstance(exc, UnsafeBearerTransportError):
                print(f'✗ {name}: {exc}')
                return False
            raise
        if not info:
            print(f'✗ {name}: unreachable or pinned identity/auth did not verify')
            return False
        pol = info.get('policy', {})
        print(f'✔ alive: {info["display"]}')
        print(f'  signed-only={pol.get("require_signed_tasks")} '
              f'peers={len(pol.get("trusted_peers", []))}')
        return True

    if requested_name.lower() == 'all':
        if explicit_address or explicit_public_key:
            sys.exit('--peer-address/--peer-public-key cannot be used with --name all')
        targets = [
            (name, mate) for name, mate in sorted(st.get('teammates', {}).items())
            if mate.get('url')
        ]
        if not targets:
            sys.exit('no teammates with a url')
        _reject_multi_peer_bearer(
            resolve_bearer_token(token_file=token_file),
            dict(targets),
            'ping all',
        )
        failed = [
            name for name, mate in targets
            if not ping_one(
                name,
                str(mate.get('url', '')),
                str(mate.get('address', '')),
                str(mate.get('public_key', '')),
            )
        ]
        if failed:
            sys.exit(1)
        return

    mate: dict = {}
    display_name = requested_name or 'peer'
    if requested_name:
        display_name, mate = _resolve_mate(st, requested_name)
    url = str(getattr(args, 'url', '') or mate.get('url', ''))
    if not url:
        sys.exit(f'no url for "{display_name}" — pass one or re-run trust/discover')
    expected_address = explicit_address or str(mate.get('address', ''))
    expected_public_key = explicit_public_key or str(mate.get('public_key', ''))
    if not expected_address or not expected_public_key:
        sys.exit('ping requires --name for a trusted teammate or both pinned identity flags')
    if not ping_one(display_name, url, expected_address, expected_public_key):
        print('  checklist: is the node running, reachable, and using the expected token?')
        sys.exit(1)


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
                and not (args.experimental_plaintext_mailbox
                         and target.get('mailbox')):
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
        try:
            selection = int(pick)
        except ValueError:
            sys.exit(f'pick must be a number between 1 and {len(mates)}')
        if not 1 <= selection <= len(mates):
            sys.exit(f'pick must be between 1 and {len(mates)}')
        target_name, target = list(mates.items())[selection - 1]

    try:
        explicit_url = _validated_node_url(args.url) if args.url else ''
    except ValueError as exc:
        sys.exit(f'invalid --url: {exc}')
    url = explicit_url or (target or {}).get('url', '')
    peer_addr = (target or {}).get('address', '')
    peer_pub = (target or {}).get('public_key', '')
    repo = Path(st.get('repo') or BASE / 'team-repo')
    idn = RavenIdentity.load_or_create(repo / '.team' / 'keys')

    # ---------------- RDAP Transport Manager ladder -----------------------
    # T1 direct A2A · T2/T3 raven-swarm mailbox · T4 git relay
    def _sign_payload() -> tuple[str, str]:
        from team_agents.raven_identity import (
            MAX_DELEGATION_TTL_SECONDS,
            sign_delegation,
        )

        tid = uuid.uuid4().hex[:12]
        payload = {
            'id': tid, 'kind': 'task', 'from': idn.address,
            'to': peer_addr, 'text': args.text,
            'raven': sign_delegation(
                idn,
                args.text,
                recipient=peer_addr,
                task_id=tid,
                ttl_seconds=MAX_DELEGATION_TTL_SECONDS,
            ),
        }
        return tid, json.dumps(payload, ensure_ascii=False)

    if not args.relay and url:
        print(ui.dim(ARROW + f' checking {target_name} at {url} …'))
        try:
            info = _probe(
                url,
                expected_address=peer_addr,
                expected_public_key=peer_pub,
                token_file=args.token_file,
            )
        except Exception as exc:
            from team_agents.client import UnsafeBearerTransportError

            if isinstance(exc, UnsafeBearerTransportError):
                sys.exit(f'refusing direct Bearer transport: {exc}')
            raise
        if info is not None:
            mb = info.get('mailbox')
            target_changed = False
            if explicit_url and target is not None and target.get('url') != explicit_url:
                target['url'] = explicit_url
                target_changed = True
            if (args.experimental_plaintext_mailbox and mb and target is not None
                    and target.get('mailbox') != mb):
                target['mailbox'] = mb          # remember for future fallback
                target_changed = True
            if target_changed:
                _save_json(STATE_FILE, st)
            print(f'✔ {target_name} alive — sending task …')
            result = asyncio.run(send_task(
                url,
                args.text,
                identity=idn,
                expected_peer_address=peer_addr,
                expected_peer_public_key=peer_pub,
                token_file=args.token_file,
                timeout=90,
            ))
            print(result)
            return
        ui.err('[direct] unreachable')

    # T3 — raven swarm offline mailbox (task lands in THEIR store)
    if args.experimental_plaintext_mailbox and not args.git_only:
        ui.warn('EXPERIMENTAL PLAINTEXT mailbox requested; task is not confidential')
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
        print(
            f'  {ui.bold(cmd.ljust(8))} {ui.dim(desc.ljust(26))} {ui.cyan(ex)}'
        )
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
        ('mailbox ', ('experimental binary present (disabled by default)'
                      if find_swarm_bin() else 'experimental binary not built')),
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


def _expand_dotargv(argv: list[str]) -> list[str]:
    """Expand worker.do/worker.ask/worker.ping command shorthand.

    ``do`` takes the teammate as a positional target; ``ask`` and ``ping``
    take it through ``--name``. Returns argv unchanged when there is no match.
    """
    import re

    if len(argv) > 1:
        m = re.fullmatch(r'([A-Za-z0-9_.-]+)\.(do|ask|ping)', argv[1])
        if m:
            target, command = m.groups()
            if command == 'do':
                return [argv[0], command, target] + argv[2:]
            return [argv[0], command, '--name', target] + argv[2:]
    return argv


def _resolve_mate(st: dict, want: str) -> tuple[str, dict]:
    """Resolve one exact normalized name, or one unambiguous prefix."""
    mates = st.get('teammates', {})
    key = _normalized_mate_name(want)
    if not key:
        sys.exit('invalid teammate name — target cannot normalize to an empty value')
    normalized = {
        name: _normalized_mate_name(name) for name in mates
    }
    exact = [name for name, candidate in normalized.items() if candidate == key]
    if len(exact) == 1:
        name = exact[0]
        return name, mates[name]
    if len(exact) > 1:
        sys.exit(f'ambiguous teammate "{want}" — exact aliases: {", ".join(sorted(exact))}')
    prefixes = [name for name, candidate in normalized.items() if candidate.startswith(key)]
    if len(prefixes) == 1:
        name = prefixes[0]
        return name, mates[name]
    if len(prefixes) > 1:
        sys.exit(f'ambiguous teammate "{want}" — matches: {", ".join(sorted(prefixes))}')
    sys.exit(f'unknown teammate "{want}" — known: {", ".join(mates) or "(none)"}')


def cmd_do(args) -> None:
    """Shortest path to delegate:  ./rdap do WORKER "text"  |  do all "text"."""
    import asyncio

    from team_agents.client import (
        UnsafeBearerTransportError,
        require_secure_bearer_transport,
        resolve_bearer_token,
        send_task,
    )
    from team_agents.raven_identity import RavenIdentity

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    repo = Path(st.get('repo') or BASE / 'team-repo')
    idn = RavenIdentity.load_or_create(repo / '.team' / 'keys')

    if args.target.lower() == 'all':
        targets = {nm: m for nm, m in st.get('teammates', {}).items() if m.get('url')}
        if not targets:
            sys.exit('no teammates with a url — run `./rdap discover --trust all`')
    else:
        nm, mate = _resolve_mate(st, args.target)
        if not mate.get('url'):
            sys.exit(f'no url for "{nm}" — re-run `./rdap discover --trust all`')
        targets = {nm: mate}

    token = resolve_bearer_token(token_file=args.token_file)
    _reject_multi_peer_bearer(token, targets, 'do all')
    try:
        for mate in targets.values():
            require_secure_bearer_transport(str(mate['url']), token)
    except UnsafeBearerTransportError as exc:
        sys.exit(str(exc))

    async def _run():
        import asyncio as _aio

        results = await _aio.gather(
            *(send_task(
                m['url'],
                args.text,
                identity=idn,
                expected_peer_address=str(m.get('address', '')),
                expected_peer_public_key=str(m.get('public_key', '')),
                token_file=args.token_file,
                timeout=90,
            )
              for m in targets.values()),
            return_exceptions=True)
        return list(zip(targets, results))

    for nm, res in asyncio.run(_run()):
        head = res.splitlines()[0] if isinstance(res, str) and res else repr(res)
        print(f'{nm}: {head}')


def cmd_ls(args) -> None:
    """One line per teammate: name, url, alive, last activity."""
    import httpx
    from team_agents.client import (
        UnsafeBearerTransportError,
        require_secure_bearer_transport,
        resolve_bearer_token,
    )

    st = state()
    me = st.get('name', '?')
    print(f'me: {me}  ({st.get("address", "?")[:18]}…)')
    mates = st.get('teammates', {})
    if not mates:
        print('teammates: (none) — ./rdap discover --trust all')
        return
    token = resolve_bearer_token(token_file=args.token_file)
    network_targets = {
        name: mate for name, mate in mates.items() if mate.get('url')
    }
    _reject_multi_peer_bearer(token, network_targets, 'ls')
    try:
        for mate in mates.values():
            if mate.get('url'):
                require_secure_bearer_transport(str(mate['url']), token)
    except UnsafeBearerTransportError as exc:
        sys.exit(str(exc))
    headers = {'Authorization': f'Bearer {token}'} if token else None
    for nm, m in sorted(mates.items()):
        url = m.get('url', '')
        last = '(no url)'
        if url:
            try:
                info = _probe(
                    url,
                    seconds=4,
                    expected_address=str(m.get('address', '')),
                    expected_public_key=str(m.get('public_key', '')),
                    token_file=args.token_file,
                )
                if info is None:
                    raise ValueError('pinned identity/auth did not verify')
                with httpx.Client(
                    timeout=4, headers=headers, trust_env=False
                ) as activity_client:
                    response = activity_client.get(
                        url.rstrip('/') + '/raven/activity',
                        params={'limit': 1},
                    )
                if response.status_code == 403:
                    last = 'alive; activity auth disabled/required'
                else:
                    response.raise_for_status()
                    evs = response.json().get('events', [])
                    last = f'{evs[0]["text"][:60]}' if evs else 'alive, quiet'
            except Exception:  # noqa: BLE001
                last = '✗ unreachable'
        print(f'  {nm:22} {url or "-":32} {last}')


def cmd_watch(args) -> None:
    """Live dashboard of every agent — zero input, Ctrl+C to leave."""
    import httpx
    from team_agents.client import (
        UnsafeBearerTransportError,
        require_secure_bearer_transport,
        resolve_bearer_token,
    )

    st = state()
    if not st.get('name'):
        sys.exit('run `./rdap init` first')
    repo = Path(st.get('repo') or BASE / 'team-repo')

    from team_agents.memory import TeamMemory

    mem = TeamMemory(repo)
    token = resolve_bearer_token(token_file=args.token_file)
    network_targets = {
        name: mate
        for name, mate in st.get('teammates', {}).items()
        if mate.get('url')
    }
    _reject_multi_peer_bearer(token, network_targets, 'watch')
    try:
        for mate in st.get('teammates', {}).values():
            if mate.get('url'):
                require_secure_bearer_transport(str(mate['url']), token)
    except UnsafeBearerTransportError as exc:
        sys.exit(str(exc))
    headers = {'Authorization': f'Bearer {token}'} if token else None

    def fetch(mate: dict):
        url = str(mate.get('url', ''))
        if not url:
            return 'unreachable', []
        try:
            info = _probe(
                url,
                seconds=4,
                expected_address=str(mate.get('address', '')),
                expected_public_key=str(mate.get('public_key', '')),
                token_file=args.token_file,
            )
            if info is None:
                return 'unreachable', []
            with httpx.Client(
                timeout=4, headers=headers, trust_env=False
            ) as activity_client:
                r = activity_client.get(
                    url.rstrip('/') + '/raven/activity',
                    params={'limit': args.lines},
                )
            if r.status_code == 403:
                return 'restricted', []
            r.raise_for_status()
            return 'ok', r.json().get('events', [])
        except Exception:  # noqa: BLE001
            return 'unreachable', []

    def fmt(evs) -> list[str]:
        out = []
        for e in evs or []:
            t = time.strftime('%H:%M:%S', time.localtime(e.get('at', 0)))
            who = str(e.get('w', '?'))
            out.append(f'      {t}  {who[:14]:14} {str(e.get("text", ""))[:70]}')
        return out or ['      (quiet)']

    try:
        while True:
            panels = [f'\033[2J\033[H',   # clear screen + home
                      f'RDAP live — {time.strftime("%Y-%m-%d %H:%M:%S")}'
                      f'   (Ctrl+C to exit)']
            local = mem.recent_events(args.lines)
            panels.append(f'── {st["name"]} @ local ──────────────')
            panels += fmt(local)
            for nm, m in sorted(st.get('teammates', {}).items()):
                url = m.get('url', '')
                fetch_state, evs = fetch(m)
                if fetch_state == 'restricted':
                    state_txt = '  alive; activity auth disabled/required'
                elif fetch_state == 'unreachable':
                    state_txt = '  ✗ unreachable'
                else:
                    state_txt = ''
                panels.append(f'── {nm} @ {url or "?"}{state_txt} ──────')
                panels += fmt(evs)
            print('\n'.join(panels), flush=True)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print('\nbye.')


def main() -> None:
    import argparse

    sys.argv = _expand_dotargv(sys.argv)

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
    t.add_argument(
        'invite', nargs='?',
        help='four-field RDAP1 line, optionally followed by its http(s) URL',
    )
    t.add_argument('--url', default='', help='verified node URL when invite has none')
    t.add_argument('--token-file', default='', help='Bearer token file for identity fetch')
    t.add_argument(
        '--experimental-plaintext-mailbox', action='store_true',
        help='capture explicitly enabled non-confidential mailbox coordinates',
    )
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
    s.add_argument(
        '--open', action='store_true',
        help='DANGEROUS: explicitly accept unsigned tasks from reachable clients',
    )
    s.add_argument('--token-file', default='', help='read server Bearer token from file')
    s.add_argument(
        '--experimental-plaintext-mailbox', action='store_true',
        help='DANGEROUS/EXPERIMENTAL: enable non-confidential mailbox adapter',
    )
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
    a.add_argument('--token-file', default='', help='Bearer token file for direct A2A')
    a.add_argument(
        '--experimental-plaintext-mailbox', action='store_true',
        help='explicitly allow the non-confidential experimental mailbox fallback',
    )
    a.set_defaults(fn=cmd_ask)

    g = sub.add_parser('ping', help='check whether a teammate node is reachable')
    g.add_argument('url', nargs='?', default='', help='http://<ip>:<port>')
    g.add_argument('--name', default='', help='trusted teammate name (fuzzy) or "all"')
    g.add_argument('--peer-address', default='', help='pinned RVN address')
    g.add_argument('--peer-public-key', default='', help='pinned Ed25519 public key')
    g.add_argument('--token-file', default='', help='Bearer token file')
    g.set_defaults(fn=cmd_ping)

    v = sub.add_parser('invite', help='print your invite line (add --port for url)')
    v.add_argument('--port', type=int, default=0)
    v.set_defaults(fn=cmd_invite)

    d = sub.add_parser('discover', help='find nearby agents on this LAN (mDNS)')
    d.add_argument('--timeout', type=float, default=4.0)
    d.add_argument('--trust', default='', help="number from list, or 'all'")
    d.add_argument(
        '--token-file', default='',
        help='rejected for TOFU discovery; use signed invite + manual trust',
    )
    d.add_argument(
        '--experimental-plaintext-mailbox', action='store_true',
        help='capture explicitly enabled non-confidential mailbox coordinates',
    )
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
    sy.add_argument('--token-file', default='', help='Bearer token file for direct A2A')
    sy.add_argument(
        '--experimental-plaintext-mailbox', action='store_true',
        help='explicitly allow the non-confidential experimental mailbox fallback',
    )
    sy.set_defaults(fn=cmd_say)

    ch = sub.add_parser('chat', help='show the shared team thread')
    ch.add_argument('--lines', type=int, default=30)
    ch.set_defaults(fn=cmd_chat)

    stt = sub.add_parser('status', help='one-glance dashboard')

    w = sub.add_parser('watch', help='live dashboard of all agents (no input)')
    w.add_argument('--interval', type=float, default=3.0, help='refresh seconds')
    w.add_argument('--lines', type=int, default=6, help='events per panel')
    w.add_argument('--token-file', default='', help='Bearer token file for peers')
    d2 = sub.add_parser('do', help='short delegation: do WORKER "text" | do all "text"')
    d2.add_argument('target', help='teammate name (fuzzy) or "all"')
    d2.add_argument('text')
    d2.add_argument('--token-file', default='', help='Bearer token file for direct A2A')
    l2 = sub.add_parser('ls', help='list teammates + last activity')
    l2.add_argument('--token-file', default='', help='Bearer token file for peers')
    stt.set_defaults(fn=cmd_status)
    w.set_defaults(fn=cmd_watch)
    d2.set_defaults(fn=cmd_do)
    l2.set_defaults(fn=cmd_ls)

    bd = sub.add_parser('board', help='show the shared task board')
    bd.set_defaults(fn=cmd_board)

    mb = sub.add_parser('mesh-build',
                        help='build EXPERIMENTAL PLAINTEXT mailbox binary (disabled by default)')
    mb.add_argument('--force', action='store_true')
    mb.set_defaults(fn=cmd_mesh_build)

    args = p.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
