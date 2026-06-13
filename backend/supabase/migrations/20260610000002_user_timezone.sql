-- Pipeline Performance Architecture
-- Migration: user timezone storage
-- Spec: MBI_Chronos_BuildHandoff_PipelinePerformance_v1_0.docx §5.2
--
-- Stores IANA timezone string (e.g. 'America/Chicago') for each user.
-- Required by the 5pm local fallback scheduler.
-- DO NOT store as UTC offset integer — offsets do not handle DST.

alter table public.users
  add column if not exists timezone text;

comment on column public.users.timezone is
  'IANA timezone string (e.g. America/Chicago). Captured at app launch. '
  'Used by fallback-orchestrator for per-user 5pm local scheduled computation. '
  'Null for legacy accounts — fallback defaults to UTC-6 (CST).';
