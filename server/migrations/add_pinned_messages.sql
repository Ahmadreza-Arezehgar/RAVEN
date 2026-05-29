-- 2026-05-06: pinned messages + saved messages.
--
-- Pinned: either party in a DM, or any group member, can pin/unpin.
-- Visible to all participants. `pinned_at` NULL = not pinned.
--
-- Saved: per-user private bookmark of any message they can see. Pin and
-- save are independent — saving doesn't affect what others see.
--
-- Idempotent — safe to re-run.

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMP WITHOUT TIME ZONE;
ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS pinned_by_user_id VARCHAR;

ALTER TABLE group_messages
    ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMP WITHOUT TIME ZONE;
ALTER TABLE group_messages
    ADD COLUMN IF NOT EXISTS pinned_by_user_id VARCHAR;

-- Partial indexes — only the (small) subset of pinned messages, so the
-- "show pinned in this conversation" query is O(pinned-count), not full
-- table scan.
CREATE INDEX IF NOT EXISTS ix_messages_pinned
    ON messages (sender_id, recipient_id, pinned_at)
    WHERE pinned_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_group_messages_pinned
    ON group_messages (group_id, pinned_at)
    WHERE pinned_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS saved_messages (
    id VARCHAR PRIMARY KEY,
    user_id VARCHAR NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message_id VARCHAR NOT NULL,
    is_group BOOLEAN NOT NULL DEFAULT FALSE,
    saved_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT uq_saved_user_msg UNIQUE (user_id, message_id, is_group)
);
CREATE INDEX IF NOT EXISTS ix_saved_messages_user_id ON saved_messages (user_id);
CREATE INDEX IF NOT EXISTS ix_saved_messages_saved_at ON saved_messages (saved_at);
