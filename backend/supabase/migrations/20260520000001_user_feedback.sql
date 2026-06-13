-- Migration: 20260520000001_user_feedback
-- Creates user_feedback table for Step 7 three-dimension feedback system.
-- Replaces the binary felt_accurate model in the legacy `feedback` table.
-- Legacy table is preserved — not dropped.

create table if not exists public.user_feedback (
    id              uuid primary key default gen_random_uuid(),
    score_id        uuid not null references public.daily_scores(id) on delete cascade,
    user_id         uuid not null references public.users(id) on delete cascade,
    date            text not null,
    score_accuracy  text check (score_accuracy  in ('accurate', 'somewhat', 'off')),
    brief_quality   text check (brief_quality   in ('aligned', 'somewhat', 'missed')),
    nudge_relevance text check (nudge_relevance in ('helpful', 'somewhat', 'not_relevant', 'not_applicable')),
    note_text       text,
    submitted_at    timestamptz not null default now(),
    created_at      timestamptz not null default now()
);

-- Constraint: at least one dimension flag must be present
alter table public.user_feedback
    add constraint user_feedback_at_least_one_flag check (
        score_accuracy is not null
        or brief_quality is not null
        or nudge_relevance is not null
    );

alter table public.user_feedback enable row level security;

create policy "Users can insert their own feedback"
    on public.user_feedback for insert
    with check (auth.uid() = user_id);

create policy "Users can view their own feedback"
    on public.user_feedback for select
    using (auth.uid() = user_id);

create index user_feedback_user_date_idx
    on public.user_feedback (user_id, date desc);
