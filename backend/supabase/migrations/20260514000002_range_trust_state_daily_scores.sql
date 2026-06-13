-- Migration: 20260514000002_range_trust_state_daily_scores.sql
-- Step 2 — Pre-Beta Sprint: range_trust_state on daily_scores
--
-- Audit finding: range_trust_state was computed in score/index.ts and written
-- to baselines only. The iOS client has no direct access path for trust-state-gated
-- UI decisions (provisional guard on driver chips, Horizon confidence gating).
--
-- Writing it to daily_scores gives iOS a clean, single-row read path alongside
-- zone_1 / zone_2 on the same row.

BEGIN;

ALTER TABLE daily_scores
  ADD COLUMN IF NOT EXISTS range_trust_state TEXT;

-- Index for trust-state queries (e.g. admin views, analytics)
CREATE INDEX IF NOT EXISTS idx_daily_scores_range_trust_state
  ON daily_scores (user_id, range_trust_state);

COMMIT;
