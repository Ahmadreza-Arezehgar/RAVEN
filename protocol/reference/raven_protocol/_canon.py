# Canonical length-prefix helpers for record signing bytes.
#
# lp() uses a fixed 2-byte big-endian length, so every lp-framed field is capped
# at 65535 bytes. Ports MUST reject (fail closed) a field that exceeds this, never
# truncate or wrap — a silently wrapped u16 length would corrupt field boundaries
# and diverge the signing bytes across implementations. In CPython, to_bytes(2)
# raises OverflowError above 65535, which is the intended fail-closed behavior.
LP_MAX_LEN = 0xFFFF


def lp(b: bytes) -> bytes:
    if len(b) > LP_MAX_LEN:
        raise ValueError(f"lp field exceeds {LP_MAX_LEN} bytes")
    return len(b).to_bytes(2, "big") + b


def u64(n: int) -> bytes:
    return n.to_bytes(8, "big")
