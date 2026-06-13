-- backend/supabase/migrations/20260522000001_data_tier_and_gap_framework.sql
-- MBI Phase 1.5 — Data Tier Architecture + Missing Data Validation Framework
--
-- Adds tier classification to ingested inputs and scored days so the pipeline
-- can distinguish wearable-quality data from steps-only iPhone data.
-- Introduces gap tracking, escalation flags, and an ingest error log table.
--
-- MANUAL EXECUTION: Paste into Supabase SQL Editor → Run.
-- DO NOT apply via supabase db push (Docker not available in this environment).

-- ── daily_inputs: tier + gap reason ─────────────────────────────────────────
-- data_tier: classified at ingest time by classifyDataTier() in ingest/index.ts
--   wearable   = ≥4 Apple Watch signals present
--   partial    = 1–3 Watch signals (some coverage, degrade gracefully)
--   steps_only = 0 Watch signals (iPhone only — no wearable scoring)
--   unknown    = no signals at all (empty payload)
-- gap_reason: written when user later validates a steps_only day
--   device_not_worn  = user confirmed Watch was not worn
--   sync_failure     = Watch was worn but sync did not complete
--   NULL (default)   = not yet validated or not applicable
ALTER TABLE daily_inputs
  ADD COLUMN IF NOT EXISTS data_tier  TEXT
      NOT NULL DEFAULT 'unknown'
      CONSTRAINT daily_inputs_data_tier_check
        CHECK (data_tier IN ('wearable', 'partial', 'steps_only', 'unknown')),
  ADD COLUMN IF NOT EXISTS gap_reason TEXT;

COMMENT ON COLUMN daily_inputs.data_tier  IS
  'Tier classified at ingest: wearable (≥4 Watch signals), partial (1–3), steps_only (0), unknown';
COMMENT ON COLUMN daily_inputs.gap_reason IS
  'Why this day had no Watch data: device_not_worn | sync_failure | NULL (not validated)';

-- ── daily_scores: tier mirror + escalation flag ──────────────────────────────
-- data_tier mirrors daily_inputs.data_tier — propagated by score/index.ts so iOS
-- can read tier directly from the score row without joining daily_inputs.
-- escalation_flag: set by server-side escalation check or iOS sync failure count.
ALTER TABLE daily_scores
  ADD COLUMN IF NOT EXISTS data_tier       TEXT
      NOT NULL DEFAULT 'unknown'
      CONSTRAINT daily_scores_data_tier_check
        CHECK (data_tier IN ('wearable', 'partial', 'steps_only', 'unknown')),
  ADD COLUMN IF NOT EXISTS escalation_flag TEXT;

COMMENT ON COLUMN daily_scores.data_tier       IS
  'Mirrors daily_inputs.data_tier for the scored day — propagated by score function';
COMMENT ON COLUMN daily_scores.escalation_flag IS
  'Set to persistent_sync_failure when ≥3 failures in 7 days are detected';

-- ── users: connected device name ─────────────────────────────────────────────
-- Used by the gap validation prompt (Section 7) to show the correct device name
-- dynamically instead of hard-coding "Apple Watch".
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS connected_device_name TEXT;

COMMENT ON COLUMN users.connected_device_name IS
  'Display name of user''s connected wearable (e.g. "Apple Watch", "Oura Ring") — used in gap validation prompt';

-- ── ingest_errors: server-side sync failure log ───────────────────────────────
-- Records sync failures so the escalation check (Section 8) can query the DB
-- rather than relying solely on iOS UserDefaults (survives app reinstalls).
CREATE TABLE IF NOT EXISTS ingest_errors (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date         DATE        NOT NULL,
  error_type   TEXT        NOT NULL,
  -- error_type domain: 'sync_failure' | 'validation_error' | 'network_error' | 'steps_only_skipped'
  error_detail TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE ingest_errors IS
  'Server-side log of sync failures and validation errors per user per day';

-- Indexes — support the 7-day look-back query in checkEscalationThreshold
CREATE INDEX IF NOT EXISTS ingest_errors_user_date_idx
  ON ingest_errors (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ingest_errors_type_idx
  ON ingest_errors (user_id, error_type, created_at DESC);

-- ── data_tier index on daily_inputs ─────────────────────────────────────────
-- Supports the baselines filter query (Section 5) and Section 15 verification.
CREATE INDEX IF NOT EXISTS daily_inputs_data_tier_idx
  ON daily_inputs (user_id, data_tier, date);
