-- OI-004 · p10/p90 Shadow Scoring Mode
-- Migration: shadow_scoring_p1090
-- Shadow version: shadow-v0.1
-- Spec: MBI_Chronos_OI004_ShadowMode_SpecHandoff_v1_0.docx
--
-- INVARIANT: This table is the sole write target for the shadow layer.
-- daily_scores and all production tables are untouched by this migration.

-- ── Table ────────────────────────────────────────────────────────────────────

create table if not exists public.shadow_scoring_p1090 (
  id             uuid         not null default gen_random_uuid(),
  user_id        uuid         not null references auth.users(id),
  score_date     date         not null,
  domain_version text         not null,
  trust_state    text         not null,
  computed_at    timestamptz  not null default now(),
  metric_zones   jsonb        not null,
  shadow_version text         not null,
  constraint pk_shadow_scoring_p1090 primary key (id),
  -- One shadow row per user per day. On conflict: upsert (matches production pattern).
  constraint uq_shadow_scoring_p1090_user_date unique (user_id, score_date)
);

comment on table public.shadow_scoring_p1090 is
  'OI-004 shadow scoring output. p10/p90 zone classifications run in parallel '
  'with production p20/p80 scoring. Read-only for post-beta analysis. '
  'Does not influence any production score, flag, driver, or narrative.';

-- ── Index ────────────────────────────────────────────────────────────────────

create index if not exists idx_shadow_scoring_p1090_user_date
  on public.shadow_scoring_p1090 (user_id, score_date desc);

-- ── Row-Level Security ───────────────────────────────────────────────────────

alter table public.shadow_scoring_p1090 enable row level security;

-- Authenticated users can read only their own rows
create policy "shadow_read_own_rows"
  on public.shadow_scoring_p1090
  for select
  to authenticated
  using (auth.uid() = user_id);

-- Service role has full write access; anon key cannot read or write
create policy "shadow_service_write"
  on public.shadow_scoring_p1090
  for all
  to service_role
  using (true)
  with check (true);
