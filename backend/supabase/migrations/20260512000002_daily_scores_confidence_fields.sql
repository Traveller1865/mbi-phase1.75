-- MBI Scoring Engine Architecture Review v1.0 — D12 Confidence Tier + D13 H-01 fields

BEGIN;
ALTER TABLE daily_scores ADD COLUMN IF NOT EXISTS confidence_tier  text    DEFAULT 'full';
ALTER TABLE daily_scores ADD COLUMN IF NOT EXISTS pre_drift_signal boolean DEFAULT false;
ALTER TABLE daily_scores ADD COLUMN IF NOT EXISTS reserve_flags    jsonb   DEFAULT '[]'::jsonb;
ALTER TABLE trend_aggregates ADD COLUMN IF NOT EXISTS spo2_avg        numeric;
ALTER TABLE trend_aggregates ADD COLUMN IF NOT EXISTS stand_hours_avg numeric;
COMMIT;
