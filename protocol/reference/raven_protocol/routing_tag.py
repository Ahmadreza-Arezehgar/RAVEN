# raven_protocol/routing_tag.py
import hmac, hashlib

LABEL = b"rvn1/route"

def derive(k_route: bytes, epoch: int, counter: int) -> bytes:
    msg = LABEL + epoch.to_bytes(8, "big") + counter.to_bytes(8, "big")
    return hmac.new(k_route, msg, hashlib.sha256).digest()[:16]
