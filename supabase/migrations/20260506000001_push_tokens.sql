-- =============================================================================
-- MBI Phase 2 — Push Token Storage
-- Migration: 20260506000001_push_tokens.sql
-- =============================================================================
--
-- This migration:
--   1. Creates push_tokens — stores APNs device token per user per device.
--      Written by iOS on every launch after token is received.
--      Upserted on (user_id, device_id) — safe to call repeatedly.
--      Ready for future remote push delivery from backend.
--
-- RLS: authenticated user can read/write only own rows.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PUSH TOKENS
-- Keyed on (user_id, device_id) where device_id is IDFV from UIDevice.
-- Token rotates occasionally — upsert keeps the latest value per device.
-- platform column reserved for future Android support.
-- -----------------------------------------------------------------------------

create table if not exists public.push_tokens (
    id          uuid        primary key default gen_random_uuid(),
    user_id     uuid        not null references auth.users(id) on delete cascade,
    device_id   text        not null,   -- IDFV (UIDevice.current.identifierForVendor)
    token       text        not null,   -- hex-encoded APNs token
    platform    text        not null default 'ios',
    updated_at  timestamptz not null default now(),
    created_at  timestamptz not null default now(),

    unique (user_id, device_id)
);

comment on table public.push_tokens is
    'APNs device token per user per device. Upserted on every app launch after permission granted.';

comment on column public.push_tokens.device_id is
    'UIDevice.current.identifierForVendor UUID string. Identifies a specific app-device pair.';

comment on column public.push_tokens.token is
    'Hex-encoded APNs device token. Rotates occasionally — upsert on (user_id, device_id) keeps latest.';

alter table public.push_tokens enable row level security;

create policy "Users read own push tokens"
    on public.push_tokens for select
    using (auth.uid() = user_id);

create policy "Users insert own push tokens"
    on public.push_tokens for insert
    with check (auth.uid() = user_id);

create policy "Users update own push tokens"
    on public.push_tokens for update
    using (auth.uid() = user_id);

create index if not exists idx_push_tokens_user
    on public.push_tokens (user_id);
