-- MBI Phase 1.5 — trend_aggregates Table
-- Migration: Sprint 2 · Epic 1
-- Run via: supabase db push

-- ─────────────────────────────────────────
-- TREND AGGREGATES
-- Pre-computed weekly and monthly rollups per user per metric.
-- The iOS client never aggregates raw daily_scores rows.
-- All window data is fetched from this table as a lightweight payload.
-- ─────────────────────────────────────────

create table if not exists public.trend_aggregates (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.users(id) on delete cascade,
  window_type             text not null,            -- 'weekly' | 'monthly'
  window_start            date not null,
  window_end              date not null,

  -- Chronos composite
  chronos_avg             numeric,
  chronos_min             numeric,
  chronos_max             numeric,
  trend_direction         text,                     -- 'improving' | 'stable' | 'declining'
  days_in_window          integer not null default 0,

  -- Per-metric averages (mirrors daily_inputs columns)
  hrv_avg                 numeric,
  resting_hr_avg          numeric,
  respiratory_rate_avg    numeric,
  sleep_duration_avg      numeric,
  sleep_efficiency_avg    numeric,
  steps_avg               numeric,
  active_minutes_avg      numeric,

  -- Top flagged drivers across the window (most frequent driver_1/driver_2 appearances)
  top_driver_1            text,
  top_driver_2            text,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  unique(user_id, window_type, window_start)
);

alter table public.trend_aggregates enable row level security;

create policy "Users can read own trend aggregates"
  on public.trend_aggregates for select
  using (auth.uid() = user_id);

create policy "Service role can write trend aggregates"
  on public.trend_aggregates for all
  using (true)
  with check (true);

-- ─────────────────────────────────────────
-- INDEXES
-- ─────────────────────────────────────────
create index if not exists trend_aggregates_user_type_start
  on public.trend_aggregates(user_id, window_type, window_start desc);