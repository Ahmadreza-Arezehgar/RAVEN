-- Add audio_duration_seconds to messages and group_messages tables
-- for storing voice message duration sent by clients

ALTER TABLE messages ADD COLUMN IF NOT EXISTS audio_duration_seconds INTEGER;
ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS audio_duration_seconds INTEGER;
