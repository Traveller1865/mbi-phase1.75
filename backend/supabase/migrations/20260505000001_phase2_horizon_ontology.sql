-- =============================================================================
-- MBI Phase 2 — Horizon Ontology Engine + Feature Waitlist
-- Migration: 20260505000001_phase2_horizon_ontology.sql
-- =============================================================================
--
-- This migration:
--   1. Creates pathway_classifications — replaces horizon_signals as the
--      canonical Ontology Engine output table. iOS client and narrate-horizon
--      Edge Function migrate to read/write this table. horizon_signals is
--      deprecated and will be dropped in the next sprint cleanup migration.
--
--   2. Creates metric_node_map — maps raw metric keys to classification nodes.
--
--   3. Creates node_activation_rules — deterministic rule set per node.
--
--   4. Creates node_activation_log — per-user audit log of node firing events.
--
--   5. Creates user_feature_waitlist — feature interest capture for deferred CTAs
--      on the Escalate page (Doctor Report, DPC Scheduling, Horizon Assist).
--
-- All tables use RLS. Only authenticated users can read/write their own rows.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. PATHWAY CLASSIFICATIONS
-- Replaces horizon_signals. Written by the horizon-classify Edge Function.
-- Read by iOS HorizonModuleView (via fetchHorizonSignals — query updated to
-- pull from this table post-migration).
-- -----------------------------------------------------------------------------

create table if not exists public.pathway_classifications (
    id                  uuid        primary key default gen_random_uuid(),
    user_id             uuid        not null references auth.users(id) on delete cascade,
    date                date        not null,
    pathway             text        not null check (pathway in ('autonomic', 'sleep', 'metabolic')),
    condition_class     text,       -- null when no pattern meets threshold
    trajectory_label    text,
    escalation_level    integer     not null default 0 check (escalation_level between 0 and 3),
    confidence_gate     numeric(4,3) not null default 0.0 check (confidence_gate between 0 and 1),
    days_in_pattern     integer     not null default 0,
    schema_version      text        not null default 'v2.0',
    calibration_status  text        not null default 'pending_biomarker_validation',
    ontology_version    text        not null default 'v2.0',
    created_at          timestamptz not null default now(),

    unique (user_id, date, pathway)
);

-- Valid condition_class values per Design Session §2.3
-- autonomic_stress_load | sleep_architecture_disruption | metabolic_inactivity_load
-- combined_autonomic_sleep | combined_metabolic_sleep | full_system_load

comment on table public.pathway_classifications is
    'Ontology Engine output. Replaces horizon_signals. One row per user per date per pathway.';

comment on column public.pathway_classifications.condition_class is
    'Null = no pattern at threshold. Values: autonomic_stress_load, sleep_architecture_disruption, metabolic_inactivity_load, combined_autonomic_sleep, combined_metabolic_sleep, full_system_load';

comment on column public.pathway_classifications.confidence_gate is
    'Within-user confidence 0.0–1.0. Trajectory gate ≥ 0.3, Redirect gate ≥ 0.5, Escalate gate ≥ 0.75.';

alter table public.pathway_classifications enable row level security;

create policy "Users read own pathway_classifications"
    on public.pathway_classifications for select
    using (auth.uid() = user_id);

create policy "Service role writes pathway_classifications"
    on public.pathway_classifications for insert
    with check (true);  -- Edge Function uses service role key

create policy "Service role updates pathway_classifications"
    on public.pathway_classifications for update
    using (true);

create index if not exists idx_pathway_classifications_user_date
    on public.pathway_classifications (user_id, date desc);

create index if not exists idx_pathway_classifications_user_date_pathway
    on public.pathway_classifications (user_id, date desc, pathway);


-- -----------------------------------------------------------------------------
-- 2. METRIC NODE MAP
-- Maps raw metric keys (matching daily_inputs columns) to classification nodes.
-- Weights are pathway-relative, not cross-pathway.
-- -----------------------------------------------------------------------------

create table if not exists public.metric_node_map (
    id              uuid    primary key default gen_random_uuid(),
    metric_key      text    not null,   -- e.g. 'hrv_ms', 'sleep_duration_hrs'
    node_id         text    not null,   -- e.g. 'hrv_suppression', 'sleep_fragmentation'
    pathway         text    not null check (pathway in ('autonomic', 'sleep', 'metabolic')),
    weight          numeric(4,3) not null default 1.0,  -- relative weight within pathway
    schema_version  text    not null default 'v2.0',
    created_at      timestamptz not null default now(),

    unique (metric_key, node_id)
);

comment on table public.metric_node_map is
    'Maps raw metric columns to ontology classification nodes. Read-only at runtime — seeded at deploy.';

-- Seed: Autonomic pathway nodes
insert into public.metric_node_map (metric_key, node_id, pathway, weight) values
    ('hrv_ms',              'hrv_suppression',          'autonomic', 1.00),
    ('resting_hr_bpm',      'rhr_elevation',            'autonomic', 0.80),
    ('respiratory_rate_rpm','respiratory_load',         'autonomic', 0.60)
on conflict (metric_key, node_id) do nothing;

-- Seed: Sleep pathway nodes
insert into public.metric_node_map (metric_key, node_id, pathway, weight) values
    ('sleep_duration_hrs',    'sleep_duration_deficit',   'sleep', 1.00),
    ('sleep_efficiency_pct',  'sleep_efficiency_decline', 'sleep', 0.90)
on conflict (metric_key, node_id) do nothing;

-- Seed: Metabolic pathway nodes
insert into public.metric_node_map (metric_key, node_id, pathway, weight) values
    ('steps',           'step_count_deficit',       'metabolic', 0.85),
    ('active_minutes',  'activity_inactivity_load', 'metabolic', 1.00)
on conflict (metric_key, node_id) do nothing;


-- -----------------------------------------------------------------------------
-- 3. NODE ACTIVATION RULES
-- Deterministic threshold rules per node. Edge Function evaluates these
-- against daily_inputs to fire nodes and compute confidence_gate.
-- -----------------------------------------------------------------------------

create table if not exists public.node_activation_rules (
    id                  uuid    primary key default gen_random_uuid(),
    node_id             text    not null,
    pathway             text    not null check (pathway in ('autonomic', 'sleep', 'metabolic')),
    rule_type           text    not null check (rule_type in ('threshold', 'trend', 'duration')),
    threshold_value     numeric,        -- absolute threshold (for 'threshold' rules)
    comparison_operator text    check (comparison_operator in ('<', '>', '<=', '>=')),
    days_window         integer not null default 7,    -- rolling window for evaluation
    required_hits       integer not null default 5,   -- days within window that must meet threshold
    schema_version      text    not null default 'v2.0',
    created_at          timestamptz not null default now()
);

comment on table public.node_activation_rules is
    'Deterministic classification rules evaluated against daily_inputs per node. Seeded at deploy, versioned.';

-- Seed: Autonomic rules (within-user — applied as % deviation from 90-day baseline in Edge Function)
insert into public.node_activation_rules (node_id, pathway, rule_type, threshold_value, comparison_operator, days_window, required_hits) values
    ('hrv_suppression',     'autonomic', 'threshold', -15.0, '<',  7, 5),  -- HRV 15% below baseline 5/7 days
    ('rhr_elevation',       'autonomic', 'threshold',   8.0, '>',  7, 5),  -- RHR 8 bpm above baseline 5/7 days
    ('respiratory_load',    'autonomic', 'threshold',   2.0, '>',  7, 4)   -- RR 2 rpm above baseline 4/7 days
on conflict do nothing;

-- Seed: Sleep rules
insert into public.node_activation_rules (node_id, pathway, rule_type, threshold_value, comparison_operator, days_window, required_hits) values
    ('sleep_duration_deficit',   'sleep', 'threshold', -0.75, '<', 7, 5),  -- 45 min below baseline 5/7 days
    ('sleep_efficiency_decline', 'sleep', 'threshold',  -8.0, '<', 7, 4)   -- 8% below baseline 4/7 days
on conflict do nothing;

-- Seed: Metabolic rules
insert into public.node_activation_rules (node_id, pathway, rule_type, threshold_value, comparison_operator, days_window, required_hits) values
    ('step_count_deficit',       'metabolic', 'threshold', -2500, '<', 7, 5),  -- 2500 steps below baseline 5/7 days
    ('activity_inactivity_load', 'metabolic', 'threshold',   -20, '<', 7, 4)   -- 20 active min below baseline 4/7 days
on conflict do nothing;


-- -----------------------------------------------------------------------------
-- 4. NODE ACTIVATION LOG
-- Per-user audit log of node firing events. Written by Edge Function.
-- Powers escalation_level accumulation and confidence_gate derivation.
-- -----------------------------------------------------------------------------

create table if not exists public.node_activation_log (
    id                  uuid        primary key default gen_random_uuid(),
    user_id             uuid        not null references auth.users(id) on delete cascade,
    date                date        not null,
    node_id             text        not null,
    pathway             text        not null check (pathway in ('autonomic', 'sleep', 'metabolic')),
    fired               boolean     not null default false,
    input_value         numeric,    -- raw metric value that triggered evaluation
    threshold_crossed   boolean     not null default false,
    days_in_run         integer     not null default 0,   -- consecutive days this node has fired
    schema_version      text        not null default 'v2.0',
    created_at          timestamptz not null default now(),

    unique (user_id, date, node_id)
);

comment on table public.node_activation_log is
    'Audit log of node firing events per user per day. Used to derive escalation_level and confidence_gate in pathway_classifications.';

alter table public.node_activation_log enable row level security;

create policy "Users read own node_activation_log"
    on public.node_activation_log for select
    using (auth.uid() = user_id);

create policy "Service role writes node_activation_log"
    on public.node_activation_log for insert
    with check (true);

create index if not exists idx_node_activation_log_user_date
    on public.node_activation_log (user_id, date desc);

create index if not exists idx_node_activation_log_user_node_date
    on public.node_activation_log (user_id, node_id, date desc);


-- -----------------------------------------------------------------------------
-- 5. USER FEATURE WAITLIST
-- Captures feature interest from Escalate page deferred CTAs.
-- Written by iOS client via enrollFeatureWaitlist (best-effort POST).
-- One row per user per feature_slug — upsert with ignore-duplicates.
-- -----------------------------------------------------------------------------

create table if not exists public.user_feature_waitlist (
    id              uuid        primary key default gen_random_uuid(),
    user_id         uuid        not null references auth.users(id) on delete cascade,
    feature_slug    text        not null check (feature_slug in ('doctor_report', 'dpc_scheduling', 'horizon_assist')),
    enrolled_at     timestamptz not null default now(),
    notified_at     timestamptz,        -- null until feature ships and notification is sent
    source_page     text        not null default 'escalate',
    created_at      timestamptz not null default now(),

    unique (user_id, feature_slug)
);

comment on table public.user_feature_waitlist is
    'Feature interest capture from Escalate page Notify me toggles. One enrollment per user per feature.';

comment on column public.user_feature_waitlist.feature_slug is
    'Values: doctor_report | dpc_scheduling | horizon_assist';

comment on column public.user_feature_waitlist.notified_at is
    'Null until feature ships. Set when notification email/push is sent.';

alter table public.user_feature_waitlist enable row level security;

create policy "Users read own waitlist entries"
    on public.user_feature_waitlist for select
    using (auth.uid() = user_id);

create policy "Users insert own waitlist entries"
    on public.user_feature_waitlist for insert
    with check (auth.uid() = user_id);

-- No delete policy — enrollments are permanent (one-way).
-- Admins use service role to manage notified_at.

create index if not exists idx_user_feature_waitlist_slug
    on public.user_feature_waitlist (feature_slug, enrolled_at desc);


-- -----------------------------------------------------------------------------
-- 6. DEPRECATION NOTICE: horizon_signals
-- horizon_signals is superseded by pathway_classifications.
-- It is NOT dropped here — the iOS client and Edge Function migration
-- to pathway_classifications must complete first. Drop in next sprint.
-- -----------------------------------------------------------------------------

comment on table public.horizon_signals is
    '⚠️ DEPRECATED — superseded by pathway_classifications (Phase 2 Sprint 3). Do not write new rows. Drop after iOS + Edge Function migration confirmed.';
