# CLAUDE.md — Operating rules for Claude Code in this repo

## Canonical backend structure (Canonical Backend Architecture v1.2)
- **Domain logic lives in exactly one place:** `backend/supabase/functions/_shared/domain/`. There is no `packages/domain` and no second copy.
- **All consumers import domain logic from `_shared/domain/index.ts`** (the public surface) — not from individual files.
- **`backend/supabase` is the single deploy root** (the only `config.toml` in the repo). There is no top-level `supabase/`. Deploys run only from `backend/`.
- **Migrations live only in `backend/supabase/migrations/`.**
- Domain logic is **pure**: no env reads, no Supabase client, no HTTP, no Deno globals. Those belong in the Edge-Function wrappers, never in `_shared/domain`.

## Before modifying any backend code, report (v1.2 §6.4)
1. The intended files to modify.
2. Whether the change touches **domain logic** (must be in `_shared/domain`) or **Edge-Function wiring** (in the function directory).
3. Whether the change would introduce any **Edge-Function concern into domain logic** (forbidden — breaks package-grade boundaries).
4. Confirmation that **no second copy of domain logic** is being created anywhere.

## Testing
- `npm run test:domain` — unit tests against `_shared/domain` (the live code). Expected values trace to the Logic Registry / documented rules, never to code output.
- `npm run test:integration` — smoke tests against deployed functions (needs `PROJECT_URL` + `SB_SECRET_KEY` in env; skips cleanly without them).
- `npm run check:structure` — fails if the duplication/landmine classes reappear.

## Secrets
- Never hardcode keys/secrets. iOS → `Secrets.swift` (gitignored); Edge Functions → `SB_SECRET_KEY` / `SB_PUBLISHABLE_KEY` env; cron/SQL → Supabase Vault. Never inline a key in a cron command, migration, or function.

## Deferred to Phase 3 / Post-Beta (do not build pre-beta)
- Shared-package extraction + sync/import-map machinery (package-grade boundaries keep the future lift trivial).
- CI-based guardrail enforcement; Node/Lambda runtime migration.
