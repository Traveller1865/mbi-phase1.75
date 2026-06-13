-- 20260516000001_drop_horizon_signals.sql
-- Dead code removal: horizon_signals table superseded by pathway_classifications.
-- No code reads horizon_signals; safe to drop.

DROP TABLE IF EXISTS public.horizon_signals;
