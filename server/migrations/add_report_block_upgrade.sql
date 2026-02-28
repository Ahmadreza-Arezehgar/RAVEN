-- ============================================================================
-- Migration: Report & Block System Upgrade
-- ============================================================================

-- 1. Add columns to reports table
ALTER TABLE reports ADD COLUMN reported_user_id TEXT;
ALTER TABLE reports ADD COLUMN context_json TEXT;

-- 2. Create hidden_content table (for hide-after-report and block cleanup)
CREATE TABLE IF NOT EXISTS hidden_content (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    object_type TEXT NOT NULL,  -- post, comment, message, story, user
    object_id TEXT NOT NULL,
    hidden_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reason TEXT DEFAULT 'reported'  -- reported, blocked
);

CREATE INDEX IF NOT EXISTS idx_hidden_user ON hidden_content(user_id);
CREATE INDEX IF NOT EXISTS idx_hidden_object ON hidden_content(object_type, object_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_hidden_unique ON hidden_content(user_id, object_type, object_id);
