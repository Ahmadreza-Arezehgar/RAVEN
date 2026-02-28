-- =====================================================
-- Enhanced Auth System Migration
-- Run: psql -d your_database -f add_auth_tables.sql
-- =====================================================

-- 1. Add new columns to users table
ALTER TABLE users 
ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMP,
ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMP,
ADD COLUMN IF NOT EXISTS phone_e164 VARCHAR(20),
ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'active';

-- Create unique index on phone_e164 if not exists
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_e164 ON users(phone_e164) WHERE phone_e164 IS NOT NULL;

-- 2. Create verification_tokens table
CREATE TABLE IF NOT EXISTS verification_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel VARCHAR(10) NOT NULL, -- 'email' or 'sms'
    purpose VARCHAR(20) NOT NULL, -- 'verify_email', 'verify_phone', 'reset_password'
    token_hash VARCHAR(64) NOT NULL, -- SHA256 hash
    sent_to VARCHAR(255) NOT NULL, -- Email or phone
    expires_at TIMESTAMP NOT NULL,
    attempts INTEGER DEFAULT 0,
    cooldown_until TIMESTAMP,
    consumed_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_verification_tokens_user_id ON verification_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_verification_tokens_sent_to_purpose ON verification_tokens(sent_to, purpose);

-- 3. Create refresh_tokens table
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash VARCHAR(64) NOT NULL, -- SHA256 hash
    expires_at TIMESTAMP NOT NULL,
    revoked_at TIMESTAMP,
    device_id VARCHAR(255),
    device_name VARCHAR(255),
    ip_address VARCHAR(45), -- IPv6 compatible
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);

-- 4. Cleanup old expired tokens (scheduled job)
-- Run periodically: DELETE FROM verification_tokens WHERE expires_at < NOW() - INTERVAL '1 day';
-- Run periodically: DELETE FROM refresh_tokens WHERE expires_at < NOW() - INTERVAL '1 day';

COMMENT ON TABLE verification_tokens IS 'Secure OTP/email verification tokens with rate limiting';
COMMENT ON TABLE refresh_tokens IS 'Revocable refresh tokens for JWT session management';
