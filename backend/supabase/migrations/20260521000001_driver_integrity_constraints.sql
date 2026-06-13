-- 20260521000001_driver_integrity_constraints.sql
-- Data integrity constraints preventing duplicate driver values.
-- Enforces the deduplication rule at the DB level so dirty data cannot be written
-- even if the application-layer guard is bypassed (e.g. direct SQL, migration backfill).
--
-- Paired runtime assertion in score/index.ts fails fast before the DB write.
-- This constraint is the last line of defence.

ALTER TABLE public.daily_scores
  ADD CONSTRAINT chk_drivers_distinct
  CHECK (driver_1 IS NULL OR driver_2 IS NULL OR driver_1 != driver_2);

ALTER TABLE public.trend_aggregates
  ADD CONSTRAINT chk_top_drivers_distinct
  CHECK (top_driver_1 IS NULL OR top_driver_2 IS NULL OR top_driver_1 != top_driver_2);
