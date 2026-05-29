-- 2026-05-06: inline video-jump commands (`vM:SS`) parsed from post bodies
-- at create-time and persisted alongside the post so the iOS feed can render
-- scrub-bar chapter markers without re-parsing per render.
--
-- Idempotent — safe to re-run.

ALTER TABLE posts
    ADD COLUMN IF NOT EXISTS video_chapters TEXT;
