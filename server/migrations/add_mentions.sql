-- Mentions table for tracking @mentions in chat messages and post comments
CREATE TABLE IF NOT EXISTS mentions (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK(type IN ('chat_message', 'post_comment')),
    source_id TEXT NOT NULL,          -- message_id or comment_id
    post_id TEXT,                      -- nullable, only for post_comment type
    room_id TEXT,                      -- nullable, only for chat_message type (group_id)
    mentioned_user_id TEXT NOT NULL,
    mentioned_by_user_id TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    snippet TEXT,                       -- short preview of the message/comment
    deep_link TEXT,                     -- app://chat/<room_id>?message=<id> or app://post/<id>?comment=<id>
    is_read BOOLEAN NOT NULL DEFAULT 0,
    FOREIGN KEY (mentioned_user_id) REFERENCES users(id),
    FOREIGN KEY (mentioned_by_user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_mentions_mentioned_user ON mentions(mentioned_user_id);
CREATE INDEX IF NOT EXISTS idx_mentions_mentioned_by ON mentions(mentioned_by_user_id);
CREATE INDEX IF NOT EXISTS idx_mentions_source ON mentions(source_id);
CREATE INDEX IF NOT EXISTS idx_mentions_is_read ON mentions(mentioned_user_id, is_read);

-- Add entities JSON column to group_messages for structured mention data
ALTER TABLE group_messages ADD COLUMN entities TEXT;

-- Add entities JSON column to comments for structured mention data  
ALTER TABLE comments ADD COLUMN entities TEXT;
