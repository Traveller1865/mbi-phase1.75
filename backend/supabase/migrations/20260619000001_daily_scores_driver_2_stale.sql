-- Migration: 20260619000001_daily_scores_driver_2_stale.sql
-- driver_2 Baseline-Aware Fallback (Domain v1.7) — driver_2_stale on daily_scores
--
-- driver_2 may now resolve via a baseline-only fallback (selectTopDrivers): when today's
-- data supplies no second metric, driver_2 is drawn from a metric the user has a baseline
-- pattern for, with no fresh reading today. driver_2_stale = true marks that case so the
-- narration frames the driver as a steady recent pattern, not a measured change
-- (Non-Negotiable #4 — always two drivers; Non-Negotiable #7 — narration honours the flag).
--
-- APPLY VIA `supabase migration up`, NOT the SQL Editor (build handoff §2.5).
-- BLOCKER (CC-04): the remote schema_migrations ledger is desynced — ~26 local migrations
-- are not recorded as applied remotely. Running `supabase migration up` now would attempt
-- to (re)apply those and likely fail. This migration's apply step is gated on the CC-04
-- ledger reconciliation. Do not run it into the desync, and do not fall back to SQL Editor.

ALTER TABLE daily_scores
  ADD COLUMN IF NOT EXISTS driver_2_stale BOOLEAN NOT NULL DEFAULT false;
