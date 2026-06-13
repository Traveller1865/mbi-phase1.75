-- =============================================================================
-- MBI Phase 2 Sprint 8 — Terra Provider Storage
-- Migration: 20260507000002_terra_providers.sql
--
-- Adds terra_providers jsonb column to public.users.
--
-- Phase 2: UserDefaults cache in TerraService is the primary store.
-- This column is the foundation for cross-device persistence in Phase 3,
-- when TerraService.load/save will be wired to read/write this column.
--
-- The existing "Users can update own row" policy on public.users already
-- covers this column — no new RLS policy needed.
-- =============================================================================

alter table public.users
    add column if not exists terra_providers jsonb not null default '[]'::jsonb;

comment on column public.users.terra_providers is
    'Array of connected Terra provider IDs e.g. ["oura","garmin"]. Written by TerraService on connect/disconnect. Phase 2: supplemented by UserDefaults cache. Phase 3: primary store.';

-- GIN index supports future queries: WHERE terra_providers @> ''["oura"]''
create index if not exists idx_users_terra_providers
    on public.users using gin (terra_providers);
