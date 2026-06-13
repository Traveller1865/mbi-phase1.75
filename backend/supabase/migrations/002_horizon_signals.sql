-- MBI Phase 2 — Horizon Signals Table
-- Version: 1.0 | Epic 3 Sprint 1
-- Stores per-pathway ontology engine outputs for Horizon Pages 2–4.
-- One row per user / date / pathway. Upserted by the `horizon` Edge Function.

create table if not exists public.horizon_signals (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references public.users(id) on delete cascade,
  date                date not null,
  pathway             text not null check (pathway in ('autonomic', 'sleep', 'metabolic')),

  -- Ontology outputs (null = pattern not yet activated)
  condition_class     text,
  trajectory_label    text,
  escalation_level    integer not null default 0 check (escalation_level between 0 and 3),
  confidence_gate     numeric not null default 0.0 check (confidence_gate between 0.0 and 1.0),
  days_in_pattern     integer not null default 0,

  -- Provenance — required per MBI knowledge vault v1 calibration protocol
  schema_version      text not null default 'v1.0-derived',
  calibration_status  text not null default 'pending_biomarker_validation',

  created_at          timestamptz not null default now(),

  unique (user_id, date, pathway)
);

alter table public.horizon_signals enable row level security;

create policy "Users can read own horizon signals"
  on public.horizon_signals for select
  using (auth.uid() = user_id);

-- Service role bypasses RLS — Edge Functions use service role key.

create index if not exists horizon_signals_user_date_idx
  on public.horizon_signals (user_id, date desc);
