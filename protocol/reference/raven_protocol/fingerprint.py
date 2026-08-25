import hashlib

def _group4(s: str) -> str:
    return "-".join(s[i:i+4] for i in range(0, len(s), 4))

def device_fingerprint_v1(ed_pub: bytes) -> str:
    """Canonical RavenDeviceFingerprintV1 — matches shipping app DeviceIdentityService."""
    import base64
    h = hashlib.sha256(ed_pub).digest()
    b64 = base64.b64encode(h[:9]).decode().replace("+", "").replace("/", "")
    return _group4(b64[:12])

def mesh_v1_hex_fingerprint(ed_pub: bytes) -> str:
    """DEPRECATED MeshV1 scheme, kept only to lock the frozen v1 vector."""
    h = hashlib.sha256(ed_pub).digest()
    return _group4(h[:6].hex().upper())
