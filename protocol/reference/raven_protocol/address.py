import hashlib
from . import bech32m

ADDRESS_VERSION = 1

def encode(identity_ed_pub: bytes) -> str:
    addr_hash = hashlib.sha256(identity_ed_pub).digest()[:20]
    payload = bytes([ADDRESS_VERSION]) + addr_hash
    return bech32m.encode("rvn", payload)

def decode(addr: str):
    """Returns (addr_hash_20, version) or None."""
    res = bech32m.decode(addr.strip())
    if res is None:
        return None
    hrp, payload = res
    if hrp != "rvn" or len(payload) != 21:
        return None
    return payload[1:], payload[0]

def to_display(addr: str) -> str:
    data = addr.split("1", 1)[1].upper()
    return "rvn1:" + "-".join(data[i:i+4] for i in range(0, len(data), 4))

def from_display(disp: str) -> str:
    body = disp.replace("rvn1:", "").replace("-", "").lower()
    return "rvn1" + body
