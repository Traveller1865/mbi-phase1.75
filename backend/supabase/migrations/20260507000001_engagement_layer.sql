-- =============================================================================
-- MBI Phase 2 Sprint 7 — Engagement Layer
-- Migration: 20260507000001_engagement_layer.sql
--
-- Creates:
--   logged_workouts  — manual workout entries from iOS WorkoutLogSheet
--   daily_checkins   — daily mood/energy/stress ratings from iOS DailyCheckInCard
--
-- Both tables use RLS. Policy: users can read/write only their own rows.
-- logged_workouts uses a simple insert (multiple entries per day allowed).
-- daily_checkins uses unique(user_id, date) — iOS upserts via merge-duplicates.
-- =============================================================================

-- LOGGED WORKOUTS
create table if not exists public.logged_workouts (
    id               uuid        primary key default gen_random_uuid(),
    user_id          uuid        not null references auth.users(id) on delete cascade,
    date             date        not null,
    workout_type     text        not null
                     check (workout_type in ('Strength', 'Cardio', 'Yoga', 'HIIT', 'Other')),
    duration_minutes integer     not null check (duration_minutes > 0),
    logged_at        timestamptz not null default now()
);

comment on table public.logged_workouts is
    'Manual workout log from iOS WorkoutLogSheet. Feeds D3 Active Minutes augmentation (Phase 3 wiring).';
comment on column public.logged_workouts.workout_type is
    'Values: Strength | Cardio | Yoga | HIIT | Other. Matches iOS WorkoutLogSheet picker.';
comment on column public.logged_workouts.duration_minutes is
    'Workout duration in minutes. iOS slider steps: 15, 20, 30, 45, 60, 75, 90, 120.';

alter table public.logged_workouts enable row level security;

create policy "Users manage own workouts"
    on public.logged_workouts for all
    using  (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create index if not exists idx_logged_workouts_user_date
    on public.logged_workouts (user_id, date desc);


-- DAILY CHECKINS
create table if not exists public.daily_checkins (
    id         uuid        primary key default gen_random_uuid(),
    user_id    uuid        not null references auth.users(id) on delete cascade,
    date       date        not null,
    mood       smallint    not null check (mood between 1 and 5),
    energy     smallint    not null check (energy between 1 and 5),
    stress     smallint    not null check (stress between 1 and 5),
    created_at timestamptz not null default now(),

    unique (user_id, date)   -- one check-in per day; iOS upserts via Prefer: resolution=merge-duplicates
);

comment on table public.daily_checkins is
    'Daily self-reported mood/energy/stress from iOS DailyCheckInCard. One row per user per day.';
comment on column public.daily_checkins.mood is
    '1 = lowest (😔) through 5 = highest (😄).';
comment on column public.daily_checkins.energy is
    '1 = exhausted through 5 = energised.';
comment on column public.daily_checkins.stress is
    '1 = very stressed through 5 = very calm. Note: higher score = less stress.';

alter table public.daily_checkins enable row level security;

create policy "Users manage own checkins"
    on public.daily_checkins for all
    using  (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create index if not exists idx_daily_checkins_user_date
    on public.daily_checkins (user_id, date desc);
