-- 2026-05-06: message edits + emoji reactions
-- Run once against the production DB; idempotent (uses IF NOT EXISTS).

-- Edits — null for messages that have never been edited.
ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS edited_at TIMESTAMP WITHOUT TIME ZONE;

ALTER TABLE group_messages
    ADD COLUMN IF NOT EXISTS edited_at TIMESTAMP WITHOUT TIME ZONE;

-- Reactions — single table for both 1:1 and group messages, distinguished by
-- the is_group flag so a user can't accidentally double-react with the same
-- emoji on the same message.
CREATE TABLE IF NOT EXISTS message_reactions (
    id          VARCHAR PRIMARY KEY,
    message_id  VARCHAR NOT NULL,
    is_group    BOOLEAN NOT NULL DEFAULT FALSE,
    user_id     VARCHAR NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    emoji       VARCHAR NOT NULL,
    created_at  TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT uq_reaction_msg_user_emoji UNIQUE (message_id, user_id, emoji)
);

CREATE INDEX IF NOT EXISTS ix_message_reactions_message_id
    ON message_reactions (message_id);

CREATE INDEX IF NOT EXISTS ix_message_reactions_user_id
    ON message_reactions (user_id);
