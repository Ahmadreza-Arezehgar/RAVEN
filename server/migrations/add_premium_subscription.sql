-- Migration: Add is_premium column to users table
-- Date: 2026-02-16
-- Description: Adds RAVEN+ subscription status and grants permanent premium to AHMADREZA

-- 1. Add the is_premium column (default false for all existing users)
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_premium BOOLEAN DEFAULT FALSE;

-- 2. Grant permanent premium to AHMADREZA (admin account)
UPDATE users SET is_premium = TRUE WHERE LOWER(username) = 'ahmadreza';
