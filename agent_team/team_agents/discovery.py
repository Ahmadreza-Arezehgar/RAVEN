"""Zero-config LAN discovery for RDAP nodes via mDNS/DNS-SD (_rdap._tcp).

Follows the two-stage pattern from IETF draft-jakab-dawn-agent-discovery:
DNS-SD enumerates candidates, the A2A AgentCard endpoint describes them.
"""

from __future__ import annotations

import socket
from typing import Any

SERVICE_TYPE = '_rdap._tcp.local.'
PROP_VERSION = '1'


def _lan_ips() -> list[str]:
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith('127.'):
                ips.add(ip)
    except OSError:
        pass
    return sorted(ips)


def advertise(name: str, port: int, raven_address: str, advertised_ip: str = ''):
    """Start broadcasting this node. Returns (zc, infos) — keep referenced."""
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except ImportError:
        return None, None

    ips = [advertised_ip] if advertised_ip else _lan_ips()
    if not ips:
        return None, None
    props: dict[str, Any] = {
        'addr': raven_address,
        'v': PROP_VERSION,
        'path': '/',
    }
    # bind only the primary LAN interface — the wildcard bind collides with
    # other apps that hold :5353 without REUSEPORT
    zc = Zeroconf(interfaces=[ips[0]])
    info = ServiceInfo(
        SERVICE_TYPE,
        f'{name}.{SERVICE_TYPE}',
        parsed_addresses=[ips[0]],
        port=port,
        properties=props,
        server=f'{name}.local.',
    )
    zc.register_service(info)
    return zc, [info]


def stop_advertise(zc, infos) -> None:
    if not zc or not infos:
        return
    try:
        for info in infos:
            zc.unregister_service(info)
        zc.close()
    except Exception:  # noqa: BLE001
        pass


def browse(timeout: float = 4.0) -> list[dict]:
    """Return nearby RDAP nodes: [{name, ip, port, url, addr}]."""
    import time

    from zeroconf import ServiceBrowser, Zeroconf

    found: dict[str, dict] = {}

    class _Listener:
        def add_service(self, zc, type_, name) -> None:
            info = zc.get_service_info(type_, name, timeout=2500)
            if not info or not info.parsed_addresses():
                return
            ip = info.parsed_addresses()[0]
            props = {k.decode() if isinstance(k, bytes) else k:
                     v.decode() if isinstance(v, bytes) else v
                     for k, v in (info.properties or {}).items()}
            short = name.removesuffix('.' + SERVICE_TYPE)
            found[name] = {
                'name': short,
                'ip': ip,
                'port': info.port,
                'url': f'http://{ip}:{info.port}',
                'addr': str(props.get('addr', '')),
            }

        def update_service(self, zc, type_, name) -> None:
            pass

        def remove_service(self, zc, type_, name) -> None:
            pass

    ips = _lan_ips() or ['127.0.0.1']
    last_exc = None
    for attempt_ips in (ips, ['0.0.0.0']):
        try:
            zc = Zeroconf(interfaces=attempt_ips)
            break
        except OSError as exc:      # some other app hogging mDNS sockets
            last_exc = exc
            continue
    else:
        raise RuntimeError(f'mDNS unavailable ({last_exc!r}) — '
                           'fall back to `./rdap trust`')
    try:
        _ = ServiceBrowser(zc, SERVICE_TYPE, _Listener())
        time.sleep(timeout)
    finally:
        zc.close()
    return list(found.values())
