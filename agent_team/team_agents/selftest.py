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
    validate_address_public_key,
    verify_delegation,
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

        from team_agents.memory import FileLockTimeout, TeamGitError, TeamMemory

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
        from team_agents.server import build_agent_card, build_app

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

            active_store = BoundedTaskStore(
                max_count=2,
                max_bytes=64 * 1024,
                ttl_seconds=60,
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

            def __init__(self, task_id, text, metadata):
                self.task_id = task_id
                self.context_id = 'ctx-' + task_id
                self._text = text
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
            trusted_peers=_peers(alice),
        )
        ingress_executor = TeamAgentExecutor(
            ingress_cfg,
            ingress_brain,
            ingress_memory,
            trusted_peers=_peers(alice),
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
                ),
                policy_queue,
            )
            policy_rejected = any(
                isinstance(event, Task)
                and event.status.state == TaskState.TASK_STATE_REJECTED
                and 'raven delegation rejected' in str(event).lower()
                for event in policy_queue.events
            )
            return unsigned_rejected, policy_rejected

        unsigned_rejected, policy_rejected = asyncio.run(
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
            from team_agents.client import _response_text

            transport = httpx.ASGITransport(app=bounded_app)
            async with httpx.AsyncClient(
                transport=transport, base_url='http://test'
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
                    valid_text = 'valid task survives bounded store pressure'
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
                        completed_request, ServerCallContext()
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
            'valid signed flow survives bounded-store eviction pressure',
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
        finally:
            mesh._run = original_run

        # Invalid replies are quarantined rather than destroyed.
        from team_agents.memory import TeamMemory
        from team_agents.relay import GitRelay

        relay_repo = tmp / 'relay-e2e'
        alice_relay = GitRelay(
            TeamMemory(relay_repo), alice, trusted_peers=_peers(bob)
        )
        bob_relay = GitRelay(
            TeamMemory(relay_repo), bob, trusted_peers=_peers(alice)
        )
        alice_relay.send_task(bob.address, 'git task')

        async def answer_task(text):
            return 'signed answer: ' + text

        import asyncio

        processed = asyncio.run(bob_relay.process_inbox(answer_task))
        signed_replies = alice_relay.take_replies()
        check(
            'Git relay verifies task and signed reply end-to-end',
            processed == 1
            and len(signed_replies) == 1
            and signed_replies[0].get('text') == 'signed answer: git task',
        )

        tampered_file = alice_relay.send_task(bob.address, 'outer tamper')
        tampered = json.loads(tampered_file.read_text(encoding='utf-8'))
        tampered['from'] = eve.address
        tampered_file.write_text(json.dumps(tampered), encoding='utf-8')
        processed = asyncio.run(bob_relay.process_inbox(answer_task))
        task_quarantine = list(
            (relay_repo / '.team' / 'quarantine' / 'tasks').glob('*.json')
        )
        check(
            'Git relay rejects outer sender/signature mismatch',
            processed == 0 and bool(task_quarantine),
        )

        relay = GitRelay(TeamMemory(tmp / 'relay'), bob, trusted_peers=peers)
        bad_slot = relay._slot('outbox', bob.address)
        bad_file = bad_slot / 'forged.json'
        bad_file.write_text(json.dumps({
            'id': 'forged', 'kind': 'answer', 'from': alice.address,
            'to': bob.address, 'text': 'forged', 'raven': {},
        }))
        replies = relay.take_replies()
        quarantine = list((tmp / 'relay' / '.team' / 'quarantine' / 'replies').glob('forged.json'))
        check('invalid reply quarantined and not returned', not replies and bool(quarantine))

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
def wait_health(
    url: str, proc: subprocess.Popen, token: str = '', timeout: float = 25.0
) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            out, _ = proc.communicate()
            raise RuntimeError(f'node died early: rc={proc.returncode}\n{out[-1500:]}')
        try:
            headers = {'Authorization': f'Bearer {token}'} if token else None
            if httpx.get(url + '/health', timeout=2, headers=headers).status_code == 200:
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
    token = 'rdap-selftest-bearer-secret'
    token_file = home / 'bearer.token'
    token_file.write_text(token)
    token_file.chmod(0o600)
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
             '--token-file', str(token_file), '--repo', str(home / repo),
             '--peers', str(peers)],
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
        wait_health(url, pb, token)
        print('· Bearer-protected node healthy')

        check('Bearer rejects unauthenticated health',
              httpx.get(url + '/health', timeout=5).status_code == 401)

        card = httpx.get(url + '/.well-known/agent-card.json',
                         timeout=5).json()
        check('card served with signatures', bool(card.get('signatures')))
        caps = card.get('capabilities', {})
        check('streaming advertised', caps.get('streaming') is True)
        ext_uris = [e.get('uri') for e in caps.get('extensions', [])]
        check('experimental mailbox not advertised by default', not ext_uris, str(ext_uris))
        check('security scheme declared',
              card.get('securitySchemes', {}).get('bearer', {})
              .get('httpAuthSecurityScheme', {})
              .get('scheme') == 'Bearer')

        ident = httpx.get(
            url + '/raven/identity', timeout=5,
            headers={'Authorization': f'Bearer {token}'},
        ).json()
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
                )
                check('client verified card JWS against pinned identity', bool(fp))
            out = await send_task(
                url,
                'ping node-b',
                identity=alice,
                expected_peer_address=bob.address,
                expected_peer_public_key=bob.public_hex,
                token_file=token_file,
            )
            check(
                'signed task and signed reply executed end-to-end',
                'completed' in out.lower(),
                out.splitlines()[0],
            )

            try:
                await send_task(
                    url,
                    'wrong token',
                    identity=alice,
                    expected_peer_address=bob.address,
                    expected_peer_public_key=bob.public_hex,
                    bearer_token='wrong',
                )
                check('official client propagates Bearer auth', False)
            except Exception:  # noqa: BLE001
                check('official client propagates Bearer auth', True)

            # A real unsigned JSON-RPC request must fail on a fresh/default node.
            import a2a.client.client as a2a_client_mod
            from a2a.client import ClientConfig, ClientFactory
            from a2a.types import Role
            from team_agents.client import _response_text

            headers = {'Authorization': f'Bearer {token}'}
            async with httpx.AsyncClient(timeout=30, headers=headers) as http:
                resolved = await A2ACardResolver(
                    httpx_client=http, base_url=url + '/'
                ).get_agent_card()
                client = ClientFactory(ClientConfig(
                    streaming=False, polling=False, httpx_client=http
                )).create(resolved)
                try:
                    message = a2a_client_mod.SendMessageRequest().message.__class__()
                    message.message_id = 'unsigned-' + os.urandom(8).hex()
                    message.role = Role.Value('ROLE_USER')
                    message.parts.add().text = 'unsigned must fail'
                    request = a2a_client_mod.SendMessageRequest(message=message)
                    pieces = []
                    async for response in client.send_message(request):
                        pieces.append(_response_text(response))
                finally:
                    await client.close()
            unsigned_result = '\n'.join(pieces).lower()
            check(
                'fresh/default node rejects unsigned JSON-RPC task',
                'rejected' in unsigned_result or 'failed' in unsigned_result,
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
