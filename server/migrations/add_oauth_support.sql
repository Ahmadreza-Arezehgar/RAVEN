-- Migration: Add OAuth support to users table
-- Run this migration on your production database

-- Add OAuth columns
ALTER TABLE users ADD COLUMN oauth_provider VARCHAR(50);
ALTER TABLE users ADD COLUMN oauth_provider_id VARCHAR(255);

-- Make username and password_hash nullable for OAuth users
ALTER TABLE users MODIFY COLUMN username VARCHAR(255) NULL;
ALTER TABLE users MODIFY COLUMN password_hash VARCHAR(255) NULL;

-- Add index for OAuth provider ID lookups
CREATE INDEX idx_oauth_provider_id ON users(oauth_provider_id);
CREATE INDEX idx_oauth_provider ON users(oauth_provider);

-- Note: Existing users will have NULL for oauth_provider and oauth_provider_id
-- This is intentional - they are traditional username/password users
