-- backend/supabase/migrations/20260522000002_data_tier_backfill_and_verify.sql
-- MBI Phase 1.5 — Data Tier Backfill + Verification Queries
--
-- SECTION 13: Classify existing daily_inputs rows and remove steps_only scores.
-- SECTION 15: Verification queries — run after backfill to confirm correctness.
--
-- EXECUTION ORDER:
--   Step 1: Apply 20260522000001_data_tier_and_gap_framework.sql first.
--   Step 2: Run SECTION 13 UPDATE (classifies all existing daily_inputs rows).
--   Step 3: Run SECTION 13 DELETE (removes daily_scores for steps_only days).
--   Step 4: Run SECTION 15 queries to verify.
--
-- PERMANENT DELETION WARNING: Step 3 deletes daily_scores rows where the
-- corresponding daily_inputs row was classified as steps_only. These score
-- rows are irrecoverable. Run Step 2 and verify counts before running Step 3.
--
-- MANUAL EXECUTION ONLY: Paste into Supabase SQL Editor → Run.
-- DO NOT apply via supabase db push.

-- ════════════════════════════════════════════════════════════════════════════
-- SECTION 13 — BACKFILL EXISTING ROWS
-- ════════════════════════════════════════════════════════════════════════════

-- ── Step 2: Classify all existing daily_inputs rows ──────────────────────────
-- Mirrors classifyDataTier() in ingest/index.ts:
--   wearable   = ≥4 of the 7 Watch-specific signals are non-null
--   partial    = 1–3 Watch signals non-null
--   steps_only = 0 Watch signals; at least one of steps/active_minutes/distance_km present
--   unknown    = no signals at all
--
-- Watch-specific signals: hrv_ms, resting_hr_bpm, respiratory_rate_rpm,
--   sleep_continuity_pct, spo2_pct, resting_energy, stand_hours
-- Steps/activity signals (iPhone-capable): steps, active_minutes, distance_km

UPDATE daily_inputs
SET data_tier = CASE
  -- Count non-null Watch signals
  WHEN (
    (CASE WHEN hrv_ms             IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN resting_hr_bpm     IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN respiratory_rate_rpm IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN sleep_continuity_pct IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN spo2_pct           IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN resting_energy     IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN stand_hours        IS NOT NULL THEN 1 ELSE 0 END)
  ) >= 4 THEN 'wearable'
  WHEN (
    (CASE WHEN hrv_ms             IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN resting_hr_bpm     IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN respiratory_rate_rpm IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN sleep_continuity_pct IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN spo2_pct           IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN resting_energy     IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN stand_hours        IS NOT NULL THEN 1 ELSE 0 END)
  ) >= 1 THEN 'partial'
  WHEN (steps IS NOT NULL OR active_minutes IS NOT NULL OR distance_km IS NOT NULL)
    THEN 'steps_only'
  ELSE 'unknown'
END
WHERE data_tier = 'unknown';
-- Only updates rows that haven't been classified yet (new rows arrive as 'unknown').
-- Safe to re-run: rows already set to wearable/partial/steps_only are untouched.

-- Preview what will be classified before committing:
-- SELECT data_tier, COUNT(*) FROM daily_inputs GROUP BY data_tier ORDER BY data_tier;

-- ── Step 2b: Mirror data_tier onto daily_scores ───────────────────────────────
-- daily_scores.data_tier is written by the score function going forward (Section 4).
-- For existing rows, join to daily_inputs and copy the tier.

UPDATE daily_scores ds
SET data_tier = di.data_tier
FROM daily_inputs di
WHERE ds.user_id = di.user_id
  AND ds.date    = di.date
  AND ds.data_tier = 'unknown';  -- only update unclassified score rows

-- ── Step 3: Remove daily_scores for steps_only input days ────────────────────
-- The scoring engine (Section 4) now skips steps_only days.
-- Existing score rows for these days are inconsistent with the new pipeline.
-- DELETE is permanent. Verify Step 2 counts first.
--
-- PREVIEW (run this SELECT before DELETE to see which rows will be removed):
--
--   SELECT ds.date, ds.chronos_score, di.data_tier
--   FROM daily_scores ds
--   JOIN daily_inputs di ON ds.user_id = di.user_id AND ds.date = di.date
--   WHERE di.data_tier = 'steps_only'
--   ORDER BY ds.date;
--
-- EXECUTE DELETE (only when preview output is verified):

DELETE FROM daily_scores
WHERE (user_id, date) IN (
  SELECT di.user_id, di.date
  FROM daily_inputs di
  WHERE di.data_tier = 'steps_only'
);

-- Note: FK-dependent tables (nudge_events, explanations, etc.) must already
-- be empty for these dates. After the cleanse run, this is guaranteed for the
-- primary user. If any FK violations occur, delete child rows first.


-- ════════════════════════════════════════════════════════════════════════════
-- SECTION 15 — VERIFICATION QUERIES
-- Run after Sections 13 and both function deploys to confirm correctness.
-- Expected results annotated inline.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 15.1: Data tier distribution in daily_inputs ─────────────────────────────
-- Expected: no 'unknown' rows after Step 2.
-- Rough expectation for primary user: ~70% wearable, ~25% partial, ~5% steps_only.

SELECT data_tier, COUNT(*) AS day_count
FROM daily_inputs
WHERE user_id = 'c1992eec-7328-4dc1-8fea-55e2b3b07d3e'
GROUP BY data_tier
ORDER BY day_count DESC;

-- ── 15.2: Confirm no steps_only rows in daily_scores ─────────────────────────
-- Expected: 0 rows. All steps_only days must have been deleted (Step 3)
-- or never written (Section 4 guard prevents new writes).

SELECT COUNT(*) AS steps_only_score_rows
FROM daily_scores ds
JOIN daily_inputs di ON ds.user_id = di.user_id AND ds.date = di.date
WHERE di.data_tier = 'steps_only'
  AND ds.user_id = 'c1992eec-7328-4dc1-8fea-55e2b3b07d3e';

-- ── 15.3: Baseline quality check ─────────────────────────────────────────────
-- Expected: all baselines table rows have non-null hrv_avg (Section 5 guard).
-- After backfill with history filter, no corrupt baseline should exist.

SELECT COUNT(*) AS total_baselines,
       COUNT(hrv_avg) AS with_hrv_avg,
       COUNT(*) - COUNT(hrv_avg) AS missing_hrv_avg
FROM baselines
WHERE user_id = 'c1992eec-7328-4dc1-8fea-55e2b3b07d3e';

-- ── 15.4: Narrate-trend gap day count check ───────────────────────────────────
-- Counts steps_only days in the last 7-day window.
-- Expected: whatever the real count is. If > 3 (>50% of 7), narrate-trend
-- will return not_enough_data for the 7D window.

SELECT COUNT(*) AS steps_only_last_7_days
FROM daily_inputs
WHERE user_id = 'c1992eec-7328-4dc1-8fea-55e2b3b07d3e'
  AND data_tier = 'steps_only'
  AND date >= (CURRENT_DATE - INTERVAL '7 days');

-- ── 15.5: data_tier column present in both tables ────────────────────────────
-- Expected: data_tier column exists in daily_inputs and daily_scores.
-- Returns one row per table confirming column presence.

SELECT table_name, column_name, data_type, column_default, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('daily_inputs', 'daily_scores')
  AND column_name IN ('data_tier', 'gap_reason', 'escalation_flag')
ORDER BY table_name, column_name;
