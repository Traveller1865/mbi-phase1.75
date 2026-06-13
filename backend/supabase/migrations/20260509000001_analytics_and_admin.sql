-- Migration: Analytics & Admin Devices
-- Sprint: Beta Readiness — P3.2 + P4.3
-- Apply via: Supabase Dashboard → SQL Editor → Run

-- ─────────────────────────────────────────────────────────────
-- app_events: custom analytics table (no third-party SDKs)
-- Users can insert their own events; no client-side reads.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS app_events (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        REFERENCES auth.users(id) ON DELETE CASCADE,
    event_name  TEXT        NOT NULL,
    properties  JSONB       DEFAULT '{}',
    app_version TEXT,
    os_version  TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE app_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users can insert own events"
    ON app_events FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- ─────────────────────────────────────────────────────────────
-- admin_devices: stores founder APNs push tokens for Horizon
-- escalation alerts. Backend-only — no client RLS needed.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_devices (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_user_id UUID        REFERENCES auth.users(id),
    push_token    TEXT        NOT NULL,
    platform      TEXT        DEFAULT 'ios',
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- No RLS: table is accessed exclusively via service_role key in Edge Functions.
-- Client never reads or writes this table directly.
