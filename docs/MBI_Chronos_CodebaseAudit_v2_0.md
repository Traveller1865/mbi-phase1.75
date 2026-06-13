# MBI · Chronos — Codebase State Audit v2.0

**Date:** 2026-06-13 · **Scope:** Full audit against the Phase 1.75 clean-slate baseline (commit `a97d187`, repo `mbi-phase1.75`).
**Method:** Read-only inspection + runtime diagnostics surfaced during the key-rotation work this session. No findings below were inferred without evidence.

> This supersedes the partial state-map produced earlier in the session. The risk center of gravity is the **runtime/operational** layer (§3), not static hygiene (§4).

---

## 1. Version-control state (post-migration)

- **`mbi-phase1.75`** (`origin`) — new clean-slate home. `main` = single root commit, no history, no secrets/build artifacts. Refreshed `.gitignore` excludes `.claude/`, `Secrets.swift`, `.mcp.json`, signing assets, build output, macOS/Supabase temp, and raw data dumps.
- **`mbi-phase1.5`** (`archive-1.5`) — frozen integrity copy. Retains full history **including the exposed `service_role` key** (commit `2198c61`).
- Score Card work (`1da9ca0`) lives only on the 1.5 archive branch `claude/xenodochial-goldstine-99ae1c`.

---

## 2. Security findings

| # | Finding | Status |
|---|---------|--------|
| S1 | **`service_role` JWT (full admin) committed in 1.5 history** (`2198c61`), repo was public. Same project (`sjhysadnpswrcpmezmoc`) still in use. | Kept out of 1.75. **Still on 1.5 archive — revoke legacy key and/or privatize/delete 1.5.** |
| S2 | **`.claude/settings.local.json` held the service_role JWT, anon JWT, and a plaintext test-account credential** in the permission allowlist (values redacted from this report). | Now gitignored (not committed). **Rotate that test password.** |
| S3 | Anon/publishable key hardcoded in `Config.swift`. | Fixed — now proxies to gitignored `Secrets.swift`. |
| S4 | Backend ran entirely on the exposed legacy `service_role` key via auto-injected `SUPABASE_SERVICE_ROLE_KEY`. | Migrated to custom `SB_SECRET_KEY`/`SB_PUBLISHABLE_KEY` env vars (fallback pattern); deployed. Revoke legacy once confirmed stable. |

---

## 3. Runtime / operational findings (highest priority)

| # | Finding | Evidence | Status |
|---|---------|----------|--------|
| R1 | **Daily sync broken ~1 week.** Orchestrator called `ingest`/`score` with the service key, but those run `verifyCallerOwnsUser` (expects a user JWT) → 401 → orchestrator 500. | `score-orchestrator` 500s; direct `score` probe with service key returned 401; escalation log "3 failures in 7 days". | **Fixed** — `auth.ts` now trusts service-key callers (`isTrustedServiceCaller`). Deployed. Verify a real sync produces a fresh score. |
| R2 | **Silent multi-day ingestion gap.** Backfill only fills *historical* days (stops at yesterday); the "today" path was failing (R1), so 12–13 never ingested. `daily_inputs` ended at June 11. | `daily_inputs`/`daily_scores` queries; backfill logs. | Partially resolved (R1 fix + backfill caught June 12). Today still depends on a working sync. |
| R3 | **Stale-score display.** Today card renders the newest *available* score as if it's today's, with no staleness indicator. User who slept 3h39m was shown "92 / Thriving / system at its best" (actually Thursday's score). | Screenshot vs `daily_scores` (no June 12/13 rows). | **OPEN** — needs a staleness guard/indicator. (Beta-readiness + trust erosion.) |
| R4 | **`compute-outcome-windows` cron never scheduled.** GUC `app.service_role_key` never existed; `current_setting` (no missing-ok) would abort. Job absent from `cron.job`. Learning/outcome-windows table likely empty. | `pg_db_role_setting`, `cron.job` queries. | **Fixed** — recreated via Supabase Vault. **Migration file out of sync — update to Vault version.** |
| R5 | **Swallowed sync errors.** `SyncCoordinator` caught errors, mapped to friendly UI text, never logged the underlying error — failures undiagnosable. | Required a code change just to see the cause. | Diagnostic logging added. Consider structured error reporting. |
| R6 | **`driver_2` null on 43 high-scoring rows** → iOS decoder crash on dashboard load. | `daily_scores` query; decoder error. | **Fixed** — `drivers.ts` fallback + DB patch; deployed. |

---

## 4. Static / structural findings

| # | Finding | Detail |
|---|---------|--------|
| T1 | **Triplicated backend code.** `backend/supabase/` (live, deployed), top-level `supabase/` (stale — `functions/horizon-classify`, `migrations/`), and `packages/domain/` (orphaned domain logic). | `packages/domain/*` all **differ** from live `backend/.../_shared/domain/*`. Tests (`packages/domain/__tests__`) run against the stale copy. **Decide canonical; delete the others.** |
| T2 | **Three score-band systems.** Backend `ScoreBand` (5-tier, Thriving 80+/Recovering 70–79), iOS `Models.swift ScoreBand` (legacy 5-tier), iOS `ScoreDisplayBand` (6-tier, Strong 75–89). A score of 78 = backend "Recovering" but card "Strong." | Unify; have iOS derive from backend, not re-encode thresholds. |
| T3 | **Dead code / stubs.** `ScoreCardSparkline` unreferenced; `bg_*` image stubs point to no files. | Inventory only. |
| T4 | **Xcode project model.** `project.yml` = XcodeGen ⇒ Swift sources are source of truth, `.xcodeproj` regenerable. Per-user Xcode state was tracked (now gitignored). | Consider not tracking `.xcodeproj`. |
| T5 | **AppleDouble/junk** (52 `._*`, `.temp/`, xcuserstate) were tracked on 1.5. | Excluded from 1.75 baseline. |

---

## 5. Prioritized open actions

1. **Revoke the legacy `service_role`/anon keys** once the new-key backend is confirmed stable (verify a real app sync scores today). Closes S1/S4.
2. **Privatize or scrub the 1.5 archive** (still holds the live key in history). 
3. **Rotate the test-account password** (S2).
4. **Stale-score guard** (R3) — don't present an old score as today's.
5. **Scoring-window design** — decide how last night's sleep attributes to "today" (the near-real-time vision). Scoring-correctness lens.
6. **Update `compute_outcome_windows_cron.sql`** migration to the Vault version (R4) so repo matches infra.
7. **Resolve triplication** (T1) and **unify band systems** (T2).
8. **Score Card disposition** — three variants exist; pick canonical.

---

## 6. Fixed this session
`drivers.ts` (driver_2), `auth.ts` (service-auth + key migration), `Config.swift`/`Secrets.swift` (key out of git), 13 functions (custom env vars), `SyncCoordinator` (error logging), `.gitignore` (comprehensive), Vault-based cron, clean-slate migration to 1.75.
