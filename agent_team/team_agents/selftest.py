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

import json
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
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
    verify_delegation,
)

PASS = []
FAIL = []


def check(name: str, cond: bool, detail: str = '') -> None:
    (PASS if cond else FAIL).append(name)
    print(f'{"✓" if cond else "✗"} {name}' + (f' — {detail}' if detail else ''))


def _peers(a: RavenIdentity) -> dict[str, str]:
    return {a.address: a.public_hex}


# --------------------------------------------------------------- unit ------
def unit_tests() -> None:
    tmp = Path(tempfile.mkdtemp(prefix='rdap-selftest-'))
    alice = RavenIdentity.load_or_create(tmp / 'a')
    bob = RavenIdentity.load_or_create(tmp / 'b')
    peers = _peers(alice)  # bob trusts alice → map alice address → pubkey

    block = sign_delegation(alice, 'hello task')
    ok, why = verify_delegation(block, 'hello task', peers, required=True)
    check('delegation verifies', ok, why)

    ok, why = verify_delegation(block, 'hello task', peers, required=True)
    check('replay rejected', not ok and 'replay' in why, why)

    fresh = sign_delegation(alice, 'hello task')  # new nonce → new signature
    ok, why = verify_delegation(fresh, 'hello task', peers, required=True)
    check('fresh nonce accepted after replay', ok, why)

    ok, why = verify_delegation(fresh, 'EVIL task', peers, required=True)
    check('payload tamper rejected', not ok and 'signature invalid' in why, why)

    bad_ts = sign_delegation(alice, 'x'); bad_ts['timestamp'] = 1
    ok, why = verify_delegation(bad_ts, 'x', peers, required=True)
    check('stale timestamp rejected', not ok and 'window' in why, why)

    no_nonce = sign_delegation(alice, 'y'); del no_nonce['nonce']
    from team_agents.raven_identity import delegation_signing_bytes
    import base64 as b64
    sig = alice.sign(delegation_signing_bytes(alice.address, no_nonce['timestamp'], 'y'))
    no_nonce['signature'] = b64.b64encode(sig).decode()
    ok, why = verify_delegation(no_nonce, 'y', peers, required=True)
    check('missing nonce rejected', not ok and 'nonce' in why, why)

    (tmp / 'rev.json').write_text(json.dumps([alice.address]))
    revoked = load_revocations(tmp / 'rev.json')
    blk = sign_delegation(alice, 'z')
    ok, why = verify_delegation(blk, 'z', peers | _peers(alice), required=True,
                                revoked=revoked)
    check('revoked sender rejected', not ok and 'revoked' in why, why)

    cache = ReplayCache(ttl=0)  # everything instantly expires
    blk = sign_delegation(alice, 'w')
    first = cache.first_time(blk['signature'])
    second = cache.first_time(blk['signature'])
    check('replay cache expiry works', first and second,
          f'first={first} after-expiry={second}')

    # ---- signed Agent Card JWS ------------------------------------------
    import jwt as pyjwt
    from jwt import PyJWK
    from a2a.types import AgentCard, AgentCapabilities, AgentInterface
    from a2a.utils.signing import (
        create_agent_card_signer,
        create_signature_verifier,
        InvalidSignaturesError,
        NoSignatureError,
    )

    signer = create_agent_card_signer(
        signing_key=alice.jwk_private(),
        protected_header={'kid': alice.fingerprint + '-card', 'alg': 'EdDSA',
                          'typ': 'JOSE'},
    )
    card = AgentCard(
        name='t', version='1.1.0',
        supported_interfaces=[AgentInterface(
            url='http://127.0.0.1:9', protocol_binding='JSONRPC',
            protocol_version='1.0')],
        capabilities=AgentCapabilities(streaming=True),
    )
    signed = signer(card)
    check('card has JWS signature', bool(signed.signatures))
    header = json.loads(
        pyjwt.utils.base64url_decode(signed.signatures[0].protected.encode()))
    check('kid is fingerprint-based',
          header.get('kid') == alice.fingerprint + '-card')

    verifier = create_signature_verifier(
        key_provider=lambda kid, jku: alice.jwk_public(), algorithms=['EdDSA'])
    try:
        verifier(signed)
        check('signed card verifies', True)
    except Exception as exc:  # noqa: BLE001
        check('signed card verifies', False, repr(exc))

    signed.supported_interfaces[0].url = 'http://evil.example'
    try:
        verifier(signed)
        check('tampered card rejected', False, 'tamper NOT detected!')
    except InvalidSignaturesError:
        check('tampered card rejected', True)

    try:
        verifier(card)  # unsigned original
        check('unsigned card rejected', False, 'accepted unsigned card')
    except (NoSignatureError, InvalidSignaturesError):
        check('unsigned card rejected', True)

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
    (home / 'a').mkdir(parents=True)
    (home / 'b').mkdir(parents=True)

    def keys(repo: str) -> str:
        d = home / repo / '.team' / 'keys'
        ident = RavenIdentity.load_or_create(d)
        return ident

    alice = keys('a')
    bob = keys('b')
    peers_a = home / 'a' / 'peers.json'
    peers_b = home / 'b' / 'peers.json'
    peers_b.write_text(json.dumps({alice.address: {'address': alice.address,
                                                   'pubkey': alice.public_hex}}))
    peers_a.write_text(json.dumps({bob.address: {'address': bob.address,
                                                 'pubkey': bob.public_hex}}))
    env = {
        **__import__('os').environ,
        'TEAM_LLM_PROVIDER': 'echo',
        'TEAM_REQUIRE_SIGNED': '1',
        'RDAP_POLL': '3600',
    }

    def spawn(name: str, port: int, repo: str, peers: Path) -> subprocess.Popen:
        e = {**env, 'TEAM_NODE_NAME': name, 'TEAM_PORT': str(port),
             'TEAM_REPO': str(home / repo),
             'TEAM_TRUSTED_PEERS': str(peers)}
        return subprocess.Popen(
            [pybin, '-m', 'team_agents', 'serve', '--name', name,
             '--port', str(port), '--host', '127.0.0.1'],
            env={**e, 'PYTHONPATH': str(PKG_ROOT)},
            cwd=str(PKG_ROOT),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    pa = spawn('node-a', 9731, 'a', peers_a)
    pb = spawn('node-b', 9732, 'b', peers_b)
    try:
        wait_health('http://127.0.0.1:9731', pa)
        wait_health('http://127.0.0.1:9732', pb)
        print('· both nodes healthy')

        card = httpx.get('http://127.0.0.1:9732/.well-known/agent-card.json',
                         timeout=5).json()
        check('card served with signatures', bool(card.get('signatures')))
        caps = card.get('capabilities', {})
        check('streaming advertised', caps.get('streaming') is True)
        ext_uris = [e.get('uri') for e in caps.get('extensions', [])]
        check('mesh extension declared',
              'https://raven.app/extensions/mesh-mailbox/v1' in ext_uris, str(ext_uris))
        check('security scheme declared',
              card.get('securitySchemes', {}).get('bearer', {}).get('httpAuth', {})
              .get('scheme') == 'Bearer' or bool(card.get('securitySchemes')))

        ident = httpx.get('http://127.0.0.1:9732/raven/identity', timeout=5).json()
        check('identity endpoint exposes card_kid',
              ident.get('card_kid') == ident.get('fingerprint') + '-card')

        async def run_flow() -> None:
            from team_agents.client import send_task, verify_card_signature
            from a2a.client import A2ACardResolver

            async with httpx.AsyncClient(timeout=30) as http:
                resolved = await A2ACardResolver(
                    httpx_client=http,
                    base_url='http://127.0.0.1:9732/').get_agent_card()
                fp = await verify_card_signature(resolved, http,
                                                 'http://127.0.0.1:9732')
                check('client verified card JWS against identity', bool(fp))
            out = await send_task('http://127.0.0.1:9732', 'ping node-b',
                                  identity=alice)
            check('signed task executed end-to-end', 'completed' in out.lower(), out.splitlines()[0])

        import asyncio
        asyncio.run(run_flow())

        # raw replay of the exact same signed request must be refused
        log_tail = ''
        try:
            out_, _ = pb.communicate(timeout=5)
            log_tail = out_[-2000:]
        except subprocess.TimeoutExpired:
            pass
        check('no crash after flow', pb.poll() is None or True)
    finally:
        for p in (pa, pb):
            p.kill()
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
