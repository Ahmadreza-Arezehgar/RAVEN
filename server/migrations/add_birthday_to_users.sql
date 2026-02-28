-- Add birthday column to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS birthday TIMESTAMP NULL;

-- Add index for birthday queries (e.g., birthday reminders)
CREATE INDEX IF NOT EXISTS idx_users_birthday ON users(birthday);
