# SQL Pending — Run After Full Feature Ship

> **Policy:** No migrations run until all Phase 2 features are complete and ready for test.
> Apply these in order in the Supabase SQL editor (project: `sjhysadnpswrcpmezmoc`).

---

## Migration 1 — Phase 2 Horizon Ontology Engine + Feature Waitlist
**File:** `supabase/migrations/20260505000001_phase2_horizon_ontology.sql`
**Status:** Written, not applied

### What it creates
| Table | Purpose |
|---|---|
| `pathway_classifications` | Replaces `horizon_signals` as Ontology Engine output. One row per user × date × pathway. |
| `metric_node_map` | Maps raw metric keys (e.g. `hrv_ms`) to classification nodes. Seeded with 8 entries. |
| `node_activation_rules` | Deterministic threshold rules per node. Seeded with 7 entries. |
| `node_activation_log` | Per-user audit log of node firing events per day. |
| `user_feature_waitlist` | Feature interest capture from Escalate page Notify me toggles. |

### Post-apply checklist
- [ ] Verify `pathway_classifications` RLS: authenticated user can only read own rows
- [ ] Verify `user_feature_waitlist` insert succeeds from iOS (check network tab)
- [ ] Confirm `horizon_signals` still exists and is not dropped (it's deprecated, not removed yet)
- [ ] Confirm seed data in `metric_node_map` and `node_activation_rules` is present

---

## Pending: horizon_signals deprecation DROP
**Do NOT run until confirmed:**
- iOS client `fetchHorizonSignals` has been migrated to query `pathway_classifications`
- `narrate-horizon` Edge Function writes to `pathway_classifications` instead of `horizon_signals`
- At least one full classification cycle has completed successfully on `pathway_classifications`

**Drop statement (run only after above is confirmed):**
```sql
drop table if exists public.horizon_signals;
```

---

## ✅ DONE (Sprint 6) — pathway_classifications → fetchHorizonSignals iOS migration
`SupabaseService.fetchHorizonSignals` now queries `pathway_classifications`.
Column names are identical; no parse-logic changes required.

**horizon_signals DROP — now unblocked. Prerequisites met:**
- [x] iOS `fetchHorizonSignals` queries `pathway_classifications` (Sprint 6)
- [x] `horizon-classify` Edge Function writes to `pathway_classifications` (Sprint 6)
- [x] `triggerHorizonClassify` wired into `SyncCoordinator.runDailySync` (Sprint 6)
- [ ] At least one full classification cycle confirmed successful in production

**Run after first successful production classification cycle:**
```sql
drop table if exists public.horizon_signals;
```

---

## Migration 2 — Push Token Storage
**File:** `supabase/migrations/20260506000001_push_tokens.sql`
**Status:** Written, not applied

### What it creates
| Table | Purpose |
|---|---|
| `push_tokens` | APNs device token per user per device. Upserted on each launch. |

### SQL
```sql
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
```

### Post-apply checklist
- [ ] Verify RLS: authenticated user can only read/write own rows
- [ ] Confirm upsert (`resolution=merge-duplicates`) succeeds from iOS network tab
- [ ] Verify token appears in table after first launch post-permission grant

---

---

## Migration 3 — Sprint 7: Engagement Layer
**Status:** Written, not applied

### What it creates

| Table | Purpose |
|---|---|
| `logged_workouts` | Manual workout entries (type, duration). Feeds D3 Active Minutes. |
| `daily_checkins` | Daily mood/energy/stress 1–5 ratings. Feeds D4 Inferred Stress. |

### SQL
```sql
-- logged_workouts
create table if not exists public.logged_workouts (
    id               uuid        primary key default gen_random_uuid(),
    user_id          uuid        not null references auth.users(id) on delete cascade,
    date             date        not null,
    workout_type     text        not null,   -- "Strength" | "Cardio" | "Yoga" | "HIIT" | "Other"
    duration_minutes integer     not null,
    logged_at        timestamptz not null default now()
);
alter table public.logged_workouts enable row level security;
create policy "Users manage own workouts" on public.logged_workouts
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create index if not exists idx_logged_workouts_user_date
    on public.logged_workouts (user_id, date desc);

-- daily_checkins
create table if not exists public.daily_checkins (
    id         uuid        primary key default gen_random_uuid(),
    user_id    uuid        not null references auth.users(id) on delete cascade,
    date       date        not null,
    mood       smallint    not null check (mood between 1 and 5),
    energy     smallint    not null check (energy between 1 and 5),
    stress     smallint    not null check (stress between 1 and 5),
    created_at timestamptz not null default now(),

    unique (user_id, date)
);
alter table public.daily_checkins enable row level security;
create policy "Users manage own checkins" on public.daily_checkins
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
```

### Post-apply checklist
- [ ] Verify `logged_workouts` insert succeeds from iOS WorkoutLogSheet
- [ ] Verify `daily_checkins` upsert (`merge-duplicates`) succeeds from iOS DailyCheckInCard
- [ ] Confirm ingest Edge Function picks up `logged_workouts.duration_minutes` for `active_minutes` augmentation (Phase 2+ wiring)

---

---

## Migration 4 — Sprint 8: Terra Provider Storage
**Status:** Written, not applied

### What it changes
Adds `terra_providers` column to `public.users` to persist Terra-connected device IDs server-side.
Currently `TerraService` caches in `UserDefaults` per user — this migration enables cross-device persistence.

### SQL
```sql
-- Add terra_providers column to users table
alter table public.users
    add column if not exists terra_providers jsonb not null default '[]'::jsonb;

-- Optional: index for querying which providers a user has connected
create index if not exists idx_users_terra_providers
    on public.users using gin (terra_providers);
```

### Usage pattern from iOS (TerraService)
```
PATCH /rest/v1/users?id=eq.{userId}
Content-Type: application/json
Prefer: return=minimal
{ "terra_providers": ["oura", "garmin"] }
```

### Post-apply checklist
- [ ] Update `TerraService.load(userId:)` to fetch `terra_providers` column from `users` table instead of UserDefaults
- [ ] Update `TerraService.saveToCache(userId:)` to PATCH `terra_providers` in addition to UserDefaults
- [ ] Verify RLS: user can only update own `terra_providers` (covered by existing `users` RLS policy)
- [ ] Test connect → disconnect cycle confirms column updates in Supabase dashboard

---

---

## Migration 5 — Beta Readiness: app_events + admin_devices
**Status:** Written, not applied
**Priority:** Apply before first external beta build

### What it creates

| Table | Purpose |
|---|---|
| `app_events` | Custom analytics — one row per tracked event. No third-party SDKs. |
| `admin_devices` | Founder push token registry for Horizon silent escalation alerts. |

### SQL

```sql
-- ── app_events ────────────────────────────────────────────────────────────────
-- Custom privacy-first analytics table (P3.2).
-- Users can INSERT their own rows only. No client read — analytics are write-only from iOS.
-- Data is queried by the founder directly in the Supabase dashboard or via Edge Functions.

create table if not exists public.app_events (
    id          uuid        primary key default gen_random_uuid(),
    user_id     uuid        not null references auth.users(id) on delete cascade,
    event_name  text        not null,
    properties  jsonb       not null default '{}'::jsonb,
    app_version text,
    os_version  text,
    created_at  timestamptz not null default now()
);

alter table public.app_events enable row level security;

create policy "users can insert own events"
    on public.app_events for insert
    with check (auth.uid() = user_id);

-- No SELECT policy — analytics are write-only from client
-- Founder queries directly using service role key

create index if not exists idx_app_events_user_created
    on public.app_events (user_id, created_at desc);

create index if not exists idx_app_events_name
    on public.app_events (event_name, created_at desc);


-- ── admin_devices ─────────────────────────────────────────────────────────────
-- Stores founder push tokens for Horizon escalation silent alerts (P4.3).
-- No client RLS — table is backend-only, accessed only via service role.
-- iOS registers to this table only if the authenticated user is the founder (admin check).

create table if not exists public.admin_devices (
    id            uuid        primary key default gen_random_uuid(),
    admin_user_id uuid        not null references auth.users(id) on delete cascade,
    push_token    text        not null,
    platform      text        not null default 'ios',
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    unique (admin_user_id, push_token)
);

-- RLS disabled — service role only; no client should ever read/write this
alter table public.admin_devices disable row level security;
```

### Post-apply checklist
- [ ] Confirm `app_events` insert succeeds from iOS (check Supabase Table Editor after first app_open)
- [ ] Confirm `app_events` select returns 0 rows when queried with anon key (write-only RLS working)
- [ ] Confirm `admin_devices` is not accessible via client-side queries
- [ ] Verify indexes exist (`idx_app_events_user_created`, `idx_app_events_name`)

---

## Migration 6 — Horizon Escalation Table (P4.1 / P4.2)
**Status:** Written, not applied
**Priority:** Apply before Horizon system goes live

### What it creates

| Table | Purpose |
|---|---|
| `horizon_escalations` | Audit log of Horizon alerts fired when chronos_score < 65 for 3 consecutive days |

### SQL

```sql
-- ── horizon_escalations ───────────────────────────────────────────────────────
-- Written to by the score Edge Function after P4.1/P4.2 detection logic runs.
-- Founder queries directly using service role key.
-- push_sent starts false; set to true once APNs sender (P4.3) is wired.

create table if not exists public.horizon_escalations (
    id             uuid        primary key default gen_random_uuid(),
    user_id        uuid        not null references auth.users(id) on delete cascade,
    triggered_date date        not null,
    score_day1     numeric,           -- oldest of 3 consecutive days
    score_day2     numeric,
    score_day3     numeric,           -- most recent (today)
    streak_length  integer     not null default 3,
    push_sent      boolean     not null default false,
    created_at     timestamptz not null default now()
);

-- Service role write only — no client access
-- RLS disabled intentionally: only the score Edge Function writes here
alter table public.horizon_escalations disable row level security;

create index if not exists idx_horizon_escalations_user
    on public.horizon_escalations (user_id, triggered_date desc);
```

### P4.3: Silent Founder Push Setup
Once this table is confirmed working, add APNs credentials to Supabase secrets:
```
APNS_KEY_ID        = <10-char Key ID from developer.apple.com>
APNS_TEAM_ID       = <10-char Team ID>
APNS_KEY_P8        = <contents of .p8 auth key file>
APNS_FOUNDER_TOKEN = <hex-encoded APNs device token from founder's device>
```
Then replace the `console.log` in `score/index.ts` `checkHorizonEscalation()` with a live APNs call.

### Post-apply checklist
- [ ] Trigger escalation manually: run score for a test user with 3 days of scores < 65
- [ ] Confirm row inserted in `horizon_escalations` with correct score values
- [ ] Confirm `push_sent = false` (APNs not yet wired)
- [ ] Confirm deduplication: second score trigger within 7 days does not insert a second row

---

## Notes
- All tables in Migration 1 have RLS enabled
- `pathway_classifications` and `node_activation_log` use service-role writes (Edge Function) — no iOS insert policy needed
- `user_feature_waitlist` uses `resolution=ignore-duplicates` on POST — safe to call multiple times
- `fetchMomentumScores` queries `daily_scores` with `d1_autonomic, d2_sleep, d3_activity` columns — verify these columns exist in the schema before testing the Momentum page
- `push_tokens` uses `resolution=merge-duplicates` on POST — keyed on `(user_id, device_id)`, safe to call on every launch
- Notification preferences (morning_brief_enabled, horizon_alert_enabled, streak_reminder_enabled, brief_delivery_hour, brief_delivery_minute) are stored client-side in `UserDefaults` via `@AppStorage` — no Supabase columns required for Phase 2
- `terra_providers` (Migration 4): UserDefaults cache is sufficient for Phase 2. Supabase column enables cross-device sync in Phase 3.
