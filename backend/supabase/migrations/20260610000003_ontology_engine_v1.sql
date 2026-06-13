-- Ontology Engine v1 — Phase 1.75
-- Spec: MBI_Chronos_BuildHandoff_OntologyEngineV1_v1_0.docx
-- Ontology version: phase1_75-v1.0
--
-- Four additive tables. No existing tables modified.
-- Apply via Supabase SQL Editor. Confirm with information_schema query.

-- ── 1. ontology_nodes ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.ontology_nodes (
  id                     uuid         NOT NULL DEFAULT gen_random_uuid(),
  node_key               text         NOT NULL,
  tier                   text         NOT NULL,  -- root_cause | biological_response | intermediate_dysfunction | disease_endpoint | protective
  display_name           text         NOT NULL,
  is_active              boolean      NOT NULL DEFAULT false,
  data_source_required   text         NOT NULL,  -- wearable | biomarker | symptom_log | journal
  decay_half_life_days   integer,               -- Phase 2 reserved, null in v1
  ontology_version       text         NOT NULL,
  created_at             timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT pk_ontology_nodes PRIMARY KEY (id),
  CONSTRAINT uq_ontology_nodes_key UNIQUE (node_key)
);

-- ── 2. metric_node_map ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.metric_node_map (
  id               uuid         NOT NULL DEFAULT gen_random_uuid(),
  metric_key       text         NOT NULL,
  node_id          uuid         NOT NULL REFERENCES public.ontology_nodes(id),
  weight           numeric      NOT NULL DEFAULT 1.0,
  direction        text         NOT NULL,  -- below_baseline | above_baseline | variance_high | absolute_threshold
  ontology_version text         NOT NULL,
  created_at       timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT pk_metric_node_map PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_metric_node_map_node ON public.metric_node_map (node_id);

-- ── 3. node_activations ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.node_activations (
  id                    uuid         NOT NULL DEFAULT gen_random_uuid(),
  user_id               uuid         NOT NULL REFERENCES auth.users(id),
  node_id               uuid         NOT NULL REFERENCES public.ontology_nodes(id),
  activation_date       date         NOT NULL,
  is_active             boolean      NOT NULL,
  activation_strength   numeric      NOT NULL CHECK (activation_strength >= 0 AND activation_strength <= 1),
  contributing_metrics  jsonb        NOT NULL,
  days_active           integer      NOT NULL DEFAULT 0,
  ontology_version      text         NOT NULL,
  created_at            timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT pk_node_activations PRIMARY KEY (id),
  CONSTRAINT uq_node_activations UNIQUE (user_id, node_id, activation_date)
);

CREATE INDEX IF NOT EXISTS idx_node_activations_user_date
  ON public.node_activations (user_id, activation_date DESC);

ALTER TABLE public.node_activations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "node_activations_user_read"
  ON public.node_activations FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "node_activations_service_write"
  ON public.node_activations FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- ── 4. pathway_classifications ───────────────────────────────────────────────
-- Replaces deprecated horizon_signals as the Horizon tab read source.

CREATE TABLE IF NOT EXISTS public.pathway_classifications (
  id                  uuid         NOT NULL DEFAULT gen_random_uuid(),
  user_id             uuid         NOT NULL REFERENCES auth.users(id),
  classification_date date         NOT NULL,
  pathway_key         text         NOT NULL,  -- autonomic | sleep | metabolic
  state               text         NOT NULL,  -- CALM | ELEVATED | FLAGGED
  trajectory_label    text,                   -- null when CALM
  condition_class     text,                   -- null when CALM; legal-gated, never user-facing verbatim
  escalation_level    integer      NOT NULL CHECK (escalation_level BETWEEN 0 AND 3),
  confidence_gate     numeric      NOT NULL CHECK (confidence_gate BETWEEN 0.0 AND 1.0),
  days_in_pattern     integer      NOT NULL DEFAULT 0,
  activating_nodes    jsonb        NOT NULL,
  ontology_version    text         NOT NULL,
  created_at          timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT pk_pathway_classifications PRIMARY KEY (id),
  CONSTRAINT uq_pathway_classifications UNIQUE (user_id, classification_date, pathway_key)
);

CREATE INDEX IF NOT EXISTS idx_pathway_classifications_user_date
  ON public.pathway_classifications (user_id, classification_date DESC, pathway_key);

ALTER TABLE public.pathway_classifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pathway_classifications_user_read"
  ON public.pathway_classifications FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "pathway_classifications_service_write"
  ON public.pathway_classifications FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- ── Seed: 12 active ontology nodes ──────────────────────────────────────────

INSERT INTO public.ontology_nodes (node_key, tier, display_name, is_active, data_source_required, ontology_version) VALUES
  -- Root causes
  ('poor_sleep_quality',       'root_cause',                 'Sleep Quality Insufficiency',        true,  'wearable', 'phase1_75-v1.0'),
  ('physical_inactivity',      'root_cause',                 'Movement Deficit',                   true,  'wearable', 'phase1_75-v1.0'),
  ('circadian_disruption',     'root_cause',                 'Circadian Rhythm Drift',             true,  'wearable', 'phase1_75-v1.0'),
  -- Biological responses
  ('low_hrv',                  'biological_response',        'HRV Suppression',                    true,  'wearable', 'phase1_75-v1.0'),
  ('elevated_resting_hr',      'biological_response',        'Resting Heart Rate Elevation',       true,  'wearable', 'phase1_75-v1.0'),
  ('autonomic_dysfunction',    'biological_response',        'Autonomic Imbalance Signal',         true,  'wearable', 'phase1_75-v1.0'),
  ('sympathetic_dominance',    'biological_response',        'Sympathetic Tone Pattern',           true,  'wearable', 'phase1_75-v1.0'),
  -- Intermediate dysfunctions
  ('sleep_fragmentation',      'intermediate_dysfunction',   'Sleep Architecture Disruption',      true,  'wearable', 'phase1_75-v1.0'),
  ('chronic_fatigue_signal',   'intermediate_dysfunction',   'Sustained Recovery Deficit',         true,  'wearable', 'phase1_75-v1.0'),
  ('recovery_load_imbalance',  'intermediate_dysfunction',   'Recovery-Load Asymmetry',            true,  'wearable', 'phase1_75-v1.0'),
  -- Protective
  ('daily_exercise',           'protective',                 'Movement Sufficiency',               true,  'wearable', 'phase1_75-v1.0'),
  ('quality_sleep',            'protective',                 'Sleep Sufficiency',                  true,  'wearable', 'phase1_75-v1.0')
ON CONFLICT (node_key) DO NOTHING;

-- Inactive placeholder nodes (disease_endpoint tier + biomarker-sourced)
-- Forward-compatibility rows. is_active = false. Never activated in v1.
INSERT INTO public.ontology_nodes (node_key, tier, display_name, is_active, data_source_required, ontology_version) VALUES
  ('hypertension_risk',         'disease_endpoint', 'Hypertension Risk Signal',       false, 'biomarker', 'phase1_75-v1.0'),
  ('metabolic_syndrome_risk',   'disease_endpoint', 'Metabolic Syndrome Risk Signal', false, 'biomarker', 'phase1_75-v1.0'),
  ('cardiovascular_load',       'disease_endpoint', 'Cardiovascular Load Signal',     false, 'biomarker', 'phase1_75-v1.0'),
  ('insulin_resistance_signal', 'disease_endpoint', 'Insulin Resistance Signal',      false, 'biomarker', 'phase1_75-v1.0'),
  ('cortisol_dysregulation',    'biological_response', 'Cortisol Rhythm Disruption',  false, 'biomarker', 'phase1_75-v1.0'),
  ('inflammation_signal',       'biological_response', 'Inflammatory Load Signal',    false, 'biomarker', 'phase1_75-v1.0')
ON CONFLICT (node_key) DO NOTHING;

-- ── Seed: metric_node_map ────────────────────────────────────────────────────

INSERT INTO public.metric_node_map (metric_key, node_id, weight, direction, ontology_version)
SELECT 'hrv',               id, 1.0, 'below_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'low_hrv'
UNION ALL
SELECT 'resting_hr',        id, 1.0, 'above_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'elevated_resting_hr'
UNION ALL
SELECT 'sleep_duration_hrs',id, 1.0, 'below_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'poor_sleep_quality'
UNION ALL
SELECT 'sleep_continuity',  id, 1.0, 'below_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'poor_sleep_quality'
UNION ALL
SELECT 'sleep_continuity',  id, 1.0, 'below_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'sleep_fragmentation'
UNION ALL
SELECT 'sleep_duration_hrs',id, 1.0, 'variance_high',  'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'sleep_fragmentation'
UNION ALL
SELECT 'steps',             id, 1.0, 'below_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'physical_inactivity'
UNION ALL
SELECT 'active_minutes',    id, 1.0, 'below_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'physical_inactivity'
UNION ALL
SELECT 'steps',             id, 1.0, 'above_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'daily_exercise'
UNION ALL
SELECT 'active_minutes',    id, 1.0, 'above_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'daily_exercise'
UNION ALL
SELECT 'respiratory_rate',  id, 1.0, 'above_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'autonomic_dysfunction'
UNION ALL
SELECT 'sleep_duration_hrs',id, 1.0, 'above_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'quality_sleep'
UNION ALL
SELECT 'sleep_continuity',  id, 1.0, 'above_baseline', 'phase1_75-v1.0' FROM public.ontology_nodes WHERE node_key = 'quality_sleep';
