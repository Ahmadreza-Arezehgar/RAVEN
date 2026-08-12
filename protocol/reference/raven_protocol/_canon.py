def lp(b: bytes) -> bytes:
    return len(b).to_bytes(2, "big") + b
def u64(n: int) -> bytes:
    return n.to_bytes(8, "big")
