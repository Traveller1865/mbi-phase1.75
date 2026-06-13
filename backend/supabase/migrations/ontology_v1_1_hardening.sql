-- MBI Chronos — Ontology Engine v1.1 Hardening Migrations
-- Execute each block manually in Supabase SQL Editor.
-- See: MBI_Chronos_BuildHandoff_OntologyV1_1_Hardening_v1_0.docx
-- DO NOT apply ontology_version bump (phase1_75-v1.1) until all 12 AC pass.

-- ── CHANGE 1: Node Key Rename ────────────────────────────────────────────────
-- AC-01 / AC-02 / AC-03

UPDATE ontology_nodes
SET node_key = 'sustained_recovery_deficit'
WHERE node_key = 'chronic_fatigue_signal';

UPDATE node_activations
SET contributing_metrics = replace(
  contributing_metrics::text,
  'chronic_fatigue_signal',
  'sustained_recovery_deficit'
)::jsonb
WHERE contributing_metrics::text LIKE '%chronic_fatigue_signal%';

UPDATE pathway_classifications
SET activating_nodes = replace(
  activating_nodes::text,
  'chronic_fatigue_signal',
  'sustained_recovery_deficit'
)::jsonb
WHERE activating_nodes::text LIKE '%chronic_fatigue_signal%';

-- ── CHANGE 2: Add skipped_reason to node_activations ────────────────────────

ALTER TABLE node_activations
  ADD COLUMN IF NOT EXISTS skipped_reason text NULL;

-- ── CHANGE 3: Travel and Timezone Suppression columns ───────────────────────
-- AC-05

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS timezone_shift_detected boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS timezone_shift_date date NULL;

-- ── CHANGE 4: user_escalation_context table ─────────────────────────────────
-- AC-08

CREATE TABLE IF NOT EXISTS user_escalation_context (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  escalation_date     date        NOT NULL,
  pathway_key         text        NOT NULL,
  context_flags       jsonb       NOT NULL DEFAULT '[]',
  context_flag_active boolean     NOT NULL DEFAULT false,
  responded_at        timestamptz NOT NULL DEFAULT now(),
  ontology_version    text        NOT NULL DEFAULT 'phase1_75-v1.0',
  UNIQUE (user_id, escalation_date, pathway_key)
);

CREATE INDEX IF NOT EXISTS idx_user_escalation_context_user_date
  ON user_escalation_context (user_id, escalation_date DESC);

-- RLS: users read and write own rows only
ALTER TABLE user_escalation_context ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_escalation_context_owner"
  ON user_escalation_context
  FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ── CHANGE 5: suppressed_classifications table ───────────────────────────────
-- AC-11

CREATE TABLE IF NOT EXISTS suppressed_classifications (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  classification_date date        NOT NULL,
  pathway_key         text        NOT NULL,
  state               text        NOT NULL CHECK (state IN ('ELEVATED', 'FLAGGED')),
  confidence_gate     numeric     NOT NULL,
  trust_factor        numeric     NULL,
  depth_factor        numeric     NULL,
  stability_factor    numeric     NULL,
  activating_nodes    jsonb       NOT NULL DEFAULT '[]',
  condition_class     text        NULL,
  ontology_version    text        NOT NULL DEFAULT 'phase1_75-v1.0',
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, classification_date, pathway_key)
);

CREATE INDEX IF NOT EXISTS idx_suppressed_classifications_user_date
  ON suppressed_classifications (user_id, classification_date DESC);

-- RLS: service role reads only (founder-facing audit). Users cannot read this table.
ALTER TABLE suppressed_classifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "suppressed_classifications_service_only"
  ON suppressed_classifications
  FOR ALL
  USING (false);

-- Grant service role full access (bypasses RLS)
GRANT ALL ON suppressed_classifications TO service_role;

-- ── POST-COMPLETION ONLY: Ontology Version Bump ──────────────────────────────
-- Run ONLY after all 12 acceptance criteria pass (AC-01 through AC-12).
-- This is the last step — do not run prematurely.
-- The version bump is a CODE change, not a SQL change:
--   Update ONTOLOGY_VERSION in _shared/domain/ontology/types.ts from
--   'phase1_75-v1.0' to 'phase1_75-v1.1', then redeploy ontology-classify.
--   All rows written after redeployment will carry the new version string.
