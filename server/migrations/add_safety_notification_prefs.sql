-- Add the six new notification toggles + the cross-feature
-- allow_contact_share privacy gate. Mirrors the iOS
-- NotificationsSettingsView "Privacy & Safety" section + the
-- PrivacySettingsView toggle added at the same time.
--
-- Idempotent: safe to run multiple times. PostgreSQL only.

ALTER TABLE users ADD COLUMN IF NOT EXISTS security_alert_notifications_enabled BOOLEAN DEFAULT TRUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS live_location_notifications_enabled  BOOLEAN DEFAULT TRUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS reaction_notifications_enabled       BOOLEAN DEFAULT TRUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS contact_shared_notifications_enabled BOOLEAN DEFAULT TRUE;
-- Profile views default to OFF — opt-in. Showing "X viewed you" by
-- default has stalker-friendly UX and most messengers got burned for
-- shipping it on. Users who want it can flip it in Settings.
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_view_notifications_enabled   BOOLEAN DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS screenshot_notifications_enabled     BOOLEAN DEFAULT TRUE;

-- Cross-feature privacy gate — read by the contact-card share flow
-- to decide whether to accept or refuse a share targeting this user.
ALTER TABLE users ADD COLUMN IF NOT EXISTS allow_contact_share BOOLEAN DEFAULT TRUE;
