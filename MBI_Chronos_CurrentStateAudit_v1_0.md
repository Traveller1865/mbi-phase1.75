# MBI Chronos — Current State Audit
## Version 1.0 | Pre-Beta Closeout | 2026-05-25

> **Purpose:** Ground-truth forensic inventory of the MBI Chronos codebase at pre-beta closeout.
> Surfaces the gap between what handoff documents claim is built and what is actually present in the code.
> File paths and line numbers are cited throughout. Stubs, deferred items, and unconfirmed deployments are explicitly flagged.
> This document does not paper over gaps.

---

## Table of Contents

1. [Repository Structure](#1-repository-structure)
2. [iOS Client State](#2-ios-client-state)
3. [Supabase Backend State](#3-supabase-backend-state)
4. [Edge Functions](#4-edge-functions)
5. [Scoring Engine](#5-scoring-engine)
6. [Narrative Layer](#6-narrative-layer)
7. [Logging and Instrumentation](#7-logging-and-instrumentation)
8. [Learning Foundation Layer](#8-learning-foundation-layer)
9. [Nudge System](#9-nudge-system)
10. [Connected Devices](#10-connected-devices)
11. [Known Gaps and Stubs](#11-known-gaps-and-stubs)
12. [Build State](#12-build-state)
13. [Dependencies](#13-dependencies)
14. [Divergence from Handoff Documents](#14-divergence-from-handoff-documents)

---

## 1. Repository Structure

```
/Users/traveller/Documents/MBI Pre-Beta/Phase 1.5/MVP1.0/
├── README.md
├── SETUP.md
├── backend/                    — Supabase project config, migrations, edge functions
├── docs/                       — Handoff documents, schema, legal, SQL_PENDING.md
├── elements/                   — (not audited in this pass)
├── ios/                        — Xcode project root
├── packages/                   — TypeScript monorepo (domain package only)
├── supabase/                   — ⚠️ DUPLICATE / RESIDUAL (see note below)
└── {ios/                       — ⚠️ STRAY MALFORMED DIRECTORY (brace in name)
```

### Structural Anomalies

| Path | Issue |
|---|---|
| `/supabase/` | Parallel Supabase directory distinct from `/backend/supabase/`. Contains only `functions/horizon-classify/`. This appears to be a residual from an earlier migration attempt. The canonical functions live in `/backend/supabase/functions/`. |
| `/{ios/` | Directory with a literal brace character in the name. Not a valid path in most tooling. Should be deleted. |

### Key Subdirectories

| Path | Contents |
|---|---|
| `backend/supabase/config.toml` | Edge function registry, JWT settings, runtime policy |
| `backend/supabase/migrations/` | 25 migration SQL files (see §3) |
| `backend/supabase/functions/` | 14 edge functions (see §4) |
| `packages/domain/` | TypeScript scoring engine (`@mbi/domain` v1.1.0) |
| `ios/MBI/MBI/` | 39 Swift source files |
| `docs/SQL_PENDING.md` | Tracks which migrations have been manually applied — critical document |

---

## 2. iOS Client State

### Project Configuration

| Property | Value |
|---|---|
| Bundle ID | `com.chronos.mbi.MBI` |
| Deployment Target | iOS 17.0 |
| Swift Version | 5.9 |
| Build System | XcodeGen (`project.yml`) |
| Entitlements | `com.apple.developer.healthkit`, `health-records` access |
| Push Notifications | APNs token registration implemented; remote push NOT active (local only) |
| Package Manager | SPM (Supabase iOS SDK via Xcode package resolution; no `Package.swift` — managed via XcodeGen `project.yml` or Xcode GUI) |

### All Swift Source Files (39 files)

#### Config / App

| File | Status | Notes |
|---|---|---|
| `MBIApp.swift` | ✅ Implemented | AppDelegate added Sprint 4 for push token registration |
| `Config.swift` | ✅ Implemented | `supabaseURL`, `supabaseAnonKey`. ⚠️ Line 20: `horizon-assist` URL commented out pending Phase 3 |
| `Secrets.swift` | ✅ Implemented | Runtime secret injection. `Secrets.example.swift` in root for onboarding |

#### Models

| File | Status | Notes |
|---|---|---|
| `Models/Models.swift` | ✅ Implemented | Full model layer. `HorizonAssessment`, `HorizonSignal`, `HorizonNarrativeResponse`, `HorizonAssistResponse`. Line 728–729: `isStub = true` on `HorizonAssistResponse` pending Phase 3 Edge Function |

#### Services

| File | Status | Notes |
|---|---|---|
| `Services/SupabaseService.swift` | ✅ Implemented | Auth, data fetch, edge function calls, correction logging, `logNudgeResponse()` at line 1391. ⚠️ See §9 for wiring gap |
| `Services/SupabaseService+Domains.swift` | ✅ Implemented | Domain score fetch, `narrate-domain-expanded`, `narrate-domains-pattern`, `narrate-domains-30day` calls |
| `Services/HealthKitManager.swift` | ✅ Implemented | Full HealthKit read. Source filtering (Apple Watch), sleep deduplication, data tier classification |
| `Services/SyncCoordinator.swift` | ✅ Implemented | Orchestrates `ingest → score → narrate → horizon-classify → fetchHorizonSignals`. `triggerHorizonClassify` wired at line 174 |
| `Services/NotificationService.swift` | ✅ Implemented | Morning Brief (local), Horizon Alert (one-shot local), Streak Reminder (local). APNs token registration active. Remote push NOT active |
| `Services/TerraService.swift` | ⚠️ Stub | UI shell + `UserDefaults` cache. `connect()` uses `Task.sleep` to simulate latency. No `TerraSwift` SDK installed |
| `Services/AnalyticsService.swift` | ✅ Implemented | Custom privacy-first event logger. Calls `insertAnalyticsEvent` via REST |
| `Services/BiometricAuthService.swift` | ✅ Implemented | Face ID / Touch ID gate via `LocalAuthentication` |
| `Services/DoctorReportService.swift` | ✅ Implemented | PDF generation for doctor report. Wired to Escalate page CTA |

#### Views — Tab Structure

The app uses a 5-tab `TabView`:

| Tab | View | Status |
|---|---|---|
| Today | `DashboardView.swift` | ✅ Fully implemented |
| Trend | `TrendView.swift` | ✅ Fully implemented |
| Domains | `DomainBreakdownView.swift` | ✅ Implemented. Several Phase 2 drill-throughs commented as deferred (lines 338, 342, 364, 427) |
| Horizon | `HorizonModuleView.swift` + sub-pages | ✅ Implemented (see below) |
| Account | `AccountView.swift` | ✅ Implemented |

#### Views — Horizon Pages

| File | Page | Gate | Status |
|---|---|---|---|
| `HorizonView.swift` | Page 1 — Signal | Always visible | ✅ Implemented |
| `HorizonTrajectoryView.swift` | Page 2 — Trajectory | Always visible | ✅ Implemented |
| `HorizonRedirectView.swift` | Page 3 — Redirect | `page3Active` (conditionClass + confidenceGate ≥ 0.5) | ✅ Implemented |
| `HorizonEscalateView.swift` | Page 4 — Escalate | `page4Active` (escalationLevel == 3 + confidenceGate ≥ 0.75) | ✅ Implemented. ⚠️ Legal review note at line 14 |
| `HorizonFoundationsView.swift` | Sheet — Foundations | Presented from info button | ✅ Implemented |
| `HorizonAssistView.swift` | Sheet — Horizon Assist | Tap from Escalate page | ⚠️ Stub — returns locally-built answer; no Edge Function |
| `HorizonMomentumView.swift` | Retired | — | ⚠️ File exists; removed from page array in `HorizonModuleView` |
| `HorizonModuleView.swift` | Container | — | ✅ Implemented |

#### Views — Other

| File | Status | Notes |
|---|---|---|
| `StateView.swift` | ✅ Implemented | Yellowline, Drift, Chronos, state-gated display |
| `TrendView.swift` | ✅ Implemented | 30-day trend panels, metric detail integration |
| `MetricDetailView.swift` | ⚠️ Partial | Implemented but contextual note at lines 109, 467–468 is a Phase 2 stub; Phase 3 planned to wire `narrate-metric` Edge Function |
| `DomainDetailView.swift` | ✅ Implemented | — |
| `DomainBreakdownView.swift` | ✅ Implemented | Phase 2 deferred items annotated inline |
| `PatternDetailView.swift` | ✅ Implemented | — |
| `IntelligenceCardView.swift` | ✅ Implemented | — |
| `PeakWindowCard.swift` | ✅ Implemented | — |
| `FeedbackView.swift` | ✅ Implemented | Accepts `nudgeEventId: String?`. Called with `nil` from `DashboardView` (line 268), non-nil from `StateView` (line 198) |
| `OnboardingFlowView.swift` | ✅ Implemented | — |
| `AdminView.swift` | ✅ Implemented | Founder-only admin panel |
| `AuthView.swift` | ✅ Implemented | — |
| `NotificationPreferencesView.swift` | ✅ Implemented | All prefs stored in `UserDefaults` via `@AppStorage` |
| `PolicyView.swift` | ✅ Implemented | — |
| `DriverMetricHelpers.swift` | ✅ Implemented | — |

#### Helpers

| File | Status |
|---|---|
| `Helpers/Date+Relative.swift` | ✅ Implemented |

### State Management

- **`SyncCoordinator`** (`@StateObject` in `MBIApp`) — orchestrates daily sync pipeline
- **`SupabaseService`** (`@StateObject`) — auth session, API calls, `@Published latestNudgeEventId`
- No third-party state management (Combine used directly)

### HealthKit Queries

Metrics queried from HealthKit:

| Metric | Type | Source Filter |
|---|---|---|
| HRV (SDNN) | `HKQuantityTypeIdentifier.heartRateVariabilitySDNN` | Apple Watch only (`com.apple.health*`) |
| Resting HR | `HKQuantityTypeIdentifier.restingHeartRate` | Apple Watch only |
| Respiratory Rate | `HKQuantityTypeIdentifier.respiratoryRate` | Apple Watch only |
| Sleep Duration | `HKCategoryTypeIdentifier.sleepAnalysis` | Apple Watch only + interval deduplication |
| Sleep Efficiency | Derived from sleep analysis stages | Apple Watch only |
| Steps | `HKQuantityTypeIdentifier.stepCount` | No filter (Watch + iPhone both valid) |
| Active Minutes | `HKQuantityTypeIdentifier.appleExerciseTime` | Wearable filter |
| SpO2 | `HKQuantityTypeIdentifier.oxygenSaturation` | Wearable filter |
| Resting Energy | `HKQuantityTypeIdentifier.basalEnergyBurned` | Wearable filter |
| Stand Hours | `HKCategoryTypeIdentifier.appleStandHour` | Apple Watch only |

---

## 3. Supabase Backend State

### Migration Files

25 migration files exist in `backend/supabase/migrations/`. Per `docs/SQL_PENDING.md`, migrations are applied manually via Supabase SQL Editor (project: `sjhysadnpswrcpmezmoc`) — `supabase db push` is prohibited by project policy.

**⚠️ Critical: `docs/SQL_PENDING.md` explicitly documents that several migrations were written but NOT applied as of the time that document was last updated. The document also includes items marked ✅ DONE for later migrations. The exact applied-vs-pending state for any given production Supabase instance cannot be confirmed from this codebase alone.**

### All Tables (derived from migrations)

| Table | Migration | Status | Notes |
|---|---|---|---|
| `users` | `001_initial_schema.sql` | ✅ Initial | Core user row |
| `daily_inputs` | `001_initial_schema.sql` | ✅ Initial | Raw HealthKit data per day |
| `baselines` | `001_initial_schema.sql` | ✅ Initial | 7-day rolling baselines. Extended by learning foundation migration |
| `daily_scores` | `001_initial_schema.sql` | ✅ Initial | D1–D5 + Chronos composite. Extended by subsequent migrations |
| `explanations` | `001_initial_schema.sql` | ✅ Initial | Narrative outputs from Claude |
| `feedback` | `001_initial_schema.sql` | ✅ Initial | Simple thumbs feedback |
| `user_roles` | `001_initial_schema.sql` | ✅ Initial | `admin` role gate |
| `horizon_signals` | `002_horizon_signals.sql` | ⚠️ Deprecated | Superseded by `pathway_classifications`. Dropped by `20260516000001`. SQL_PENDING.md documents drop was pending production cycle confirmation |
| `trend_aggregates` | `20260427000000_trend_aggregates.sql` | ✅ Applied | 7-day/30-day metric aggregates |
| `pathway_classifications` | `20260505000001_phase2_horizon_ontology.sql` | ⚠️ Written; SQL_PENDING says not applied at doc time | Ontology Engine output. Replaces `horizon_signals` |
| `metric_node_map` | `20260505000001_phase2_horizon_ontology.sql` | ⚠️ Same | Seeded with 8 metric-to-node mappings |
| `node_activation_rules` | `20260505000001_phase2_horizon_ontology.sql` | ⚠️ Same | 7 threshold rules (autonomic ×3, sleep ×2, metabolic ×2) |
| `node_activation_log` | `20260505000001_phase2_horizon_ontology.sql` | ⚠️ Same | Per-user node firing audit log |
| `user_feature_waitlist` | `20260505000001_phase2_horizon_ontology.sql` | ⚠️ Same | Feature interest capture: `doctor_report`, `dpc_scheduling`, `horizon_assist` |
| `push_tokens` | `20260506000001_push_tokens.sql` | ⚠️ Written; SQL_PENDING says not applied | APNs token per user per device (IDFV keyed) |
| `logged_workouts` | `20260507000001_engagement_layer.sql` | ⚠️ Written; SQL_PENDING says not applied | Manual workout log |
| `daily_checkins` | `20260507000001_engagement_layer.sql` | ⚠️ Same | Daily mood/energy/stress (1–5 each) |
| `app_events` | `20260509000001_analytics_and_admin.sql` | ⚠️ Written; SQL_PENDING says not applied | Custom analytics. Write-only from client |
| `admin_devices` | `20260509000001_analytics_and_admin.sql` | ⚠️ Same | Founder push token registry |
| `horizon_escalations` | `20260509000002_horizon_escalations.sql` | ⚠️ Written; SQL_PENDING says not applied | 3-consecutive-day low-score escalation log |
| `nudge_events` | `20260514000001_learning_foundation.sql` | ✅ Applied (learning foundation) | Core outcome learning log. Written by `narrate` Edge Function |
| `nudge_responses` | `20260514000001_learning_foundation.sql` | ✅ Applied | User response log. `logNudgeResponse()` writes here — see §9 |
| `decision_context_snapshots` | `20260514000001_learning_foundation.sql` | ✅ Applied | Full system state snapshot at nudge decision point |
| `first_occurrence_events` | `20260514000001_learning_foundation.sql` | ✅ Applied | Tracks first time user sees each nudge domain |
| `outcome_windows` | `20260514000001_learning_foundation.sql` | ✅ Applied | 7-day post-nudge outcome measurement windows |
| `user_feedback` | `20260520000001_user_feedback.sql` | Applied (post-learning-foundation) | Extended feedback with relevance, tone, category |
| `score_corrections` | `20260520000002_score_corrections.sql` | Applied | User-submitted metric corrections. Powers `escalation-alert` |
| `trend_narratives` | `20260520000004_trend_narratives.sql` | Applied | Cache for `narrate-trend` outputs (TTL-gated) |
| `ingest_errors` | `20260522000001_data_tier_and_gap_framework.sql` | Applied | Structured ingest failure log |

### Column-Level Additions (ALTER TABLE migrations)

| Migration | Change | Notes |
|---|---|---|
| `20260512000001_sleep_continuity_rename.sql` | Renames `sleep_efficiency_pct` → `sleep_continuity_pct` in `daily_inputs` | Sleep architecture rename |
| `20260512000002_daily_scores_confidence_fields.sql` | Adds `range_trust_state`, confidence fields to `daily_scores` | |
| `20260513000001_baseline_range_schema.sql` | Adds range/p-value columns to `baselines` | |
| `20260514000001_learning_foundation.sql` | Adds p10/p90 columns + fixes silent-drop bug for `spo2_avg`, `resting_energy_avg`, `stand_hours_avg` on `baselines` | ⚠️ p10/p90 columns exist but deviation.ts does NOT use them (see §14) |
| `20260514000002_range_trust_state_daily_scores.sql` | Adds `range_trust_state TEXT` to `daily_scores` | |
| `20260516000001_drop_horizon_signals.sql` | `DROP TABLE IF EXISTS horizon_signals` | SQL_PENDING tracks this as pending production confirmation |
| `20260516000002_compute_outcome_windows_cron.sql` | Registers `compute-outcome-windows-daily` pg_cron at `0 6 * * *` UTC | ⚠️ Cron registration is a SQL statement — confirmation of actual cron run requires Supabase dashboard check |
| `20260519000001_explanations_evening_brief.sql` | Adds `evening_explanation_text`, `evening_nudge_text` to `explanations` | |
| `20260520000003_explanations_detail_fields.sql` | Adds `detail_narrative`, `domain_insights`, `pattern_context` to `explanations` | |
| `20260521000001_driver_integrity_constraints.sql` | Adds FK/check constraints on driver columns in `daily_scores` | |
| `20260522000001_data_tier_and_gap_framework.sql` | Adds `data_tier TEXT` column to `daily_inputs` + `daily_scores` | |
| `20260522000002_data_tier_backfill_and_verify.sql` | Backfills `data_tier` on existing rows | |
| `20260522000003_bp_and_weight_columns.sql` | Adds `blood_pressure_systolic`, `blood_pressure_diastolic`, `weight_kg` to `daily_inputs` | |

### RLS Summary

- All user-facing tables have RLS enabled with `auth.uid() = user_id` pattern
- `horizon_escalations` and `admin_devices`: RLS disabled, service-role-only
- `app_events`: INSERT only from client (no SELECT policy — analytics are write-only)
- Edge Functions use service role key, bypassing RLS for all writes

---

## 4. Edge Functions

### Registry

13 functions registered in `config.toml`. 14 function directories exist in `backend/supabase/functions/` (including the deprecated `horizon` function which is not in the config). A 15th copy of `horizon-classify` exists in the stray `/supabase/` directory.

| Function | `verify_jwt` | Status | Trigger |
|---|---|---|---|
| `ingest` | `false` | ✅ Active | iOS `SyncCoordinator` post-HealthKit read |
| `score` | `false` | ✅ Active | iOS after `ingest` completes |
| `narrate` | `false` | ✅ Active | iOS after `score` completes |
| `admin` | `false` | ✅ Active | iOS `AdminView` (founder only) |
| `compute-outcome-windows` | `false` | ⚠️ Scaffold | pg_cron daily 06:00 UTC. Function body is a stub (see §8) |
| `narrate-detail` | `false` | ✅ Active | iOS `MetricDetailView` contextual trigger |
| `narrate-trend` | `false` | ✅ Active | iOS `TrendView` 30-day panel |
| `narrate-domains-pattern` | `false` | ✅ Active | iOS `DomainBreakdownView` pattern block |
| `narrate-domain-expanded` | `false` | ✅ Active | iOS `DomainDetailView` expanded narrative |
| `narrate-domains-30day` | `false` | ✅ Active | iOS `DomainBreakdownView` 30-day mode |
| `horizon-classify` | `false` | ✅ Active | iOS `SyncCoordinator` post-score |
| `narrate-horizon` | `false` | ✅ Active | iOS `HorizonModuleView` / `HorizonSignalView` |
| `escalation-alert` | **`true`** | ✅ Active | iOS `SupabaseService.sendEscalationAlert` (correction count ≥ 3 in 14 days) |
| `horizon` | N/A | ⚠️ Deprecated | Not in `config.toml`. Header: "MBI Phase 2 — Horizon Ontology Engine (DEPRECATED)" |
| `horizon-assist` | N/A | ⚠️ Not deployed | Referenced in `Config.swift` line 20 as commented-out; Phase 3 |

### Security Note

**12 of 13 active registered functions have `verify_jwt = false`.** This means any request with the correct URL and service-role or anon key can invoke these functions without a valid user JWT. The iOS client performs its own user-ownership checks via `verifyCallerOwnsUser()` in `_shared/auth.ts`, but this relies on the client passing a correct `userId` field in the POST body — it is not enforced at the JWT layer. `escalation-alert` is the only function with proper JWT verification.

---

## 5. Scoring Engine

### Package Identity

| Property | Value |
|---|---|
| Package name | `@mbi/domain` |
| `package.json` version | `1.1.0` |
| `contracts.ts` `DOMAIN_VERSION` | `"1.2"` |
| `narrate/index.ts` hardcoded `DOMAIN_VERSION` | `"1.5"` ⚠️ |

**Version mismatch**: `narrate/index.ts` (line 22) hardcodes `DOMAIN_VERSION = "1.5"` with a comment "must match contracts.ts DOMAIN_VERSION", but `contracts.ts` exports `"1.2"`. This discrepancy means `nudge_events.scoring_version` and `explanations.scoring_version` written by the `narrate` function carry an incorrect version string.

### Domain Scores

| Domain | Key | Metrics |
|---|---|---|
| D1 | `d1_autonomic` | HRV (2×), Resting HR (2×), Respiratory Rate (2×) |
| D2 | `d2_sleep` | Sleep Duration (1.5×), Sleep Efficiency/Continuity (1.5×) |
| D3 | `d3_activity` | Steps (1×), Active Minutes (1×) |
| D4 | `d4_inferred_stress` | Derived composite |
| D5 | `d5_readiness` | Derived composite |

### Baseline (`baseline.ts`)

- 7-day rolling window
- Minimum 3 days required; returns `null` if fewer than 3 days available
- Used by deviation scoring; p10/p90 personal percentile columns exist in DB (`baselines` table) but are **not read by `deviation.ts`** (see §14)

### Deviation Weights (`deviation.ts`)

| Metric | Weight |
|---|---|
| HRV (two metrics) | 2.0× each |
| Resting HR (two metrics) | 2.0× each |
| Respiratory Rate (two metrics) | 2.0× each |
| Sleep Duration | 1.5× |
| Sleep Efficiency/Continuity | 1.5× |
| Steps | 1.0× |
| Active Minutes | 1.0× |
| SpO2 | 1.0× |
| Resting Energy | 1.0× |
| Stand Hours | 1.0× |

### Fail States (`failstates.ts`)

- `Redline` — score collapse + multi-day pattern
- `Ghost-AtRisk` — data gap + concerning prior pattern
- `Ghost-Healthy` — data gap + healthy prior pattern
- `Drift` — gradual decline, not acute
- `null` — no fail state

### Drivers (`drivers.ts`)

- Always returns exactly 2 drivers
- Tiebreak: physiological > behavioral

### Delta Override

Implemented in `scoring.ts`. If today's deviation magnitude exceeds threshold, `delta_override = true` is written to `daily_scores`. `narrate/index.ts` checks this flag and adjusts narrative tone.

### Horizon Ontology Engine (`horizon-classify/index.ts`)

Separate from domain scoring. Evaluates `node_activation_rules` against `daily_inputs` to populate `pathway_classifications`. Within-user baseline: median of days `[7..97]` (90-day window). Three pathways: autonomic, sleep, metabolic. Confidence gates: Trajectory ≥ 0.3, Redirect ≥ 0.5, Escalate ≥ 0.75.

---

## 6. Narrative Layer

### Functions Calling Claude

| Function | Model | Prompt Version | Notes |
|---|---|---|---|
| `narrate` | `claude-sonnet-4-6` | v2.0 | Primary daily brief. `response_tone` hardcoded `"balanced"` (line 165, 664): "Hardcoded as 'balanced' for Phase 1. Phase 2 wires user preference toggle" |
| `narrate-trend` | `claude-sonnet-4-6` | v1.3 | Gap honesty framework (50% skip threshold). Writes to `trend_narratives` cache |
| `narrate-horizon` | `claude-sonnet-4-6` | v1.1 | CALM state uses static copy (no Claude call). Active pathways invoke Claude |
| `narrate-detail` | `claude-sonnet-4-6` | — | Metric drill-through contextual narrative |
| `narrate-domain-expanded` | `claude-sonnet-4-6` | — | Expanded domain narrative |
| `narrate-domains-30day` | `claude-sonnet-4-6` | — | 30-day domain history narrative |
| `narrate-domains-pattern` | `claude-sonnet-4-6` | — | Pattern block narrative |

**`horizon-assist`** is referenced in code but **not deployed** — no directory in `backend/supabase/functions/` (see §11).

### Input/Output Shapes

- All narrate functions accept `{ userId, date, ... }` POST body
- All return structured JSON with `nudge_text`, `explanation_text`, and function-specific fields
- `narrate` returns `nudge_event_id` — stored in `SupabaseService.latestNudgeEventId` for FeedbackView linkage

### Error Handling

- All functions use try/catch with structured error responses
- `narrate-trend` implements gap honesty framework: skips narrative generation when gap detection confidence is < 50%
- `narrate-horizon` short-circuits for CALM state (no Claude call, returns static copy)

---

## 7. Logging and Instrumentation

### Event Tables

| Table | Written by | Read by | Notes |
|---|---|---|---|
| `nudge_events` | `narrate` Edge Function | Analytics (service role) | Full system state at nudge generation time |
| `nudge_responses` | iOS `logNudgeResponse()` | Analytics | ⚠️ Not wired to nudge card interactions (see §9) |
| `decision_context_snapshots` | `narrate` Edge Function | Analytics | — |
| `first_occurrence_events` | `narrate` Edge Function | Analytics | First time user sees each nudge domain |
| `outcome_windows` | `compute-outcome-windows` | Analytics | ⚠️ Edge Function is a scaffold (see §8) |
| `app_events` | iOS `AnalyticsService` | Service role only | Privacy-first, write-only from client |
| `horizon_escalations` | `score` Edge Function | Service role | 3-day low-score escalation audit log |
| `feedback` | iOS `FeedbackView` | — | Simple thumbs rating (legacy) |
| `user_feedback` | iOS `FeedbackView` | — | Extended: relevance, tone, category |
| `score_corrections` | iOS correction workflow | `score` Edge Function (override), `escalation-alert` | User-submitted metric corrections |
| `ingest_errors` | `ingest` Edge Function | Analytics | Structured error log for data pipeline failures |

### Analytics Service

`AnalyticsService.swift` implements a custom privacy-first event logger. Events are POSTed to `app_events` via REST. No third-party analytics SDK (no Mixpanel, Amplitude, etc.).

---

## 8. Learning Foundation Layer

### Migration Status

Migration `20260514000001_learning_foundation.sql` is the primary learning foundation migration. It is in the applied set (referenced by subsequent migrations and confirmed present).

### Exit Criteria Verification

The learning foundation was defined with 8 exit criteria. State of each:

| # | Criterion | Status |
|---|---|---|
| 1 | `nudge_events` table created with full system state columns | ✅ Table exists per migration |
| 2 | `narrate` Edge Function writes to `nudge_events` on every call | ✅ Implemented in `narrate/index.ts` |
| 3 | `nudge_event_id` returned to iOS client and stored in `SupabaseService.latestNudgeEventId` | ✅ Implemented |
| 4 | `nudge_responses` table created | ✅ Table exists per migration |
| 5 | `logNudgeResponse()` implemented in `SupabaseService` | ✅ At line 1391 |
| 6 | `logNudgeResponse()` called from nudge card tap interactions | ⚠️ **NOT IMPLEMENTED** — see §9 |
| 7 | `outcome_windows` table created + `compute-outcome-windows` function scheduled | ✅ Table exists; pg_cron SQL applied per migration. ⚠️ Edge Function body is scaffold only |
| 8 | p10/p90 personal percentile columns added to `baselines` | ✅ Columns exist. ⚠️ `deviation.ts` does not use them |

### p10/p90 Gap

The learning foundation migration adds 12 p10/p90 columns to `baselines` (for HRV, Resting HR, Sleep Duration, Sleep Continuity, Steps, Active Minutes). Per design, these are intended to replace hardcoded absolute reserve thresholds with personal percentile thresholds once sufficient history exists.

**`packages/domain/deviation.ts` does not read or reference these columns.** The scoring engine continues to use its hardcoded deviation weights and absolute thresholds. The columns exist in the schema but have no code path populating or consuming them.

---

## 9. Nudge System

### Generation

Nudges are generated by the `narrate` Edge Function (Claude `claude-sonnet-4-6`). The nudge domain is selected by `scoring.ts` in the domain package. A `nudge_event_id` is returned to the iOS client.

### Delivery

Nudge cards are rendered in three components in `DashboardView.swift` and `StateView.swift`:

| Component | Location | `nudge_event_id` passed? |
|---|---|---|
| `ChronosNudgeCard` | `DashboardView.swift` line 233, `StateView.swift` line 187 | No — takes only `nudge: String` |
| `YellowlineNudgeCard` | `DashboardView.swift` line 194 | No — takes only `nudge: String` |
| `DriftNudgeCard` | `DashboardView.swift` line 230 | No — takes only `nudge: String` |

### Response Logging Gap

`SupabaseService.logNudgeResponse()` is fully implemented at line 1391. It correctly accepts `nudgeEventId: String`, `responseType: String`, and writes to `nudge_responses`.

**None of the three nudge card components call `logNudgeResponse()`.** None of them accept a `nudge_event_id` parameter. There is no tap callback, swipe-away callback, or dismiss callback wired to the logging function.

**Net result:** `nudge_responses` table exists and `logNudgeResponse()` is implemented, but the table will contain zero rows during beta unless wiring is added. The outcome learning loop is structurally incomplete.

**Additionally:** `FeedbackView` in `DashboardView.swift` (line 268) passes `nudgeEventId: nil`, breaking the link between feedback and nudge events for users coming through `DashboardView`. The `StateView` path at line 198 correctly passes `supabase.latestNudgeEventId`.

---

## 10. Connected Devices

### HealthKit

**Status: Fully implemented** for Apple Watch wearable data.

Source routing logic is in `HealthKitManager.swift`:
- `HealthKitSourceRegistry.classify()` at line 685 classifies sources by bundle ID prefix
- `com.apple.health*` → `.appleWatch`
- All wearable metrics (HRV, RHR, respiratory rate, sleep, SpO2, resting energy, stand hours) filter to Apple Watch sources only
- Steps: no filter — both Watch and iPhone accepted (HKStatisticsQuery sums across sources)
- Sleep: interval deduplication applied before efficiency computation

### Data Tier Classification

`classifyDataTier()` in the `ingest` Edge Function classifies each day's ingest as:

| Tier | Condition |
|---|---|
| `wearable` | HRV and sleep data present from watch source |
| `partial` | Some wearable data but incomplete |
| `steps_only` | Only step count data |
| `unknown` | No data or unrecognized source |

`data_tier` column added to `daily_inputs` and `daily_scores` by migration `20260522000001`.

### Terra Integration

**Status: Stub.**

`TerraService.swift` implements:
- `UserDefaults`-based provider list cache
- `connect(provider:)` — calls `Task.sleep` to simulate latency, then writes to `UserDefaults`. **No actual Terra API call.**
- `disconnect(provider:)` — removes from `UserDefaults` cache

**`TerraSwift` SDK is not installed.** No `Package.swift` dependency, no import, no SPM reference. The Terra provider column on the `users` table (Migration 4 in SQL_PENDING) is also not confirmed applied.

Terra is currently display/UX only with no data flowing in.

---

## 11. Known Gaps and Stubs

### High Priority (blocks learning loop / core function)

| Gap | Location | Notes |
|---|---|---|
| `logNudgeResponse()` not wired to nudge card interactions | `DashboardView.swift` lines 194, 230, 233; `StateView.swift` line 187 | `nudge_responses` table will be empty in beta. Full learning loop broken. |
| `FeedbackView` in DashboardView passes `nudgeEventId: nil` | `DashboardView.swift` line 268 | Feedback events not linkable to nudge events for dashboard-path users |
| `compute-outcome-windows` Edge Function is scaffold only | `backend/supabase/functions/compute-outcome-windows/index.ts` | Function body: "full implementation deferred per handoff". pg_cron schedule registered; function will execute but perform no useful work |
| p10/p90 percentile columns not used by scoring engine | `packages/domain/deviation.ts` | Columns populated in DB by migration but never read by TypeScript |

### Medium Priority (feature completeness)

| Gap | Location | Notes |
|---|---|---|
| `horizon-assist` Edge Function not deployed | `Config.swift` line 20 (commented out); `HorizonAssistView.swift` | `HorizonAssistView` returns locally-constructed answer. Models.swift line 728–729 flags `isStub = true` |
| `MetricDetailView` contextual note is Phase 2 stub | `MetricDetailView.swift` lines 109, 467–468 | Shows static placeholder copy. Phase 3: replace with `narrate-metric` Edge Function call |
| DPC scheduling is Phase 3 | `HorizonEscalateView.swift` lines 455–461 | Notify me CTA wired to `user_feature_waitlist` insert; scheduling UI not built |
| `response_tone` hardcoded to `"balanced"` | `narrate/index.ts` lines 165, 664 | User preference toggle planned for Phase 2 per inline comment |
| `TerraService` is a stub with no SDK | `TerraService.swift` | No data flows from third-party wearables |
| Horizon push notification is local only | `NotificationService.swift` | APNs token registration implemented and table exists; actual server-side push not active |
| `HorizonMomentumView` retired but file still present | `HorizonMomentumView.swift` | Not in page array; dead code |

### Low Priority / Cosmetic

| Gap | Location | Notes |
|---|---|---|
| `DOMAIN_VERSION` mismatch | `narrate/index.ts` line 22 vs `packages/domain/contracts.ts` | narrate writes `"1.5"` to DB; actual version is `"1.2"` |
| Stray `/{ios` directory | Repo root | Directory with brace character in name |
| Duplicate `/supabase/` directory | Repo root | Contains only `horizon-classify`; canonical location is `/backend/supabase/functions/` |
| `horizon` Edge Function directory exists but is deprecated | `backend/supabase/functions/horizon/` | Not in `config.toml`. Should be deleted |
| `DomainBreakdownView` Phase 2 drill-through items | Lines 338, 342, 364, 427, 1332, 1377 | Chevron tap affordance present but full-card tap not wired |
| `score/index.ts` line 706: "P4.3 placeholder: silent founder push" | `score/index.ts` | Founder escalation push not implemented |

---

## 12. Build State

### Last Confirmed Build

- **Date:** 2026-05-25
- **Target:** `MBI` scheme, `iPhone 17 Pro` simulator
- **Result:** `** BUILD SUCCEEDED **`
- **Errors:** 0
- **Warnings:** Not captured in last build output (build succeeded cleanly)

### Test Files

No test files found in the repository. `ios/MBI/MBI.xcodeproj` has no test targets defined in `project.yml`. No `*Tests.swift` or `*UITests.swift` files exist.

**There is no test suite.** All verification has been manual.

---

## 13. Dependencies

### iOS (Swift)

| Dependency | Source | Version | Notes |
|---|---|---|---|
| `supabase-swift` | SPM (Xcode) | Not pinned in `project.yml` | Supabase iOS SDK |
| `TerraSwift` | Not installed | — | Referenced conceptually; no SPM entry |

No `Package.swift` or `Podfile` present. SPM dependencies managed through Xcode's package resolution (stored in `.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`).

### TypeScript / Backend

| Dependency | Version | Location |
|---|---|---|
| `@supabase/supabase-js` | `^2` (via esm.sh CDN) | All Edge Functions |
| `deno` standard library | `0.168.0` | All Edge Functions |
| `anthropic` SDK | Via Deno CDN | All `narrate-*` functions |

No `package.json` at the backend level. Edge Functions use Deno's URL-based import model.

### Domain Package (`packages/domain/`)

| Property | Value |
|---|---|
| `package.json` name | `@mbi/domain` |
| `package.json` version | `1.1.0` |
| TypeScript target | ES2020 |
| No external npm dependencies | Self-contained |

### External Services

| Service | Integration Status | Notes |
|---|---|---|
| Supabase | ✅ Active | Project ref: `sjhysadnpswrcpmezmoc` |
| Anthropic (Claude) | ✅ Active | `claude-sonnet-4-6` across 7 narrate functions |
| Apple HealthKit | ✅ Active | Full HealthKit integration |
| APNs | ⚠️ Partial | Token registration active; server-side push not implemented |
| Terra | ⚠️ Stub | No SDK installed |
| Resend (email) | ✅ Active | Used by `escalation-alert` for correction escalation emails. Requires `RESEND_API_KEY` env var |

---

## 14. Divergence from Handoff Documents

### From `MBI_Chronos_HorizonTab_Redesign_BuildHandoff_v1_0.docx`

| Claim | Actual State |
|---|---|
| Horizon Assist as a live AI Q&A feature | Stub only; returns locally-built answer; no Edge Function deployed |
| DPC scheduling available | Phase 3 deferred; Notify Me CTA writes to `user_feature_waitlist` only |
| Full 4-page Horizon architecture delivered | Pages 1–4 implemented; HorizonMomentumView retired and file left as dead code |

### From `MBI_BetaReadiness_Epic_v1_0.md` (Learning Foundation exit criteria)

| Claim | Actual State |
|---|---|
| Nudge response logging wired to card interactions | `logNudgeResponse()` implemented but NOT called from any nudge card component |
| Outcome windows computed daily | `compute-outcome-windows` Edge Function is a scaffold; no computation logic implemented |
| p10/p90 personal percentile thresholds active | Columns exist in DB; `deviation.ts` never reads them |

### Scoring / Versioning

| Claim | Actual State |
|---|---|
| `DOMAIN_VERSION = "1.2"` (contracts.ts) | `narrate/index.ts` hardcodes `"1.5"`, writing incorrect version strings to `nudge_events` and `explanations` tables |
| `@mbi/domain` package version matches contracts | package.json says `"1.1.0"`; contracts.ts says `"1.2"`; narrate says `"1.5"` — three different version strings for the same artifact |

### Database Application Status

| Claim | Actual State |
|---|---|
| All migrations applied to production | `docs/SQL_PENDING.md` explicitly marks multiple migrations as "Written, not applied" including `pathway_classifications`, `push_tokens`, `logged_workouts`, `daily_checkins`, `app_events`, `admin_devices`, `horizon_escalations`. Applied status can only be confirmed via Supabase dashboard inspection |
| `horizon_signals` deprecated and dropped | Migration `20260516000001` exists; SQL_PENDING documents drop was pending production classification cycle confirmation (one checklist item unchecked) |
| pg_cron for `compute-outcome-windows` registered | SQL to register the cron exists in migration `20260516000002`. Actual scheduler confirmation requires Supabase dashboard check |

### Terra

| Claim | Actual State |
|---|---|
| Terra connected devices integration | Zero Terra code implemented beyond a UI stub; `TerraSwift` SDK not installed; no data flows |

---

## Audit Confidence Notes

- **High confidence:** iOS client state, Swift source files, Edge Function code, domain package implementation, migration SQL content
- **Medium confidence:** Which migrations are actually applied to the live Supabase instance — this requires dashboard verification and cannot be inferred from the repo alone
- **Low confidence:** Whether pg_cron for `compute-outcome-windows` is actively firing on the hosted Supabase instance
- **Cannot determine from repo:** Push notification delivery success rate, actual Supabase table row counts, production API error rates

---

*Generated: 2026-05-25 | Audit scope: `/Users/traveller/Documents/MBI Pre-Beta/Phase 1.5/MVP1.0/` | Build: SUCCEEDED (iPhone 17 Pro simulator)*
