-- Migration: Horizon Escalations
-- Sprint: Beta Readiness — P4.2
-- Apply via: Supabase Dashboard → SQL Editor → Run

-- ─────────────────────────────────────────────────────────────
-- horizon_escalations: audit log of 3-consecutive-day low-score
-- detections. Written by the score Edge Function (service_role).
-- Founder reviews via Supabase Studio or admin dashboard.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS horizon_escalations (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID        REFERENCES auth.users(id) ON DELETE CASCADE,
    triggered_date DATE        NOT NULL,           -- date of the 3rd consecutive low-score day
    score_day1     NUMERIC,                        -- oldest of the 3 days
    score_day2     NUMERIC,
    score_day3     NUMERIC,                        -- most recent (today)
    streak_length  INTEGER     DEFAULT 3,
    push_sent      BOOLEAN     DEFAULT FALSE,      -- set to TRUE once P4.3 APNs sender fires
    created_at     TIMESTAMPTZ DEFAULT NOW()
);

-- RLS: users cannot read or write their own escalation records.
-- All access is via service_role key in the score Edge Function.
ALTER TABLE horizon_escalations ENABLE ROW LEVEL SECURITY;
-- (No permissive policies — service_role bypasses RLS automatically)

-- Index for cooldown lookup in score/index.ts:
-- SELECT id FROM horizon_escalations WHERE user_id = $1 AND triggered_date >= $2
CREATE INDEX IF NOT EXISTS idx_horizon_escalations_user_date
    ON horizon_escalations (user_id, triggered_date);
