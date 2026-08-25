import pytest

from raven_protocol import store_tags


def test_mailbox_and_store_tags_match_frozen_vector():
    k_route = bytes(range(32))
    mailbox = store_tags.mailbox_tag(k_route, 1_700_000_000, 0)
    assert mailbox.hex() == "cb693b77e3f986fe8394872d73f35428"
    assert store_tags.store_tag(mailbox).hex() == "648ba67cde1b71c8257b0c7e3c8315b3"


def test_mailbox_tag_rotates_and_store_tag_validates_length():
    key = bytes(range(32))
    assert store_tags.mailbox_tag(key, 10, 0) != store_tags.mailbox_tag(key, 11, 0)
    assert store_tags.mailbox_tag(key, 10, 0) != store_tags.mailbox_tag(key, 10, 1)
    with pytest.raises(ValueError):
        store_tags.store_tag(b"short")
