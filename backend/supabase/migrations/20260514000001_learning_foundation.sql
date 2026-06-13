-- ══════════════════════════════════════════════════════════════
-- Learning Foundation Migration v1.0
-- Date: 2026-05-14
-- Purpose: p10/p90 personal percentile columns, fix silent-drop
--          bug, and create full beta learning foundation schema
-- ══════════════════════════════════════════════════════════════

BEGIN;

-- ── Part A-1: Add p10/p90 columns to baselines ──────────────────────────
-- Used by deviation.ts to replace hardcoded absolute reserve thresholds
-- with personal percentile thresholds once sufficient history exists.
ALTER TABLE baselines
  ADD COLUMN IF NOT EXISTS p10_hrv_7d           numeric,
  ADD COLUMN IF NOT EXISTS p90_hrv_7d           numeric,
  ADD COLUMN IF NOT EXISTS p10_resting_hr       numeric,
  ADD COLUMN IF NOT EXISTS p90_resting_hr       numeric,
  ADD COLUMN IF NOT EXISTS p10_sleep_duration   numeric,
  ADD COLUMN IF NOT EXISTS p90_sleep_duration   numeric,
  ADD COLUMN IF NOT EXISTS p10_sleep_continuity numeric,
  ADD COLUMN IF NOT EXISTS p90_sleep_continuity numeric,
  ADD COLUMN IF NOT EXISTS p10_steps            numeric,
  ADD COLUMN IF NOT EXISTS p90_steps            numeric,
  ADD COLUMN IF NOT EXISTS p10_active_minutes   numeric,
  ADD COLUMN IF NOT EXISTS p90_active_minutes   numeric;

-- ── Part A-2: Fix silent-drop bug ───────────────────────────────────────
-- spo2_avg, resting_energy_avg, stand_hours_avg exist in the TypeScript
-- Baseline interface but not in the SQL table. Every upsert has been
-- silently discarding these values. Fix now.
ALTER TABLE baselines
  ADD COLUMN IF NOT EXISTS spo2_avg           numeric,
  ADD COLUMN IF NOT EXISTS resting_energy_avg numeric,
  ADD COLUMN IF NOT EXISTS stand_hours_avg    numeric;

-- ── Part B-1: nudge_events ───────────────────────────────────────────────
-- Logs every nudge surface event with full system state at that exact
-- moment. Core of the outcome learning loop. nudge_text populated after
-- Claude responds (non-blocking update). Cannot be reconstructed later.
CREATE TABLE IF NOT EXISTS nudge_events (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date             date        NOT NULL,
  score_id         uuid        REFERENCES daily_scores(id),
  nudge_domain     text        NOT NULL,
  nudge_text       text,
  chronos_score    numeric,
  score_band       text,
  d1_autonomic     numeric,
  d2_sleep         numeric,
  d3_activity      numeric,
  fail_state       text,
  trust_state      text,
  data_confidence  text,
  delta_override   boolean,
  policy_version   text        NOT NULL,
  prompt_version   text        NOT NULL,
  scoring_version  text        NOT NULL,
  shown_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS nudge_events_user_date
  ON nudge_events(user_id, date);

ALTER TABLE nudge_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own nudge_events"
  ON nudge_events FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Service role can write nudge_events"
  ON nudge_events FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── Part B-2: nudge_responses ───────────────────────────────────────────
-- Records what the user actually did with each nudge.
-- response_type: accepted | ignored | dismissed | snoozed | completed
CREATE TABLE IF NOT EXISTS nudge_responses (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  nudge_event_id  uuid        NOT NULL REFERENCES nudge_events(id) ON DELETE CASCADE,
  user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  response_type   text        NOT NULL,
  responded_at    timestamptz NOT NULL DEFAULT now(),
  latency_seconds integer,
  user_note       text
);

ALTER TABLE nudge_responses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own nudge_responses"
  ON nudge_responses FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own nudge_responses"
  ON nudge_responses FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Service role can write nudge_responses"
  ON nudge_responses FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── Part B-3: decision_context_snapshots ───────────────────────────────
-- Freezes the full system state at every score or nudge surface event.
-- Prevents future ambiguity about what the system knew and why it acted.
-- event_type: score_computed | nudge_shown | explanation_shown | feedback_received
CREATE TABLE IF NOT EXISTS decision_context_snapshots (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date                  date        NOT NULL,
  event_type            text        NOT NULL,
  score_id              uuid        REFERENCES daily_scores(id),
  nudge_event_id        uuid        REFERENCES nudge_events(id),
  chronos_score         numeric,
  score_band            text,
  primary_driver        text,
  secondary_driver      text,
  fail_state            text,
  trust_state           text,
  data_confidence       text,
  completeness_score    numeric,
  scoring_version       text        NOT NULL,
  nudge_policy_version  text,
  prompt_version        text,
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS decision_ctx_user_date
  ON decision_context_snapshots(user_id, date);

ALTER TABLE decision_context_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role can write decision_context_snapshots"
  ON decision_context_snapshots FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── Part B-4: first_occurrence_events ──────────────────────────────────
-- Timestamps the FIRST time a user hits each significant milestone.
-- UNIQUE(user_id, event_name) handles deduplication — second insert
-- fails silently, which is the correct and intended behaviour.
CREATE TABLE IF NOT EXISTS first_occurrence_events (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event_name           text        NOT NULL,
  related_score_id     uuid        REFERENCES daily_scores(id),
  related_nudge_id     uuid        REFERENCES nudge_events(id),
  context_snapshot_id  uuid        REFERENCES decision_context_snapshots(id),
  first_seen_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, event_name)
);

ALTER TABLE first_occurrence_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role can write first_occurrence_events"
  ON first_occurrence_events FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── Part B-5: outcome_windows ───────────────────────────────────────────
-- Connects nudge events to actual metric changes in the days that follow.
-- Populated by compute-outcome-windows cron job, not at nudge time.
-- outcome_window: next_day | 7_day
CREATE TABLE IF NOT EXISTS outcome_windows (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  nudge_event_id       uuid        NOT NULL REFERENCES nudge_events(id) ON DELETE CASCADE,
  outcome_window       text        NOT NULL,
  chronos_score_delta  numeric,
  d1_delta             numeric,
  d2_delta             numeric,
  d3_delta             numeric,
  hrv_delta            numeric,
  resting_hr_delta     numeric,
  sleep_duration_delta numeric,
  computed_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE(nudge_event_id, outcome_window)
);

ALTER TABLE outcome_windows ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role can write outcome_windows"
  ON outcome_windows FOR ALL
  USING (true)
  WITH CHECK (true);

-- ── Part B-6: Expand feedback table ────────────────────────────────────
-- The existing felt_accurate boolean is insufficient for model training.
-- Add context linkage and granular signal columns.
ALTER TABLE feedback
  ADD COLUMN IF NOT EXISTS nudge_event_id           uuid REFERENCES nudge_events(id),
  ADD COLUMN IF NOT EXISTS context_snapshot_id      uuid REFERENCES decision_context_snapshots(id),
  ADD COLUMN IF NOT EXISTS felt_helpful             boolean,
  ADD COLUMN IF NOT EXISTS felt_overwhelming        boolean,
  ADD COLUMN IF NOT EXISTS trust_state_at_time      text,
  ADD COLUMN IF NOT EXISTS scoring_version_at_time  text;

COMMIT;
