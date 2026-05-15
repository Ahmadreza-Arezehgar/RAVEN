-- Add push notification token fields to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS push_token VARCHAR(255);
ALTER TABLE users ADD COLUMN IF NOT EXISTS push_platform VARCHAR(20);
ALTER TABLE users ADD COLUMN IF NOT EXISTS push_environment VARCHAR(20);

-- Create index for efficient token lookups
CREATE INDEX IF NOT EXISTS idx_users_push_token ON users(push_token) WHERE push_token IS NOT NULL;
