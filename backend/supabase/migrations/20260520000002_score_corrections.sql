-- Migration: 20260520000002_score_corrections
-- Step 8: Score Correction Flow.
-- Original score rows are never mutated — corrections are additive records here.

create table public.score_corrections (
  id                uuid        primary key default gen_random_uuid(),
  user_id           uuid        not null references public.users(id) on delete cascade,
  date              date        not null,
  signal_name       text        not null,
  original_value    numeric     null,
  corrected_value   numeric     not null,
  correction_type   text        not null default 'user_edit',
  submitted_at      timestamptz not null default now(),
  window_expires_at timestamptz not null,
  is_applied        boolean     not null default false,
  dismissed         boolean     not null default false,
  dismissed_at      timestamptz null,
  escalation_sent   boolean     not null default false,
  constraint score_corrections_type_check
    check (correction_type in ('user_edit', 'missing_acknowledged'))
);

create index idx_score_corrections_user_date
  on public.score_corrections(user_id, date desc);

create index idx_score_corrections_signal
  on public.score_corrections(user_id, signal_name, submitted_at desc);

alter table public.score_corrections enable row level security;

create policy "Users can insert their own corrections"
  on public.score_corrections for insert
  with check (auth.uid() = user_id);

create policy "Users can view their own corrections"
  on public.score_corrections for select
  using (auth.uid() = user_id);

create policy "Users can update their own corrections"
  on public.score_corrections for update
  using (auth.uid() = user_id);
