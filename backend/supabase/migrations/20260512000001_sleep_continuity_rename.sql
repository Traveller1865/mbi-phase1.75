-- MBI Scoring Engine Architecture Review v1.0 — D3 Sleep Continuity Rename
-- DEPENDENCY: Deploy before domain package v1.3 and iOS/backend Edge Function release.
-- Sleep continuity accurately describes consolidation/fragmentation measurement.

BEGIN;
ALTER TABLE daily_inputs RENAME COLUMN sleep_efficiency_pct TO sleep_continuity_pct;
ALTER TABLE baselines    RENAME COLUMN sleep_efficiency_avg  TO sleep_continuity_avg;
COMMIT;
