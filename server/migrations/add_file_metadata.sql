-- Migration: Add file metadata columns to messages table
-- Run: sqlite3 messenger.db < migrations/add_file_metadata.sql

-- Add file_name column
ALTER TABLE messages ADD COLUMN file_name VARCHAR;

-- Add file_size column  
ALTER TABLE messages ADD COLUMN file_size INTEGER;

-- Add mime_type column
ALTER TABLE messages ADD COLUMN mime_type VARCHAR;

-- Verify columns were added
SELECT sql FROM sqlite_master WHERE type='table' AND name='messages';
