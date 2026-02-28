-- Moderation System Upgrade Migration
-- Adds AI triage, decision, appeal fields to reports table
-- Creates moderation_actions audit log table

-- ==================== REPORTS: AI Triage ====================
ALTER TABLE reports ADD COLUMN IF NOT EXISTS evidence_json TEXT;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_category VARCHAR;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_severity INTEGER;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_confidence FLOAT;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS ai_summary TEXT;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS triaged_at TIMESTAMP;

-- ==================== REPORTS: Decision ====================
ALTER TABLE reports ADD COLUMN IF NOT EXISTS decision VARCHAR DEFAULT 'none';
ALTER TABLE reports ADD COLUMN IF NOT EXISTS decision_reason TEXT;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS decided_by VARCHAR;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS decided_at TIMESTAMP;

-- ==================== REPORTS: Appeal ====================
ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_status VARCHAR DEFAULT 'none';
ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_text TEXT;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_decided_by VARCHAR;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS appeal_decided_at TIMESTAMP;

-- ==================== REPORTS: Update default status ====================
-- Existing "new" statuses should become "open"
UPDATE reports SET status = 'open' WHERE status = 'new';
UPDATE reports SET decision = 'none' WHERE decision IS NULL;
UPDATE reports SET appeal_status = 'none' WHERE appeal_status IS NULL;

-- ==================== MODERATION ACTIONS (Audit Log) ====================
CREATE TABLE IF NOT EXISTS moderation_actions (
    id VARCHAR PRIMARY KEY,
    report_id VARCHAR REFERENCES reports(id),
    target_type VARCHAR NOT NULL,
    target_id VARCHAR NOT NULL,
    action_type VARCHAR NOT NULL,
    parameters_json TEXT,
    actor VARCHAR NOT NULL,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    reversible BOOLEAN DEFAULT TRUE,
    reversed_at TIMESTAMP,
    reversed_by VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_moderation_actions_report ON moderation_actions(report_id);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_target ON moderation_actions(target_id);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_timestamp ON moderation_actions(timestamp);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_actor ON moderation_actions(actor);

-- ==================== INDEXES for new report columns ====================
CREATE INDEX IF NOT EXISTS idx_reports_ai_severity ON reports(ai_severity);
CREATE INDEX IF NOT EXISTS idx_reports_decision ON reports(decision);
CREATE INDEX IF NOT EXISTS idx_reports_appeal_status ON reports(appeal_status);
