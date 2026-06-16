# MBI · Chronos — Backend Path Reconciliation Map v1.0

**Date:** 2026-06-15 · **Scope:** Phase A (worktree accounting) + Phase B (ghost-path diff). **Read-only** — nothing removed, merged, or moved. Resolves audit T1 (triplication).

---

## Phase A — Worktree Accounting

**Worktree:** `.claude/worktrees/xenodochial-goldstine-99ae1c` → branch `claude/xenodochial-goldstine-99ae1c` @ `1da9ca0` (May 18 "Score Card Step 1"). Clean at its commit (only ambient untracked `.agents/`, `.claude/`, `.codex/`, `.mcp.json`, `skills-lock.json`).

**Unique work stranded: NONE.** Every worktree-only item is either `._*` AppleDouble junk or one mis-named migration `20260427000000_trend_aggregates` (no `.sql`) that is **byte-identical** to the live `…_trend_aggregates.sql`.

**The worktree is massively stale:**
- 2 migrations vs the live tree's 30.
- `DashboardView.swift` 1543 lines vs live 2261 — the live tree **already contains** `ScoreDisplayBand`, `ChronosArcMeter`, `ScoreExplanationView`, superseding the worktree.
- Live has the real `bg_*.png` images; worktree has only empty `Contents.json` stubs.
- Live has files the worktree lacks: `AnalyticsService`, `BiometricAuthService`, `DoctorReportService`, `Helpers/`, `PrivacyInfo.xcprivacy`.

**Verdict: ✅ SAFE TO REMOVE.** Removal command (NOT run — Phase D + approval):
```
git worktree remove .claude/worktrees/xenodochial-goldstine-99ae1c
git branch -D claude/xenodochial-goldstine-99ae1c
```

---

## Phase B.1 — Live path (confirmed)

**`backend/supabase/` is the single live path** — has `config.toml`, linked project ref `sjhysadnpswrcpmezmoc`, all 18 deployed functions; Edge Functions import shared logic from its `functions/_shared/domain/`. Top-level `supabase/` has **no `config.toml`** (not a deploy root — though it *was* linked to the project; see landmine below).

---

## Phase B.2 — Ghost `supabase/` (top-level) vs live

Direction is uniform: **the ghost is older/stale. No built-but-never-deployed work is stranded.**

| File | Class | Finding |
|---|---|---|
| `functions/horizon-classify/index.ts` | **DIVERGED** | Ghost is older: lacks `verifyCallerOwnsUser`, uses pre-rename `sleep_efficiency_pct`, old key var, and **missing the descending-fetch bug fix the live version has.** |
| `migrations/20260423125512_remote_schema.sql` | **ORPHAN** | Ghost-only schema dump. Verify if needed baseline before deletion. |
| `…_compute_outcome_windows_cron.sql` | DIVERGED | Live was updated to the Vault version (2026-06-13); ghost has old GUC version. |
| `…_explanations_evening_brief.sql` | DIVERGED | Header-comment path only; content identical. |
| `…_user_feedback.sql` | **DIVERGED** | Different CHECK enum vocab. Live governs (deploys run from `backend/`). |
| 4 other migrations | IDENTICAL | Safe stale duplicates. |

---

## Phase B.3 — `packages/domain/` vs live

**All files DIVERGED; `packages/` is pre-v1.5 (stale)** — returns `"Recovering"` where live returns `"Yellowline"`, and **lacks the `driver_2` fix**.

**⚠️ Tests import from `packages/domain/` itself** (`../scoring.ts`, `../drivers.ts`…) → the test suite validates the **stale copy, not the deployed code.**

---

## Phase B.4 — Connecting trace (blast radius)

- **`packages/domain/`: zero real importers.** Only vestigial `// packages/domain/…` header comments inside the live `_shared/domain` files reference the name; nothing `import`s it except its own tests → **fully orphaned.**
- **Live consumers:** 5 Edge Functions import the live `_shared/domain`.
- **Ghost `supabase/`:** not deployed (deploys run from `backend/`); migrations not applied from there → orphaned.

---

## "Never worked 100%" — assessment

The hypothesis (edits landed in a dead path, never deployed) is **not supported** — every divergence shows the *live* path is ahead. Two real contributors did surface:

1. **Tests validate stale `packages/domain/`** → no coverage of the deployed scoring path. The `driver_2` crash and horizon `ascending+limit` bug would never have been caught.
2. **Deploy-from-root landmine:** top-level `supabase/` is linked to the live project but holds the *old, buggy* `horizon-classify`. Running a deploy from the repo root (instead of `backend/`) would silently regress auth + the bug fix.

---

## Proposed Phase C/D plan (recommendations only — nothing executed)

1. **Remove the worktree** (safe; nothing unique).
2. **Delete top-level `supabase/`** — stale ghost + deploy-from-root landmine. First confirm the ORPHAN `20260423125512_remote_schema.sql` isn't a needed baseline.
3. **`packages/domain/`:** delete it, or repoint its tests at the live `_shared/domain` and make that canonical. (Larger option: make `packages/domain` the single imported source — functions don't import it today.)
4. **Cosmetic:** fix the misleading `// packages/domain/…` headers in the live files.

**Status:** Map delivered at hard stop. Phase C (verification) and Phase D (cleanup) to be scoped after founder + thought-partner review.
