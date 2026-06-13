-- MBI Phase 1 — Full Schema Migration
-- Version: 1.0 | Sprint 1
-- Run via: supabase db push

-- ─────────────────────────────────────────
-- USERS
-- ─────────────────────────────────────────
create table if not exists public.users (
  id                  uuid primary key references auth.users(id) on delete cascade,
  email               text not null,
  display_name        text,
  step_goal           integer not null default 8000,
  onboarding_complete boolean not null default false,
  created_at          timestamptz not null default now()
);

alter table public.users enable row level security;

create policy "Users can read own row"
  on public.users for select
  using (auth.uid() = id);

create policy "Users can update own row"
  on public.users for update
  using (auth.uid() = id);

create policy "Users can insert own row"
  on public.users for insert
  with check (auth.uid() = id);

-- ─────────────────────────────────────────
-- DAILY INPUTS
-- ─────────────────────────────────────────
create table if not exists public.daily_inputs (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references public.users(id) on delete cascade,
  date                 date not null,
  hrv_ms               numeric,
  resting_hr_bpm       numeric,
  respiratory_rate_rpm numeric,
  sleep_duration_hrs   numeric,
  sleep_efficiency_pct numeric,
  steps                integer,
  active_minutes       integer,
  distance_km          numeric,
  data_quality_flags   jsonb not null default '{}',
  source_version       text not null default '1.0',
  created_at           timestamptz not null default now(),
  unique(user_id, date)
);

alter table public.daily_inputs enable row level security;

create policy "Users can read own inputs"
  on public.daily_inputs for select
  using (auth.uid() = user_id);

create policy "Service role can write inputs"
  on public.daily_inputs for all
  using (true)
  with check (true);

-- ─────────────────────────────────────────
-- BASELINES
-- ─────────────────────────────────────────
create table if not exists public.baselines (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.users(id) on delete cascade,
  computed_on             date not null,
  hrv_avg                 numeric,
  hrv_sd                  numeric,
  resting_hr_avg          numeric,
  resting_hr_sd           numeric,
  respiratory_rate_avg    numeric,
  sleep_duration_avg      numeric,
  sleep_efficiency_avg    numeric,
  steps_avg               numeric,
  active_minutes_avg      numeric,
  window_days             integer not null default 7,
  domain_version          text not null default '1.1',
  created_at              timestamptz not null default now(),
  unique(user_id, computed_on)
);

alter table public.baselines enable row level security;

create policy "Users can read own baselines"
  on public.baselines for select
  using (auth.uid() = user_id);

create policy "Service role can write baselines"
  on public.baselines for all
  using (true)
  with check (true);

-- ─────────────────────────────────────────
-- DAILY SCORES
-- ─────────────────────────────────────────
create table if not exists public.daily_scores (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references public.users(id) on delete cascade,
  date                     date not null,
  chronos_score            numeric,
  score_band               text,
  health_score             numeric,
  risk_score               numeric,
  alpha                    numeric,
  d1_autonomic             numeric,
  d2_sleep                 numeric,
  d3_activity              numeric,
  d4_stress                numeric,
  d5_allostatic            numeric,
  driver_1                 text,
  driver_2                 text,
  delta_override_triggered boolean not null default false,
  fail_state               text,
  is_provisional           boolean not null default false,
  domain_version           text not null default '1.1',
  created_at               timestamptz not null default now(),
  unique(user_id, date)
);

alter table public.daily_scores enable row level security;

create policy "Users can read own scores"
  on public.daily_scores for select
  using (auth.uid() = user_id);

create policy "Service role can write scores"
  on public.daily_scores for all
  using (true)
  with check (true);

-- ─────────────────────────────────────────
-- EXPLANATIONS
-- ─────────────────────────────────────────
create table if not exists public.explanations (
  id               uuid primary key default gen_random_uuid(),
  score_id         uuid not null references public.daily_scores(id) on delete cascade,
  user_id          uuid not null references public.users(id) on delete cascade,
  date             date not null,
  explanation_text text,
  nudge_text       text,
  prompt_version   text not null default '1.0',
  model_version    text not null default 'claude-sonnet-4-20250514',
  created_at       timestamptz not null default now(),
  unique(score_id)
);

alter table public.explanations enable row level security;

create policy "Users can read own explanations"
  on public.explanations for select
  using (auth.uid() = user_id);

create policy "Service role can write explanations"
  on public.explanations for all
  using (true)
  with check (true);

-- ─────────────────────────────────────────
-- FEEDBACK
-- ─────────────────────────────────────────
create table if not exists public.feedback (
  id             uuid primary key default gen_random_uuid(),
  score_id       uuid not null references public.daily_scores(id) on delete cascade,
  user_id        uuid not null references public.users(id) on delete cascade,
  date           date not null,
  felt_accurate  boolean not null,
  note           text,
  created_at     timestamptz not null default now(),
  unique(score_id, user_id)
);

alter table public.feedback enable row level security;

create policy "Users can read own feedback"
  on public.feedback for select
  using (auth.uid() = user_id);

create policy "Users can insert own feedback"
  on public.feedback for insert
  with check (auth.uid() = user_id);

-- ─────────────────────────────────────────
-- ADMIN: user_roles
-- ─────────────────────────────────────────
create table if not exists public.user_roles (
  user_id uuid primary key references public.users(id) on delete cascade,
  role    text not null default 'user' -- 'user' | 'admin'
);

alter table public.user_roles enable row level security;

create policy "Admins can read all roles"
  on public.user_roles for select
  using (
    exists (
      select 1 from public.user_roles r
      where r.user_id = auth.uid() and r.role = 'admin'
    )
  );

-- ─────────────────────────────────────────
-- HELPFUL INDEXES
-- ─────────────────────────────────────────
create index if not exists daily_inputs_user_date   on public.daily_inputs(user_id, date desc);
create index if not exists daily_scores_user_date   on public.daily_scores(user_id, date desc);
create index if not exists baselines_user_date      on public.baselines(user_id, computed_on desc);
create index if not exists explanations_user_date   on public.explanations(user_id, date desc);
create index if not exists feedback_user_date       on public.feedback(user_id, date desc);
