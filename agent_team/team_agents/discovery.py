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
    """Start broadcasting this node. Returns (zc, info) — keep referenced."""
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except ImportError:
        return None, None

    props: dict[str, Any] = {
        'addr': raven_address,
        'v': PROP_VERSION,
        'path': '/',
    }
    ips = [advertised_ip] if advertised_ip else _lan_ips()
    # register once per local IP so every interface answers
    zc = Zeroconf()
    infos = []
    for i, ip in enumerate(ips):
        info = ServiceInfo(
            SERVICE_TYPE,
            f'{name}.{SERVICE_TYPE}',
            parsed_addresses=[ip],
            port=port,
            properties=props,
            server=f'{name}-{i}.local.',
        )
        zc.register_service(info)
        infos.append(info)
    return zc, infos


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

    zc = Zeroconf()
    try:
        _ = ServiceBrowser(zc, SERVICE_TYPE, _Listener())
        socket.setdefaulttimeout(timeout)
        import time

        time.sleep(timeout)
    finally:
        zc.close()
    return list(found.values())
