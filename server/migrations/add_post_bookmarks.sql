-- Migration: post_bookmarks table
--
-- Adds server-side persistence for the iOS / Mac / Web bookmark
-- feature. Bookmarks were previously only stored client-side in
-- UserDefaults, so a user couldn't see their saved posts on a
-- different device. With this junction table the toggle endpoint
-- (POST /api/posts/{id}/bookmark) and the listing endpoint
-- (GET /api/posts/me/bookmarks) operate against the database.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS post_bookmarks (
    id          TEXT PRIMARY KEY,
    post_id     TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    timestamp   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT  unique_post_bookmark UNIQUE (post_id, user_id)
);

-- Indexes that match the filters used by the bookmark endpoints.
CREATE INDEX IF NOT EXISTS idx_post_bookmarks_post_id ON post_bookmarks(post_id);
CREATE INDEX IF NOT EXISTS idx_post_bookmarks_user_id ON post_bookmarks(user_id);
CREATE INDEX IF NOT EXISTS idx_post_bookmarks_timestamp ON post_bookmarks(timestamp DESC);
