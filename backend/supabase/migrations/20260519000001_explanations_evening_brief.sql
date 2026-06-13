-- backend/supabase/migrations/20260519000001_explanations_evening_brief.sql
-- Add evening brief columns to explanations table.
-- morning brief: explanation_text / nudge_text (existing — unchanged)
-- evening brief: evening_explanation_text / evening_nudge_text (new, nullable)
-- Both sessions upsert on conflict score_id to the same row.

alter table public.explanations
  add column if not exists evening_explanation_text text,
  add column if not exists evening_nudge_text        text;
