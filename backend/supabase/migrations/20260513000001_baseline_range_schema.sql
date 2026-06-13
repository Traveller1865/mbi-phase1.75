-- MBI Baseline Range Architecture v1.0 — Phase 2 Sprint 1
-- Adds p20/p80 adaptive percentile boundary columns to baselines table.
-- Adds trust state + HRV smoothing metadata columns to baselines table.
-- Adds zone_1 / zone_2 classification result columns to daily_scores table.
-- All additions are additive — no existing columns altered or removed.

BEGIN;

-- ── p20/p80 Range Boundary Columns ────────────────────────────────────────
-- HRV uses 7-day rolling average as input (not raw daily reading)
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_hrv_7d              numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_hrv_7d              numeric;

-- Resting HR
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_resting_hr          numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_resting_hr          numeric;

-- Sleep Duration
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_sleep_duration      numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_sleep_duration      numeric;

-- Sleep Continuity (p80 may be auto-widened to p85 if within 3pp of p50)
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_sleep_continuity    numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_sleep_continuity    numeric;

-- Steps — weekday (Mon–Fri) and weekend (Sat–Sun) split
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_steps_weekday       numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_steps_weekday       numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_steps_weekend       numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_steps_weekend       numeric;

-- Active Minutes — weekday and weekend split
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_active_minutes_weekday  numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_active_minutes_weekday  numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p20_active_minutes_weekend  numeric;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS p80_active_minutes_weekend  numeric;

-- ── Trust State and Metadata Columns ──────────────────────────────────────
-- range_trust_state: establishing | calibrating | provisional | trusted | established
-- Reflects the minimum trust state across primary tracked metrics.
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS range_trust_state       text;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS range_valid_days        integer;
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS range_computed_at       timestamptz;

-- 7-day rolling average of raw HRV — used as HRV input to zone classification
ALTER TABLE baselines ADD COLUMN IF NOT EXISTS hrv_7d_rolling_avg      numeric;

-- ── Zone Classification Result Columns (daily_scores) ─────────────────────
-- Stores the per-day zone label for driver_1 and driver_2.
-- Enum: elevated | within_range_high | within_range_low | below_range | flagged
-- NULL when trust state is below provisional or metric has insufficient data.
ALTER TABLE daily_scores ADD COLUMN IF NOT EXISTS zone_1               text;
ALTER TABLE daily_scores ADD COLUMN IF NOT EXISTS zone_2               text;

COMMIT;
