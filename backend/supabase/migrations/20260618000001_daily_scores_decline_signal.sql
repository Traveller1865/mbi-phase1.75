-- Migration: 20260618000001_daily_scores_decline_signal.sql
-- Yellowline Momentum Signal (Domain v1.6) — decline_signal on daily_scores
--
-- Yellowline is no longer a score band. It is now a momentum signal: it fires when
-- a user in the upper range (chronos_score >= 70) has declined >= 5 points versus a
-- reference score from 5-7 days ago (with a hysteresis band). The signal is computed
-- in the scoring pipeline (computeDeclineSignal) and persisted here as a separate
-- field alongside score_band — never an override of the band.
--
-- Value domain: 'yellowline' | NULL. Lowercase by spec (DeclineSignal contract type).

BEGIN;

ALTER TABLE daily_scores
  ADD COLUMN IF NOT EXISTS decline_signal TEXT;

-- Constrain to the documented value domain (idempotent: drop-then-add).
ALTER TABLE daily_scores
  DROP CONSTRAINT IF EXISTS chk_decline_signal;
ALTER TABLE daily_scores
  ADD CONSTRAINT chk_decline_signal
  CHECK (decline_signal IN ('yellowline') OR decline_signal IS NULL);

COMMIT;
