# tests/test_routing_tag.py
from raven_protocol import routing_tag

K_ROUTE = bytes(range(32))

def test_tag_is_16_bytes_and_deterministic():
    t1 = routing_tag.derive(K_ROUTE, epoch=1700000000, counter=0)
    t2 = routing_tag.derive(K_ROUTE, epoch=1700000000, counter=0)
    assert t1 == t2 and len(t1) == 16

def test_unlinkable_across_counter_and_epoch():
    base = routing_tag.derive(K_ROUTE, 1700000000, 0)
    assert routing_tag.derive(K_ROUTE, 1700000000, 1) != base
    assert routing_tag.derive(K_ROUTE, 1700003600, 0) != base

def test_wrong_key_gives_different_tag():
    base = routing_tag.derive(K_ROUTE, 1700000000, 0)
    assert routing_tag.derive(bytes(32), 1700000000, 0) != base
