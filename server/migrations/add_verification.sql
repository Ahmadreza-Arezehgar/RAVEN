-- ============================================================================
-- Migration: Identity Verification System
-- ============================================================================

-- 1. Create verification_requests table
CREATE TABLE IF NOT EXISTS verification_requests (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    status TEXT NOT NULL DEFAULT 'pending',  -- not_verified, pending, needs_more_info, rejected, verified, revoked
    
    -- Personal info
    legal_first_name TEXT NOT NULL,
    legal_last_name TEXT NOT NULL,
    country TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'person',  -- person, brand, org
    
    -- Document info
    doc_type TEXT NOT NULL,  -- passport, national_id, drivers_license
    doc_front_url TEXT,
    doc_back_url TEXT,
    selfie_url TEXT,
    
    -- Optional links for notability
    links_json TEXT,  -- JSON: [{type: "website", url: "..."}, ...]
    
    -- Timestamps
    submitted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reviewed_at TIMESTAMP,
    
    -- Admin review
    reviewer_admin_id TEXT,
    decision_reason TEXT,       -- Shown to user (polite)
    notes_internal TEXT,        -- Admin-only notes
    
    -- Anti-spam
    hash_dedupe TEXT,           -- Hash of user_id + doc for dedup
    version INTEGER DEFAULT 1  -- Optimistic locking
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_verification_user_id ON verification_requests(user_id);
CREATE INDEX IF NOT EXISTS idx_verification_status ON verification_requests(status);
CREATE INDEX IF NOT EXISTS idx_verification_submitted ON verification_requests(submitted_at);

-- 2. Add verification columns to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS verified_at TIMESTAMP;
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_badge_type TEXT DEFAULT 'identity';  -- identity, business, creator
ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_visibility BOOLEAN DEFAULT TRUE;
-- Note: verification_status already exists on users table (line 42 models.py)
-- Note: is_verified already exists on users table (line 32 models.py)
