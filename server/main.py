from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.types import ASGIApp, Receive, Scope, Send
from dotenv import load_dotenv

# Load environment variables from .env file (MUST be before other imports)
load_dotenv()

from database import engine, Base
from routers import auth, users, messages, posts, uploads, comments, search, counts, voice, backup, subscriptions, notifications, devices, knowledge, groups, reports, blocks, debug_email, ai, events, recommendation, hashtags, admin, presence, contacts, rooms, livekit, mentions, verification_identity, discovery, data_export, webhook_revenuecat, snaps, message_requests, channels, stats, invites, group_keys, linked_devices, nearby, diagnostics, concert_mode, mesh, qr_login, e2ee, auth_opaque, gateway, atsam_prekey, ghost_route
import models  # ✅ CRITICAL: Import all models to register them with Base.metadata
from logging_config import configure_secure_logging
import os
import logging

# Configure secure logging (MUST be before any logging calls)
configure_secure_logging(level=logging.INFO)
logger = logging.getLogger(__name__)

# NOTE: Database tables and migrations are now created in the startup event
# to avoid blocking the port binding and causing Cloud Run startup probe timeouts.

# Run migrations for new columns/tables that create_all doesn't add to existing tables
def run_migrations():
    """Add missing columns to existing tables - PostgreSQL needs ALTER TABLE"""
    from sqlalchemy import text
    from database import SessionLocal
    
    migrations = [
        # ═══════════════════════════════════════════════════════════════════════════
        # INVITES (referral) - referrer + redeemer both get 30 days of Raven+
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS invite_redemptions (
            id VARCHAR PRIMARY KEY,
            inviter_id VARCHAR NOT NULL,
            redeemer_id VARCHAR NOT NULL,
            code VARCHAR NOT NULL,
            device_fingerprint VARCHAR,
            redeemed_at TIMESTAMP DEFAULT NOW()
        )
        """, "invite_redemptions table"),
        ("CREATE INDEX IF NOT EXISTS idx_invite_redemptions_inviter ON invite_redemptions(inviter_id)", "invite_redemptions.inviter_id idx"),
        ("CREATE INDEX IF NOT EXISTS idx_invite_redemptions_redeemer ON invite_redemptions(redeemer_id)", "invite_redemptions.redeemer_id idx"),
        ("CREATE INDEX IF NOT EXISTS idx_invite_redemptions_device ON invite_redemptions(device_fingerprint)", "invite_redemptions.device_fingerprint idx"),
        ("CREATE UNIQUE INDEX IF NOT EXISTS idx_invite_redemptions_inviter_redeemer ON invite_redemptions(inviter_id, redeemer_id)", "invite_redemptions.unique idx"),

        # Create content_consumptions table
        ("""
        CREATE TABLE IF NOT EXISTS content_consumptions (
            id VARCHAR PRIMARY KEY,
            user_id VARCHAR NOT NULL REFERENCES users(id),
            content_id VARCHAR NOT NULL,
            content_type VARCHAR NOT NULL,
            status VARCHAR NOT NULL,
            consumed_at TIMESTAMP DEFAULT NOW(),
            client_event_id VARCHAR,
            UNIQUE(user_id, content_id)
        )
        """, "content_consumptions table"),
        # Add index for performance
        ("CREATE INDEX IF NOT EXISTS idx_content_consumptions_user ON content_consumptions(user_id)", "content_consumptions index"),
        # Create mesh_view_receipts table for offline view tracking
        ("""
        CREATE TABLE IF NOT EXISTS mesh_view_receipts (
            id VARCHAR PRIMARY KEY,
            receipt_id VARCHAR NOT NULL,
            post_id VARCHAR NOT NULL REFERENCES posts(id),
            viewer_hash VARCHAR(64) NOT NULL,
            origin_device_id VARCHAR NOT NULL,
            hop_count INTEGER DEFAULT 0,
            created_at TIMESTAMP DEFAULT NOW(),
            synced_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(post_id, viewer_hash)
        )
        """, "mesh_view_receipts table"),
        ("CREATE INDEX IF NOT EXISTS idx_mesh_view_receipts_post ON mesh_view_receipts(post_id)", "mesh_view_receipts index"),
        # Add post_type, room_id, and is_hidden to posts table
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS post_type VARCHAR DEFAULT 'text'", "posts.post_type"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS room_id VARCHAR", "posts.room_id"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS is_hidden BOOLEAN DEFAULT FALSE", "posts.is_hidden"),
        # Mesh post support columns
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS mesh_origin BOOLEAN DEFAULT FALSE", "posts.mesh_origin"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS hashtags TEXT", "posts.hashtags"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS mesh_signature TEXT", "posts.mesh_signature"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS mesh_signer_key VARCHAR", "posts.mesh_signer_key"),
        # Voice post support
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS voice_url VARCHAR", "posts.voice_url"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS voice_duration INTEGER", "posts.voice_duration"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS waveform TEXT", "posts.waveform"),
        # Collaborative post (chain publish) support
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS origin_chain_id VARCHAR", "posts.origin_chain_id"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS co_authors TEXT", "posts.co_authors"),
        # Add reported_user_id and context_json to reports (for databases created before full schema)
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS reported_user_id VARCHAR", "reports.reported_user_id"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS context_json TEXT", "reports.context_json"),
        # Add share_slug to audio_rooms table for deep linking
        ("ALTER TABLE audio_rooms ADD COLUMN IF NOT EXISTS share_slug VARCHAR UNIQUE", "audio_rooms.share_slug"),
        # ═══════════════════════════════════════════════════════════════════════════
        # MESSAGE TABLE MIGRATIONS - Smart Message Expiry & Scheduled Messages
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS expiry_mode VARCHAR DEFAULT 'none'", "messages.expiry_mode"),
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP", "messages.expires_at"),
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_expired BOOLEAN DEFAULT FALSE", "messages.is_expired"),
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS allow_forward BOOLEAN DEFAULT TRUE", "messages.allow_forward"),
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS send_mode VARCHAR DEFAULT 'instant'", "messages.send_mode"),
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS scheduled_at_utc TIMESTAMP", "messages.scheduled_at_utc"),
        # ═══════════════════════════════════════════════════════════════════════════
        # GROUPS TABLE MIGRATIONS
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS groups (
            id VARCHAR PRIMARY KEY,
            name VARCHAR NOT NULL,
            created_by VARCHAR NOT NULL,
            avatar_url VARCHAR,
            created_at TIMESTAMP DEFAULT NOW()
        )
        """, "groups table"),
        ("""
        CREATE TABLE IF NOT EXISTS group_members (
            id VARCHAR PRIMARY KEY,
            group_id VARCHAR NOT NULL,
            user_id VARCHAR NOT NULL,
            role VARCHAR DEFAULT 'member',
            joined_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(group_id, user_id)
        )
        """, "group_members table"),
        # ═══════════════════════════════════════════════════════════════════════════
        # ROOM VISIBILITY TABLE (for unread counts)
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS room_visibility (
            id VARCHAR PRIMARY KEY,
            user_id VARCHAR NOT NULL,
            room_id VARCHAR NOT NULL,
            last_read_at TIMESTAMP,
            is_pinned BOOLEAN DEFAULT FALSE,
            is_muted BOOLEAN DEFAULT FALSE,
            UNIQUE(user_id, room_id)
        )
        """, "room_visibility table"),
        # ═══════════════════════════════════════════════════════════════════════════
        # USER PRIVACY & PROFILE SETTINGS
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS is_private BOOLEAN DEFAULT FALSE", "users.is_private"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS show_birthday BOOLEAN DEFAULT FALSE", "users.show_birthday"),
        # ═══════════════════════════════════════════════════════════════════════════
        # COMMENTS TABLE MIGRATIONS - Per-media comments
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS media_id VARCHAR", "comments.media_id"),
        # ═══════════════════════════════════════════════════════════════════════════
        # REFRESH TOKEN ROTATION - Token theft detection
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS replaced_by VARCHAR", "refresh_tokens.replaced_by"),
        ("CREATE INDEX IF NOT EXISTS idx_refresh_tokens_replaced_by ON refresh_tokens(replaced_by)", "refresh_tokens.replaced_by index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # ADVANCED MODERATION - AI Triage, Decisions, Appeals & Audit Log
        # ═══════════════════════════════════════════════════════════════════════════
        # AI Triage columns on reports
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_category VARCHAR", "reports.ai_category"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_severity INTEGER", "reports.ai_severity"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_confidence FLOAT", "reports.ai_confidence"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_summary TEXT", "reports.ai_summary"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS triaged_at TIMESTAMP", "reports.triaged_at"),
        # Decision tracking
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS decision VARCHAR", "reports.decision"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS decision_reason TEXT", "reports.decision_reason"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS decided_by VARCHAR", "reports.decided_by"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS decided_at TIMESTAMP", "reports.decided_at"),
        # Appeal workflow
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_status VARCHAR DEFAULT 'none'", "reports.appeal_status"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_text TEXT", "reports.appeal_text"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_decided_by VARCHAR", "reports.appeal_decided_by"),
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_decided_at TIMESTAMP", "reports.appeal_decided_at"),
        # Evidence
        ("ALTER TABLE reports ADD COLUMN IF NOT EXISTS evidence_json TEXT", "reports.evidence_json"),
        # Update existing statuses
        ("UPDATE reports SET status = 'open' WHERE status = 'new'", "reports.status migration"),
        # Moderation actions audit table
        ("""
        CREATE TABLE IF NOT EXISTS moderation_actions (
            id VARCHAR PRIMARY KEY,
            report_id VARCHAR REFERENCES reports(id),
            target_type VARCHAR NOT NULL,
            target_id VARCHAR NOT NULL,
            action_type VARCHAR NOT NULL,
            parameters_json TEXT,
            actor VARCHAR NOT NULL,
            timestamp TIMESTAMP DEFAULT NOW(),
            reversible BOOLEAN DEFAULT TRUE,
            reversed_at TIMESTAMP,
            reversed_by VARCHAR
        )
        """, "moderation_actions table"),
        ("CREATE INDEX IF NOT EXISTS idx_moderation_actions_report ON moderation_actions(report_id)", "moderation_actions.report_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_moderation_actions_target ON moderation_actions(target_id)", "moderation_actions.target_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_moderation_actions_timestamp ON moderation_actions(timestamp)", "moderation_actions.timestamp index"),
        # Add 'moderation' to hidden_content reason
        ("ALTER TABLE hidden_content ADD COLUMN IF NOT EXISTS reason VARCHAR DEFAULT 'reported'", "hidden_content.reason"),
        # ═══════════════════════════════════════════════════════════════════════════
        # IDENTITY VERIFICATION COLUMNS ON USERS
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS verified_at TIMESTAMP", "users.verified_at"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_badge_type VARCHAR DEFAULT 'identity'", "users.verification_badge_type"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_visibility BOOLEAN DEFAULT TRUE", "users.verification_visibility"),
        # ═══════════════════════════════════════════════════════════════════════════
        # EMAIL/PHONE VERIFICATION TIMESTAMPS
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN DEFAULT FALSE", "users.email_verified"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified BOOLEAN DEFAULT FALSE", "users.phone_verified"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMP", "users.email_verified_at"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMP", "users.phone_verified_at"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_e164 VARCHAR", "users.phone_e164"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_hash VARCHAR", "users.phone_hash"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS allow_contact_discovery BOOLEAN DEFAULT TRUE", "users.allow_contact_discovery"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS verification_status VARCHAR DEFAULT 'pending'", "users.verification_status"),
        # ═══════════════════════════════════════════════════════════════════════════
        # COMMENTS & GROUP MESSAGES - Entities / Mentions
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS entities TEXT", "comments.entities"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS is_hidden BOOLEAN DEFAULT FALSE", "comments.is_hidden"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS is_ai_generated BOOLEAN DEFAULT FALSE", "comments.is_ai_generated"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS parent_comment_id VARCHAR", "comments.parent_comment_id"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS score INTEGER DEFAULT 0", "comments.score"),
        # Groups missing columns
        ("ALTER TABLE groups ADD COLUMN IF NOT EXISTS description TEXT", "groups.description"),
        ("ALTER TABLE groups ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT NOW()", "groups.updated_at"),
        # Group messages table (full creation)
        ("""
        CREATE TABLE IF NOT EXISTS group_messages (
            id VARCHAR PRIMARY KEY,
            group_id VARCHAR NOT NULL,
            sender_id VARCHAR NOT NULL,
            content TEXT NOT NULL,
            timestamp TIMESTAMP DEFAULT NOW(),
            message_type VARCHAR DEFAULT 'text',
            audio_url VARCHAR,
            file_name VARCHAR,
            file_size INTEGER,
            mime_type VARCHAR,
            reply_to_message_id VARCHAR,
            reply_to_text_preview VARCHAR,
            reply_to_sender_name VARCHAR,
            reply_to_type VARCHAR,
            entities TEXT
        )
        """, "group_messages table"),
        ("CREATE INDEX IF NOT EXISTS idx_group_messages_group ON group_messages(group_id)", "group_messages.group_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_group_messages_timestamp ON group_messages(timestamp)", "group_messages.timestamp index"),
        # Ensure all group_messages columns exist (table may have been created before these were added)
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS message_type VARCHAR DEFAULT 'text'", "group_messages.message_type"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS audio_url VARCHAR", "group_messages.audio_url"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS file_name VARCHAR", "group_messages.file_name"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS file_size INTEGER", "group_messages.file_size"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS mime_type VARCHAR", "group_messages.mime_type"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS reply_to_message_id VARCHAR", "group_messages.reply_to_message_id"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS reply_to_text_preview VARCHAR", "group_messages.reply_to_text_preview"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS reply_to_sender_name VARCHAR", "group_messages.reply_to_sender_name"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS reply_to_type VARCHAR", "group_messages.reply_to_type"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS entities TEXT", "group_messages.entities"),
        # Mesh delivery tracking for group messages
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS recipient_set TEXT", "group_messages.recipient_set"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS delivered_to TEXT", "group_messages.delivered_to"),
        # Group privacy & invite link support
        ("ALTER TABLE groups ADD COLUMN IF NOT EXISTS visibility VARCHAR DEFAULT 'private'", "groups.visibility"),
        ("ALTER TABLE groups ADD COLUMN IF NOT EXISTS link_join_enabled BOOLEAN DEFAULT TRUE", "groups.link_join_enabled"),
        ("""
        CREATE TABLE IF NOT EXISTS group_invite_links (
            id VARCHAR PRIMARY KEY,
            group_id VARCHAR NOT NULL UNIQUE,
            invite_code VARCHAR NOT NULL UNIQUE,
            created_by VARCHAR NOT NULL,
            enabled BOOLEAN DEFAULT TRUE,
            use_count INTEGER DEFAULT 0,
            max_uses INTEGER,
            expires_at TIMESTAMP,
            created_at TIMESTAMP DEFAULT NOW()
        )
        """, "group_invite_links table"),
        ("CREATE INDEX IF NOT EXISTS idx_invite_code ON group_invite_links(invite_code)", "group_invite_links.invite_code index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # MENTIONS TABLE
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS mentions (
            id VARCHAR PRIMARY KEY,
            type VARCHAR NOT NULL,
            source_id VARCHAR NOT NULL,
            post_id VARCHAR,
            room_id VARCHAR,
            mentioned_user_id VARCHAR NOT NULL,
            mentioned_by_user_id VARCHAR NOT NULL,
            created_at TIMESTAMP DEFAULT NOW(),
            snippet TEXT,
            deep_link VARCHAR,
            is_read BOOLEAN DEFAULT FALSE
        )
        """, "mentions table"),
        ("CREATE INDEX IF NOT EXISTS idx_mentions_mentioned_user ON mentions(mentioned_user_id)", "mentions.mentioned_user_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_mentions_is_read ON mentions(is_read)", "mentions.is_read index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # VERIFICATION REQUESTS TABLE
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS verification_requests (
            id VARCHAR PRIMARY KEY,
            user_id VARCHAR NOT NULL REFERENCES users(id),
            status VARCHAR NOT NULL DEFAULT 'pending',
            legal_first_name VARCHAR NOT NULL,
            legal_last_name VARCHAR NOT NULL,
            country VARCHAR NOT NULL,
            category VARCHAR NOT NULL DEFAULT 'person',
            doc_type VARCHAR NOT NULL,
            doc_front_url VARCHAR,
            doc_back_url VARCHAR,
            selfie_url VARCHAR,
            links_json TEXT,
            submitted_at TIMESTAMP DEFAULT NOW(),
            reviewed_at TIMESTAMP,
            reviewer_admin_id VARCHAR,
            decision_reason TEXT,
            notes_internal TEXT,
            hash_dedupe VARCHAR,
            version INTEGER DEFAULT 1
        )
        """, "verification_requests table"),
        ("CREATE INDEX IF NOT EXISTS idx_verification_req_user ON verification_requests(user_id)", "verification_requests.user_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_verification_req_status ON verification_requests(status)", "verification_requests.status index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # REPORTS TABLE (content moderation)
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS reports (
            id VARCHAR PRIMARY KEY,
            reporter_id VARCHAR NOT NULL REFERENCES users(id),
            target_type VARCHAR NOT NULL,
            target_id VARCHAR NOT NULL,
            reported_user_id VARCHAR REFERENCES users(id),
            reason VARCHAR NOT NULL,
            note TEXT,
            evidence_json TEXT,
            context_json TEXT,
            status VARCHAR DEFAULT 'open',
            created_at TIMESTAMP DEFAULT NOW(),
            ai_category VARCHAR,
            ai_severity INTEGER,
            ai_confidence FLOAT,
            ai_summary TEXT,
            triaged_at TIMESTAMP,
            decision VARCHAR DEFAULT 'none',
            decision_reason TEXT,
            decided_by VARCHAR,
            decided_at TIMESTAMP,
            appeal_status VARCHAR DEFAULT 'none',
            appeal_text TEXT,
            appeal_decided_by VARCHAR,
            appeal_decided_at TIMESTAMP
        )
        """, "reports table"),
        ("CREATE INDEX IF NOT EXISTS idx_reports_reporter ON reports(reporter_id)", "reports.reporter_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_reports_target ON reports(target_id)", "reports.target_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_reports_reported_user ON reports(reported_user_id)", "reports.reported_user_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_reports_created ON reports(created_at)", "reports.created_at index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # MODERATION ACTIONS TABLE (audit log)
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS moderation_actions (
            id VARCHAR PRIMARY KEY,
            report_id VARCHAR REFERENCES reports(id),
            target_type VARCHAR NOT NULL,
            target_id VARCHAR NOT NULL,
            action_type VARCHAR NOT NULL,
            parameters_json TEXT,
            actor VARCHAR NOT NULL,
            timestamp TIMESTAMP DEFAULT NOW(),
            reversible BOOLEAN DEFAULT TRUE,
            reversed_at TIMESTAMP,
            reversed_by VARCHAR
        )
        """, "moderation_actions table"),
        ("CREATE INDEX IF NOT EXISTS idx_mod_actions_report ON moderation_actions(report_id)", "moderation_actions.report_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_mod_actions_target ON moderation_actions(target_id)", "moderation_actions.target_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_mod_actions_timestamp ON moderation_actions(timestamp)", "moderation_actions.timestamp index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # MODERATION ENFORCEMENT COLUMNS ON USERS
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS is_banned BOOLEAN DEFAULT FALSE", "users.is_banned"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS banned_at TIMESTAMP", "users.banned_at"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS ban_reason TEXT", "users.ban_reason"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS is_restricted BOOLEAN DEFAULT FALSE", "users.is_restricted"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS restricted_until TIMESTAMP", "users.restricted_until"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS restriction_scope VARCHAR", "users.restriction_scope"),
        # Push notification columns
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS push_token VARCHAR", "users.push_token"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS push_platform VARCHAR", "users.push_platform"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS push_environment VARCHAR", "users.push_environment"),
        # Spotify columns
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS spotify_track_id VARCHAR", "users.spotify_track_id"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS spotify_track_title VARCHAR", "users.spotify_track_title"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS spotify_track_artist VARCHAR", "users.spotify_track_artist"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS spotify_cover_url VARCHAR", "users.spotify_cover_url"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS spotify_preview_url VARCHAR", "users.spotify_preview_url"),
        # ═══════════════════════════════════════════════════════════════════════════
        # FRIENDSHIPS TABLE
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS friendships (
            id VARCHAR PRIMARY KEY,
            user_id VARCHAR NOT NULL REFERENCES users(id),
            friend_id VARCHAR NOT NULL REFERENCES users(id),
            created_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(user_id, friend_id)
        )
        """, "friendships table"),
        ("CREATE INDEX IF NOT EXISTS idx_friendships_user ON friendships(user_id)", "friendships.user_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_friendships_friend ON friendships(friend_id)", "friendships.friend_id index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # COMMENT MEDIA COLUMNS (voice + image comments)
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS comment_type VARCHAR DEFAULT 'text'", "comments.comment_type"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS media_url VARCHAR", "comments.media_url"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS duration_sec FLOAT", "comments.duration_sec"),
        # ═══════════════════════════════════════════════════════════════════════════
        # NOTIFICATION PREFERENCES & PRIVACY SETTINGS ON USERS
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS push_enabled BOOLEAN DEFAULT TRUE", "users.push_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS message_notifications_enabled BOOLEAN DEFAULT TRUE", "users.message_notifications_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS friend_request_notifications_enabled BOOLEAN DEFAULT TRUE", "users.friend_request_notifications_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS likes_comments_notifications_enabled BOOLEAN DEFAULT TRUE", "users.likes_comments_notifications_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS sounds_enabled BOOLEAN DEFAULT TRUE", "users.sounds_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS message_preview_enabled BOOLEAN DEFAULT TRUE", "users.message_preview_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS show_online_status BOOLEAN DEFAULT TRUE", "users.show_online_status"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS read_receipts_enabled BOOLEAN DEFAULT TRUE", "users.read_receipts_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS who_can_message VARCHAR DEFAULT 'everyone'", "users.who_can_message"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS who_can_see_profile VARCHAR DEFAULT 'public'", "users.who_can_see_profile"),
        # Hobbies
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS hobbies TEXT", "users.hobbies"),
        # ═══════════════════════════════════════════════════════════════════════════
        # GROUP CHAT FUN PACK
        # ═══════════════════════════════════════════════════════════════════════════
        # Freeze Mode columns on groups
        ("ALTER TABLE groups ADD COLUMN IF NOT EXISTS is_frozen BOOLEAN DEFAULT FALSE", "groups.is_frozen"),
        ("ALTER TABLE groups ADD COLUMN IF NOT EXISTS frozen_by VARCHAR", "groups.frozen_by"),
        ("ALTER TABLE groups ADD COLUMN IF NOT EXISTS frozen_at TIMESTAMP", "groups.frozen_at"),
        # Time Bomb + Poll reference on group_messages
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS bomb_duration_sec INTEGER", "group_messages.bomb_duration_sec"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS poll_id VARCHAR", "group_messages.poll_id"),
        # Poll tables
        ("""
        CREATE TABLE IF NOT EXISTS group_polls (
            id VARCHAR PRIMARY KEY,
            group_id VARCHAR NOT NULL REFERENCES groups(id),
            creator_id VARCHAR NOT NULL REFERENCES users(id),
            question TEXT NOT NULL,
            allow_multiple BOOLEAN DEFAULT FALSE,
            is_anonymous BOOLEAN DEFAULT FALSE,
            expires_at TIMESTAMP,
            is_closed BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP DEFAULT NOW()
        )
        """, "group_polls table"),
        ("CREATE INDEX IF NOT EXISTS idx_group_polls_group ON group_polls(group_id)", "group_polls.group_id index"),
        ("""
        CREATE TABLE IF NOT EXISTS group_poll_options (
            id VARCHAR PRIMARY KEY,
            poll_id VARCHAR NOT NULL REFERENCES group_polls(id),
            text VARCHAR NOT NULL,
            order_index INTEGER DEFAULT 0,
            vote_count INTEGER DEFAULT 0
        )
        """, "group_poll_options table"),
        ("CREATE INDEX IF NOT EXISTS idx_poll_options_poll ON group_poll_options(poll_id)", "group_poll_options.poll_id index"),
        ("""
        CREATE TABLE IF NOT EXISTS group_poll_votes (
            id VARCHAR PRIMARY KEY,
            poll_id VARCHAR NOT NULL REFERENCES group_polls(id),
            option_id VARCHAR NOT NULL REFERENCES group_poll_options(id),
            user_id VARCHAR NOT NULL REFERENCES users(id),
            voted_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(poll_id, option_id, user_id)
        )
        """, "group_poll_votes table"),
        ("CREATE INDEX IF NOT EXISTS idx_poll_votes_poll ON group_poll_votes(poll_id)", "group_poll_votes.poll_id index"),
        # Group Masks table
        ("""
        CREATE TABLE IF NOT EXISTS group_masks (
            id VARCHAR PRIMARY KEY,
            group_id VARCHAR NOT NULL REFERENCES groups(id),
            user_id VARCHAR NOT NULL REFERENCES users(id),
            mask_name VARCHAR NOT NULL,
            mask_emoji VARCHAR NOT NULL,
            is_active BOOLEAN DEFAULT TRUE,
            assigned_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(group_id, user_id)
        )
        """, "group_masks table"),
        ("CREATE INDEX IF NOT EXISTS idx_group_masks_group ON group_masks(group_id)", "group_masks.group_id index"),
        # Voice Chain tables
        ("""
        CREATE TABLE IF NOT EXISTS voice_chains (
            id VARCHAR PRIMARY KEY,
            group_id VARCHAR NOT NULL REFERENCES groups(id),
            creator_id VARCHAR NOT NULL REFERENCES users(id),
            title VARCHAR NOT NULL,
            max_duration_sec INTEGER DEFAULT 15,
            status VARCHAR DEFAULT 'open',
            created_at TIMESTAMP DEFAULT NOW()
        )
        """, "voice_chains table"),
        ("CREATE INDEX IF NOT EXISTS idx_voice_chains_group ON voice_chains(group_id)", "voice_chains.group_id index"),
        ("""
        CREATE TABLE IF NOT EXISTS voice_chain_links (
            id VARCHAR PRIMARY KEY,
            chain_id VARCHAR NOT NULL REFERENCES voice_chains(id),
            user_id VARCHAR NOT NULL REFERENCES users(id),
            audio_url VARCHAR NOT NULL,
            duration_sec INTEGER NOT NULL,
            order_index INTEGER DEFAULT 0,
            created_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(chain_id, user_id)
        )
        """, "voice_chain_links table"),
        ("CREATE INDEX IF NOT EXISTS idx_voice_chain_links_chain ON voice_chain_links(chain_id)", "voice_chain_links.chain_id index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # VOICE TRANSCRIPTION COLUMNS (Gemini-powered on-demand transcription)
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS transcript_text TEXT", "posts.transcript_text"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS transcript_status VARCHAR DEFAULT 'none'", "posts.transcript_status"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS transcript_language VARCHAR", "posts.transcript_language"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS transcript_text TEXT", "comments.transcript_text"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS transcript_status VARCHAR DEFAULT 'none'", "comments.transcript_status"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS transcript_language VARCHAR", "comments.transcript_language"),
        # ═══════════════════════════════════════════════════════════════════════════
        # VOICE MESSAGE TRANSCRIPTION COLUMNS (chat messages — 1:1 & group)
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS transcript_text TEXT", "messages.transcript_text"),
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS transcript_status VARCHAR DEFAULT 'none'", "messages.transcript_status"),
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS transcript_language VARCHAR", "messages.transcript_language"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS transcript_text TEXT", "group_messages.transcript_text"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS transcript_status VARCHAR DEFAULT 'none'", "group_messages.transcript_status"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS transcript_language VARCHAR", "group_messages.transcript_language"),
        # ═══════════════════════════════════════════════════════════════════════════
        # VOICE MESSAGE DURATION (for receiver playback)
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE messages ADD COLUMN IF NOT EXISTS audio_duration_seconds INTEGER", "messages.audio_duration_seconds"),
        ("ALTER TABLE group_messages ADD COLUMN IF NOT EXISTS audio_duration_seconds INTEGER", "group_messages.audio_duration_seconds"),
        # ═══════════════════════════════════════════════════════════════════════════
        # AUDIO ROOM AUTO-CLOSE (heartbeat + TTL)
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE audio_rooms ADD COLUMN IF NOT EXISTS last_activity TIMESTAMP", "audio_rooms.last_activity"),
        ("ALTER TABLE audio_room_participants ADD COLUMN IF NOT EXISTS last_heartbeat_at TIMESTAMP", "audio_room_participants.last_heartbeat_at"),
        # 🔒 is_locked — was settable via /settings, but the column never existed
        # so SQLAlchemy's setattr silently dropped it. Now the host's "lock room"
        # control actually keeps people out (see join_room).
        ("ALTER TABLE audio_rooms ADD COLUMN IF NOT EXISTS is_locked BOOLEAN DEFAULT FALSE", "audio_rooms.is_locked"),
        # ✏️ Comment edit + 📌 pin support
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS edited_at TIMESTAMP", "comments.edited_at"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN DEFAULT FALSE", "comments.is_pinned"),
        ("ALTER TABLE comments ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMP", "comments.pinned_at"),
        ("CREATE INDEX IF NOT EXISTS idx_comments_pinned ON comments(post_id, is_pinned)", "comments.pinned idx"),
        # ═══════════════════════════════════════════════════════════════════════════
        # RAVEN+ PREMIUM SUBSCRIPTION
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS is_premium BOOLEAN DEFAULT FALSE", "users.is_premium"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS premium_expires_at TIMESTAMP", "users.premium_expires_at"),
        # Grant permanent premium to admin account
        ("UPDATE users SET is_premium = TRUE WHERE LOWER(username) = 'ahmadreza'", "users.is_premium (AHMADREZA)"),
        # ═══════════════════════════════════════════════════════════════════════════
        # ⚡ PERFORMANCE INDEXES — accelerate chat loading queries
        # ═══════════════════════════════════════════════════════════════════════════
        ("CREATE INDEX IF NOT EXISTS idx_messages_recipient_ts ON messages(recipient_id, timestamp DESC)", "messages composite index (recipient+ts)"),
        ("CREATE INDEX IF NOT EXISTS idx_messages_sender_recipient_ts ON messages(sender_id, recipient_id, timestamp)", "messages composite index (sender+recipient+ts)"),
        ("CREATE INDEX IF NOT EXISTS idx_messages_read_at ON messages(recipient_id, read_at) WHERE read_at IS NULL", "messages partial index (unread)"),
        ("CREATE INDEX IF NOT EXISTS idx_group_messages_group_ts ON group_messages(group_id, timestamp DESC)", "group_messages composite index (group+ts)"),
        ("CREATE INDEX IF NOT EXISTS idx_group_members_user_group ON group_members(user_id, group_id)", "group_members composite index (user+group)"),
        # ═══════════════════════════════════════════════════════════════════════════
        # EPHEMERAL PHOTO (Snap) COLUMNS
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE snap_messages ADD COLUMN IF NOT EXISTS conversation_id VARCHAR", "snap_messages.conversation_id"),
        ("ALTER TABLE snap_messages ADD COLUMN IF NOT EXISTS ttl_seconds INTEGER DEFAULT 10", "snap_messages.ttl_seconds"),
        ("CREATE INDEX IF NOT EXISTS idx_snap_messages_conversation ON snap_messages(conversation_id)", "snap_messages.conversation_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_snap_messages_status ON snap_messages(status)", "snap_messages.status index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # CHANNELS (Telegram-style broadcast)
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS channels (
            id VARCHAR PRIMARY KEY,
            owner_id VARCHAR NOT NULL REFERENCES users(id),
            channel_username VARCHAR NOT NULL UNIQUE,
            name VARCHAR NOT NULL,
            description TEXT,
            avatar_url VARCHAR,
            type VARCHAR DEFAULT 'public',
            verified_status VARCHAR DEFAULT 'none',
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        )
        """, "channels table"),
        ("CREATE INDEX IF NOT EXISTS idx_channels_owner ON channels(owner_id)", "channels.owner_id index"),
        ("CREATE UNIQUE INDEX IF NOT EXISTS idx_channels_username ON channels(channel_username)", "channels.channel_username unique index"),
        ("""
        CREATE TABLE IF NOT EXISTS channel_members (
            id VARCHAR PRIMARY KEY,
            channel_id VARCHAR NOT NULL REFERENCES channels(id),
            user_id VARCHAR NOT NULL REFERENCES users(id),
            role VARCHAR DEFAULT 'member',
            muted BOOLEAN DEFAULT FALSE,
            joined_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(channel_id, user_id)
        )
        """, "channel_members table"),
        ("CREATE INDEX IF NOT EXISTS idx_channel_members_channel ON channel_members(channel_id)", "channel_members.channel_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_channel_members_user ON channel_members(user_id)", "channel_members.user_id index"),
        ("""
        CREATE TABLE IF NOT EXISTS channel_posts (
            id VARCHAR PRIMARY KEY,
            channel_id VARCHAR NOT NULL REFERENCES channels(id),
            author_id VARCHAR NOT NULL REFERENCES users(id),
            content_type VARCHAR DEFAULT 'text',
            content_payload TEXT,
            media_url VARCHAR,
            created_at TIMESTAMP DEFAULT NOW()
        )
        """, "channel_posts table"),
        ("CREATE INDEX IF NOT EXISTS idx_channel_posts_channel_ts ON channel_posts(channel_id, created_at DESC)", "channel_posts composite index"),
        ("""
        CREATE TABLE IF NOT EXISTS channel_invite_links (
            id VARCHAR PRIMARY KEY,
            channel_id VARCHAR NOT NULL REFERENCES channels(id) UNIQUE,
            invite_code VARCHAR NOT NULL UNIQUE,
            created_by VARCHAR NOT NULL REFERENCES users(id),
            enabled BOOLEAN DEFAULT TRUE,
            use_count INTEGER DEFAULT 0,
            max_uses INTEGER,
            expires_at TIMESTAMP,
            created_at TIMESTAMP DEFAULT NOW()
        )
        """, "channel_invite_links table"),
        ("CREATE INDEX IF NOT EXISTS idx_channel_invite_code ON channel_invite_links(invite_code)", "channel_invite_links.invite_code index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # HASHTAG FOLLOWS TABLE
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS hashtag_follows (
            id VARCHAR PRIMARY KEY,
            user_id VARCHAR NOT NULL REFERENCES users(id),
            hashtag VARCHAR NOT NULL,
            created_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(user_id, hashtag)
        )
        """, "hashtag_follows table"),
        ("CREATE INDEX IF NOT EXISTS idx_hashtag_follows_user ON hashtag_follows(user_id)", "hashtag_follows.user_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_hashtag_follows_hashtag ON hashtag_follows(hashtag)", "hashtag_follows.hashtag index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # POST MEDIA — Video thumbnail support
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE post_media ADD COLUMN IF NOT EXISTS thumbnail_url VARCHAR", "post_media.thumbnail_url"),
        # ═══════════════════════════════════════════════════════════════════════════
        # PROFILE TAB PRIVACY — show/hide liked posts and replies on profile
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS show_liked_posts BOOLEAN DEFAULT TRUE", "users.show_liked_posts"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS show_replies BOOLEAN DEFAULT TRUE", "users.show_replies"),
        # ═══════════════════════════════════════════════════════════════════════════
        # GRANULAR SOCIAL NOTIFICATION PREFERENCES
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS new_post_notifications_enabled BOOLEAN DEFAULT TRUE", "users.new_post_notifications_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS audio_room_notifications_enabled BOOLEAN DEFAULT TRUE", "users.audio_room_notifications_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS mention_notifications_enabled BOOLEAN DEFAULT TRUE", "users.mention_notifications_enabled"),
        # ═══════════════════════════════════════════════════════════════════════════
        # USER NOTIFICATION SUBSCRIPTIONS (Bell icon per-user)
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS user_notification_subscriptions (
            id VARCHAR PRIMARY KEY,
            subscriber_id VARCHAR NOT NULL REFERENCES users(id),
            target_id VARCHAR NOT NULL REFERENCES users(id),
            notify_posts BOOLEAN DEFAULT TRUE,
            notify_audio_rooms BOOLEAN DEFAULT TRUE,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(subscriber_id, target_id)
        )
        """, "user_notification_subscriptions table"),
        ("CREATE INDEX IF NOT EXISTS idx_notif_sub_subscriber ON user_notification_subscriptions(subscriber_id)", "user_notification_subscriptions.subscriber_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_notif_sub_target ON user_notification_subscriptions(target_id)", "user_notification_subscriptions.target_id index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # FOLLOW SYSTEM (Instagram-style directional follows)
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS follows (
            id VARCHAR PRIMARY KEY,
            follower_id VARCHAR NOT NULL REFERENCES users(id),
            following_id VARCHAR NOT NULL REFERENCES users(id),
            created_at TIMESTAMP DEFAULT NOW(),
            UNIQUE(follower_id, following_id)
        )
        """, "follows table"),
        ("CREATE INDEX IF NOT EXISTS idx_follows_follower ON follows(follower_id)", "follows.follower_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_follows_following ON follows(following_id)", "follows.following_id index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # TWO-FACTOR AUTHENTICATION COLUMNS
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS two_factor_enabled BOOLEAN DEFAULT FALSE", "users.two_factor_enabled"),
        ("ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_secret VARCHAR", "users.totp_secret"),
        # ═══════════════════════════════════════════════════════════════════════════
        # RAVEN SHOT — Social Map opt-in column
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS show_on_raven_shot BOOLEAN DEFAULT FALSE", "posts.show_on_raven_shot"),
        ("CREATE INDEX IF NOT EXISTS idx_posts_raven_shot ON posts(show_on_raven_shot) WHERE show_on_raven_shot = TRUE", "posts.show_on_raven_shot index"),
        # ═══════════════════════════════════════════════════════════════════════════
        # LOCATION NAME — Human-readable place name on posts
        # ═══════════════════════════════════════════════════════════════════════════
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS location_name VARCHAR", "posts.location_name"),
        # ═══════════════════════════════════════════════════════════════════════════
        # POST TAGS — Tag people in posts/photos (Instagram-style)
        # ═══════════════════════════════════════════════════════════════════════════
        ("""
        CREATE TABLE IF NOT EXISTS post_tags (
            id VARCHAR PRIMARY KEY,
            post_id VARCHAR NOT NULL REFERENCES posts(id),
            media_id VARCHAR,
            tagged_user_id VARCHAR NOT NULL REFERENCES users(id),
            tagged_by_user_id VARCHAR NOT NULL REFERENCES users(id),
            x_position FLOAT,
            y_position FLOAT,
            timestamp TIMESTAMP DEFAULT NOW(),
            UNIQUE(post_id, tagged_user_id)
        )
        """, "post_tags table"),
        ("CREATE INDEX IF NOT EXISTS idx_post_tags_post ON post_tags(post_id)", "post_tags.post_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_post_tags_user ON post_tags(tagged_user_id)", "post_tags.tagged_user_id index"),
        ("CREATE INDEX IF NOT EXISTS idx_post_tags_by ON post_tags(tagged_by_user_id)", "post_tags.tagged_by_user_id index"),
    ]

    
    from database import engine as _engine
    
    # ── Always-run mini migrations ──
    # Brand-new tables added in recent deploys. These are SAFE to run on every
    # startup (CREATE TABLE IF NOT EXISTS is a no-op when the table exists)
    # and they MUST run unconditionally because the guard below will short-
    # circuit the main migration list once the marker column exists.
    always_run = [
        ("""
        CREATE TABLE IF NOT EXISTS invite_redemptions (
            id VARCHAR PRIMARY KEY,
            inviter_id VARCHAR NOT NULL,
            redeemer_id VARCHAR NOT NULL,
            code VARCHAR NOT NULL,
            device_fingerprint VARCHAR,
            redeemed_at TIMESTAMP DEFAULT NOW()
        )
        """, "invite_redemptions table (always-run)"),
        ("CREATE INDEX IF NOT EXISTS idx_invite_redemptions_inviter ON invite_redemptions(inviter_id)", "invite_redemptions.inviter_id idx"),
        ("CREATE INDEX IF NOT EXISTS idx_invite_redemptions_redeemer ON invite_redemptions(redeemer_id)", "invite_redemptions.redeemer_id idx"),
        ("CREATE INDEX IF NOT EXISTS idx_invite_redemptions_device ON invite_redemptions(device_fingerprint)", "invite_redemptions.device_fingerprint idx"),
        ("CREATE UNIQUE INDEX IF NOT EXISTS idx_invite_redemptions_inviter_redeemer ON invite_redemptions(inviter_id, redeemer_id)", "invite_redemptions.unique idx"),
        # ── Per-group AES-256 keys (mesh anti-spoof) ──
        ("""
        CREATE TABLE IF NOT EXISTS group_keys (
            id VARCHAR PRIMARY KEY,
            group_id VARCHAR NOT NULL,
            version INTEGER NOT NULL,
            key_b64 VARCHAR NOT NULL,
            created_at TIMESTAMP DEFAULT NOW() NOT NULL
        )
        """, "group_keys table"),
        ("CREATE UNIQUE INDEX IF NOT EXISTS idx_group_keys_group_version ON group_keys(group_id, version)", "group_keys.unique idx"),
        # ── Linked devices (multi-device sessions) ──
        ("""
        CREATE TABLE IF NOT EXISTS linked_devices (
            id VARCHAR PRIMARY KEY,
            user_id VARCHAR NOT NULL,
            device_name VARCHAR,
            device_model VARCHAR,
            device_os VARCHAR,
            ip_first VARCHAR,
            paired_at TIMESTAMP DEFAULT NOW() NOT NULL,
            last_seen_at TIMESTAMP DEFAULT NOW() NOT NULL,
            revoked_at TIMESTAMP
        )
        """, "linked_devices table"),
        ("CREATE INDEX IF NOT EXISTS idx_linked_devices_user ON linked_devices(user_id)", "linked_devices.user_id idx"),
        # ── 🚨 CRITICAL: posts schema columns that the feed query depends on ──
        # These were added to the BIG migration list above the guard, so on
        # databases provisioned before they existed the feed crashes with
        # `UndefinedColumn`. Promoting them to always-run guarantees the feed
        # endpoints return 200 regardless of which migration generation the
        # database started at. `IF NOT EXISTS` makes this a no-op once applied.
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS show_on_raven_shot BOOLEAN DEFAULT FALSE", "posts.show_on_raven_shot (always-run)"),
        ("CREATE INDEX IF NOT EXISTS idx_posts_raven_shot ON posts(show_on_raven_shot) WHERE show_on_raven_shot = TRUE", "posts.show_on_raven_shot idx (always-run)"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS location_name VARCHAR", "posts.location_name (always-run)"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION", "posts.latitude (always-run)"),
        ("ALTER TABLE posts ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION", "posts.longitude (always-run)"),
        # ── Crash / perf diagnostics intake (MetricKit) ──
        ("""
        CREATE TABLE IF NOT EXISTS crash_reports (
            id VARCHAR PRIMARY KEY,
            user_id VARCHAR,
            type VARCHAR NOT NULL,
            occurred_at TIMESTAMP NOT NULL,
            received_at TIMESTAMP DEFAULT NOW() NOT NULL,
            app_version VARCHAR,
            os_version VARCHAR,
            device_model VARCHAR,
            session_id VARCHAR,
            summary VARCHAR,
            payload_size INTEGER DEFAULT 0,
            payload TEXT
        )
        """, "crash_reports table"),
        ("CREATE INDEX IF NOT EXISTS idx_crash_reports_user ON crash_reports(user_id)", "crash_reports.user idx"),
        ("CREATE INDEX IF NOT EXISTS idx_crash_reports_type_occurred ON crash_reports(type, occurred_at DESC)", "crash_reports.type+occurred idx"),
        # ── Concert Mode (ephemeral venue groups) ──
        ("""
        CREATE TABLE IF NOT EXISTS concert_groups (
            id VARCHAR PRIMARY KEY,
            h3_cell VARCHAR NOT NULL,
            group_id VARCHAR NOT NULL,
            created_at TIMESTAMP DEFAULT NOW() NOT NULL,
            expires_at TIMESTAMP NOT NULL
        )
        """, "concert_groups table"),
        ("CREATE INDEX IF NOT EXISTS idx_concert_h3_active ON concert_groups(h3_cell, expires_at)", "concert_groups.h3 idx"),
    ]
    try:
        with _engine.connect() as ar_conn:
            ar_conn.execute(text("SET statement_timeout = '10s'"))
            for sql, desc in always_run:
                try:
                    ar_conn.execute(text(sql))
                    ar_conn.commit()
                    logger.info(f"✅ Always-run migration: {desc}")
                except Exception as e:
                    logger.warning(f"⚠️ Always-run migration failed for {desc}: {e}")
    except Exception as e:
        logger.warning(f"⚠️ Always-run migrations connection failed: {e}")

    # ─────────────────────────────────────────────────────────────────────
    # APPLIED-MIGRATIONS LEDGER (Alembic-style)
    # ─────────────────────────────────────────────────────────────────────
    # Replaces the previous "marker column" guard which caused the
    # `posts.show_on_raven_shot does not exist` outage: any new migration
    # added AFTER `users.push_environment` was already in production
    # silently failed to apply on existing databases.
    #
    # New design:
    #   * `applied_migrations(key TEXT PRIMARY KEY, applied_at TIMESTAMP)`
    #     stores the set of migrations that have run against THIS database.
    #   * `key` = the second tuple element ("description") of each migration,
    #     which is already a unique human-readable string in the codebase.
    #   * On each startup we read the set, skip migrations whose key is
    #     present, and INSERT the key for each newly-applied one.
    #
    # Bootstrap: on the FIRST startup with this code, the ledger is empty,
    # so EVERY migration runs once. Every migration in the list is
    # idempotent (`CREATE … IF NOT EXISTS`, `ALTER … ADD COLUMN IF NOT
    # EXISTS`, or pure UPDATE statements), so a one-time replay is safe.
    # Subsequent startups see all keys already in the ledger and become
    # near-zero overhead — solving the "minutes over cross-region Cloud SQL"
    # concern that motivated the original guard.
    try:
        with _engine.connect() as ledger_conn:
            ledger_conn.execute(text("SET statement_timeout = '10s'"))
            ledger_conn.execute(text("""
                CREATE TABLE IF NOT EXISTS applied_migrations (
                    key TEXT PRIMARY KEY,
                    applied_at TIMESTAMP DEFAULT NOW() NOT NULL
                )
            """))
            ledger_conn.commit()
    except Exception as e:
        logger.error(f"❌ Could not create applied_migrations ledger: {e}")
        # Without the ledger we'd risk re-running the whole list every cold
        # start. Bail out — the always-run block above already ran the
        # critical schema fixes, so the app stays up.
        return

    # Pull the set of already-applied keys.
    applied_keys: set[str] = set()
    try:
        with _engine.connect() as read_conn:
            read_conn.execute(text("SET statement_timeout = '10s'"))
            rows = read_conn.execute(text("SELECT key FROM applied_migrations")).fetchall()
            applied_keys = {r[0] for r in rows}
    except Exception as e:
        logger.warning(f"⚠️ Could not read applied_migrations: {e}")

    pending = [(sql, desc) for sql, desc in migrations if desc not in applied_keys]
    if not pending:
        logger.info(f"✅ Migrations up-to-date ({len(applied_keys)} applied, 0 pending)")
        return

    logger.info(f"📦 Running {len(pending)} pending migrations ({len(applied_keys)} already applied)")

    # Run each pending migration; mark as applied on success.
    # Each migration in its own AUTOCOMMIT transaction so a single failure
    # doesn't abort the rest. Wrapped with a generous per-statement timeout.
    success = 0
    failed = 0
    for i, (sql, description) in enumerate(pending):
        try:
            with _engine.connect() as conn:
                conn.execute(text("SET statement_timeout = '30s'"))
                conn.execute(text(sql))
                conn.execute(
                    text("INSERT INTO applied_migrations(key) VALUES (:k) ON CONFLICT (key) DO NOTHING"),
                    {"k": description},
                )
                conn.commit()
                success += 1
                if (i + 1) % 25 == 0 or (i + 1) == len(pending):
                    logger.info(f"📦 Migration progress: {i + 1}/{len(pending)}")
        except Exception as e:
            err = str(e).lower()
            # Common benign case: the column / index / table was added by an
            # earlier always-run entry or by the OLD guard-skipping run.
            # Treat as success and record the key so we don't keep retrying.
            #
            # ⚠️ Match SCHEMA-OBJECT-already-exists patterns specifically.
            # Naïvely matching "duplicate" is dangerous: PostgreSQL also
            # writes "duplicate key violates unique constraint" for unrelated
            # FK / unique violations, which would silently mark a never-applied
            # migration as applied.
            benign_patterns = (
                "already exists",         # "relation X already exists", "column X already exists"
                "duplicate column",       # PG: duplicate column on ALTER ADD COLUMN
                "duplicate object",       # PG: duplicate_object SQLSTATE 42710
                "duplicate_object",
                "duplicate table",
                "duplicate schema",
                "duplicate index",
            )
            if any(p in err for p in benign_patterns):
                try:
                    with _engine.connect() as conn2:
                        conn2.execute(
                            text("INSERT INTO applied_migrations(key) VALUES (:k) ON CONFLICT (key) DO NOTHING"),
                            {"k": description},
                        )
                        conn2.commit()
                        success += 1
                except Exception:
                    pass
            else:
                failed += 1
                logger.warning(f"⚠️ Migration failed: {description} — {e}")

    logger.info(f"✅ Migrations done: {success} applied, {failed} failed (will retry next startup)")

# run_migrations() and setup_admin_user() are now called in @app.on_event("startup")




app = FastAPI(
    title="RAIVEN API",
    description="Encrypted messaging and social media backend",
    version="1.0.0",
    redirect_slashes=False
)

# ==================== SECURITY MIDDLEWARE ====================

# 1. CORS Configuration (Strict)
# In production, only allow your actual domains
ALLOWED_ORIGINS = [
    "http://localhost:3000",      # Development web app
    "http://localhost:8080",      # Development mobile
    "https://yourdomain.com",     # Production web (replace with actual domain)
]

# For mobile apps, we allow all origins since they use native HTTP clients
# But we restrict methods and headers
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS if os.getenv("ENVIRONMENT") == "production" else ["*"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE"],  # Explicit methods only
    allow_headers=["Authorization", "Content-Type"],  # Only needed headers
    max_age=600,  # Cache preflight for 10 minutes
)

# ⚡ GZip Compression — reduces JSON payload sizes by ~70%
from starlette.middleware.gzip import GZipMiddleware
app.add_middleware(GZipMiddleware, minimum_size=500)  # Only compress responses > 500 bytes

# 2. Security Headers Middleware (Pure ASGI - no thread overhead)
class SecurityHeadersMiddleware:
    """Add security headers to all responses - pure ASGI implementation"""
    
    def __init__(self, app: ASGIApp):
        self.app = app
    
    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        
        path = scope.get("path", "")
        is_admin = path.startswith("/static/admin")
        is_dashboard = path.startswith("/static/dashboard")
        
        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = dict(message.get("headers", []))
                extra = [
                    (b"x-content-type-options", b"nosniff"),
                    (b"x-frame-options", b"DENY"),
                    (b"x-xss-protection", b"1; mode=block"),
                    (b"strict-transport-security", b"max-age=31536000; includeSubDomains"),
                    (b"referrer-policy", b"strict-origin-when-cross-origin"),
                ]
                if is_admin:
                    extra.append((b"content-security-policy",
                        b"default-src 'self'; script-src 'self' 'unsafe-inline'; "
                        b"style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
                        b"font-src 'self' https://fonts.gstatic.com; "
                        b"img-src 'self' data: blob:; connect-src 'self'"))
                elif is_dashboard:
                    extra.append((b"content-security-policy",
                        b"default-src 'self'; script-src 'self' 'unsafe-inline'; "
                        b"style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
                        b"font-src 'self' https://fonts.gstatic.com; "
                        b"img-src 'self' data: blob:; "
                        b"connect-src 'self' https://raven-server-5iwa2y5n3a-ww.a.run.app"))
                else:
                    extra.append((b"content-security-policy", b"default-src 'self'"))
                
                message["headers"] = list(message.get("headers", [])) + extra
            await send(message)
        
        await self.app(scope, receive, send_with_headers)

app.add_middleware(SecurityHeadersMiddleware)

# 3. Request Size Limit Middleware (Pure ASGI - no thread overhead)
class RequestSizeLimitMiddleware:
    """Prevent DoS attacks via large payloads - pure ASGI implementation"""
    
    def __init__(self, app: ASGIApp, max_size: int = 10 * 1024 * 1024):
        self.app = app
        self.max_size = max_size
    
    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        
        method = scope.get("method", "GET")
        if method in ("POST", "PUT", "PATCH"):
            path = scope.get("path", "")
            
            # Upload routes get a much higher limit for file/voice/video uploads
            if path.startswith("/api/uploads") or path.startswith("/api/snaps"):
                effective_max = 500 * 1024 * 1024  # 500MB — covers premium 2GB tier after compression
            else:
                effective_max = self.max_size
            
            headers = dict(scope.get("headers", []))
            content_length = headers.get(b"content-length")
            if content_length and int(content_length) > effective_max:
                response = JSONResponse(
                    status_code=413,
                    content={"detail": f"Request body too large. Maximum {effective_max / (1024*1024):.0f}MB allowed."}
                )
                await response(scope, receive, send)
                return
        
        await self.app(scope, receive, send)

app.add_middleware(RequestSizeLimitMiddleware, max_size=10 * 1024 * 1024)  # 10MB

# ==================== ROUTERS ====================

# Include routers
app.include_router(auth.router)
app.include_router(users.router)
app.include_router(messages.router)
app.include_router(posts.router)
app.include_router(uploads.router)
app.include_router(comments.router)
app.include_router(search.router)
app.include_router(counts.router)
app.include_router(voice.router)
app.include_router(backup.router)
app.include_router(subscriptions.router)
app.include_router(notifications.router)
app.include_router(devices.router)  # Device identity for mesh/BLE
app.include_router(verification_identity.router)  # Identity verification requests
app.include_router(knowledge.router)  # Offline Wiki facts
app.include_router(groups.router)  # Group chats
app.include_router(reports.router)  # Content moderation reports
app.include_router(blocks.router)  # User blocking
app.include_router(invites.router)  # Referral / invite-a-friend → 1 month Raven+ for both
app.include_router(group_keys.router)  # Per-group symmetric keys (mesh anti-spoof)
app.include_router(e2ee.router)  # X3DH pre-key bundle distribution for Double Ratchet sessions
app.include_router(auth_opaque.router)  # OPAQUE PAKE auth (Phase 2 — stubs return 501 until libopaque is wired)
app.include_router(linked_devices.router)  # Multi-device session registry
app.include_router(qr_login.router)  # Desktop login via mobile QR scan (WhatsApp-Web pattern)
app.include_router(nearby.router)  # Nearby people via mesh discovery
app.include_router(mesh.router)  # Cross-platform mesh bridge (Windows ↔ iOS/Mac)
app.include_router(gateway.router)  # Mesh-to-Internet Gateway (v1.6 MVP — stubs)
app.include_router(diagnostics.router)  # MetricKit crash + perf diagnostics intake
app.include_router(concert_mode.router)  # Auto-group everyone in a venue
app.include_router(debug_email.router)  # Debug email testing
app.include_router(ai.router)  # Gemini AI Ask
app.include_router(events.router)  # Event tracking for recommendations
app.include_router(recommendation.router)  # Personalized "For You" feed
app.include_router(hashtags.router)  # Hashtag follow and discovery
app.include_router(admin.router)  # Admin database management
app.include_router(presence.router)  # User presence for hybrid routing
app.include_router(contacts.router)  # Contact sync for finding friends
app.include_router(discovery.router)  # Suggested friends discovery
app.include_router(rooms.router)  # Audio rooms (Clubhouse-like)
app.include_router(livekit.router)  # LiveKit token generation
app.include_router(mentions.router)  # @mention tracking and notifications
app.include_router(data_export.router)  # GDPR-style "Download My Data"
app.include_router(webhook_revenuecat.router)  # RevenueCat payment webhooks
app.include_router(snaps.router)  # Ephemeral photo messages
app.include_router(message_requests.router)  # Message request accept/decline
app.include_router(channels.router)  # Broadcast channels (Telegram-style)
app.include_router(stats.router)  # Public live stats (user count dashboard)
app.include_router(atsam_prekey.router)  # ATSAM hybrid pre-key bundles + pair-init queue
app.include_router(ghost_route.router)   # Ghost Route online inbox (tag-keyed mailbox, no per-user routing identifier)

# Mount static files for uploaded images
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

# Mount static files for system images (like Gemini avatar)
app.mount("/static", StaticFiles(directory="static"), name="static")

# ==================== WEBSOCKET INBOX ====================

from fastapi import WebSocket, WebSocketDisconnect, Query
import asyncio
import json
from ws_manager import ws_manager

@app.websocket("/ws/inbox")
async def websocket_inbox(websocket: WebSocket, token: str = Query(None)):
    """
    Real-time inbox via WebSocket — EVENT-DRIVEN PUSH.
    
    Client connects with: wss://server/ws/inbox?token=JWT
    Messages are pushed instantly when send_message() or bridge_message()
    calls ws_manager.notify() — no more 3s DB polling delay.
    
    Fallback: DB catch-up poll every 30s to recover any missed messages.
    """
    from auth import decode_token
    from database import SessionLocal
    from models import Message, User
    from encryption import decrypt_text
    
    # ── Auth ──
    if not token:
        await websocket.close(code=4001, reason="Missing token")
        return
    
    payload = decode_token(token)
    if not payload or not payload.get("sub"):
        await websocket.close(code=4001, reason="Invalid token")
        return
    
    user_id = payload["sub"]
    
    await websocket.accept()
    print(f"🔌 [WS] WebSocket connected for user {user_id[:8]}")
    
    # Register with WebSocket manager — get event queue for instant push
    queue = await ws_manager.connect(user_id, websocket)
    last_db_check = datetime.utcnow()
    
    try:
        while True:
            # ─── Wait for either: (1) event-driven push, (2) client message, (3) 30s timeout ───
            try:
                # Create tasks for both queue events and client messages
                queue_task = asyncio.create_task(queue.get())
                client_task = asyncio.create_task(websocket.receive_text())
                
                done, pending = await asyncio.wait(
                    {queue_task, client_task},
                    timeout=30.0,
                    return_when=asyncio.FIRST_COMPLETED
                )
                
                # Cancel whichever didn't complete.
                #
                # ⚠️ Catch `RuntimeError` too — Starlette raises
                # `RuntimeError("WebSocket is not connected...")` or
                # `Cannot call "receive" once a disconnect message has been
                # received` when receive_text() is awaited on an already-
                # disconnected socket. Without this catch the cancel-and-
                # await path leaks the exception → "Task exception was never
                # retrieved" log spam (was filling the audit logs).
                for task in pending:
                    task.cancel()
                    try:
                        await task
                    except (asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
                        pass
                
                if queue_task in done:
                    # ⚡ Instant push — message arrived via ws_manager.notify()
                    message_data = queue_task.result()
                    
                    # Drain any additional queued messages (batch send)
                    batch = [message_data]
                    while not queue.empty():
                        try:
                            batch.append(queue.get_nowait())
                        except asyncio.QueueEmpty:
                            break
                    
                    await websocket.send_text(json.dumps(batch))
                    print(f"⚡ [WS] Instant push: {len(batch)} messages to {user_id[:8]}")
                    continue
                
                if client_task in done:
                    # Client sent a message — OR the websocket disconnected
                    # and receive_text() raised. Inspect the exception so we
                    # don't keep recreating a doomed task in the next loop
                    # iteration (was the source of WS log spam).
                    exc = client_task.exception()
                    if exc is not None:
                        # Disconnect / runtime error → exit cleanly
                        raise WebSocketDisconnect()
                    # Client sent a real message (ping/pong or app-level)
                    continue
                
                # Timeout — do a fallback DB catch-up poll every 30s
                # This catches any messages that might have been missed
                # (e.g., during brief disconnection or race conditions)
                
            except asyncio.TimeoutError:
                pass  # Fall through to DB catch-up
            
            # ─── Fallback DB catch-up poll (every 30s) ───
            db = SessionLocal()
            try:
                messages = db.query(Message).filter(
                    Message.recipient_id == user_id,
                    Message.timestamp > last_db_check
                ).order_by(Message.timestamp.desc()).limit(50).all()
                
                if messages:
                    sender_ids = set(m.sender_id for m in messages)
                    senders = {u.id: u for u in db.query(User).filter(User.id.in_(sender_ids)).all()}
                    
                    result = []
                    for msg in messages:
                        sender = senders.get(msg.sender_id)
                        try:
                            content = decrypt_text(msg.content) if msg.content else None
                        except Exception:
                            content = "[Encrypted]"
                        
                        result.append({
                            "id": msg.id,
                            "sender_id": msg.sender_id,
                            "recipient_id": msg.recipient_id,
                            "content": content,
                            "timestamp": msg.timestamp.isoformat() + "Z",
                            "read_at": msg.read_at.isoformat() + "Z" if msg.read_at else None,
                            "delivered_at": msg.delivered_at.isoformat() + "Z" if msg.delivered_at else None,
                            "sender_username": sender.username if sender else None,
                            "sender_name": f"{sender.first_name} {sender.last_name}" if sender else None,
                            "message_type": msg.message_type or "text",
                            "room_id": msg.sender_id,
                            "audio_url": msg.audio_url,
                            "audio_duration_seconds": msg.audio_duration_seconds,
                            "file_name": msg.file_name,
                            "file_size": msg.file_size,
                            "mime_type": msg.mime_type,
                            "reply_to_message_id": msg.reply_to_message_id,
                            "reply_to_text_preview": msg.reply_to_text_preview,
                            "reply_to_sender_name": msg.reply_to_sender_name,
                            "reply_to_type": msg.reply_to_type,
                            "expiry_mode": msg.expiry_mode,
                            "expires_at": msg.expires_at.isoformat() + "Z" if msg.expires_at else None,
                            "allow_forward": msg.allow_forward if msg.allow_forward is not None else True,
                        })
                    
                    await websocket.send_text(json.dumps(result))
                    last_db_check = messages[0].timestamp
                    print(f"🔌 [WS] DB catch-up: {len(result)} messages to {user_id[:8]}")
                else:
                    last_db_check = datetime.utcnow()
            finally:
                db.close()
                
    except WebSocketDisconnect:
        print(f"🔌 [WS] WebSocket disconnected for user {user_id[:8]}")
    except Exception as e:
        print(f"❌ [WS] WebSocket error for user {user_id[:8]}: {e}")
        try:
            await websocket.close(code=1011, reason="Internal error")
        except Exception:
            pass
    finally:
        await ws_manager.disconnect(user_id)


# ==================== HEALTH ENDPOINTS ====================

@app.get("/")
def root():
    return {
        "status": "ok",
        "message": "RAIVEN API",
        "version": "1.0.0",
        "security": "enabled"
    }

@app.get("/health")
def health_check():
    return {"status": "healthy"}


# ==================== CRASH REPORTS ====================

from pydantic import BaseModel

class CrashBreadcrumb(BaseModel):
    timestamp: str
    category: str
    message: str
    metadata: dict | None = None

class CrashReportPayload(BaseModel):
    deviceModel: str = ""
    osVersion: str = ""
    appVersion: str = ""
    buildNumber: str = ""
    memoryUsageMB: float = 0
    crashTimestamp: str | None = None
    launchTimestamp: str = ""
    lastException: str | None = None
    lastSignal: str | None = None
    breadcrumbs: list[CrashBreadcrumb] = []
    sessionId: str = ""
    previousSessionId: str | None = None

@app.post("/api/crash-reports")
async def receive_crash_report(report: CrashReportPayload, request: Request):
    """
    Receive crash breadcrumb reports from iOS CrashGuard.
    Logs the report for debugging. Auth is optional (crash may happen before login).
    """
    # Try to extract user from auth header if present
    user_id = "anonymous"
    auth_header = request.headers.get("authorization", "")
    if auth_header.startswith("Bearer "):
        try:
            from auth import decode_token
            payload = decode_token(auth_header.replace("Bearer ", ""))
            if payload and payload.get("sub"):
                user_id = payload["sub"]
        except Exception:
            pass

    # Log the crash report
    logger.warning(f"🛡️ [CrashReport] ═══════════════════════════════════════")
    logger.warning(f"🛡️ [CrashReport] User: {user_id[:8]}...")
    logger.warning(f"🛡️ [CrashReport] Device: {report.deviceModel} / iOS {report.osVersion}")
    logger.warning(f"🛡️ [CrashReport] App: {report.appVersion} ({report.buildNumber})")
    logger.warning(f"🛡️ [CrashReport] Memory: {report.memoryUsageMB:.1f} MB")
    logger.warning(f"🛡️ [CrashReport] Session: {report.sessionId[:8]}... (prev: {(report.previousSessionId or 'none')[:8]})")
    
    if report.lastException:
        logger.warning(f"🛡️ [CrashReport] Exception: {report.lastException[:500]}")
    if report.lastSignal:
        logger.warning(f"🛡️ [CrashReport] Signal: {report.lastSignal}")
    if report.crashTimestamp:
        logger.warning(f"🛡️ [CrashReport] Crashed around: {report.crashTimestamp}")
    
    logger.warning(f"🛡️ [CrashReport] Breadcrumbs ({len(report.breadcrumbs)} items):")
    for crumb in report.breadcrumbs:
        meta = " | ".join(f"{k}={v}" for k, v in (crumb.metadata or {}).items())
        logger.warning(f"🛡️   [{crumb.timestamp}] [{crumb.category}] {crumb.message} {meta}")
    
    logger.warning(f"🛡️ [CrashReport] ═══════════════════════════════════════")
    
    return {"status": "received", "session_id": report.sessionId}


# Runs AFTER uvicorn binds to port (so Cloud Run startup probe succeeds immediately)

@app.on_event("startup")
async def startup_db_init():
    """Initialize database tables, run migrations, and setup admin user.
    
    This runs after uvicorn is already listening on PORT, preventing
    Cloud Run startup probe timeouts from slow migrations.
    """
    import threading
    
    def _db_init():
        try:
            logger.info("🔧 [Startup] Beginning database initialization...")
            
            # 1. Create tables
            Base.metadata.create_all(bind=engine)
            logger.info("✅ Database tables created/verified")
            
            # 2. Run migrations
            run_migrations()
            
            # 3. Setup admin user
            _setup_admin_user()
            
            # 4. Flush stale feed caches (ensures new response format is served)
            try:
                from cache import cache as _cache
                cleared = _cache.invalidate("feed:*")
                logger.info(f"🗑️ [Startup] Flushed {cleared} cached feed entries")
            except Exception as ce:
                logger.warning(f"⚠️ [Startup] Cache flush failed: {ce}")
            
            logger.info("✅ [Startup] Database initialization complete")
        except Exception as e:
            logger.error(f"❌ [Startup] Database initialization failed: {e}")
    
    # Run in a thread so it doesn't block the event loop
    thread = threading.Thread(target=_db_init, daemon=True)
    thread.start()
    
    # Start background cleanup job for stale audio rooms
    asyncio.create_task(_room_cleanup_loop())

    # Start background cleanup for expired registration verification tokens
    asyncio.create_task(_registration_token_cleanup_loop())

    # Start the scheduled-message wake-up worker — flips scheduled
    # messages whose scheduled_at_utc has passed back to the regular
    # delivery path, fan-outs the WS event + push notification.
    asyncio.create_task(_scheduled_messages_loop())


async def _registration_token_cleanup_loop():
    """Background task: purge expired/unconsumed registration tokens every 5 minutes.
    
    Only cleans up tokens with purpose='registration' that were never consumed
    and whose expiry is older than 10 minutes. This prevents orphaned tokens
    from accumulating when users abandon the signup flow.
    """
    import asyncio as _asyncio
    
    # Wait for DB init to complete
    await _asyncio.sleep(15)
    
    logger.info("🗑️ [TokenCleanup] Registration token cleanup loop started")
    
    while True:
        try:
            from database import SessionLocal
            from models import VerificationToken
            from datetime import timedelta
            
            db = SessionLocal()
            try:
                cutoff = datetime.utcnow() - timedelta(minutes=10)
                deleted = db.query(VerificationToken).filter(
                    VerificationToken.purpose == 'registration',
                    VerificationToken.consumed_at.is_(None),
                    VerificationToken.expires_at < cutoff,
                ).delete()
                db.commit()
                if deleted:
                    logger.info(f"🗑️ [TokenCleanup] Cleaned up {deleted} expired registration tokens")
            finally:
                db.close()
                
        except Exception as e:
            logger.error(f"❌ [TokenCleanup] Error in cleanup loop: {e}")
        
        await _asyncio.sleep(300)  # Every 5 minutes


async def _scheduled_messages_loop():
    """Background task: deliver scheduled messages whose `scheduled_at_utc`
    has passed.

    Every 30 seconds we sweep for `Message` rows with
    `send_mode == "scheduled"` and `scheduled_at_utc <= utcnow()`. For each
    we:

      1. Flip `send_mode` to "instant" so subsequent inbox queries treat
         it like a regular message.
      2. Create the `Notification` row that `send_message` would have
         created on instant send.
      3. Push the WS event so any open recipient client renders it.

    Push-notifications via APNs are intentionally skipped here — the
    deferred APNs path in `send_message` is heavy (token lookups + provider
    round-trip), and the server-side cron worker pattern would need to
    re-derive sender + recipient context. Clients re-render the message
    via the WS event or the next inbox poll, which is sufficient.
    """
    import asyncio as _asyncio

    # Wait for DB init to complete.
    await _asyncio.sleep(20)

    logger.info("⏰ [ScheduledMessages] Worker loop started")

    while True:
        try:
            from database import SessionLocal
            from models import Message as _Message, Notification, User as _User
            from encryption import decrypt_text
            import json as _json

            db = SessionLocal()
            try:
                now = datetime.utcnow()
                due = db.query(_Message).filter(
                    _Message.send_mode == "scheduled",
                    _Message.scheduled_at_utc != None,  # noqa: E711
                    _Message.scheduled_at_utc <= now,
                ).limit(50).all()

                for msg in due:
                    msg.send_mode = "instant"

                    # Compose a friendly preview based on message_type so
                    # the notification panel reads cleanly without doing
                    # a fresh decrypt per type.
                    if msg.message_type == "voice":
                        preview = "🎤 Voice message"
                    elif msg.message_type == "image":
                        preview = "📷 Image"
                    elif msg.message_type == "video":
                        preview = "🎬 Video"
                    elif msg.message_type == "location":
                        preview = "📍 Location"
                    else:
                        try:
                            decrypted = decrypt_text(msg.content) if msg.content else ""
                        except Exception:
                            decrypted = ""
                        if decrypted == "[DECRYPT_FAILED]":
                            decrypted = ""
                        preview = decrypted[:100] if decrypted else "New message"

                    sender = db.query(_User).filter(_User.id == msg.sender_id).first()
                    notif = Notification(
                        user_id=msg.recipient_id,
                        type="message",
                        data=_json.dumps({
                            "room_id": msg.sender_id,
                            "sender_id": msg.sender_id,
                            "sender_username": sender.username if sender else None,
                            "sender_avatar": sender.avatar_path if sender else None,
                            "preview": preview,
                            "message_type": msg.message_type or "text",
                        }),
                        is_read=False,
                    )
                    db.add(notif)

                    # WS push so any open client renders the message in
                    # real time. Mirrors the payload shape from
                    # send_message's instant path.
                    try:
                        decrypted_for_ws = decrypt_text(msg.content) if msg.content else ""
                    except Exception:
                        decrypted_for_ws = ""
                    await ws_manager.notify(msg.recipient_id, {
                        "id": msg.id,
                        "sender_id": msg.sender_id,
                        "recipient_id": msg.recipient_id,
                        "content": decrypted_for_ws,
                        "timestamp": msg.timestamp.isoformat() + "Z",
                        "read_at": None,
                        "delivered_at": None,
                        "sender_username": sender.username if sender else None,
                        "message_type": msg.message_type or "text",
                        "room_id": msg.sender_id,
                        "audio_url": msg.audio_url,
                        "audio_duration_seconds": msg.audio_duration_seconds,
                        "file_name": msg.file_name,
                        "file_size": msg.file_size,
                        "mime_type": msg.mime_type,
                        "reply_to_message_id": msg.reply_to_message_id,
                        "reply_to_text_preview": msg.reply_to_text_preview,
                        "reply_to_sender_name": msg.reply_to_sender_name,
                        "reply_to_type": msg.reply_to_type,
                        "expiry_mode": msg.expiry_mode,
                        "expires_at": msg.expires_at.isoformat() + "Z" if msg.expires_at else None,
                        "allow_forward": msg.allow_forward if msg.allow_forward is not None else True,
                    })

                if due:
                    db.commit()
                    logger.info(f"⏰ [ScheduledMessages] Delivered {len(due)} scheduled message(s)")
            finally:
                db.close()

        except Exception as e:
            logger.error(f"❌ [ScheduledMessages] Error in worker loop: {e}")

        await _asyncio.sleep(30)


async def _room_cleanup_loop():
    """Background task: auto-close stale audio rooms every 30 seconds.
    
    Checks for rooms where last_activity is older than 60 seconds.
    Marks stale participants as left, auto-ends empty rooms,
    and hides associated room posts from feeds.
    """
    import asyncio as _asyncio
    
    # Wait for DB init to complete
    await _asyncio.sleep(10)
    
    logger.info("🔄 [RoomCleanup] Background room cleanup loop started")
    
    while True:
        try:
            from database import SessionLocal
            from models import AudioRoom, AudioRoomParticipant, Post
            from datetime import timedelta
            
            db = SessionLocal()
            try:
                now = datetime.utcnow()
                stale_threshold = now - timedelta(seconds=60)
                
                # 1. Find stale rooms (is_live but no activity for 60s+)
                stale_rooms = db.query(AudioRoom).filter(
                    AudioRoom.is_live == True,
                    AudioRoom.last_activity != None,
                    AudioRoom.last_activity < stale_threshold
                ).all()
                
                for room in stale_rooms:
                    # Mark all participants as left
                    db.query(AudioRoomParticipant).filter(
                        AudioRoomParticipant.room_id == room.id,
                        AudioRoomParticipant.left_at.is_(None)
                    ).update({"left_at": now})
                    
                    room.is_live = False
                    room.ended_at = now
                    room.participant_count = 0
                    
                    # Hide the associated room post
                    room_post = db.query(Post).filter(Post.room_id == room.id).first()
                    if room_post:
                        room_post.is_hidden = True
                    
                    logger.info(f"🧹 [RoomCleanup] Auto-closed stale room: '{room.title}' (last_activity: {room.last_activity})")
                
                # 2. Also catch rooms with 0 participants but still marked live
                empty_rooms = db.query(AudioRoom).filter(
                    AudioRoom.is_live == True,
                    AudioRoom.participant_count <= 0
                ).all()
                
                for room in empty_rooms:
                    if room not in stale_rooms:  # Avoid double-processing
                        room.is_live = False
                        room.ended_at = now
                        room_post = db.query(Post).filter(Post.room_id == room.id).first()
                        if room_post:
                            room_post.is_hidden = True
                        logger.info(f"🧹 [RoomCleanup] Auto-closed empty room: '{room.title}'")
                
                if stale_rooms or empty_rooms:
                    db.commit()
                    
            finally:
                db.close()
                
        except Exception as e:
            logger.error(f"❌ [RoomCleanup] Error in cleanup loop: {e}")
        
        await _asyncio.sleep(30)


def _setup_admin_user():
    """Create or update admin user and Apple reviewer demo accounts.

    Both passwords MUST be set via environment variables:
      - ADMIN_BOOTSTRAP_PASSWORD  → admin "Raven-messenger" account
      - REVIEWER_PASSWORD         → reviewer1 / reviewer2 (Apple review)

    If env vars are missing we SKIP creation/update for that account
    rather than re-seeding a hardcoded value (which made manual rotation
    impossible). To rotate, change the env var and restart.
    """
    from sqlalchemy import text
    from database import SessionLocal
    from auth import hash_password
    import uuid
    import os as _os

    admin_username = "Raven-messenger"
    admin_password = _os.getenv("ADMIN_BOOTSTRAP_PASSWORD")
    reviewer_password = _os.getenv("REVIEWER_PASSWORD")

    db = SessionLocal()
    try:
        # ── 1. Admin account ──
        result = db.execute(text("SELECT id FROM users WHERE username = :u"), {"u": admin_username}).fetchone()

        if not admin_password:
            if not result:
                logger.warning(
                    "⚠️ ADMIN_BOOTSTRAP_PASSWORD not set — admin account '%s' was never created",
                    admin_username,
                )
            else:
                logger.info(
                    "ℹ️ ADMIN_BOOTSTRAP_PASSWORD not set — leaving existing admin '%s' password unchanged",
                    admin_username,
                )
        elif not result:
            user_id = str(uuid.uuid4())
            hashed = hash_password(admin_password)
            db.execute(text("""
                INSERT INTO users (id, username, password_hash, first_name, last_name, birth_year, created_at)
                VALUES (:id, :username, :password_hash, :first_name, :last_name, :birth_year, NOW())
            """), {
                "id": user_id,
                "username": admin_username,
                "password_hash": hashed,
                "first_name": "Admin",
                "last_name": "RAVEN",
                "birth_year": 2000
            })
            db.commit()
            logger.info(f"✅ Admin user created: {admin_username}")
        else:
            hashed = hash_password(admin_password)
            db.execute(text("UPDATE users SET password_hash = :ph WHERE username = :u"), {
                "ph": hashed, "u": admin_username
            })
            db.commit()
            logger.info(f"✅ Admin user password updated from ADMIN_BOOTSTRAP_PASSWORD: {admin_username}")
        
        # ── 2. Apple Reviewer demo accounts ──
        # These accounts let Apple reviewers test the app during App Store review.
        # Password is read from REVIEWER_PASSWORD env var (must be set by deployer
        # via Cloud Run secret manager). If unset, reviewer accounts are skipped
        # entirely — DO NOT hardcode a default. To rotate, change the secret and
        # restart the service.
        if not reviewer_password:
            logger.warning(
                "⚠️ REVIEWER_PASSWORD env var not set — skipping reviewer account "
                "setup. Set this in Cloud Run before App Review submission."
            )
            return

        reviewer_accounts = [
            {
                "username": "reviewer1",
                "first_name": "Apple",
                "last_name": "Reviewer",
                "email": "apple-reviewer-1@raven-messenger.com",
            },
            {
                "username": "reviewer2",
                "first_name": "App",
                "last_name": "Reviewer",
                "email": "apple-reviewer-2@raven-messenger.com",
            },
        ]

        import hashlib
        from encryption import encrypt_text

        reviewer_ids = []
        for acct in reviewer_accounts:
            row = db.execute(
                text("SELECT id FROM users WHERE username = :u"),
                {"u": acct["username"]}
            ).fetchone()
            
            hashed_pw = hash_password(reviewer_password)
            email_hash = hashlib.sha256(acct["email"].lower().encode()).hexdigest()
            
            if not row:
                uid = str(uuid.uuid4())
                db.execute(text("""
                    INSERT INTO users
                        (id, username, password_hash, first_name, last_name,
                         birth_year, email, email_hash, email_verified, created_at)
                    VALUES
                        (:id, :username, :pw, :fn, :ln,
                         2000, :email, :eh, TRUE, NOW())
                """), {
                    "id": uid,
                    "username": acct["username"],
                    "pw": hashed_pw,
                    "fn": encrypt_text(acct["first_name"]),
                    "ln": encrypt_text(acct["last_name"]),
                    "email": encrypt_text(acct["email"]),
                    "eh": email_hash,
                })
                reviewer_ids.append(uid)
                logger.info(f"✅ Reviewer account created: {acct['username']}")
            else:
                # Update password so it always matches what we expect
                uid = row[0]
                db.execute(text(
                    "UPDATE users SET password_hash = :pw, email_verified = TRUE WHERE username = :u"
                ), {"pw": hashed_pw, "u": acct["username"]})
                reviewer_ids.append(uid)
                logger.info(f"✅ Reviewer account updated: {acct['username']}")
        
        db.commit()
        
        # ── 3. Make reviewer accounts friends with each other ──
        if len(reviewer_ids) == 2:
            for a, b in [(reviewer_ids[0], reviewer_ids[1]), (reviewer_ids[1], reviewer_ids[0])]:
                existing = db.execute(
                    text("SELECT 1 FROM friendships WHERE user_id = :a AND friend_id = :b"),
                    {"a": a, "b": b}
                ).fetchone()
                if not existing:
                    db.execute(text("""
                        INSERT INTO friendships (id, user_id, friend_id, created_at)
                        VALUES (:id, :uid, :fid, NOW())
                    """), {"id": str(uuid.uuid4()), "uid": a, "fid": b})
            db.commit()
            logger.info("✅ Reviewer accounts are now friends with each other")
        
    except Exception as e:
        db.rollback()
        logger.warning(f"⚠️ Admin/reviewer user setup failed: {e}")
    finally:
        db.close()

# ==================== TIME SYNC ====================

from datetime import datetime

@app.get("/api/time")
def get_server_time():
    """
    Return current server time in UTC ISO8601 format.
    Used by clients to synchronize their clocks.
    """
    return {"utc": datetime.utcnow().isoformat() + "Z"}

