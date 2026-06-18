# Contributing — MBI Chronos backend conventions

These conventions exist because backend code was once duplicated across three paths
(`backend/supabase`, a top-level `supabase/`, and `packages/domain`), which diverged and
let bugs ship. The consolidation (Canonical Backend Architecture v1.2) removed the copies;
these rules keep them from coming back.

## Structural convention (v1.2 §6.1)
- **Domain logic lives only in `backend/supabase/functions/_shared/domain/`.** Written nowhere else.
- **Import domain logic from `_shared/domain/index.ts`** — the public surface. Don't reach into individual files from consumers.
- **No Edge-Function concerns in domain logic** — no env reads, no Supabase client, no HTTP, no Deno globals. Keep `_shared/domain` pure (package-grade boundaries) so a future Phase 3 package extraction is a clean lift.
- **Deploys run only from `backend/supabase`.** No other deploy root may exist or be created.
- **Migrations live only in `backend/supabase/migrations/`.** No second migrations directory.
- **No alternate `supabase/` path and no `packages/domain` copy** may be created anywhere.

## Guardrails
- `npm run check:structure` enforces the above (single deploy root, no top-level `supabase/`, no `packages/domain`, one canonical domain dir). Run it before pushing structural changes.
- Two-layer tests: `npm run test:domain` (unit, against `_shared/domain`) and `npm run test:integration` (smoke, against deployed functions).

## Tests trace to documented rules
Unit-test expected values must trace to the Logic Registry / scoring spec / Non-Negotiables —
never mirrored from current code output (that would make a test unable to fail when the code is wrong).
The numeric deviation-threshold tests are a follow-on item, gated on a consolidated v1.5 Logic
Registry being committed to the repo (see `backend/supabase/functions/_shared/domain/__tests__/README.md`).

## Secrets
Never hardcode keys. iOS → `Secrets.swift` (gitignored); Edge Functions → `SB_SECRET_KEY`/`SB_PUBLISHABLE_KEY`
env vars; cron/SQL → Supabase Vault. No key inlined in a cron command, migration, or function.
