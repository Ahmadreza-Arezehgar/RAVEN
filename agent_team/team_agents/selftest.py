#!/usr/bin/env python3
"""Self-test for the RDAP A2A upgrades.

Unit part  : delegation sign/verify, nonce, replay rejection, revocation,
             tamper rejection, signed Agent Card JWS round-trip.
Network part: boots two real nodes (echo brain) and exercises
             card-signature verification + a signed delegated task end-to-end
             via the actual JSON-RPC path.

    ./.venv/bin/python selftest.py            # everything
    ./.venv/bin/python selftest.py --unit     # offline only
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent          # …/agent_team/team_agents
PKG_ROOT = HERE.parent                          # …/agent_team
sys.path.insert(0, str(PKG_ROOT))
sys.path.insert(1, str(HERE))

import httpx  # noqa: E402

from team_agents.raven_identity import (  # noqa: E402
    RavenIdentity,
    ReplayCache,
    load_revocations,
    sign_delegation,
    sign_http_request,
    validate_address_public_key,
    verify_delegation,
    verify_http_request,
)

PASS = []
FAIL = []


def check(name: str, cond: bool, detail: str = '') -> None:
    (PASS if cond else FAIL).append(name)
    print(f'{"✓" if cond else "✗"} {name}' + (f' — {detail}' if detail else ''))


def _peers(a: RavenIdentity) -> dict[str, str]:
    return {a.address: a.public_hex}


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ['git', '-C', str(repo), *args],
        capture_output=True,
        text=True,
        timeout=20,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f'git {args[0] if args else "command"} failed: '
            f'{(result.stderr + result.stdout)[-1000:]}'
        )
    return result.stdout.strip()


def _tree_snapshot(root: Path) -> dict[str, str]:
    """Content/type snapshot used to prove rejected ingress is mutation-free."""
    if not root.exists():
        return {}
    snapshot: dict[str, str] = {}
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root).as_posix()
        if path.is_symlink():
            snapshot[rel] = 'symlink:' + os.readlink(path)
        elif path.is_dir():
            snapshot[rel] = 'dir'
        elif path.is_file():
            snapshot[rel] = 'file:' + hashlib.sha256(path.read_bytes()).hexdigest()
        else:
            snapshot[rel] = 'other'
    return snapshot


# --------------------------------------------------------------- unit ------
def unit_tests() -> None:
    tmp = Path(tempfile.mkdtemp(prefix='rdap-selftest-'))
    try:
        alice = RavenIdentity.load_or_create(tmp / 'a')
        bob = RavenIdentity.load_or_create(tmp / 'b')
        eve = RavenIdentity.load_or_create(tmp / 'e')
        peers = _peers(alice)  # bob trusts alice

        check(
            'address/public-key binding validates',
            validate_address_public_key(alice.address, alice.public_hex)
            == alice.public_bytes,
        )
        try:
            validate_address_public_key(alice.address, eve.public_hex)
            check('mismatched identity binding rejected', False)
        except ValueError:
            check('mismatched identity binding rejected', True)

        from team_agents.config import NodeConfig, load_trusted_peers

        peers_file = tmp / 'peers.json'
        peers_file.write_text(json.dumps({alice.address: alice.public_hex}))
        check('trusted peer loader validates binding', load_trusted_peers(peers_file) == peers)
        peers_file.write_text(json.dumps({alice.address: eve.public_hex}))
        try:
            load_trusted_peers(peers_file)
            check('bad trust file fails closed', False)
        except ValueError:
            check('bad trust file fails closed', True)

        def verify(meta, text='hello task', *, recipient=None, task_id='task-1',
                   cache=None, kind='task', revoked=None):
            return verify_delegation(
                meta,
                text,
                peers,
                required=True,
                revoked=revoked,
                replay=cache or ReplayCache(),
                expected_recipient=recipient or bob.address,
                expected_task_id=task_id,
                expected_kind=kind,
            )

        block = sign_delegation(
            alice, 'hello task', recipient=bob.address, task_id='task-1'
        )
        durable_path = tmp / 'replay.sqlite3'
        ok, why = verify(block, cache=ReplayCache(path=durable_path))
        check('recipient/task-bound delegation verifies', ok, why)
        durable_before_replay = durable_path.read_bytes()
        ok, why = verify(block, cache=ReplayCache(path=durable_path))
        check(
            'replay rejection after cache restart is mutation-free',
            not ok
            and 'replay' in why
            and durable_path.read_bytes() == durable_before_replay,
            why,
        )

        http_cache = ReplayCache()
        http_block = sign_http_request(
            alice,
            recipient=bob.address,
            method='POST',
            target='/',
            body=b'{"jsonrpc":"2.0"}',
        )
        http_ok, http_why, http_owner = verify_http_request(
            http_block,
            method='POST',
            target='/',
            body=b'{"jsonrpc":"2.0"}',
            trusted_peers=peers,
            expected_recipient=bob.address,
            replay=http_cache,
        )
        replay_ok, replay_why, _ = verify_http_request(
            http_block,
            method='POST',
            target='/',
            body=b'{"jsonrpc":"2.0"}',
            trusted_peers=peers,
            expected_recipient=bob.address,
            replay=http_cache,
        )
        tamper_block = sign_http_request(
            alice,
            recipient=bob.address,
            method='POST',
            target='/',
            body=b'original',
        )
        tamper_ok, tamper_why, _ = verify_http_request(
            tamper_block,
            method='POST',
            target='/',
            body=b'tampered',
            trusted_peers=peers,
            expected_recipient=bob.address,
            replay=ReplayCache(),
        )
        check(
            'HTTP request auth binds Raven owner, method/target/body and replay',
            http_ok
            and http_owner == alice.address
            and not replay_ok
            and 'replay' in replay_why
            and not tamper_ok
            and 'signature' in tamper_why,
            f'{http_why}; {replay_why}; {tamper_why}',
        )
        bounded_replay_path = tmp / 'bounded-replay.sqlite3'
        bounded_replay = ReplayCache(
            path=bounded_replay_path,
            max_entries=2,
            max_db_bytes=64 * 1024,
        )
        bounded_accepts = []
        for index in range(3):
            candidate = sign_http_request(
                alice,
                recipient=bob.address,
                method='POST',
                target='/',
                body=f'body-{index}'.encode(),
            )
            accepted, _, _ = verify_http_request(
                candidate,
                method='POST',
                target='/',
                body=f'body-{index}'.encode(),
                trusted_peers=peers,
                expected_recipient=bob.address,
                replay=bounded_replay,
            )
            bounded_accepts.append(accepted)
        with __import__('sqlite3').connect(bounded_replay_path) as replay_db:
            replay_rows = replay_db.execute(
                'SELECT COUNT(*) FROM replay_signatures'
            ).fetchone()[0]
        check(
            'replay cache enforces active-row and database-byte ceilings',
            bounded_accepts == [True, True, False]
            and replay_rows == 2
            and bounded_replay_path.stat().st_size <= 64 * 1024,
            repr((bounded_accepts, replay_rows, bounded_replay_path.stat().st_size)),
        )

        fresh = sign_delegation(
            alice, 'hello task', recipient=bob.address, task_id='task-2'
        )
        ok, why = verify(fresh, task_id='wrong')
        check('task-id substitution rejected', not ok and 'task id' in why, why)
        ok, why = verify(fresh, recipient=eve.address, task_id='task-2')
        check('recipient forwarding rejected', not ok and 'recipient' in why, why)
        ok, why = verify(fresh, 'EVIL task', task_id='task-2')
        check('payload tamper rejected', not ok and 'signature invalid' in why, why)

        no_nonce = sign_delegation(
            alice, 'y', recipient=bob.address, task_id='task-y'
        )
        del no_nonce['nonce']
        ok, why = verify(no_nonce, 'y', task_id='task-y')
        check('missing nonce rejected', not ok and 'nonce' in why, why)

        now = int(time.time())
        delayed = sign_delegation(
            alice,
            'offline',
            recipient=bob.address,
            task_id='offline-1',
            issued_at=now - 360,
            expires_at=now + 60,
        )
        ok, why = verify(delayed, 'offline', task_id='offline-1')
        check('six-minute offline task accepted before explicit expiry', ok, why)
        expired = sign_delegation(
            alice,
            'old',
            recipient=bob.address,
            task_id='old-1',
            issued_at=now - 60,
            expires_at=now - 1,
        )
        ok, why = verify(expired, 'old', task_id='old-1')
        check('expired task rejected', not ok and 'expired' in why, why)

        from unittest.mock import patch

        expiry_boundary = now + 120
        boundary_delegation = sign_delegation(
            alice,
            'boundary',
            recipient=bob.address,
            task_id='boundary-delegation',
            issued_at=expiry_boundary - 60,
            expires_at=expiry_boundary,
        )
        boundary_http = sign_http_request(
            alice,
            recipient=bob.address,
            method='POST',
            target='/',
            body=b'boundary',
            issued_at=expiry_boundary - 60,
            expires_at=expiry_boundary,
        )
        with patch(
            'team_agents.raven_identity.time.time',
            return_value=expiry_boundary,
        ):
            boundary_delegation_ok, boundary_delegation_why = verify(
                boundary_delegation,
                'boundary',
                task_id='boundary-delegation',
            )
            boundary_http_ok, boundary_http_why, _ = verify_http_request(
                boundary_http,
                method='POST',
                target='/',
                body=b'boundary',
                trusted_peers=peers,
                expected_recipient=bob.address,
                replay=ReplayCache(),
            )
        check(
            'delegation and HTTP expiry are exclusive at exact boundary',
            not boundary_delegation_ok
            and 'expired' in boundary_delegation_why
            and not boundary_http_ok
            and 'expired' in boundary_http_why,
            f'{boundary_delegation_why}; {boundary_http_why}',
        )

        (tmp / 'rev.json').write_text(json.dumps([alice.address]))
        revoked = load_revocations(tmp / 'rev.json')
        blk = sign_delegation(
            alice, 'z', recipient=bob.address, task_id='task-z'
        )
        ok, why = verify(blk, 'z', task_id='task-z', revoked=revoked)
        check('revoked sender rejected', not ok and 'revoked' in why, why)
        (tmp / 'rev.json').write_text('{broken')
        try:
            load_revocations(tmp / 'rev.json')
            check('broken revocation policy fails closed', False)
        except Exception:  # noqa: BLE001
            check('broken revocation policy fails closed', True)

        check('signed tasks required by default', NodeConfig().require_signed_tasks is True)
        unsafe_names_rejected = True
        for unsafe_name in ('.', '..', 'CON', '../escape', 'a/b', 'x' * 65):
            try:
                NodeConfig(name=unsafe_name)
                unsafe_names_rejected = False
            except ValueError:
                pass
        check(
            'node names are bounded and cross-platform path-safe',
            unsafe_names_rejected and NodeConfig(name='agent-1.prod').name == 'agent-1.prod',
        )

        # Fresh initialization must succeed with no global/system Git identity
        # and leave an explicit non-personal identity in this repository.
        init_home = tmp / 'fresh-init-no-global-git-identity'
        init_env = os.environ.copy()
        for variable in tuple(init_env):
            if variable.startswith('GIT_CONFIG_') or variable.startswith(
                ('GIT_AUTHOR_', 'GIT_COMMITTER_')
            ):
                init_env.pop(variable, None)
        init_env.update({
            'RDAP_HOME': str(init_home),
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': str(tmp / 'nonexistent-global-gitconfig'),
        })
        init_result = subprocess.run(
            [
                sys.executable,
                str(PKG_ROOT / 'rdap.py'),
                'init',
                '--name',
                'fresh-agent',
                '--role',
                'test',
                '--internet',
            ],
            cwd=PKG_ROOT,
            env=init_env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        initialized_repo = init_home / 'team-repo'
        init_identity = ''
        init_author = ''
        if init_result.returncode == 0:
            init_identity = (
                _git(initialized_repo, 'config', '--local', '--get', 'user.name')
                + ' <'
                + _git(initialized_repo, 'config', '--local', '--get', 'user.email')
                + '>'
            )
            init_author = _git(
                initialized_repo,
                'log', '-1', '--format=%an <%ae>',
            )
        check(
            'fresh init is independent of global Git identity',
            init_result.returncode == 0
            and init_identity == 'RDAP Agent <rdap@localhost.invalid>'
            and init_author == init_identity,
            (
                f'rc={init_result.returncode} identity={init_identity!r} '
                f'author={init_author!r} stderr={init_result.stderr[-500:]!r}'
            ),
        )

        initialized_tree = (
            _git(initialized_repo, 'ls-tree', '-r', '--name-only', 'HEAD')
            if init_result.returncode == 0 else ''
        )
        check(
            'fresh init commits only its explicit bootstrap allowlist',
            initialized_tree.splitlines() == ['.gitignore'],
            initialized_tree,
        )

        occupied_home = tmp / 'occupied-init-home'
        occupied_repo = occupied_home / 'team-repo'
        occupied_repo.mkdir(parents=True)
        occupied_file = occupied_repo / 'user-notes.txt'
        occupied_file.write_text('must remain private and uncommitted\n', encoding='utf-8')
        occupied_env = {**init_env, 'RDAP_HOME': str(occupied_home)}
        occupied_result = subprocess.run(
            [
                sys.executable,
                str(PKG_ROOT / 'rdap.py'),
                'init', '--name', 'must-refuse', '--role', 'test', '--internet',
            ],
            cwd=PKG_ROOT,
            env=occupied_env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        check(
            'init refuses an occupied unmanaged directory without Git mutation',
            occupied_result.returncode != 0
            and occupied_file.read_text(encoding='utf-8')
            == 'must remain private and uncommitted\n'
            and not (occupied_repo / '.git').exists()
            and not (occupied_repo / '.gitignore').exists(),
            occupied_result.stderr[-500:] + occupied_result.stdout[-500:],
        )

        existing_home = tmp / 'existing-history-init-home'
        existing_repo = existing_home / 'team-repo'
        existing_repo.mkdir(parents=True)
        _git(existing_repo, 'init', '-q')
        _git(existing_repo, 'config', 'user.name', 'Existing User')
        _git(existing_repo, 'config', 'user.email', 'existing@example.invalid')
        custom_ignore = '# project-owned\ncustom.cache\n'
        (existing_repo / '.gitignore').write_text(custom_ignore, encoding='utf-8')
        (existing_repo / 'tracked.txt').write_text('tracked\n', encoding='utf-8')
        _git(existing_repo, 'add', '--', '.gitignore', 'tracked.txt')
        _git(existing_repo, 'commit', '-q', '-m', 'existing history')
        existing_head = _git(existing_repo, 'rev-parse', 'HEAD')
        existing_untracked = existing_repo / 'user-draft.txt'
        existing_untracked.write_text('do not stage\n', encoding='utf-8')
        existing_env = {**init_env, 'RDAP_HOME': str(existing_home)}
        existing_result = subprocess.run(
            [
                sys.executable,
                str(PKG_ROOT / 'rdap.py'),
                'init', '--name', 'existing-agent', '--role', 'test', '--internet',
            ],
            cwd=PKG_ROOT,
            env=existing_env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        local_exclude = existing_repo / '.git' / 'info' / 'exclude'
        check(
            'init preserves existing history, ignore rules, and untracked files',
            existing_result.returncode == 0
            and _git(existing_repo, 'rev-parse', 'HEAD') == existing_head
            and (existing_repo / '.gitignore').read_text(encoding='utf-8')
            == custom_ignore
            and existing_untracked.read_text(encoding='utf-8') == 'do not stage\n'
            and '.team/keys/' in local_exclude.read_text(encoding='utf-8')
            and _git(existing_repo, 'status', '--short', '--untracked-files=all')
            == '?? user-draft.txt',
            f'rc={existing_result.returncode} stderr={existing_result.stderr[-500:]!r}',
        )

        # Existing homes are a migration path too: a user may have initialized
        # with an older version and later removed their global Git identity.
        init_migration_ok = False
        if init_result.returncode == 0:
            init_head = _git(initialized_repo, 'rev-parse', 'HEAD')
            _git(initialized_repo, 'config', '--unset-all', 'user.name')
            _git(initialized_repo, 'config', '--unset-all', 'user.email')
            migration_result = subprocess.run(
                [
                    sys.executable,
                    str(PKG_ROOT / 'rdap.py'),
                    'init',
                    '--name',
                    'ignored-on-rerun',
                    '--role',
                    'ignored-on-rerun',
                    '--internet',
                ],
                cwd=PKG_ROOT,
                env=init_env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            init_migration_ok = (
                migration_result.returncode == 0
                and _git(
                    initialized_repo,
                    'config', '--local', '--get', 'user.name',
                ) == 'RDAP Agent'
                and _git(
                    initialized_repo,
                    'config', '--local', '--get', 'user.email',
                ) == 'rdap@localhost.invalid'
                and _git(initialized_repo, 'rev-parse', 'HEAD') == init_head
            )
        check(
            're-running init repairs legacy local Git identity without a commit',
            init_migration_ok,
        )

        model_result = subprocess.run(
            [
                sys.executable,
                str(PKG_ROOT / 'rdap.py'),
                'model',
                'ollama',
                'llama3.2',
                '--base-url',
                'http://localhost:11434/v1',
            ],
            cwd=PKG_ROOT,
            env=init_env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        configured_model = json.loads(
            (init_home / 'rdap.json').read_text(encoding='utf-8')
        ).get('llm', {})
        check(
            'model CLI validates and persists a provider configuration',
            model_result.returncode == 0
            and configured_model == {
                'provider': 'ollama',
                'model': 'llama3.2',
                'base_url': 'http://localhost:11434/v1',
            },
            f'rc={model_result.returncode} state={configured_model!r} '
            f'stderr={model_result.stderr[-500:]!r}',
        )

        import rdap as rdap_cli

        no_route_refused = False
        with (
            patch.object(
                rdap_cli,
                'state',
                return_value={
                    'name': 'fresh-agent',
                    'address': alice.address,
                    'public_key': alice.public_hex,
                },
            ),
            patch.object(rdap_cli, 'lan_ip', return_value=''),
        ):
            try:
                rdap_cli.cmd_invite(
                    type('Args', (), {'port': 9001, 'ip': ''})()
                )
            except SystemExit as exc:
                no_route_refused = '--ip' in str(exc)
        check(
            'invite refuses a loopback lie when no default route exists',
            no_route_refused,
        )
        advertised_host_validation_ok = all(
            rdap_cli._validated_advertised_host(value) == value
            for value in ('192.168.1.8', 'alice.local')
        )
        for unsafe_host in (
            '::1',
            '[::1]',
            '192.168.1.8/path',
            '999.1.1.1',
            '255.255.255.255',
        ):
            try:
                rdap_cli._validated_advertised_host(unsafe_host)
                advertised_host_validation_ok = False
            except ValueError:
                pass
        check(
            'advertised endpoint is safe for the IPv4 listener and URL syntax',
            advertised_host_validation_ok,
        )

        import team_agents.memory as memory_mod
        from team_agents.memory import FileLockTimeout, TeamGitError, TeamMemory

        # Layout creation, claims, and BOARD projection are used concurrently
        # by the HTTP server, relay worker, and local CLI. Exercise separate
        # TeamMemory instances so this covers the filesystem lock, not merely
        # one object's in-memory state.
        from concurrent.futures import ThreadPoolExecutor

        concurrent_claim_repo = tmp / 'concurrent-claim-repo'

        def concurrent_claim(index: int) -> str:
            return TeamMemory(
                concurrent_claim_repo, auto_commit=False
            ).claim_file('shared.txt', f'owner-{index}')

        with ThreadPoolExecutor(max_workers=8) as pool:
            claim_results = list(pool.map(concurrent_claim, range(8)))
        check(
            'concurrent file claims produce exactly one winner',
            sum(result.startswith('ok: claimed') for result in claim_results) == 1,
            repr(claim_results),
        )

        concurrent_board_repo = tmp / 'concurrent-board-repo'

        def concurrent_task(index: int) -> dict:
            return TeamMemory(
                concurrent_board_repo, auto_commit=False
            ).set_task(
                title=f'task-{index}',
                task_id=f't-{index}',
                owner=f'owner-{index}',
            )

        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(concurrent_task, range(8)))
        concurrent_board_memory = TeamMemory(
            concurrent_board_repo, auto_commit=False
        )
        concurrent_board = concurrent_board_memory.read_board()
        check(
            'concurrent task writes preserve every delta and BOARD row',
            len(concurrent_board_memory._parse_board_rows()) == 8
            and all(
                f'| t-{index} | task-{index} | owner-{index} | open |'
                in concurrent_board
                for index in range(8)
            ),
            concurrent_board,
        )

        poisoned_delta_repo = tmp / 'poisoned-delta-repo'
        poisoned_memory = TeamMemory(poisoned_delta_repo, auto_commit=False)
        poisoned_memory.set_task(
            title='survives poison', task_id='safe-task', owner='safe-owner'
        )
        poison_writer = poisoned_delta_repo / '.team' / 'deltas' / 'poison'
        poison_writer.mkdir()
        (poison_writer / 'task-list.json').write_text('[]', encoding='utf-8')
        (poison_writer / 'task-bad-time.json').write_text(
            json.dumps({'w': 'poison', 'at': 'not-a-number', 'kind': 'task'}),
            encoding='utf-8',
        )
        poisoned_board = poisoned_memory.read_board()
        escaped_writer_file = poisoned_memory._delta('..').write(
            'task', {'id': 'hashed-writer', 'title': 'contained'}
        )
        (poison_writer / 'chat-overflow.json').write_text(
            json.dumps({
                'w': 'poison',
                'at': 1e308,
                'kind': 'chat',
                'sender': '\x1b[31mpoison',
                'text': 'must not wedge chat',
            }),
            encoding='utf-8',
        )
        (poison_writer / 'chat-huge-integer.json').write_text(
            json.dumps({
                'w': 'poison',
                'at': 10 ** 400,
                'kind': 'chat',
                'sender': 'poison',
                'text': 'must also be skipped',
            }),
            encoding='utf-8',
        )
        from team_agents.chat import TeamChat

        poisoned_chat = TeamChat(poisoned_memory).tail()
        check(
            'delta projection skips schema poison and contains unsafe writers',
            '| safe-task | survives poison | safe-owner | open |' in poisoned_board
            and escaped_writer_file.parent.parent
            == poisoned_memory.repo_path / '.team' / 'deltas'
            and escaped_writer_file.parent.name not in {'.', '..'}
            and poisoned_chat == '(empty)',
            f'{poisoned_board}\nchat={poisoned_chat}',
        )

        # A bounded scan must never sort an arbitrary filesystem-order prefix:
        # when the complete projection exceeds a cap it fails closed.
        from team_agents import deltas as delta_module

        capped_writer_repo = tmp / 'capped-delta-writers'
        capped_writer_memory = TeamMemory(capped_writer_repo, auto_commit=False)
        capped_writer_memory._delta('alpha').write(
            'task', {'id': 'alpha', 'title': 'alpha'}
        )
        capped_writer_memory._delta('beta').write(
            'task', {'id': 'beta', 'title': 'beta'}
        )
        with patch.object(delta_module, 'MAX_DELTA_WRITERS', 1):
            capped_writers = delta_module.DeltaStore(
                capped_writer_memory
            ).read('task')

        capped_file_repo = tmp / 'capped-delta-files'
        capped_file_memory = TeamMemory(capped_file_repo, auto_commit=False)
        capped_file_store = capped_file_memory._delta('alpha')
        capped_file_store.write('task', {'id': 'one', 'title': 'one'})
        capped_file_store.write('task', {'id': 'two', 'title': 'two'})
        with patch.object(delta_module, 'MAX_DELTA_DIRECTORY_ENTRIES', 2):
            capped_files = delta_module.DeltaStore(
                capped_file_memory
            ).read('task')
        check(
            'delta projection fails closed instead of starving capped entries',
            capped_writers == [] and capped_files == [],
            f'writers={capped_writers!r} files={capped_files!r}',
        )

        unsafe_goal_repo = tmp / 'unsafe-goal-repo'
        unsafe_goal_memory = TeamMemory(unsafe_goal_repo, auto_commit=False)
        unsafe_goal_memory.ensure_layout()
        unsafe_goal = unsafe_goal_repo / '.team' / 'GOAL.md'
        unsafe_goal.write_bytes(b'x' * (64 * 1024 + 1))
        from team_agents.llm import _team_goal

        oversized_goal_refused = _team_goal(unsafe_goal_memory) == ''
        symlink_goal_refused = True
        if os.name != 'nt':
            unsafe_goal.unlink()
            outside_goal = tmp / 'outside-goal.txt'
            outside_goal.write_text('must not enter the prompt\n', encoding='utf-8')
            unsafe_goal.symlink_to(outside_goal)
            symlink_goal_refused = _team_goal(unsafe_goal_memory) == ''
        check(
            'brain goal reader is bounded and refuses aliases',
            oversized_goal_refused and symlink_goal_refused,
        )

        # The live activity projection must stay bounded even when synced Git
        # state is malicious. It also must not follow an event/writer link or
        # expose arbitrary JSON fields and terminal control sequences.
        recent_repo = tmp / 'recent-events-repo'
        recent_repo.mkdir()
        recent_memory = TeamMemory(recent_repo, auto_commit=False)
        recent_memory.ensure_layout()
        recent_base = recent_memory.team_dir / 'deltas'
        alpha_events = recent_base / 'alpha'
        beta_events = recent_base / 'beta'
        alpha_events.mkdir(parents=True)
        beta_events.mkdir()

        def write_event(
            directory: Path,
            filename: str,
            writer: str,
            timestamp: float,
            text: str,
            **extra,
        ) -> Path:
            path = directory / filename
            path.write_text(
                json.dumps({
                    'w': writer,
                    'at': timestamp,
                    'kind': 'event',
                    'text': text,
                    **extra,
                }, ensure_ascii=False),
                encoding='utf-8',
            )
            return path

        write_event(alpha_events, 'event-001.json', 'alpha', 1, 'oldest')
        write_event(
            alpha_events,
            'event-003.json',
            'alpha',
            3,
            '\x1b[31mnewest\n\u202e' + ('x' * 500),
            private='must not be projected',
        )
        write_event(beta_events, 'event-002.json', 'beta', 2, 'middle')

        newest = recent_memory.recent_events(limit=2)
        check(
            'recent events preserve newest-first and limit semantics',
            [event['at'] for event in newest] == [3.0, 2.0]
            and recent_memory.recent_events(limit=0) == []
            and recent_memory.recent_events(limit=-5) == [],
            repr(newest),
        )
        projected = newest[0] if newest else {}
        check(
            'recent events expose only bounded terminal-safe fields',
            set(projected) == {'w', 'at', 'kind', 'text'}
            and len(projected.get('text', ''))
            <= memory_mod.MAX_RECENT_EVENT_TEXT_CHARS
            and all(
                __import__('unicodedata').category(character)
                not in {'Cc', 'Cf', 'Cs'}
                for character in projected.get('text', '')
            ),
            repr(projected),
        )

        write_event(
            alpha_events,
            'event-oversized.json',
            'alpha',
            999,
            'oversized-secret',
            padding='z' * (memory_mod.MAX_RECENT_EVENT_FILE_BYTES + 1),
        )
        (alpha_events / 'event-deeply-nested.json').write_text(
            ('[' * 1100) + '0' + (']' * 1100),
            encoding='utf-8',
        )
        outside_event = tmp / 'outside-event.json'
        outside_event.write_text(json.dumps({
            'w': 'alpha',
            'at': 1000,
            'kind': 'event',
            'text': 'linked-secret',
        }), encoding='utf-8')

        linked_file_supported = True
        try:
            (alpha_events / 'event-linked.json').symlink_to(outside_event)
        except (NotImplementedError, OSError):
            linked_file_supported = False

        hardlink_supported = True
        try:
            os.link(outside_event, alpha_events / 'event-hardlinked.json')
        except (NotImplementedError, OSError):
            hardlink_supported = False

        outside_writer = tmp / 'outside-writer'
        outside_writer.mkdir()
        write_event(
            outside_writer,
            'event-secret.json',
            'linked-writer',
            1001,
            'writer-link-secret',
        )
        linked_writer_supported = True
        try:
            (recent_base / 'linked-writer').symlink_to(
                outside_writer,
                target_is_directory=True,
            )
        except (NotImplementedError, OSError):
            linked_writer_supported = False

        link_checked = recent_memory.recent_events(limit=100)
        link_texts = {event['text'] for event in link_checked}
        check(
            'recent events reject malformed, oversized, linked and hardlinked input',
            'oversized-secret' not in link_texts
            and (not linked_file_supported or 'linked-secret' not in link_texts)
            and (not hardlink_supported or 'linked-secret' not in link_texts)
            and (
                not linked_writer_supported
                or 'writer-link-secret' not in link_texts
            ),
            repr(link_checked),
        )

        # Exercise every independent scan budget with small patched ceilings;
        # the counting iterator raises if recent_events asks the filesystem for
        # even one entry beyond its declared global/per-directory bounds.
        from unittest import mock

        bounded_repo = tmp / 'bounded-events-repo'
        bounded_repo.mkdir()
        bounded_memory = TeamMemory(bounded_repo, auto_commit=False)
        bounded_memory.ensure_layout()
        bounded_base = bounded_memory.team_dir / 'deltas'
        for writer_number in range(6):
            writer_name = f'writer-{writer_number}'
            writer_dir = bounded_base / writer_name
            writer_dir.mkdir(parents=True)
            for event_number in range(8):
                write_event(
                    writer_dir,
                    f'event-{event_number:03d}.json',
                    writer_name,
                    writer_number * 100 + event_number,
                    'y' * 80,
                )

        real_scandir = os.scandir
        real_stable_read = memory_mod._read_stable_regular_file
        scanned_total = 0
        scanned_by_path: dict[str, int] = {}
        scan_calls: list[str] = []
        stable_read_calls = 0
        stable_read_bytes = 0

        class CountingScandir:
            def __init__(self, path) -> None:
                self.path = os.path.normcase(os.path.abspath(os.fspath(path)))
                self.inner = real_scandir(path)
                scan_calls.append(self.path)

            def __enter__(self):
                self.inner.__enter__()
                return self

            def __exit__(self, *args):
                return self.inner.__exit__(*args)

            def __iter__(self):
                return self

            def __next__(self):
                nonlocal scanned_total
                entry = next(self.inner)
                scanned_total += 1
                scanned_by_path[self.path] = scanned_by_path.get(self.path, 0) + 1
                if scanned_total > 10:
                    raise AssertionError('recent event global scan exceeded bound')
                if (
                    self.path != os.path.normcase(os.path.abspath(bounded_base))
                    and scanned_by_path[self.path] > 3
                ):
                    raise AssertionError('recent event writer scan exceeded bound')
                return entry

        def counted_stable_read(*args, **kwargs):
            nonlocal stable_read_calls, stable_read_bytes
            stable_read_calls += 1
            payload, consumed = real_stable_read(*args, **kwargs)
            stable_read_bytes += consumed
            if stable_read_calls > 5 or stable_read_bytes > 400:
                raise AssertionError('recent event file/read budget exceeded')
            return payload, consumed

        with (
            mock.patch.multiple(
                memory_mod,
                MAX_RECENT_EVENT_WRITERS=2,
                MAX_RECENT_EVENT_DIRECTORY_ENTRIES=10,
                MAX_RECENT_EVENT_ENTRIES_PER_WRITER=3,
                MAX_RECENT_EVENT_FILES=5,
                MAX_RECENT_EVENT_FILE_BYTES=256,
                MAX_RECENT_EVENT_TOTAL_BYTES=400,
                MAX_RECENT_EVENTS_LIMIT=3,
            ),
            mock.patch.object(memory_mod.os, 'scandir', CountingScandir),
            mock.patch.object(
                memory_mod,
                '_read_stable_regular_file',
                counted_stable_read,
            ),
        ):
            bounded_events = bounded_memory.recent_events(limit=10_000)

        bounded_base_key = os.path.normcase(os.path.abspath(bounded_base))
        writer_scan_calls = [path for path in scan_calls if path != bounded_base_key]
        check(
            'recent event scan enforces writer/entry/file/byte/output ceilings',
            scanned_total <= 10
            and len(writer_scan_calls) <= 2
            and all(scanned_by_path[path] <= 3 for path in writer_scan_calls)
            and stable_read_calls <= 5
            and stable_read_bytes <= 400
            and len(bounded_events) <= 3,
            f'entries={scanned_total} writers={len(writer_scan_calls)} '
            f'files={stable_read_calls} bytes={stable_read_bytes} '
            f'output={len(bounded_events)}',
        )

        # Automatic memory sync must never sweep unrelated staged, unstaged or
        # private runtime files into the commit it pushes.
        scope_remote = tmp / 'scope-remote.git'
        subprocess.run(
            ['git', 'init', '--bare', '-q', str(scope_remote)],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        )
        scope_repo = tmp / 'scope-repo'
        scope_repo.mkdir()
        _git(scope_repo, 'init', '-q')
        _git(scope_repo, 'config', 'user.name', 'RDAP Selftest')
        _git(scope_repo, 'config', 'user.email', 'rdap-selftest@example.invalid')
        (scope_repo / 'tracked.txt').write_text('baseline\n', encoding='utf-8')
        _git(scope_repo, 'add', '--', 'tracked.txt')
        _git(scope_repo, 'commit', '-q', '-m', 'baseline')
        _git(scope_repo, 'branch', '-M', 'main')
        _git(scope_repo, 'remote', 'add', 'origin', str(scope_remote))
        _git(scope_repo, 'push', '-q', '-u', 'origin', 'main')

        # Adversarial push routing must not redirect an automatic sync away
        # from the branch's configured fetch/upstream remote.
        redirect_remote = tmp / 'scope-redirect.git'
        subprocess.run(
            ['git', 'init', '--bare', '-q', str(redirect_remote)],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        )
        _git(scope_repo, 'remote', 'add', 'redirect', str(redirect_remote))
        _git(scope_repo, 'push', '-q', 'redirect', 'main')
        _git(scope_repo, 'branch', 'extra')
        _git(scope_repo, 'push', '-q', 'origin', 'extra')
        _git(scope_repo, 'push', '-q', 'redirect', 'extra')
        _git(scope_repo, 'switch', '-q', 'extra')
        (scope_repo / 'extra-only.txt').write_text(
            'must not be pushed automatically\n', encoding='utf-8'
        )
        _git(scope_repo, 'add', '--', 'extra-only.txt')
        _git(scope_repo, 'commit', '-q', '-m', 'local extra branch change')
        _git(scope_repo, 'switch', '-q', 'main')
        _git(scope_repo, 'tag', '-a', 'automatic-leak', '-m', 'must stay local')
        _git(scope_repo, 'config', 'branch.main.pushRemote', 'redirect')
        _git(scope_repo, 'config', 'remote.pushDefault', 'redirect')
        _git(scope_repo, 'config', 'push.default', 'matching')
        _git(scope_repo, 'config', 'push.followTags', 'true')
        _git(scope_repo, 'config', 'push.prune', 'true')

        scoped_memory = TeamMemory(scope_repo)
        scoped_memory.log_event('scope-test', 'team-only sync')
        private_dir = scope_repo / '.team' / 'keys'
        private_dir.mkdir(parents=True, exist_ok=True)
        (private_dir / 'private.seed').write_text('must stay local\n', encoding='utf-8')
        (scope_repo / 'tracked.txt').write_text('user staged change\n', encoding='utf-8')
        _git(scope_repo, 'add', '--', 'tracked.txt')
        (scope_repo / 'untracked-secret.txt').write_text(
            'must stay local\n', encoding='utf-8'
        )
        if os.name != 'nt':
            # Automatic commits must also suppress a repository post-commit
            # hook that would otherwise stage an unrelated secret afterward.
            post_commit = scope_repo / '.git' / 'hooks' / 'post-commit'
            post_commit.write_text(
                '#!/bin/sh\ngit add -- untracked-secret.txt\n', encoding='utf-8'
            )
            post_commit.chmod(0o700)
            reference_hook = (
                scope_repo / '.git' / 'hooks' / 'reference-transaction'
            )
            reference_hook.write_text(
                '#!/bin/sh\ngit add -- untracked-secret.txt\n', encoding='utf-8'
            )
            reference_hook.chmod(0o700)
        scoped_memory.sync()

        memory_commit_paths = set(
            _git(
                scope_repo, 'show', '--format=', '--name-only', '--no-renames', 'HEAD'
            ).splitlines()
        )
        staged_after_sync = set(
            _git(scope_repo, 'diff', '--cached', '--name-only').splitlines()
        )
        remote_tree = set(
            _git(scope_repo, 'ls-tree', '-r', '--name-only', 'origin/main').splitlines()
        )
        redirect_tree = set(
            _git(
                redirect_remote,
                'ls-tree',
                '-r',
                '--name-only',
                'refs/heads/main',
            ).splitlines()
        )
        origin_extra_tree = set(
            _git(
                scope_remote,
                'ls-tree',
                '-r',
                '--name-only',
                'refs/heads/extra',
            ).splitlines()
        )
        redirect_extra_tree = set(
            _git(
                redirect_remote,
                'ls-tree',
                '-r',
                '--name-only',
                'refs/heads/extra',
            ).splitlines()
        )
        origin_tags = set(
            _git(
                scope_remote,
                'for-each-ref',
                '--format=%(refname)',
                'refs/tags',
            ).splitlines()
        )
        temporary_sync_refs = set(
            _git(
                scope_repo,
                'for-each-ref',
                '--format=%(refname)',
                'refs/raven-automatic-sync',
            ).splitlines()
        )
        check(
            'memory sync commits and pushes only allowlisted team state',
            bool(memory_commit_paths)
            and all(TeamMemory.is_shared_team_path(p) for p in memory_commit_paths)
            and all(TeamMemory.is_shared_team_path(p) for p in remote_tree - {'tracked.txt'}),
            f'commit={sorted(memory_commit_paths)}',
        )
        check(
            'memory sync preserves unrelated staged and untracked changes',
            staged_after_sync == {'tracked.txt'}
            and _git(scope_repo, 'show', 'HEAD:tracked.txt') == 'baseline'
            and (scope_repo / 'untracked-secret.txt').exists()
            and 'untracked-secret.txt' not in remote_tree,
            f'staged={sorted(staged_after_sync)} remote={sorted(remote_tree)}',
        )
        check(
            'memory sync excludes private .team runtime state',
            '.team/keys/private.seed' not in remote_tree
            and (private_dir / 'private.seed').exists(),
        )
        check(
            'automatic push pins one upstream ref despite adversarial push config',
            redirect_tree == {'tracked.txt'}
            and origin_extra_tree == {'tracked.txt'}
            and redirect_extra_tree == {'tracked.txt'}
            and 'refs/tags/automatic-leak' not in origin_tags
            and not temporary_sync_refs
            and any(path.startswith('.team/') for path in remote_tree),
            f'upstream={sorted(remote_tree)} redirect={sorted(redirect_tree)} '
            f'extra={sorted(origin_extra_tree)}',
        )

        # Even a fetched commit is not fast-forwarded automatically if it
        # changes a normal project path rather than shared team state.
        remote_writer = tmp / 'scope-remote-writer'
        _git(
            tmp,
            'clone',
            '-q',
            '--branch',
            'main',
            str(scope_remote),
            str(remote_writer),
        )
        _git(remote_writer, 'config', 'user.name', 'RDAP Selftest')
        _git(remote_writer, 'config', 'user.email', 'rdap-selftest@example.invalid')
        remote_team_file = (
            remote_writer / '.team' / 'deltas' / 'remote-agent' / 'event-safe.json'
        )
        remote_team_file.parent.mkdir(parents=True, exist_ok=True)
        remote_team_file.write_text('{"text":"safe team delta"}\n', encoding='utf-8')
        _git(remote_writer, 'add', '--', str(remote_team_file.relative_to(remote_writer)))
        _git(remote_writer, 'commit', '-q', '-m', 'remote team delta')
        _git(remote_writer, 'push', '-q')
        scoped_memory.pull_team()
        check(
            'memory sync fast-forwards verified team-only history',
            (scope_repo / remote_team_file.relative_to(remote_writer)).exists()
            and set(
                _git(scope_repo, 'diff', '--cached', '--name-only').splitlines()
            ) == {'tracked.txt'},
        )

        (remote_writer / 'remote-project-file.txt').write_text(
            'out of automatic scope\n', encoding='utf-8'
        )
        _git(remote_writer, 'add', '--', 'remote-project-file.txt')
        _git(remote_writer, 'commit', '-q', '-m', 'unrelated remote change')
        _git(remote_writer, 'push', '-q')
        head_before_refusal = _git(scope_repo, 'rev-parse', 'HEAD')
        try:
            scoped_memory.pull_team()
            refused_remote_project_change = False
        except TeamGitError:
            refused_remote_project_change = True
        check(
            'memory sync fails closed on non-team remote history',
            refused_remote_project_change
            and _git(scope_repo, 'rev-parse', 'HEAD') == head_before_refusal
            and not (scope_repo / 'remote-project-file.txt').exists(),
        )

        # A real remote commit can encode a symlink without requiring symlink
        # privileges on the test host. It must be rejected before checkout.
        link_remote = tmp / 'scope-link-remote.git'
        subprocess.run(
            ['git', 'init', '--bare', '-q', str(link_remote)],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        )
        link_repo = tmp / 'scope-link-repo'
        link_repo.mkdir()
        _git(link_repo, 'init', '-q')
        _git(link_repo, 'config', 'user.name', 'RDAP Selftest')
        _git(link_repo, 'config', 'user.email', 'rdap-selftest@example.invalid')
        (link_repo / 'tracked.txt').write_text('baseline\n', encoding='utf-8')
        _git(link_repo, 'add', '--', 'tracked.txt')
        _git(link_repo, 'commit', '-q', '-m', 'baseline')
        _git(link_repo, 'branch', '-M', 'main')
        _git(link_repo, 'remote', 'add', 'origin', str(link_remote))
        _git(link_repo, 'push', '-q', '-u', 'origin', 'main')
        link_writer = tmp / 'scope-link-writer'
        _git(
            tmp,
            'clone',
            '-q',
            '--branch',
            'main',
            str(link_remote),
            str(link_writer),
        )
        _git(link_writer, 'config', 'user.name', 'RDAP Selftest')
        _git(link_writer, 'config', 'user.email', 'rdap-selftest@example.invalid')
        payload_file = link_writer / 'symlink-payload.txt'
        payload_file.write_text('../../../../outside-secret\n', encoding='utf-8')
        payload_oid = _git(link_writer, 'hash-object', '-w', '--', payload_file.name)
        malicious_link = '.team/deltas/malicious/escape-link'
        _git(
            link_writer,
            'update-index',
            '--add',
            '--cacheinfo',
            '120000',
            payload_oid,
            malicious_link,
        )
        _git(link_writer, 'commit', '-q', '-m', 'malicious team symlink')
        _git(link_writer, 'push', '-q')
        malicious_mode = _git(
            link_writer, 'ls-tree', 'HEAD', '--', malicious_link
        )
        link_memory = TeamMemory(link_repo)
        link_head_before = _git(link_repo, 'rev-parse', 'HEAD')
        try:
            link_memory.pull_team()
            refused_remote_symlink = False
        except TeamGitError:
            refused_remote_symlink = True
        check(
            'memory sync rejects a remote .team symlink before checkout',
            malicious_mode.startswith('120000 blob ')
            and refused_remote_symlink
            and _git(link_repo, 'rev-parse', 'HEAD') == link_head_before
            and not os.path.lexists(link_repo / malicious_link),
            malicious_mode,
        )

        # The relay uses the same scoped commit path. Its local replay database
        # and unrelated user changes must remain outside the relay commit.
        from team_agents.relay import GitRelay

        relay_scope_repo = tmp / 'relay-scope-repo'
        relay_scope_repo.mkdir()
        _git(relay_scope_repo, 'init', '-q')
        _git(relay_scope_repo, 'config', 'user.name', 'RDAP Selftest')
        _git(
            relay_scope_repo,
            'config',
            'user.email',
            'rdap-selftest@example.invalid',
        )
        (relay_scope_repo / 'tracked.txt').write_text('baseline\n', encoding='utf-8')
        _git(relay_scope_repo, 'add', '--', 'tracked.txt')
        _git(relay_scope_repo, 'commit', '-q', '-m', 'baseline')
        relay_scope_remote = tmp / 'relay-scope-remote.git'
        subprocess.run(
            ['git', 'init', '--bare', '-q', str(relay_scope_remote)],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        )
        _git(relay_scope_repo, 'branch', '-M', 'main')
        _git(relay_scope_repo, 'remote', 'add', 'origin', str(relay_scope_remote))
        _git(relay_scope_repo, 'push', '-q', '-u', 'origin', 'main')
        relay_scope = GitRelay(
            TeamMemory(relay_scope_repo), alice, trusted_peers=_peers(bob)
        )
        (relay_scope_repo / 'tracked.txt').write_text(
            'user staged change\n', encoding='utf-8'
        )
        _git(relay_scope_repo, 'add', '--', 'tracked.txt')
        (relay_scope_repo / 'untracked-secret.txt').write_text(
            'must stay local\n', encoding='utf-8'
        )
        relay_task_file = relay_scope.send_task(bob.address, 'scope relay task')
        relay_commit_paths = set(
            _git(
                relay_scope_repo,
                'show',
                '--format=',
                '--name-only',
                '--no-renames',
                'HEAD',
            ).splitlines()
        )
        relay_staged = set(
            _git(relay_scope_repo, 'diff', '--cached', '--name-only').splitlines()
        )
        relay_tree = set(
            _git(relay_scope_repo, 'ls-tree', '-r', '--name-only', 'HEAD').splitlines()
        )
        check(
            'Git relay never stages or commits unrelated project changes',
            bool(relay_commit_paths)
            and all(TeamMemory.is_shared_team_path(p) for p in relay_commit_paths)
            and relay_staged == {'tracked.txt'}
            and _git(relay_scope_repo, 'show', 'HEAD:tracked.txt') == 'baseline'
            and 'untracked-secret.txt' not in relay_tree,
            f'commit={sorted(relay_commit_paths)} staged={sorted(relay_staged)}',
        )
        check(
            'Git relay excludes its private replay cache',
            '.team/keys/replay-cache.sqlite3' not in relay_tree
            and (relay_scope_repo / '.team' / 'keys' / 'replay-cache.sqlite3').exists(),
        )
        relay_task_rel = str(
            relay_task_file.relative_to(relay_scope.memory.repo_path)
        )
        relay_task_file.unlink()
        TeamMemory(relay_scope_repo).commit_team('relay deletion scope test')
        check(
            'team-scoped commits record relay deletions without touching user staging',
            relay_task_rel not in set(
                _git(relay_scope_repo, 'ls-tree', '-r', '--name-only', 'HEAD').splitlines()
            )
            and set(
                _git(relay_scope_repo, 'diff', '--cached', '--name-only').splitlines()
            ) == {'tracked.txt'},
        )
        if os.name != 'nt':
            nested_link = relay_scope_repo / '.team' / 'outputs' / 'nested-link'
            nested_link.symlink_to(relay_scope_repo / 'untracked-secret.txt')
            operational_head = _git(relay_scope_repo, 'rev-parse', 'HEAD')
            try:
                TeamMemory(relay_scope_repo).commit_team('must reject nested link')
                refused_operational_link = False
            except TeamGitError:
                refused_operational_link = True
            check(
                'operational team tree recursively rejects nested symlinks',
                refused_operational_link
                and _git(relay_scope_repo, 'rev-parse', 'HEAD') == operational_head,
            )
            nested_link.unlink()
            special_file = relay_scope_repo / '.team' / 'outputs' / 'special-fifo'
            os.mkfifo(special_file, 0o600)
            try:
                TeamMemory(relay_scope_repo).commit_team('must reject special file')
                refused_special_file = False
            except TeamGitError:
                refused_special_file = True
            check(
                'operational team tree rejects special files',
                refused_special_file
                and _git(relay_scope_repo, 'rev-parse', 'HEAD') == operational_head,
            )
            special_file.unlink()

        # Project writes and git_commit are not exposed by default, and direct
        # dispatch still denies writes. Enabling the already high-risk shell
        # capability is an explicit operator grant for both.
        import asyncio

        from team_agents.tools import ToolBox

        safe_tools_repo = tmp / 'safe-tools'
        unsafe_tools_repo = tmp / 'unsafe-tools'
        safe_box = ToolBox(
            NodeConfig(repo_path=safe_tools_repo, allow_shell=False),
            TeamMemory(safe_tools_repo, auto_commit=False),
        )
        unsafe_box = ToolBox(
            NodeConfig(repo_path=unsafe_tools_repo, allow_shell=True),
            TeamMemory(unsafe_tools_repo, auto_commit=False),
        )
        safe_names = {
            tool['function']['name'] for tool in safe_box.schemas()
        }
        unsafe_names = {
            tool['function']['name'] for tool in unsafe_box.schemas()
        }

        ordinary_file = safe_tools_repo / 'docs' / 'overview.md'
        ordinary_file.parent.mkdir(parents=True, exist_ok=True)
        ordinary_file.write_text('ordinary project documentation', encoding='utf-8')
        env_file = safe_tools_repo / '.env'
        env_file.write_text('TOP_SECRET_ENV=must-not-leak', encoding='utf-8')
        git_config = safe_tools_repo / '.git' / 'config'
        git_config.parent.mkdir(parents=True, exist_ok=True)
        git_config.write_text('credential = must-not-leak', encoding='utf-8')
        seed_file = safe_tools_repo / '.team' / 'keys' / 'device_ed25519.seed'
        seed_file.parent.mkdir(parents=True, exist_ok=True)
        seed_file.write_text('seed-must-not-leak', encoding='utf-8')
        mesh_private = safe_tools_repo / '.team' / 'mesh-store' / 'private.bin'
        mesh_private.parent.mkdir(parents=True, exist_ok=True)
        mesh_private.write_bytes(b'mesh-private-must-not-leak')
        client_secret = safe_tools_repo / 'config' / 'client_secret.json'
        client_secret.parent.mkdir(parents=True, exist_ok=True)
        client_secret.write_text('{"secret":"must-not-leak"}', encoding='utf-8')

        denied_reads = {
            path: asyncio.run(safe_box.dispatch('read_file', {'path': path}))
            for path in (
                '.env',
                '.git/config',
                '.team/keys/device_ed25519.seed',
                '.team/mesh-store/private.bin',
                'config/client_secret.json',
                'docs/../.env',
                'ordinary.txt:secret-stream',
                '.git /config',
                'GIT~1/config',
            )
        }
        ordinary_read = asyncio.run(
            safe_box.dispatch('read_file', {'path': 'docs/overview.md'})
        )
        visible_files = asyncio.run(safe_box.dispatch('list_files', {}))
        safe_box.memory.ensure_layout()
        safe_box.memory.board_md.write_text(
            'UNVALIDATED-BOARD-POISON\n' + ('x' * (1024 * 1024)),
            encoding='utf-8',
        )
        projected_board = asyncio.run(safe_box.dispatch('board_read', {}))
        check(
            'board tool derives a bounded delta projection instead of reading BOARD.md',
            projected_board.startswith('# Team Board')
            and 'UNVALIDATED-BOARD-POISON' not in projected_board,
        )

        # A harmless-looking alias must not bypass either the lexical policy or
        # the final file-identity checks. Windows CI cannot always create links
        # without Developer Mode, so the actual link test is POSIX-gated just
        # like the seed-symlink test below.
        symlink_denied = True
        if os.name != 'nt':
            alias = safe_tools_repo / 'innocent-link.txt'
            alias.symlink_to('.env')
            symlink_result = asyncio.run(
                safe_box.dispatch('read_file', {'path': alias.name})
            )
            symlink_denied = symlink_result.startswith('ERROR:')

        hardlink = safe_tools_repo / 'innocent-hardlink.txt'
        os.link(env_file, hardlink)
        hardlink_result = asyncio.run(
            safe_box.dispatch('read_file', {'path': hardlink.name})
        )

        unsafe_seed = unsafe_tools_repo / '.team' / 'keys' / 'device_ed25519.seed'
        unsafe_seed.parent.mkdir(parents=True, exist_ok=True)
        unsafe_seed.write_text('operator-mode-seed-must-not-leak', encoding='utf-8')
        unsafe_seed_result = asyncio.run(
            unsafe_box.dispatch(
                'read_file', {'path': '.team/keys/device_ed25519.seed'}
            )
        )
        check(
            'read_file denies secrets, runtime state, traversal and aliases',
            ordinary_read == 'ordinary project documentation'
            and all(result.startswith('ERROR:') for result in denied_reads.values())
            and all('must-not-leak' not in result for result in denied_reads.values())
            and symlink_denied
            and hardlink_result.startswith('ERROR:')
            and unsafe_seed_result.startswith('ERROR:')
            and '.env' not in visible_files
            and 'client_secret.json' not in visible_files,
            f'denied={denied_reads} hardlink={hardlink_result} '
            f'operator={unsafe_seed_result}',
        )

        denied_commit = asyncio.run(
            safe_box.dispatch('git_commit', {'message': 'must be denied'})
        )
        denied_write = asyncio.run(
            safe_box.dispatch(
                'write_file',
                {'path': 'must-not-exist.txt', 'content': 'denied'},
            )
        )
        check(
            'agent git_commit requires explicit high-risk authorization',
            'git_commit' not in safe_names
            and 'git_commit' in unsafe_names
            and denied_commit.startswith('ERROR:'),
            denied_commit,
        )
        allowed_write = asyncio.run(
            unsafe_box.dispatch(
                'write_file',
                {'path': 'operator-enabled.txt', 'content': 'allowed'},
            )
        )
        check(
            'project write_file requires explicit high-risk authorization',
            'write_file' not in safe_names
            and 'write_file' in unsafe_names
            and denied_write.startswith('ERROR:')
            and not (tmp / 'safe-tools' / 'must-not-exist.txt').exists()
            and allowed_write.startswith('wrote ')
            and (tmp / 'unsafe-tools' / 'operator-enabled.txt').read_text(
                encoding='utf-8'
            ) == 'allowed',
            f'denied={denied_write} allowed={allowed_write}',
        )

        # Filesystem/Git/tool bodies and the echo brain are synchronous. Their
        # async entry points must yield while that work is on a worker thread.
        import types

        from team_agents.llm import EchoBrain

        mutated_name_cfg = NodeConfig(
            name='safe-name',
            repo_path=tmp / 'mutated-output-name',
        )
        mutated_name_cfg.name = '../escape-after-init'
        mutated_name_memory = TeamMemory(
            mutated_name_cfg.repo_path, auto_commit=False
        )
        try:
            asyncio.run(
                EchoBrain(mutated_name_cfg, mutated_name_memory).run('probe')
            )
            mutated_output_refused = False
        except ValueError:
            mutated_output_refused = True
        check(
            'echo output revalidates mutated node-name containment',
            mutated_output_refused
            and not (mutated_name_cfg.repo_path / '.team' / 'outputs').exists(),
        )

        blocking_cfg = NodeConfig(
            name='blocking-test',
            repo_path=tmp / 'blocking-test',
        )
        blocking_memory = TeamMemory(
            blocking_cfg.repo_path, auto_commit=False
        )
        blocking_box = ToolBox(blocking_cfg, blocking_memory)
        blocking_brain = EchoBrain(blocking_cfg, blocking_memory)

        def slow_echo(_text):
            time.sleep(0.3)
            return 'echo-worker-finished'

        async def slow_tool(_self):
            time.sleep(0.3)
            return 'tool-worker-finished'

        blocking_brain._run_blocking = slow_echo
        blocking_box.tool_blocking_probe = types.MethodType(
            slow_tool, blocking_box
        )

        async def exercise_event_loop_offload():
            async def stays_responsive(awaitable):
                started_at = time.monotonic()
                task = asyncio.create_task(awaitable)
                await asyncio.sleep(0.03)
                heartbeat_elapsed = time.monotonic() - started_at
                result = await task
                return heartbeat_elapsed < 0.2, result

            return await asyncio.gather(
                stays_responsive(blocking_brain.run('probe')),
                stays_responsive(blocking_box.dispatch('blocking_probe', {})),
            )

        offload_results = asyncio.run(exercise_event_loop_offload())
        check(
            'blocking brain and tool work stays off the ASGI event loop',
            offload_results == [
                (True, 'echo-worker-finished'),
                (True, 'tool-worker-finished'),
            ],
            repr(offload_results),
        )

        # final_answer is invocation-local: malformed calls and overlapping
        # requests must never observe another task's previous result.
        from team_agents.config import LLMConfig
        from team_agents.llm import OpenAIBrain

        answer_cfg = NodeConfig(
            name='answer-test',
            repo_path=tmp / 'answer-state',
            llm=LLMConfig(
                provider='custom',
                model='scripted',
                base_url='https://llm.example.invalid/v1',
            ),
        )
        answer_box = ToolBox(
            answer_cfg, TeamMemory(answer_cfg.repo_path, auto_commit=False)
        )

        class ScriptedAnswerBrain(OpenAIBrain):
            async def _chat(self, client, messages):
                task = messages[1]['content']
                tool_results = [m for m in messages if m['role'] == 'tool']
                if task == 'private-a':
                    arguments = json.dumps({'answer': 'CLIENT A PRIVATE ANSWER'})
                elif task == 'malformed-b' and not tool_results:
                    arguments = '{}'
                elif task == 'malformed-b':
                    return {'content': 'safe fallback after malformed call'}
                else:
                    await asyncio.sleep(0)
                    arguments = json.dumps({'answer': f'answer-for:{task}'})
                return {
                    'content': None,
                    'tool_calls': [{
                        'id': 'call-' + task,
                        'function': {
                            'name': 'final_answer',
                            'arguments': arguments,
                        },
                    }],
                }

        answer_brain = ScriptedAnswerBrain(answer_cfg, answer_cfg.llm, answer_box)

        async def exercise_local_answers():
            first = await answer_brain.run('private-a')
            malformed = await answer_brain.run('malformed-b')
            concurrent = await asyncio.gather(
                answer_brain.run('concurrent-a'),
                answer_brain.run('concurrent-b'),
            )
            return first, malformed, concurrent

        first_answer, malformed_answer, concurrent_answers = asyncio.run(
            exercise_local_answers()
        )
        check(
            'malformed final_answer cannot reuse a previous task result',
            first_answer == 'CLIENT A PRIVATE ANSWER'
            and malformed_answer == 'safe fallback after malformed call'
            and 'CLIENT A PRIVATE ANSWER' not in malformed_answer,
            repr((first_answer, malformed_answer)),
        )
        check(
            'concurrent final_answer calls remain invocation-local',
            concurrent_answers == [
                'answer-for:concurrent-a',
                'answer-for:concurrent-b',
            ],
            repr(concurrent_answers),
        )

        credential_names = (
            'OPENAI_API_KEY', 'GROQ_API_KEY', 'OPENROUTER_API_KEY',
            'LLM_API_KEY',
        )
        saved_credentials = {
            name: os.environ.get(name) for name in credential_names
        }
        try:
            for name in credential_names:
                os.environ.pop(name, None)
            os.environ.update({
                'OPENAI_API_KEY': 'openai-only',
                'GROQ_API_KEY': 'groq-only',
                'OPENROUTER_API_KEY': 'openrouter-only',
                'LLM_API_KEY': 'legacy-must-be-ignored',
            })
            groq_key = LLMConfig(provider='groq').api_key()
            openrouter_key = LLMConfig(provider='openrouter').api_key()
            ollama_key = LLMConfig(
                provider='ollama', base_url='http://localhost:11434/v1'
            ).api_key()
            custom_key = LLMConfig(
                provider='custom',
                base_url='https://private-llm.example/v1',
                _api_key='endpoint-specific',
            ).api_key()
            try:
                LLMConfig(
                    provider='openai',
                    base_url='https://attacker.example/v1',
                )
                arbitrary_origin_refused = False
            except ValueError:
                arbitrary_origin_refused = True
            try:
                LLMConfig(
                    provider='custom',
                    base_url='http://private-llm.example/v1',
                    _api_key='must-not-cross-http',
                )
                custom_http_refused = False
            except ValueError:
                custom_http_refused = True
        finally:
            for name, value in saved_credentials.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        check(
            'LLM credentials are provider-bound and never fall back globally',
            groq_key == 'groq-only'
            and openrouter_key == 'openrouter-only'
            and ollama_key == ''
            and custom_key == 'endpoint-specific'
            and arbitrary_origin_refused
            and custom_http_refused,
            repr({
                'groq': groq_key,
                'openrouter': openrouter_key,
                'ollama': ollama_key,
                'custom': custom_key,
                'arbitrary_refused': arbitrary_origin_refused,
                'http_refused': custom_http_refused,
            }),
        )
        private_cache = '.team/keys/replay-cache.sqlite3'
        _git(relay_scope_repo, 'add', '--', private_cache)
        explicit_head = _git(relay_scope_repo, 'rev-parse', 'HEAD')
        try:
            TeamMemory(relay_scope_repo).commit_staged(
                'must refuse private state', explicitly_authorized=True
            )
            refused_private_commit = False
        except TeamGitError:
            refused_private_commit = True
        check(
            'authorized git_commit still refuses private .team state',
            refused_private_commit
            and _git(relay_scope_repo, 'rev-parse', 'HEAD') == explicit_head,
        )

        # The git critical section must contend across *processes*, stop after
        # a bounded wait, and become acquirable as soon as the holder releases.

        lock_repo = tmp / 'cross-platform-lock'
        ready_path = tmp / 'holder.ready'
        holder_code = (
            'import sys, time\n'
            'from pathlib import Path\n'
            'from team_agents.memory import TeamMemory\n'
            'repo_path, ready_path = Path(sys.argv[1]), Path(sys.argv[2])\n'
            'memory = TeamMemory(repo_path, auto_commit=False)\n'
            'with memory._git_lock(timeout=2.0):\n'
            "    ready_path.write_text('locked', encoding='utf-8')\n"
            '    time.sleep(1.2)\n'
        )
        child_env = {
            **os.environ,
            'PYTHONPATH': str(PKG_ROOT) + os.pathsep + os.environ.get('PYTHONPATH', ''),
        }
        holder = subprocess.Popen(
            [sys.executable, '-c', holder_code, str(lock_repo), str(ready_path)],
            cwd=PKG_ROOT,
            env=child_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            deadline = time.monotonic() + 4.0
            while not ready_path.exists() and holder.poll() is None \
                    and time.monotonic() < deadline:
                time.sleep(0.02)
            holder_ready = ready_path.exists() and holder.poll() is None
            detail = ''
            if not holder_ready:
                output, _ = holder.communicate(timeout=2)
                detail = output[-1000:]
            check('cross-process lock holder acquired', holder_ready, detail)

            timed_out = False
            elapsed = 0.0
            if holder_ready:
                started = time.monotonic()
                try:
                    with TeamMemory(lock_repo, auto_commit=False)._git_lock(timeout=0.2):
                        pass
                except FileLockTimeout:
                    timed_out = True
                elapsed = time.monotonic() - started
            check(
                'contended lock times out and fails closed',
                timed_out and 0.15 <= elapsed < 1.5,
                f'elapsed={elapsed:.3f}s',
            )
        finally:
            if holder.poll() is None:
                try:
                    holder.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    holder.terminate()
                    holder.wait(timeout=2)

        released = False
        try:
            with TeamMemory(lock_repo, auto_commit=False)._git_lock(timeout=0.5):
                released = True
        except Exception:  # noqa: BLE001
            released = False
        check('lock is acquirable after holder release', released)

        # Simulate a Python where importing fcntl raises.  Import must still
        # succeed; on this POSIX runner (where msvcrt is also absent), trying to
        # lock must raise FileLockUnavailable rather than proceeding unlocked.
        no_fcntl_code = r'''
import builtins
import contextlib
import errno
import json
import os
import pathlib
import re
import stat
import subprocess
import tempfile
import threading
import time
import uuid

real_import = builtins.__import__
def guarded_import(name, *args, **kwargs):
    if name == 'fcntl':
        raise ImportError('simulated platform without fcntl')
    return real_import(name, *args, **kwargs)
builtins.__import__ = guarded_import

from team_agents import memory
assert memory._fcntl is None
if memory._msvcrt is None:
    try:
        with memory._exclusive_file_lock(pathlib.Path(tempfile.mkdtemp()) / 'x'):
            raise AssertionError('entered without an OS lock backend')
    except memory.FileLockUnavailable:
        pass
print('import-without-fcntl-ok')
'''
        no_fcntl = subprocess.run(
            [sys.executable, '-c', no_fcntl_code],
            cwd=PKG_ROOT,
            env=child_env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        check(
            'memory imports without fcntl and never falls back unlocked',
            no_fcntl.returncode == 0
            and 'import-without-fcntl-ok' in no_fcntl.stdout,
            (no_fcntl.stdout + no_fcntl.stderr)[-1000:],
        )

        # Existing seed paths must not be symlinks or group/world-readable.
        if os.name != 'nt':
            insecure = tmp / 'insecure'
            insecure.mkdir()
            (insecure / 'device_ed25519.seed').write_text('00' * 32)
            (insecure / 'device_ed25519.seed').chmod(0o644)
            try:
                RavenIdentity.load_or_create(insecure)
                check('insecure seed permissions rejected', False)
            except PermissionError:
                check('insecure seed permissions rejected', True)
            link_dir = tmp / 'link'
            link_dir.mkdir()
            (link_dir / 'device_ed25519.seed').symlink_to(tmp / 'a' / 'device_ed25519.seed')
            try:
                RavenIdentity.load_or_create(link_dir)
                check('seed symlink rejected', False)
            except ValueError:
                check('seed symlink rejected', True)

        # ---- signed Agent Card JWS + pinned verification ----------------
        from team_agents.client import verify_card_signature
        from team_agents.server import build_agent_card, build_app, serve

        import socket as socket_mod

        occupied_socket = socket_mod.socket(
            socket_mod.AF_INET, socket_mod.SOCK_STREAM
        )
        if os.name == 'nt' and hasattr(socket_mod, 'SO_EXCLUSIVEADDRUSE'):
            occupied_socket.setsockopt(
                socket_mod.SOL_SOCKET,
                socket_mod.SO_EXCLUSIVEADDRUSE,
                1,
            )
        occupied_socket.bind(('127.0.0.1', 0))
        occupied_socket.listen(1)
        occupied_port = occupied_socket.getsockname()[1]
        occupied_refused = False
        occupied_cfg = NodeConfig(
            repo_path=tmp / 'occupied-port',
            host='127.0.0.1',
            port=occupied_port,
        )
        try:
            serve(occupied_cfg)
        except RuntimeError as exc:
            occupied_refused = (
                str(occupied_port) in str(exc)
                and occupied_cfg.port == occupied_port
            )
        finally:
            occupied_socket.close()
        check(
            'server refuses occupied advertised port instead of silently moving',
            occupied_refused,
        )

        card_cfg = NodeConfig(repo_path=tmp / 'card')
        signed = build_agent_card(card_cfg, alice)
        check('card has JWS signature', bool(signed.signatures))
        try:
            fp = verify_card_signature(
                signed,
                expected_address=alice.address,
                expected_public_key=alice.public_hex,
            )
            check('pinned card verifies', fp == alice.fingerprint)
        except Exception as exc:  # noqa: BLE001
            check('pinned card verifies', False, repr(exc))
        try:
            verify_card_signature(
                signed,
                expected_address=eve.address,
                expected_public_key=eve.public_hex,
            )
            check('card signed by unpinned peer rejected', False)
        except Exception:  # noqa: BLE001
            check('card signed by unpinned peer rejected', True)

        check('mailbox extension absent by default', not signed.capabilities.extensions)
        open_card = build_agent_card(
            NodeConfig(repo_path=tmp / 'open', require_signed_tasks=False), alice
        )
        check('explicit open mode is loud in public card', 'OPEN MODE' in open_card.description)
        auth_cfg = NodeConfig(repo_path=tmp / 'auth', auth_token='secret')
        auth_app = build_app(auth_cfg)
        check('Bearer app preserves Starlette state', auth_app.state.config is auth_cfg)
        auth_card = build_agent_card(auth_cfg, auth_app.state.raven)
        check('Bearer advertised only when configured', bool(auth_card.security_schemes))

        async def exercise_bearer_middleware() -> dict[str, int]:
            transport = httpx.ASGITransport(app=auth_app)
            async with httpx.AsyncClient(
                transport=transport,
                base_url='http://asgi.test',
            ) as client:
                public_card = await client.get('/.well-known/agent-card.json')
                missing = await client.get('/health')
                wrong = await client.get(
                    '/health',
                    headers={'Authorization': 'Bearer wrong'},
                )
                accepted = await client.get(
                    '/health',
                    headers={'Authorization': 'Bearer secret'},
                )
                activity = await client.get(
                    '/raven/activity',
                    headers={'Authorization': 'Bearer secret'},
                )
            return {
                'card': public_card.status_code,
                'missing': missing.status_code,
                'wrong': wrong.status_code,
                'accepted': accepted.status_code,
                'activity': activity.status_code,
            }

        bearer_statuses = asyncio.run(exercise_bearer_middleware())
        check(
            'Bearer middleware is enforced independently with ASGI transport',
            bearer_statuses == {
                'card': 200,
                'missing': 401,
                'wrong': 401,
                'accepted': 200,
                'activity': 200,
            },
            repr(bearer_statuses),
        )

        unauth_activity_app = build_app(
            NodeConfig(repo_path=tmp / 'activity-without-auth')
        )

        async def exercise_disabled_activity() -> int:
            transport = httpx.ASGITransport(app=unauth_activity_app)
            async with httpx.AsyncClient(
                transport=transport,
                base_url='http://asgi.test',
            ) as client:
                response = await client.get('/raven/activity')
                return response.status_code

        check(
            'remote activity fails closed without configured Bearer auth',
            asyncio.run(exercise_disabled_activity()) == 403,
        )

        from team_agents.client import (
            MAX_PUBLIC_DOCUMENT_BYTES,
            PublicDocumentTooLarge,
            UnsafeBearerTransportError,
            get_bounded_json_async,
            require_secure_bearer_transport,
        )

        try:
            require_secure_bearer_transport('http://127.0.0.1:9999', 'secret')
            plaintext_bearer_rejected = False
        except UnsafeBearerTransportError:
            plaintext_bearer_rejected = True
        require_secure_bearer_transport('https://agent.example', 'secret')
        check(
            'outbound Bearer requires HTTPS even for loopback',
            plaintext_bearer_rejected,
        )

        async def exercise_bounded_public_document():
            transport = httpx.MockTransport(lambda request: httpx.Response(
                200,
                content=b'x' * (MAX_PUBLIC_DOCUMENT_BYTES + 1),
                request=request,
            ))
            async with httpx.AsyncClient(transport=transport) as client:
                try:
                    await get_bounded_json_async(client, 'https://peer.test/card')
                    return False
                except PublicDocumentTooLarge:
                    return True

        check(
            'remote card/identity fetches stop at the metadata byte cap',
            asyncio.run(exercise_bounded_public_document()),
        )

        async def identity_policy_document():
            transport = httpx.ASGITransport(app=unauth_activity_app)
            async with httpx.AsyncClient(
                transport=transport, base_url='http://asgi.test'
            ) as client:
                return (await client.get('/raven/identity')).json()

        public_identity = asyncio.run(identity_policy_document())
        check(
            'public Raven identity does not disclose trust/revocation graph',
            'trusted_peers' not in public_identity['policy']
            and 'revoked' not in public_identity['policy'],
            repr(public_identity['policy']),
        )

        # The SDK's stock in-memory task store is unbounded. Verify our
        # replacement's copy semantics, global count/byte bound, terminal-first
        # eviction, active-task protection and deterministic idle TTL.
        from a2a.server.context import ServerCallContext
        from a2a.types import ListTasksRequest, Task, TaskState, TaskStatus
        from team_agents.config import (
            HARD_TASK_STORE_MAX_BYTES,
            HARD_TASK_STORE_MAX_COUNT,
            HARD_TASK_STORE_TTL_SECONDS,
        )
        from team_agents.task_store import BoundedTaskStore, TaskStoreCapacityError

        clock = [100.0]
        bounded_store = BoundedTaskStore(
            max_count=4,
            max_bytes=64 * 1024,
            ttl_seconds=10,
            clock=lambda: clock[0],
        )
        store_context = ServerCallContext()

        def stored_task(task_id, state):
            return Task(
                id=task_id,
                context_id='bounded-context',
                status=TaskStatus(state=state),
            )

        async def exercise_bounded_store():
            await asyncio.gather(*(
                bounded_store.save(
                    stored_task(f'rejected-{index}', TaskState.TASK_STATE_REJECTED),
                    store_context,
                )
                for index in range(50)
            ))
            rejected_stats = await bounded_store.stats()
            await asyncio.gather(*(
                bounded_store.save(
                    stored_task(f'failed-{index}', TaskState.TASK_STATE_FAILED),
                    store_context,
                )
                for index in range(20)
            ))
            terminal_stats = await bounded_store.stats()
            valid = stored_task('valid-result', TaskState.TASK_STATE_COMPLETED)
            await bounded_store.save(valid, store_context)
            fetched = await bounded_store.get('valid-result', store_context)
            fetched.context_id = 'caller-mutated-copy'
            fetched_again = await bounded_store.get('valid-result', store_context)
            await bounded_store.save(
                stored_task('valid-result', TaskState.TASK_STATE_REJECTED),
                store_context,
            )
            preserved_after_rejection = await bounded_store.get(
                'valid-result', store_context
            )
            listed = await bounded_store.list(ListTasksRequest(), store_context)
            first_page = await bounded_store.list(
                ListTasksRequest(page_size=2), store_context
            )
            second_page = await bounded_store.list(
                ListTasksRequest(page_size=2, page_token=first_page.next_page_token),
                store_context,
            )
            paged_ids = {
                task.id for task in (*first_page.tasks, *second_page.tasks)
            }

            owner_store = BoundedTaskStore(
                max_count=4,
                max_bytes=64 * 1024,
                ttl_seconds=60,
                owner_resolver=lambda context: context.tenant,
            )
            owner_a = ServerCallContext(tenant='owner-a')
            owner_b = ServerCallContext(tenant='owner-b')
            await owner_store.save(
                stored_task('same-id', TaskState.TASK_STATE_COMPLETED), owner_a
            )
            await owner_store.save(
                stored_task('same-id', TaskState.TASK_STATE_FAILED), owner_b
            )
            owner_a_task = await owner_store.get('same-id', owner_a)
            owner_b_task = await owner_store.get('same-id', owner_b)

            active_clock = [200.0]
            active_store = BoundedTaskStore(
                max_count=2,
                max_bytes=64 * 1024,
                ttl_seconds=60,
                clock=lambda: active_clock[0],
            )
            await active_store.save(
                stored_task('active-a', TaskState.TASK_STATE_WORKING), store_context
            )
            await active_store.save(
                stored_task('active-b', TaskState.TASK_STATE_WORKING), store_context
            )
            try:
                await active_store.save(
                    stored_task('must-refuse', TaskState.TASK_STATE_SUBMITTED),
                    store_context,
                )
                active_refused = False
            except TaskStoreCapacityError:
                active_refused = True
            active_clock[0] += 61
            active_stats = await active_store.stats()

            byte_store = BoundedTaskStore(
                max_count=4,
                max_bytes=1024,
                ttl_seconds=60,
            )
            oversized = stored_task('oversized', TaskState.TASK_STATE_COMPLETED)
            oversized.metadata['payload'] = 'x' * 4096
            try:
                await byte_store.save(oversized, store_context)
                byte_refused = False
            except TaskStoreCapacityError:
                byte_refused = True

            clock[0] += 11
            expired_stats = await bounded_store.stats()
            return {
                'rejected': rejected_stats,
                'terminal': terminal_stats,
                'valid': await bounded_store.get('valid-result', store_context),
                'copy_context': fetched_again.context_id,
                'preserved_state': preserved_after_rejection.status.state,
                'listed': listed.total_size,
                'pagination_ok': (
                    first_page.total_size == 4
                    and len(first_page.tasks) == 2
                    and len(second_page.tasks) == 2
                    and len(paged_ids) == 4
                ),
                'owner_scoped': (
                    owner_a_task.status.state == TaskState.TASK_STATE_COMPLETED
                    and owner_b_task.status.state == TaskState.TASK_STATE_FAILED
                ),
                'active_refused': active_refused,
                'active': active_stats,
                'byte_refused': byte_refused,
                'expired': expired_stats,
            }

        bounded_result = asyncio.run(exercise_bounded_store())
        check(
            'bounded task store is race-safe, copy-safe and fail-closed',
            bounded_result['rejected']['count'] == 0
            and bounded_result['terminal']['count'] == 4
            and bounded_result['terminal']['bytes'] <= 64 * 1024
            and bounded_result['copy_context'] == 'bounded-context'
            and bounded_result['preserved_state']
            == TaskState.TASK_STATE_COMPLETED
            and bounded_result['listed'] <= 4
            and bounded_result['pagination_ok']
            and bounded_result['owner_scoped']
            and bounded_result['active_refused']
            and bounded_result['active']['count'] == 2
            and bounded_result['byte_refused']
            and bounded_result['expired']['count'] == 0
            and bounded_result['valid'] is None,
            repr(bounded_result),
        )

        hard_env_limits = {
            'TEAM_TASK_STORE_MAX_COUNT': HARD_TASK_STORE_MAX_COUNT + 1,
            'TEAM_TASK_STORE_MAX_BYTES': HARD_TASK_STORE_MAX_BYTES + 1,
            'TEAM_TASK_STORE_TTL_SECONDS': HARD_TASK_STORE_TTL_SECONDS + 1,
        }
        hard_env_rejections = []
        for variable, value in hard_env_limits.items():
            previous_store_limit = os.environ.get(variable)
            os.environ[variable] = str(value)
            try:
                try:
                    NodeConfig.from_env()
                    hard_env_rejections.append(False)
                except ValueError:
                    hard_env_rejections.append(True)
            finally:
                if previous_store_limit is None:
                    os.environ.pop(variable, None)
                else:
                    os.environ[variable] = previous_store_limit
        check(
            'task-store environment tuning cannot exceed compiled hard max',
            all(hard_env_rejections),
        )

        # Rejected direct A2A ingress must be durable-mutation-free. The executor
        # emits one terminal rejected Task for clean SDK dispatch; BoundedTaskStore
        # drops it, while TeamMemory, Git sync and brain calls remain absent.
        from team_agents.executor import TeamAgentExecutor
        from team_agents.memory import TeamMemory
        from a2a.types import TaskState

        class SpyMemory(TeamMemory):
            def __init__(self, repo_path):
                super().__init__(repo_path, auto_commit=False)
                self.logged: list[tuple[str, str]] = []
                self.sync_count = 0

            def log_event(self, agent, text):
                self.logged.append((agent, text))
                super().log_event(agent, text)

            def sync(self):
                self.sync_count += 1
                return super().sync()

        class NeverBrain:
            def __init__(self):
                self.calls = 0

            async def run(self, text, cancel_event=None):
                self.calls += 1
                return 'unexpected'

        class FakeContext:
            current_task = None

            def __init__(self, task_id, text, metadata, owner=''):
                self.task_id = task_id
                self.context_id = 'ctx-' + task_id
                self._text = text
                user = type('FakeUser', (), {
                    'user_name': owner,
                    'is_authenticated': bool(owner),
                })()
                self.call_context = type('FakeCallContext', (), {
                    'user': user,
                    'tenant': owner,
                })()
                self.message = type('FakeMessage', (), {
                    'message_id': task_id,
                    'metadata': metadata,
                })()

            def get_user_input(self):
                return self._text

        class CaptureQueue:
            def __init__(self):
                self.events = []

            async def enqueue_event(self, event):
                self.events.append(event)

        ingress_repo = tmp / 'rejected-ingress'
        ingress_memory = SpyMemory(ingress_repo)
        ingress_brain = NeverBrain()
        ingress_cfg = NodeConfig(
            name='ingress-test',
            repo_path=ingress_repo,
            trusted_peers={**_peers(alice), **_peers(eve)},
        )
        ingress_executor = TeamAgentExecutor(
            ingress_cfg,
            ingress_brain,
            ingress_memory,
            trusted_peers={**_peers(alice), **_peers(eve)},
            identity=bob,
        )
        pristine_ingress = _tree_snapshot(ingress_repo)

        async def exercise_rejected_executor():
            unsigned_queue = CaptureQueue()
            await ingress_executor.execute(
                FakeContext(
                    'unsigned-ingress',
                    'ATTACKER TEXT MUST NEVER REACH TEAM MEMORY',
                    {},
                    owner=alice.address,
                ),
                unsigned_queue,
            )
            unsigned_rejected = any(
                isinstance(event, Task)
                and event.status.state == TaskState.TASK_STATE_REJECTED
                and 'raven delegation rejected' in str(event).lower()
                for event in unsigned_queue.events
            )

            broken_policy = tmp / 'broken-ingress-peers.json'
            broken_policy.write_text('{broken', encoding='utf-8')
            ingress_cfg.trusted_peers_file = str(broken_policy)
            signed_text = 'signed but policy unavailable'
            signed_meta = sign_delegation(
                alice,
                signed_text,
                recipient=bob.address,
                task_id='policy-failure',
            )
            policy_queue = CaptureQueue()
            await ingress_executor.execute(
                FakeContext(
                    'policy-failure',
                    signed_text,
                    {f'raven.{key}': value for key, value in signed_meta.items()},
                    owner=alice.address,
                ),
                policy_queue,
            )
            policy_rejected = any(
                isinstance(event, Task)
                and event.status.state == TaskState.TASK_STATE_REJECTED
                and 'raven delegation rejected' in str(event).lower()
                for event in policy_queue.events
            )
            ingress_cfg.trusted_peers_file = ''
            forwarded_text = 'valid Alice envelope forwarded under Eve transport'
            forwarded_meta = sign_delegation(
                alice,
                forwarded_text,
                recipient=bob.address,
                task_id='forwarded-before-replay',
            )
            forwarded_queue = CaptureQueue()
            await ingress_executor.execute(
                FakeContext(
                    'forwarded-before-replay',
                    forwarded_text,
                    {
                        f'raven.{key}': value
                        for key, value in forwarded_meta.items()
                    },
                    owner=eve.address,
                ),
                forwarded_queue,
            )
            forwarded_rejected_without_replay = (
                any(
                    isinstance(event, Task)
                    and event.status.state == TaskState.TASK_STATE_REJECTED
                    for event in forwarded_queue.events
                )
                and forwarded_meta['signature'] not in ingress_executor.replay
            )
            return (
                unsigned_rejected,
                policy_rejected,
                forwarded_rejected_without_replay,
            )

        unsigned_rejected, policy_rejected, forwarded_rejected = asyncio.run(
            exercise_rejected_executor()
        )
        check(
            'unsigned executor rejection has zero durable/team side effects',
            unsigned_rejected
            and not ingress_memory.logged
            and ingress_memory.sync_count == 0
            and ingress_brain.calls == 0
            and _tree_snapshot(ingress_repo) == pristine_ingress,
        )
        check(
            'authorization-policy exception rejects without durable mutation',
            policy_rejected
            and not ingress_memory.logged
            and ingress_memory.sync_count == 0
            and ingress_brain.calls == 0
            and _tree_snapshot(ingress_repo) == pristine_ingress,
        )
        check(
            'transport/delegation mismatch rejects before replay insertion',
            forwarded_rejected,
        )

        # Exercise chunked-size, body-time and saturation limits independently
        # of HTTP client conveniences, then prove build_app wires the limit in.
        from team_agents.server import RpcIngressLimitMiddleware

        def rpc_scope(headers=()):
            return {
                'type': 'http',
                'asgi': {'version': '3.0'},
                'http_version': '1.1',
                'method': 'POST',
                'scheme': 'http',
                'path': '/',
                'raw_path': b'/',
                'query_string': b'',
                'headers': list(headers),
                'client': ('127.0.0.1', 1),
                'server': ('127.0.0.1', 2),
            }

        async def exercise_ingress_limits():
            calls = 0

            def capture(bucket):
                async def send(event):
                    bucket.append(event)

                return send

            async def downstream(scope, receive, send):
                nonlocal calls
                calls += 1
                await receive()

            limiter = RpcIngressLimitMiddleware(
                downstream,
                max_body_bytes=8,
                max_concurrent=1,
                body_timeout_seconds=0.05,
                queue_timeout_seconds=0.02,
            )
            oversized_messages = iter([
                {'type': 'http.request', 'body': b'12345', 'more_body': True},
                {'type': 'http.request', 'body': b'6789', 'more_body': False},
            ])

            async def oversized_receive():
                return next(oversized_messages)

            oversized_sent = []
            await limiter(rpc_scope(), oversized_receive, capture(oversized_sent))
            oversized_status = next(
                event['status'] for event in oversized_sent
                if event['type'] == 'http.response.start'
            )

            async def slow_receive():
                await asyncio.sleep(0.2)
                return {'type': 'http.request', 'body': b'', 'more_body': False}

            slow_sent = []
            await limiter(rpc_scope(), slow_receive, capture(slow_sent))
            slow_status = next(
                event['status'] for event in slow_sent
                if event['type'] == 'http.response.start'
            )

            entered = asyncio.Event()
            release = asyncio.Event()

            async def blocking_downstream(scope, receive, send):
                await receive()
                entered.set()
                await release.wait()

            saturated = RpcIngressLimitMiddleware(
                blocking_downstream,
                max_body_bytes=8,
                max_concurrent=1,
                body_timeout_seconds=1,
                queue_timeout_seconds=0.02,
            )

            async def empty_receive():
                return {'type': 'http.request', 'body': b'', 'more_body': False}

            first_sent = []
            first = asyncio.create_task(
                saturated(rpc_scope(), empty_receive, capture(first_sent))
            )
            await entered.wait()
            saturated_sent = []
            await saturated(rpc_scope(), empty_receive, capture(saturated_sent))
            saturated_status = next(
                event['status'] for event in saturated_sent
                if event['type'] == 'http.response.start'
            )
            release.set()
            await first
            return oversized_status, slow_status, saturated_status, calls

        oversized_status, slow_status, saturated_status, ingress_calls = asyncio.run(
            exercise_ingress_limits()
        )
        check(
            'RPC ingress bounds chunked body, body time and concurrency',
            oversized_status == 413
            and slow_status == 408
            and saturated_status == 503
            and ingress_calls == 0,
        )

        limited_repo = tmp / 'limited-app'
        limited_cfg = NodeConfig(
            repo_path=limited_repo,
            auth_token='limited-secret',
            max_rpc_body_bytes=32,
        )
        limited_app = build_app(limited_cfg)
        pristine_limited = _tree_snapshot(limited_repo)

        async def exercise_wired_limit():
            transport = httpx.ASGITransport(app=limited_app)
            async with httpx.AsyncClient(
                transport=transport,
                base_url='http://test',
                headers={'Authorization': 'Bearer limited-secret'},
            ) as client:
                return await client.post('/', content=b'x' * 33)

        limited_response = asyncio.run(exercise_wired_limit())
        check(
            'oversized RPC is rejected before SDK and durable state',
            limited_response.status_code == 413
            and _tree_snapshot(limited_repo) == pristine_limited,
        )

        # Drive many unique unsigned IDs through the real JSON-RPC handler,
        # then send an authenticated task through that same saturated store.
        bounded_app_cfg = NodeConfig(
            repo_path=tmp / 'bounded-app',
            public_url='http://test',
            trusted_peers=_peers(alice),
            auto_commit_memory=False,
            task_store_max_count=4,
            task_store_max_bytes=256 * 1024,
            task_store_ttl_seconds=60,
        )
        bounded_app = build_app(bounded_app_cfg)

        async def exercise_bounded_app():
            import a2a.client.client as a2a_client_mod
            from a2a.client import A2ACardResolver, ClientConfig, ClientFactory
            from a2a.types import Role
            from team_agents.client import RavenHttpAuth, _response_text
            from team_agents.server import RavenPeerUser

            transport = httpx.ASGITransport(app=bounded_app)
            async with httpx.AsyncClient(
                transport=transport,
                base_url='http://test',
                auth=RavenHttpAuth(alice, bounded_app.state.raven.address),
            ) as http:
                card = await A2ACardResolver(
                    httpx_client=http, base_url='http://test/'
                ).get_agent_card()
                client = ClientFactory(ClientConfig(
                    streaming=False,
                    polling=False,
                    httpx_client=http,
                )).create(card)

                async def send_message(message):
                    request = a2a_client_mod.SendMessageRequest(message=message)
                    pieces = []
                    async for response in client.send_message(request):
                        pieces.append(_response_text(response))
                    return '\n'.join(pieces).lower()

                try:
                    rejected = []
                    for index in range(20):
                        message = (
                            a2a_client_mod.SendMessageRequest().message.__class__()
                        )
                        message.message_id = f'unique-unsigned-{index}'
                        message.role = Role.Value('ROLE_USER')
                        message.parts.add().text = f'invalid task {index}'
                        rejected.append(await send_message(message))
                    after_invalid = await bounded_app.state.task_store.stats()

                    valid_id = 'bounded-valid-' + os.urandom(8).hex()
                    valid_text = (
                        '  valid task survives bounded store pressure\n'
                    )
                    valid_message = (
                        a2a_client_mod.SendMessageRequest().message.__class__()
                    )
                    valid_message.message_id = valid_id
                    valid_message.role = Role.Value('ROLE_USER')
                    valid_message.parts.add().text = valid_text
                    valid_block = sign_delegation(
                        alice,
                        valid_text,
                        recipient=bounded_app.state.raven.address,
                        task_id=valid_id,
                    )
                    for key, value in valid_block.items():
                        valid_message.metadata[f'raven.{key}'] = str(value)
                    valid_response = await send_message(valid_message)
                    after_valid = await bounded_app.state.task_store.stats()
                    completed_request = ListTasksRequest(
                        status=TaskState.TASK_STATE_COMPLETED
                    )
                    completed_tasks = await bounded_app.state.task_store.list(
                        completed_request,
                        ServerCallContext(
                            user=RavenPeerUser(alice.address),
                            tenant=alice.address,
                        ),
                    )
                    return (
                        rejected,
                        after_invalid,
                        valid_response,
                        after_valid,
                        completed_tasks,
                    )
                finally:
                    await client.close()

        (
            rejected_responses,
            bounded_after_invalid,
            bounded_valid_response,
            bounded_after_valid,
            bounded_completed_tasks,
        ) = asyncio.run(exercise_bounded_app())
        check(
            'unique invalid RPC tasks cannot grow the live task store unbounded',
            all('rejected' in response for response in rejected_responses)
            and bounded_after_invalid['count'] <= bounded_app_cfg.task_store_max_count
            and bounded_after_invalid['bytes'] <= bounded_app_cfg.task_store_max_bytes,
            repr(bounded_after_invalid),
        )
        check(
            'valid signed flow preserves wire whitespace during authentication',
            'completed' in bounded_valid_response
            and bounded_completed_tasks.total_size >= 1
            and all(
                task.status.state == TaskState.TASK_STATE_COMPLETED
                for task in bounded_completed_tasks.tasks
            )
            and bounded_after_valid['count'] <= bounded_app_cfg.task_store_max_count
            and bounded_after_valid['bytes'] <= bounded_app_cfg.task_store_max_bytes,
            f'response={bounded_valid_response[:160]} stats={bounded_after_valid}',
        )

        # Exercise deployed JSON-RPC routes with two independently signed
        # Raven HTTP principals. SDK live-task registry lookups must not bypass
        # the owner-scoped store for Get/List/Subscribe/Cancel.
        isolation_app = build_app(NodeConfig(
            repo_path=tmp / 'owner-isolation-app',
            public_url='http://isolation.test',
            trusted_peers={**_peers(alice), **_peers(bob)},
            auto_commit_memory=False,
        ))

        class SlowBrain:
            def __init__(self):
                self.started = asyncio.Event()
                self.started_texts: set[str] = set()

            async def run(self, task_text, *, cancel_event=None):
                self.started_texts.add(task_text)
                self.started.set()
                if cancel_event is None:
                    await asyncio.Future()
                await cancel_event.wait()
                return 'CANCELLED'

        slow_brain = SlowBrain()
        isolation_app.state.executor.brain = slow_brain

        async def exercise_real_route_owner_isolation():
            import a2a.client.client as a2a_client_mod
            from a2a.client import A2ACardResolver, ClientConfig, ClientFactory
            from a2a.types import Role, TaskState
            from team_agents.client import RavenHttpAuth

            transport = httpx.ASGITransport(app=isolation_app)
            async with httpx.AsyncClient(
                transport=transport, base_url='http://isolation.test'
            ) as public_http:
                card = await A2ACardResolver(
                    httpx_client=public_http,
                    base_url='http://isolation.test/',
                ).get_agent_card()

            async def make_client(identity):
                http = httpx.AsyncClient(
                    transport=transport,
                    base_url='http://isolation.test',
                    auth=RavenHttpAuth(identity, isolation_app.state.raven.address),
                )
                client = ClientFactory(ClientConfig(
                    streaming=False,
                    polling=False,
                    httpx_client=http,
                )).create(card)
                return http, client

            http_a, client_a = await make_client(alice)
            http_b, client_b = await make_client(bob)
            try:
                async def send_long_task(client, identity, message_id, text):
                    message = (
                        a2a_client_mod.SendMessageRequest().message.__class__()
                    )
                    message.message_id = message_id
                    message.role = Role.Value('ROLE_USER')
                    message.parts.add().text = text
                    signed = sign_delegation(
                        identity,
                        text,
                        recipient=isolation_app.state.raven.address,
                        task_id=message_id,
                    )
                    for key, value in signed.items():
                        message.metadata[f'raven.{key}'] = str(value)
                    request = a2a_client_mod.SendMessageRequest(message=message)
                    request.configuration.return_immediately = True
                    returned = None
                    async for response in client.send_message(request):
                        if response.task is not None:
                            returned = response.task
                    if returned is None:
                        raise AssertionError('long-running request returned no Task')
                    return returned

                async def wait_started(text):
                    async def poll():
                        while text not in slow_brain.started_texts:
                            await asyncio.sleep(0.01)

                    await asyncio.wait_for(poll(), timeout=3)

                message_id = 'owner-a-' + os.urandom(8).hex()
                text = 'CLIENT A PRIVATE LONG-RUNNING TASK'
                private_task = await send_long_task(
                    client_a, alice, message_id, text
                )
                task_id = private_task.id
                await asyncio.wait_for(slow_brain.started.wait(), timeout=3)

                listed_a = await client_a.list_tasks(
                    a2a_client_mod.ListTasksRequest(include_artifacts=True)
                )
                listed_b = await client_b.list_tasks(
                    a2a_client_mod.ListTasksRequest(include_artifacts=True)
                )
                got_a = await client_a.get_task(
                    a2a_client_mod.GetTaskRequest(id=task_id)
                )

                async def denied(awaitable):
                    try:
                        await awaitable
                        return False
                    except Exception:
                        return True

                get_b_denied = await denied(client_b.get_task(
                    a2a_client_mod.GetTaskRequest(id=task_id)
                ))
                cancel_b_denied = await denied(client_b.cancel_task(
                    a2a_client_mod.CancelTaskRequest(id=task_id)
                ))

                async def subscribe_b_once():
                    async for _ in client_b.subscribe(
                        a2a_client_mod.SubscribeToTaskRequest(id=task_id)
                    ):
                        return

                subscribe_b_denied = await denied(subscribe_b_once())
                canceled = await client_a.cancel_task(
                    a2a_client_mod.CancelTaskRequest(id=task_id)
                )

                # A2A task IDs are client controlled.  Two owners may choose the
                # same generated ID (a custom SDK IDGenerator is supported).
                # Force that legitimate collision, then exercise the deployed
                # per-owner registry and cancellation map on real JSON-RPC
                # routes.
                from a2a.server.agent_execution import SimpleRequestContextBuilder
                from a2a.server.id_generator import IDGenerator

                collision_id = 'shared-' + os.urandom(8).hex()

                class FixedTaskIdGenerator(IDGenerator):
                    def generate(self, context):
                        return collision_id

                isolation_app.state.handler._request_context_builder = (
                    SimpleRequestContextBuilder(
                        should_populate_referred_tasks=False,
                        task_store=isolation_app.state.task_store,
                        task_id_generator=FixedTaskIdGenerator(),
                    )
                )
                collision_a_text = 'OWNER A SAME-ID TASK'
                collision_b_text = 'OWNER B SAME-ID TASK'
                collision_a_returned = await send_long_task(
                    client_a, alice, collision_id, collision_a_text
                )
                await wait_started(collision_a_text)
                collision_b_returned = await send_long_task(
                    client_b, bob, collision_id, collision_b_text
                )
                await wait_started(collision_b_text)
                collision_a = await client_a.get_task(
                    a2a_client_mod.GetTaskRequest(id=collision_id)
                )
                collision_b = await client_b.get_task(
                    a2a_client_mod.GetTaskRequest(id=collision_id)
                )
                await client_a.cancel_task(
                    a2a_client_mod.CancelTaskRequest(id=collision_id)
                )
                collision_b_after_a_cancel = await client_b.get_task(
                    a2a_client_mod.GetTaskRequest(id=collision_id)
                )
                await client_b.cancel_task(
                    a2a_client_mod.CancelTaskRequest(id=collision_id)
                )

                unsigned_body = json.dumps({
                    'jsonrpc': '2.0',
                    'id': 'unsigned-list',
                    'method': 'ListTasks',
                    'params': {},
                }).encode()
                async with httpx.AsyncClient(
                    transport=transport,
                    base_url='http://isolation.test',
                ) as unsigned_http:
                    unsigned_status = (
                        await unsigned_http.post('/', content=unsigned_body)
                    ).status_code
                return {
                    'task_id': task_id,
                    'a_ids': {task.id for task in listed_a.tasks},
                    'b_ids': {task.id for task in listed_b.tasks},
                    'got_a': got_a.id,
                    'get_b_denied': get_b_denied,
                    'cancel_b_denied': cancel_b_denied,
                    'subscribe_b_denied': subscribe_b_denied,
                    'canceled': canceled.status.state,
                    'canceled_value': TaskState.TASK_STATE_CANCELED,
                    'collision_a_context': collision_a.context_id,
                    'collision_b_context': collision_b.context_id,
                    'collision_a_id': collision_a_returned.id,
                    'collision_b_id': collision_b_returned.id,
                    'collision_expected_id': collision_id,
                    'collision_b_after_a_cancel': (
                        collision_b_after_a_cancel.status.state
                    ),
                    'unsigned_status': unsigned_status,
                }
            finally:
                await client_a.close()
                await client_b.close()
                await http_a.aclose()
                await http_b.aclose()
                await isolation_app.state.handler.aclose()

        isolated = asyncio.run(exercise_real_route_owner_isolation())
        check(
            'real routes isolate List/Get/Subscribe/Cancel by signed Raven owner',
            bool(isolated['task_id'])
            and isolated['task_id'] in isolated['a_ids']
            and isolated['task_id'] not in isolated['b_ids']
            and isolated['got_a'] == isolated['task_id']
            and isolated['get_b_denied']
            and isolated['cancel_b_denied']
            and isolated['subscribe_b_denied'],
            repr(isolated),
        )
        check(
            'authorized cancellation publishes a terminal canceled Task',
            isolated['canceled'] == isolated['canceled_value'],
            repr(isolated),
        )
        check(
            'simultaneous same-ID tasks and cancellation stay owner local',
            bool(isolated['collision_a_context'])
            and bool(isolated['collision_b_context'])
            and isolated['collision_a_id'] == isolated['collision_expected_id']
            and isolated['collision_b_id'] == isolated['collision_expected_id']
            and isolated['collision_a_context']
            != isolated['collision_b_context']
            and isolated['collision_b_after_a_cancel']
            != isolated['canceled_value'],
            repr(isolated),
        )
        check(
            'secure JSON-RPC routes reject unsigned transport requests',
            isolated['unsigned_status'] == 401,
            repr(isolated),
        )

        experimental_cfg = NodeConfig(
            repo_path=tmp / 'experimental', enable_experimental_mailbox=True
        )
        experimental_card = build_agent_card(experimental_cfg, bob)
        check(
            'plaintext mailbox requires explicit card opt-in',
            len(experimental_card.capabilities.extensions) == 1
            and 'PLAINTEXT' in experimental_card.capabilities.extensions[0].description,
        )

        # Pagination must feed every returned cursor to the next GET.
        from team_agents import mesh

        calls = []
        original_run = mesh._run
        cursor = '11' * 32

        def fake_run(bin_path, args, data_dir):
            calls.append(list(args))
            if '--after-hex' not in args:
                return f'object_hex=aa\nnext_cursor={cursor}\n'
            return 'object_hex=bb\nnext_cursor=end\n'

        mesh._run = fake_run
        try:
            objects = mesh.mailbox_get_all(
                Path('/unused'), tmp / 'mesh-client', '/ip4/127.0.0.1/tcp/1',
                'peer', '00' * 16,
            )
            check(
                'mailbox pagination consumes continuation cursor',
                objects == [b'\xaa', b'\xbb']
                and calls[1][-2:] == ['--after-hex', cursor],
            )
            with patch.object(mesh, 'MAX_MAILBOX_OBJECTS', 1):
                try:
                    mesh.mailbox_get_all(
                        Path('/unused'),
                        tmp / 'bounded-mesh-client',
                        '/ip4/127.0.0.1/tcp/1',
                        'peer',
                        '00' * 16,
                    )
                    mailbox_count_refused = False
                except RuntimeError as exc:
                    mailbox_count_refused = 'object count' in str(exc)
            check(
                'mailbox adapter enforces the Rust store object-count bound',
                mailbox_count_refused,
            )
        finally:
            mesh._run = original_run

        # Invalid replies are quarantined rather than destroyed.
        from team_agents import relay as relay_module
        from team_agents.memory import TeamMemory
        from team_agents.relay import GitRelay

        relay_remote = tmp / 'relay-e2e.git'
        subprocess.run(
            ['git', 'init', '--bare', '-q', str(relay_remote)],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        )
        relay_seed = tmp / 'relay-seed'
        relay_seed.mkdir()
        _git(relay_seed, 'init', '-q')
        _git(relay_seed, 'config', 'user.name', 'RDAP Selftest')
        _git(relay_seed, 'config', 'user.email', 'rdap-selftest@example.invalid')
        (relay_seed / '.gitignore').write_text('.team/keys/\n', encoding='utf-8')
        _git(relay_seed, 'add', '--', '.gitignore')
        _git(relay_seed, 'commit', '-q', '-m', 'shared relay baseline')
        _git(relay_seed, 'branch', '-M', 'main')
        _git(relay_seed, 'remote', 'add', 'origin', str(relay_remote))
        _git(relay_seed, 'push', '-q', '-u', 'origin', 'main')
        relay_alice_repo = tmp / 'relay-alice-clone'
        relay_bob_repo = tmp / 'relay-bob-clone'
        for clone in (relay_alice_repo, relay_bob_repo):
            _git(tmp, 'clone', '-q', '--branch', 'main', str(relay_remote), str(clone))
            _git(clone, 'config', 'user.name', 'RDAP Selftest')
            _git(clone, 'config', 'user.email', 'rdap-selftest@example.invalid')
        alice_relay = GitRelay(
            TeamMemory(relay_alice_repo), alice, trusted_peers=_peers(bob)
        )
        bob_relay = GitRelay(
            TeamMemory(relay_bob_repo), bob, trusted_peers=_peers(alice)
        )
        alice_relay.send_task(bob.address, 'git task')

        async def answer_task(text):
            return 'signed answer: ' + text

        import asyncio

        processed = asyncio.run(bob_relay.process_inbox(answer_task))
        signed_replies = alice_relay.take_replies()
        alice_relay.ack_replies(signed_replies)
        acknowledged_replies = alice_relay.take_replies()
        check(
            'Git relay verifies task and signed reply end-to-end',
            processed == 1
            and len(signed_replies) == 1
            and signed_replies[0].get('text') == 'signed answer: git task'
            and not acknowledged_replies,
        )

        malformed_task = alice_relay._slot('inbox', bob.address) / 'malformed.json'
        alice_relay._write_envelope(malformed_task, {
            'id': 'malformed',
            'kind': 'task',
            'from': alice.address,
            'to': bob.address,
            'text': 'must never execute',
            'raven': [],
        })
        alice_relay.memory.commit_push('test: publish malformed relay envelope')
        malformed_processed = asyncio.run(bob_relay.process_inbox(answer_task))
        malformed_quarantine = list(
            (relay_bob_repo / '.team' / 'quarantine' / 'tasks').glob(
                'malformed.json'
            )
        )
        check(
            'malformed relay documents are quarantined without wedging polling',
            malformed_processed == 0 and bool(malformed_quarantine),
        )

        oversized_task = (
            bob_relay._slot('inbox', bob.address) / 'oversized.json'
        )
        oversized_task.write_bytes(
            b'x' * (relay_module.MAX_RELAY_ENVELOPE_BYTES + 1)
        )
        oversized_record = next(
            envelope for envelope in bob_relay.inbox_for_me()
            if envelope.get('_file') == oversized_task
        )
        bob_relay._quarantine(
            oversized_record, 'tasks', 'oversized regression input'
        )
        compact_evidence = list(
            (relay_bob_repo / '.team' / 'quarantine' / 'tasks').glob(
                'unsafe-*.reason.json'
            )
        )
        check(
            'oversized relay poison becomes compact evidence, not a Git blob copy',
            not oversized_task.exists()
            and not (
                relay_bob_repo / '.team' / 'quarantine' / 'tasks'
                / 'oversized.json'
            ).exists()
            and bool(compact_evidence)
            and max(path.stat().st_size for path in compact_evidence)
            < relay_module.MAX_RELAY_ENVELOPE_BYTES,
        )
        directory_poison = (
            bob_relay._slot('inbox', bob.address) / 'directory-poison.json'
        )
        directory_poison.mkdir()
        (directory_poison / 'nested').write_text('poison', encoding='utf-8')
        directory_record = next(
            envelope for envelope in bob_relay.inbox_for_me()
            if envelope.get('_file') == directory_poison
        )
        bob_relay._quarantine(
            directory_record, 'tasks', 'directory regression input'
        )
        check(
            'relay directory poison is removed from polling without recursive deletion',
            not directory_poison.exists()
            and any(
                path.is_dir()
                for path in (
                    relay_bob_repo / '.team' / 'keys' / 'relay-rejected'
                ).iterdir()
            ),
        )

        interrupted_file = alice_relay.send_task(
            bob.address, 'simulate interrupted brain'
        )
        interrupted_calls = [0]

        async def interrupted_brain(_text):
            interrupted_calls[0] += 1
            raise KeyboardInterrupt

        try:
            asyncio.run(bob_relay.process_inbox(interrupted_brain))
        except KeyboardInterrupt:
            pass
        recovered_processed = asyncio.run(
            bob_relay.process_inbox(answer_task)
        )
        interrupted_replies = alice_relay.take_replies()
        interrupted_texts = [
            str(reply.get('text', '')) for reply in interrupted_replies
        ]
        alice_relay.ack_replies(interrupted_replies)
        check(
            'interrupted relay tasks are not rerun and return an explicit outcome',
            interrupted_calls[0] == 1
            and recovered_processed == 1
            and not interrupted_file.exists()
            and any('not automatically retried' in text for text in interrupted_texts),
            repr(interrupted_texts),
        )

        alice_relay.send_task(bob.address, 'recover after push failure')
        real_commit_push = bob_relay._commit_push
        commit_attempts = [0]

        def fail_final_push(message):
            commit_attempts[0] += 1
            if commit_attempts[0] == 2:
                raise TeamGitError('simulated network failure after durable outcome')
            return real_commit_push(message)

        bob_relay._commit_push = fail_final_push
        push_failed = False
        try:
            asyncio.run(bob_relay.process_inbox(answer_task))
        except TeamGitError:
            push_failed = True
        finally:
            bob_relay._commit_push = real_commit_push
        recovery_processed = asyncio.run(bob_relay.process_inbox(answer_task))
        recovered_replies = alice_relay.take_replies()
        alice_relay.ack_replies(recovered_replies)
        check(
            'relay flushes durable reply/deletion after a later push recovers',
            push_failed
            and recovery_processed == 0
            and any(
                reply.get('text') == 'signed answer: recover after push failure'
                for reply in recovered_replies
            ),
            f'attempts={commit_attempts[0]} replies={recovered_replies!r}',
        )

        alice_relay.send_task(bob.address, 'unicode answer bound')

        async def emoji_answer(_text):
            return '😀' * 65_536

        emoji_processed = asyncio.run(bob_relay.process_inbox(emoji_answer))
        emoji_replies = alice_relay.take_replies()
        emoji_text = str(emoji_replies[0].get('text', '')) if emoji_replies else ''
        alice_relay.ack_replies(emoji_replies)
        check(
            'relay bounds UTF-8 answers by encoded bytes and marks truncation',
            emoji_processed == 1
            and len(emoji_text.encode('utf-8'))
            <= relay_module.MAX_RELAY_ANSWER_BYTES
            and emoji_text.endswith('[relay output truncated to its durable byte limit]'),
            f'bytes={len(emoji_text.encode("utf-8"))}',
        )
        surrogate_answer = relay_module._bounded_answer_text('\ud800')
        check(
            'relay normalizes invalid Unicode before durable signing',
            surrogate_answer == '?'
            and surrogate_answer.encode('utf-8') == b'?',
            repr(surrogate_answer),
        )
        try:
            GitRelay._validated_envelope({
                'id': '\ud800',
                'kind': 'task',
                'from': alice.address,
                'to': bob.address,
                'text': 'valid text',
                'raven': {'signature': 'placeholder'},
            }, 'task')
            invalid_id_refused = False
        except ValueError:
            invalid_id_refused = True
        check(
            'relay rejects invalid Unicode in signed string siblings',
            invalid_id_refused,
        )
        surrogate_chat_memory = TeamMemory(
            tmp / 'surrogate-chat', auto_commit=False
        )
        surrogate_chat = TeamChat(surrogate_chat_memory)
        surrogate_chat.post('user', '\ud800')
        check(
            'chat normalizes invalid Unicode before writing a delta',
            '\ud800' not in surrogate_chat.tail(),
            repr(surrogate_chat.tail()),
        )

        from unittest.mock import patch as unit_patch

        bounded_outcome_path = tmp / 'bounded-relay-outcomes.sqlite3'
        with unit_patch.multiple(
            relay_module,
            MAX_RELAY_OUTCOMES=10,
            MAX_RELAY_OUTCOME_DB_BYTES=64 * 1024,
        ):
            bounded_outcomes = relay_module.RelayOutcomeStore(
                bounded_outcome_path
            )
            outcome_limit_failed = False
            for index in range(10):
                signature = f'signature-{index}'
                try:
                    bounded_outcomes.claim(signature, int(time.time()) + 3600)
                    bounded_outcomes.complete(
                        signature,
                        int(time.time()) + 3600,
                        {'text': 'x' * 40_000},
                    )
                except RuntimeError:
                    outcome_limit_failed = True
                    break
        check(
            'relay outcome database enforces its byte ceiling on every write',
            outcome_limit_failed
            and bounded_outcome_path.stat().st_size <= 64 * 1024,
            f'size={bounded_outcome_path.stat().st_size}',
        )

        tampered_file = alice_relay.send_task(bob.address, 'outer tamper')
        tampered = json.loads(tampered_file.read_text(encoding='utf-8'))
        tampered['from'] = eve.address
        tampered_file.write_text(json.dumps(tampered), encoding='utf-8')
        alice_relay.memory.commit_push('test: publish tampered relay envelope')
        processed = asyncio.run(bob_relay.process_inbox(answer_task))
        task_quarantine = list(
            (relay_bob_repo / '.team' / 'quarantine' / 'tasks').glob('*.json')
        )
        check(
            'Git relay rejects outer sender/signature mismatch',
            processed == 0 and bool(task_quarantine),
        )

        relay = bob_relay
        bad_slot = relay._slot('outbox', bob.address)
        bad_file = bad_slot / 'forged.json'
        bad_file.write_text(json.dumps({
            'id': 'forged', 'kind': 'answer', 'from': alice.address,
            'to': bob.address, 'text': 'forged', 'raven': {},
        }))
        replies = relay.take_replies()
        quarantine = list(
            (relay_bob_repo / '.team' / 'quarantine' / 'replies').glob('forged.json')
        )
        check('invalid reply quarantined and not returned', not replies and bool(quarantine))

        bounded_slot_relay = GitRelay(
            TeamMemory(tmp / 'bounded-relay-slot', auto_commit=False),
            alice,
            trusted_peers=_peers(bob),
        )
        bounded_slot = bounded_slot_relay._slot('outbox', alice.address)
        (bounded_slot / 'a.json').write_text('{}', encoding='utf-8')
        (bounded_slot / 'b.json').write_text('{}', encoding='utf-8')
        with unit_patch.object(relay_module, 'MAX_RELAY_DIRECTORY_ENTRIES', 1):
            try:
                bounded_slot_relay._read_slot('outbox', alice.address)
                bounded_slot_refused = False
            except RuntimeError as exc:
                bounded_slot_refused = 'directory-entry limit' in str(exc)
        check(
            'relay scan fails closed instead of sorting an arbitrary capped prefix',
            bounded_slot_refused,
        )

        traversal_id = '../../../../outside-answer'
        traversal_reply_path = bob_relay._reply_path(alice.address, traversal_id)
        check(
            'peer task ids are hashed before becoming reply filenames',
            traversal_reply_path.parent
            == bob_relay._slot('outbox', alice.address)
            and traversal_reply_path.name
            == hashlib.sha256(traversal_id.encode('utf-8')).hexdigest() + '.json'
            and '..' not in traversal_reply_path.name,
            str(traversal_reply_path),
        )

        local_only_relay = GitRelay(
            TeamMemory(tmp / 'local-only-relay'), alice, trusted_peers=_peers(bob)
        )
        try:
            local_only_relay.send_task(bob.address, 'must not claim queued')
            local_only_refused = False
        except TeamGitError as exc:
            local_only_refused = 'shared' in str(exc) or 'remote' in str(exc)
        check(
            'Git relay refuses local-only repositories instead of claiming queued',
            local_only_refused,
        )

        broken_revocations = tmp / 'broken-revocations.json'
        broken_revocations.write_text('{broken')
        closed_relay = GitRelay(
            TeamMemory(tmp / 'closed-relay'),
            bob,
            trusted_peers=peers,
            revocations_file=str(broken_revocations),
        )
        try:
            closed_relay._revoked()
            check('configured revocation read failure is fail-closed', False)
        except Exception:  # noqa: BLE001
            check('configured revocation read failure is fail-closed', True)

        missing_trust_relay = GitRelay(
            TeamMemory(tmp / 'missing-trust'),
            bob,
            trusted_peers_file=tmp / 'does-not-exist.json',
            trusted_peers=peers,
        )
        try:
            missing_trust_relay.peers()
            check('configured trust-file loss is fail-closed', False)
        except FileNotFoundError:
            check('configured trust-file loss is fail-closed', True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------- network --------
def wait_health(url: str, proc: subprocess.Popen, timeout: float = 25.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            out, _ = proc.communicate()
            raise RuntimeError(f'node died early: rc={proc.returncode}\n{out[-1500:]}')
        try:
            if httpx.get(url + '/health', timeout=2).status_code == 200:
                return
        except Exception:  # noqa: BLE001
            time.sleep(0.4)
    raise RuntimeError(f'{url} never became healthy')


def network_tests(pybin: str) -> None:
    home = Path(tempfile.mkdtemp(prefix='rdap-net-'))
    (home / 'b').mkdir(parents=True)

    def keys(repo: str) -> str:
        d = home / repo / '.team' / 'keys'
        ident = RavenIdentity.load_or_create(d)
        return ident

    alice = keys('a')
    bob = keys('b')
    peers_b = home / 'b' / 'peers.json'
    peers_b.write_text(json.dumps({alice.address: {'address': alice.address,
                                                   'pubkey': alice.public_hex}}))
    env = {
        **__import__('os').environ,
        'TEAM_LLM_PROVIDER': 'echo',
        'TEAM_REQUIRE_SIGNED': '1',
        'TEAM_AUTO_COMMIT': '0',
        'RDAP_POLL': '3600',
    }

    def spawn(name: str, port: int, repo: str, peers: Path) -> subprocess.Popen:
        e = {**env, 'TEAM_NODE_NAME': name, 'TEAM_PORT': str(port),
             'TEAM_REPO': str(home / repo),
             'TEAM_TRUSTED_PEERS': str(peers)}
        return subprocess.Popen(
            [pybin, '-m', 'team_agents', 'serve', '--name', name,
             '--port', str(port), '--host', '127.0.0.1',
             '--repo', str(home / repo), '--peers', str(peers)],
            env={**e, 'PYTHONPATH': str(PKG_ROOT)},
            cwd=str(PKG_ROOT),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    import socket

    probe = socket.socket()
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
    probe.close()
    pb = spawn('node-b', port, 'b', peers_b)
    url = f'http://127.0.0.1:{port}'
    try:
        wait_health(url, pb)
        print('· signed Raven node healthy (no plaintext Bearer)')

        card = httpx.get(url + '/.well-known/agent-card.json',
                         timeout=5).json()
        check('card served with signatures', bool(card.get('signatures')))
        caps = card.get('capabilities', {})
        check('streaming advertised', caps.get('streaming') is True)
        ext_uris = [e.get('uri') for e in caps.get('extensions', [])]
        check('experimental mailbox not advertised by default', not ext_uris, str(ext_uris))
        check(
            'plaintext signed node does not advertise Bearer',
            not card.get('securitySchemes'),
        )

        ident = httpx.get(url + '/raven/identity', timeout=5).json()
        check('identity endpoint exposes card_kid',
              ident.get('card_kid') == ident.get('fingerprint') + '-card')

        async def run_flow() -> None:
            from team_agents.client import send_task, verify_card_signature
            from a2a.client import A2ACardResolver

            async with httpx.AsyncClient(timeout=30) as http:
                resolved = await A2ACardResolver(
                    httpx_client=http,
                    base_url=url + '/').get_agent_card()
                fp = verify_card_signature(
                    resolved,
                    expected_address=bob.address,
                    expected_public_key=bob.public_hex,
                    expected_url=url,
                )
                check('client verified card JWS against pinned identity', bool(fp))
            out = await send_task(
                url,
                'ping node-b',
                identity=alice,
                expected_peer_address=bob.address,
                expected_peer_public_key=bob.public_hex,
            )
            check(
                'signed task and signed reply executed end-to-end',
                'completed' in out.lower()
                and not out.lower().startswith('task ')
                and '→' not in out.splitlines()[0],
                out.splitlines()[0],
            )

            # A real unsigned JSON-RPC request must fail on a fresh/default node.
            import a2a.client.client as a2a_client_mod
            from a2a.client import ClientConfig, ClientFactory
            from a2a.types import Role
            from team_agents.client import _response_text

            async with httpx.AsyncClient(timeout=30) as http:
                resolved = await A2ACardResolver(
                    httpx_client=http, base_url=url + '/'
                ).get_agent_card()
                client = ClientFactory(ClientConfig(
                    streaming=False, polling=False, httpx_client=http
                )).create(resolved)
                pieces = []
                unsigned_transport_rejected = False
                try:
                    message = a2a_client_mod.SendMessageRequest().message.__class__()
                    message.message_id = 'unsigned-' + os.urandom(8).hex()
                    message.role = Role.Value('ROLE_USER')
                    message.parts.add().text = 'unsigned must fail'
                    request = a2a_client_mod.SendMessageRequest(message=message)
                    async for response in client.send_message(request):
                        pieces.append(_response_text(response))
                except Exception as exc:
                    unsigned_transport_rejected = '401' in repr(exc)
                    pieces.append(repr(exc))
                finally:
                    await client.close()
            unsigned_result = '\n'.join(pieces).lower()
            check(
                'fresh/default node rejects unsigned JSON-RPC task',
                unsigned_transport_rejected
                or 'rejected' in unsigned_result
                or 'failed' in unsigned_result,
                unsigned_result[:180],
            )

        import asyncio
        asyncio.run(run_flow())

        check('node remains alive after positive/negative flows', pb.poll() is None)
    finally:
        pb.kill()
        shutil.rmtree(home, ignore_errors=True)


def main() -> int:
    unit_only = '--unit' in sys.argv
    print('== unit ==')
    unit_tests()
    if not unit_only:
        print('== network ==')
        venv_py = str(HERE.parent / '.venv' / 'bin' / 'python')
        network_tests(venv_py if Path(venv_py).exists() else sys.executable)
    print(f'\n{len(PASS)} passed, {len(FAIL)} failed')
    if FAIL:
        print('FAILED:', ', '.join(FAIL))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
