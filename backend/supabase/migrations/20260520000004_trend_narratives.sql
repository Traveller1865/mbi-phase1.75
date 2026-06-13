-- 20260520000004_trend_narratives.sql
-- Persistent cache for narrate-trend Claude outputs.
-- Avoids redundant API calls when the underlying window data has not changed.
-- TTL by window: 24h (7D), 7 days (8W), 30 days (12M).

CREATE TABLE IF NOT EXISTS public.trend_narratives (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  window_type   text NOT NULL CHECK (window_type IN ('7d', '8w', '12m')),
  -- Deterministic key representing the window's data state.
  -- Constructed from: window dates + avg + direction (e.g. "2026-W20-avg76-dir-declining")
  -- A cache hit requires matching user_id + window_type + window_key.
  window_key    text NOT NULL,
  narrative_text text NOT NULL,
  stat_line     text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL
);

-- One cached narrative per user + window_type + window_key at a time.
CREATE UNIQUE INDEX trend_narratives_lookup
  ON public.trend_narratives (user_id, window_type, window_key);

-- Fast expiry sweeps and lookup by user.
CREATE INDEX trend_narratives_user_expires
  ON public.trend_narratives (user_id, expires_at);

-- RLS: users can only read/write their own rows.
ALTER TABLE public.trend_narratives ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_trend_narratives" ON public.trend_narratives
  FOR ALL USING (auth.uid() = user_id);

-- Service role bypasses RLS (narrate-trend edge function uses service key).
CREATE POLICY "service_role_trend_narratives" ON public.trend_narratives
  FOR ALL TO service_role USING (true) WITH CHECK (true);
