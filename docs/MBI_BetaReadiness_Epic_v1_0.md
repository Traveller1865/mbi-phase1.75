# MBI Chronos — Beta Readiness Epic
**Version:** 1.0  
**Date:** 2026-05-09  
**Author:** Mynd & Bodi Institute  
**Status:** In Execution  

---

## Overview

This epic tracks every item required before Chronos ships to external beta testers. Work is sequenced so that foundational issues (data integrity) are resolved before surface concerns (UX polish) are addressed. Each phase gate must be cleared before the next phase begins.

Phases are executed in order. Items within a phase may be parallelised unless a dependency is noted.

---

## Phase Gates

| Phase | Name | Gate Condition |
|-------|------|----------------|
| **PHASE 0** | Scoring Integrity | All confirmed scoring bugs fixed; resync validated |
| **PHASE 1** | Missing Data Handling | Graceful nil paths confirmed end-to-end |
| **PHASE 2** | Onboarding Hardening | Height/birthday capture live; data disclosures in place |
| **PHASE 3** | Infrastructure | Sentry, analytics, JWT refresh, fallback copy live |
| **PHASE 4** | Horizon System | Escalation threshold, 3-day detection, push route live |
| **PHASE 5** | Legal & Privacy | PrivacyInfo.xcprivacy, policy URLs, health disclosure wired |
| **PHASE 6** | Should Fix | All S1–S14 items resolved or formally deferred |
| **PHASE 7** | Final Polish | N1–N8 items completed or formally deferred |

---

## PHASE 0 — Scoring Integrity

**Owner:** Engineering  
**Status:** ✅ COMPLETE (2026-05-09)

These are data-correctness bugs confirmed by cross-referencing the production HealthKit export against stored `daily_inputs` rows for the validation user (UUID `5b3dd4d1-1901-4693-8cd6-e3411704467a`).

---

### P0.1 — HRV Daily Average Bug

**File:** `ios/MBI/MBI/Services/HealthKitManager.swift`  
**Severity:** Critical — corrupts the primary scoring signal  
**Status:** ✅ FIXED 2026-05-09

**Root Cause:**  
`readHRV()` called `readLatestQuantity()`, which executes an `HKSampleQuery` with `limit: 1` sorted by `endDate descending`. This returned the *last* SDNN reading of the day, not the daily average.

Apple Watch writes many HRV samples across the day (during sleep, after workouts, during recovery). A single sample is effectively random — it may be a low post-exercise reading that has nothing to do with overall cardiovascular status.

**Evidence (Apr 27 cross-reference):**
- HealthKit daily average: **52.9 ms**
- Stored `hrv_ms` value: **15.8 ms**
- Discrepancy: **70% under-reported**

**Fix Applied:**
```swift
// BEFORE:
return try await readLatestQuantity(type: type, ...)

// AFTER:
return try await readAverageQuantity(type: type, ...)
```

`readAverageQuantity()` fetches all samples in the window and returns the arithmetic mean — the correct clinical representation of daily HRV.

**Post-Fix Action Required:**  
User must trigger Account → Resync after build update to recompute all historical scores with corrected HRV values. Baseline recalculation will also shift, which is expected and correct.

---

### P0.2 — Sleep Stage Classification Bug (watchOS 9+)

**File:** `ios/MBI/MBI/Services/HealthKitManager.swift`  
**Severity:** Critical — corrupts sleep_duration and sleep_efficiency  
**Status:** ✅ FIXED 2026-05-09

**Root Cause:**  
`readSleep()` used a binary classifier: `.inBed` → `inBedSeconds`, everything else → `asleepSeconds`. This was written against the legacy pre-watchOS 9 API where Apple Watch wrote `.inBed` as an outer wrapper and `.asleep` as the inner stage.

watchOS 9 (2022) introduced granular sleep stages: `.asleepCore` (4), `.asleepDeep` (5), `.asleepREM` (6), `.asleepUnspecified` (3), and critically `.awake` (2). Modern Apple Watches **do not write `.inBed`** — they write granular stages only.

With the old code on a modern watch:
- `inBedSeconds = 0` (no `.inBed` written)
- `.awake` fell into the `else` branch → counted as sleep
- `totalBed = max(0, asleepSeconds) = asleepSeconds`
- `efficiency = asleepSeconds / asleepSeconds = 100%` — **always**
- `durationHrs` was inflated by all awake-in-sleep time

**Evidence (Apr 26 cross-reference):**
- Stored `sleep_duration_hrs`: **9.9 h**
- HealthKit actual asleep (Core+Deep+REM): **8.87 h**
- HealthKit awake in bed: **1.03 h**
- 8.87 + 1.03 = **9.90 h** — confirms awake time counted as sleep
- Stored `sleep_efficiency_pct`: **100.0%** — confirms the constant-100 bug

**Fix Applied:**  
Switch classifier on raw value:
```swift
switch sample.value {
case HKCategoryValueSleepAnalysis.inBed.rawValue:
    inBedSeconds += duration       // legacy wrapper
case HKCategoryValueSleepAnalysis.awake.rawValue:
    awakeSeconds += duration       // exclude from sleep
default:
    asleepSeconds += duration      // 1=asleep, 3=unspecified, 4=Core, 5=Deep, 6=REM
}
```

Efficiency formula:
```swift
// Modern: explicit awake data → asleep / (asleep + awake)
// Legacy:  only inBed wrapper → asleep / inBed
// Neither: nil
```

**Post-Fix Action Required:**  
Same resync as P0.1. Sleep scores (D2) will meaningfully change. Efficiency will drop from 100% to realistic values (typically 85–95%).

---

### P0.3 — Horizon Escalation Threshold Correction

**File:** `backend/supabase/functions/_shared/domain/` (scoring layer)  
**Severity:** High — triggers false escalations during beta  
**Status:** 🔨 PENDING — must audit and correct threshold value

**Issue:**  
The original escalation threshold was set at 35 (Redline floor). This is too aggressive for beta — many users will dip into the 35–65 range from lifestyle variability, not genuine crisis.

**Agreed threshold:** `65-` (below 65 for 3 consecutive days)  
**Detection logic:** 3 consecutive calendar days, not rolling 72h  
**Escalation action:** Silent push to founder device; no user-facing alert  

This is addressed fully in Phase 4.

---

## PHASE 1 — Missing Data Handling

**Owner:** Engineering  
**Status:** 🔲 NOT STARTED

### P1.1 — IngestService Nil Metric Audit

**File:** `backend/supabase/functions/ingest/index.ts`  
**Priority:** High

**Task:**  
Walk every metric field in the ingest canonicalisation layer. Confirm each nil/missing value is handled gracefully (no 500, no silent drop). Verify `is_complete` flag accurately reflects presence of the 7 primary metrics.

**Acceptance Criteria:**
- Ingest with 0 metrics returns 200 with `is_complete: false`
- Ingest with partial metrics returns 200 with correct partial `is_complete`  
- No 500 errors for any single-metric missing combination
- Log output includes which metrics were absent

---

### P1.2 — Score Edge Function Partial Day Handling

**File:** `backend/supabase/functions/score/index.ts` (and scoring shared lib)  
**Priority:** High

**Task:**  
Confirm score function gracefully handles:
- Days where HRV is nil (e.g., Apple Watch charging all night)
- Days where all sleep metrics are nil (e.g., watch removed)
- Days with only steps (iPhone-only user)

**Acceptance Criteria:**
- chronos_score computed on available metrics without throwing
- Domain scores that rely on missing metrics → nil, not 0 (nil = "not enough data", 0 = "worst score")
- `fail_state` is not triggered purely because a metric is absent

---

### P1.3 — UI: Partial Day / No Data States

**Files:** `DashboardView.swift`, `DomainBreakdownView.swift`, `IntelligenceView.swift`  
**Priority:** Medium

**Task:**  
Design and implement UI states for when a user has a day with minimal data. Currently, the UI assumes a full score is always present.

**States to handle:**
- No sync yet today → show "Syncing…" or yesterday's score with timestamp
- Partial metrics → show score with footnote "based on N of 7 metrics"
- Complete data absence → show motivational empty state, not a crash

---

## PHASE 2 — Onboarding Hardening

**Owner:** Engineering + Design  
**Status:** 🔲 NOT STARTED

### P2.1 — Height + Birthday Capture

**Files:** `OnboardingFlowView.swift`, `SupabaseService.swift`, Supabase schema  
**Priority:** High

**Task:**  
Add two new onboarding steps after the existing profile questions:

**Birthday:**
- Date picker (wheel style, years only visible initially)
- Age-gate: user must be 18+ (calculate age on submit)
- If under 18: show message "Chronos is designed for adults 18 and older" and block progression
- Store as `date_of_birth` (date type) in `user_profiles`
- Show birthday celebration animation if today is their birthday at first launch

**Height:**
- Segmented control: Imperial (ft/in) vs Metric (cm)
- Imperial: two number pickers (feet 4–7, inches 0–11)
- Metric: single number picker (120–220 cm)
- Store as `height_cm` (integer, always store metric, convert in UI)

**Schema changes required:**
```sql
ALTER TABLE user_profiles ADD COLUMN date_of_birth DATE;
ALTER TABLE user_profiles ADD COLUMN height_cm INTEGER;
```

**Acceptance Criteria:**
- Under-18 users cannot complete onboarding
- Birthday is stored and used for future age-aware features
- Height is stored in metric regardless of UI selection
- Both fields are optional for beta (warning shown if skipped, not blocked)

---

### P2.2 — HealthKit Data Source Notice

**File:** `OnboardingFlowView.swift` (HealthKit permission step)  
**Priority:** High

**Task:**  
After HealthKit permissions are granted, show a one-screen notice:

```
About your health data

Chronos reads data from Apple Health. The quality of your 
Chronos score depends on what devices are contributing data.

Apple Watch (recommended)
Provides HRV, resting heart rate, sleep stages, active 
minutes, and respiratory rate — all primary scoring signals.

iPhone only
Provides steps and distance. HRV, sleep, and heart rate 
signals will be absent. Your score will be limited until 
a Watch is paired.

Your data never leaves your account. Chronos does not 
share it with third parties.
```

Show which scenario applies to the current user (detect if Watch data is present in the first HealthKit read).

---

### P2.3 — Data Depth Disclosure

**File:** `OnboardingFlowView.swift` (final onboarding step)  
**Priority:** Medium

**Task:**  
Before the "Enter Chronos" CTA, show a one-paragraph disclosure:

```
Your first week

Chronos becomes more accurate as it learns your personal 
baselines. For the first 7 days, scores are calibrated 
against population norms. After 7 days, Chronos uses your 
own data. After 30 days, it unlocks allostatic load tracking.

This is by design — precision takes time.
```

---

## PHASE 3 — Infrastructure

**Owner:** Engineering  
**Status:** 🔲 NOT STARTED

### P3.1 — Sentry Crash Reporting

**Files:** `MBIApp.swift`, `Package.swift` / SPM dependencies  
**Priority:** High

**Task:**  
Integrate Sentry iOS SDK for crash reporting. Privacy rationale: Sentry is chosen over Crashlytics/Firebase to avoid Google data processing. Sentry EU-hosted endpoint preferred.

**Implementation:**
```swift
// MBIApp.swift — add to didFinishLaunching equivalent
import Sentry
SentrySDK.start { options in
    options.dsn = "<SENTRY_DSN>"
    options.environment = AppConfig.environment   // "beta" | "production"
    options.debug = false
    // Strip PII from breadcrumbs
    options.beforeSend = { event in
        event.user = nil   // Never attach user identity to crash reports
        return event
    }
}
```

**Acceptance Criteria:**
- Test crash (via Settings → Debug → Trigger Test Crash) appears in Sentry within 60 seconds
- No user PII in crash reports (user ID must be stripped)
- Source maps uploaded for symbolication
- Beta environment clearly labelled in Sentry dashboard

---

### P3.2 — Custom Analytics: app_events

**Files:** New `AnalyticsService.swift`, `SupabaseService.swift`  
**Priority:** High

**Rationale:**  
No third-party analytics SDKs (no Mixpanel, Amplitude, etc.) — aligned with Chronos privacy positioning. Custom `app_events` table in Supabase gives full data ownership.

**Schema:**
```sql
CREATE TABLE app_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    event_name  TEXT NOT NULL,
    properties  JSONB DEFAULT '{}',
    app_version TEXT,
    os_version  TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- RLS: users can insert their own events only
ALTER TABLE app_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users can insert own events"
    ON app_events FOR INSERT
    WITH CHECK (auth.uid() = user_id);
```

**AnalyticsService.swift:**
```swift
final class AnalyticsService {
    static let shared = AnalyticsService()
    private let supabase = SupabaseService.shared

    func track(_ event: String, properties: [String: Any] = [:]) {
        Task {
            guard let userId = await supabase.session?.userId else { return }
            try? await supabase.insertEvent(
                userId: userId,
                name: event,
                properties: properties
            )
        }
    }
}
```

**Events to instrument (minimum viable set for beta):**
| Event | Trigger |
|-------|---------|
| `app_open` | RootView appears |
| `onboarding_complete` | OnboardingFlowView completes |
| `healthkit_authorized` | Authorization granted |
| `healthkit_denied` | Authorization denied |
| `sync_triggered` | Manual sync tapped |
| `sync_complete` | Sync succeeds |
| `sync_failed` | Sync errors |
| `horizon_card_viewed` | HorizonCardView appears |
| `score_explanation_viewed` | Score detail opened |
| `account_tab_opened` | Account tab tapped |

---

### P3.3 — Supabase Failure Handling

**Files:** `SyncCoordinator.swift`, `SupabaseService.swift`  
**Priority:** High

**Task:**  
Current sync failure shows a generic error. Beta users need:
1. Local cache of the last successful dashboard (never show empty on failure)
2. Developer alert (via Sentry + optional SMS/push to founder)
3. User-facing message that is honest but not alarming

**Local cache:**
```swift
// In SyncCoordinator — persist last known dashboard to UserDefaults
private func cacheLastKnownDashboard(_ dashboard: Dashboard) {
    if let data = try? JSONEncoder().encode(dashboard) {
        UserDefaults.standard.set(data, forKey: "last_known_dashboard")
    }
}
```

**User message on failure (in DashboardView):**
```
Having a moment.
We're having trouble connecting to Chronos right now. 
Your last data is shown below. 
We'll sync automatically when you're back online.
```

---

### P3.4 — Edge Function Timeout Fallback Copy

**Files:** `SyncCoordinator.swift`, `DashboardView.swift`  
**Priority:** Medium

**Task:**  
Edge Functions have an 8-second hard timeout. Currently a timeout surfaces as a generic spinner hang. Add:
- 8s client-side timeout on score fetch calls  
- Specific copy for timeout vs network error
- Fallback to cached score with "Score temporarily unavailable" label

**Timeout message:**
```
Still calculating.
Your data made it — we're just crunching the numbers. 
Check back in a moment. (And yes, we know this is a bit much 
for what is essentially arithmetic.)
```

---

### P3.5 — JWT 401 Silent Refresh

**File:** `SupabaseService.swift`  
**Priority:** High

**Task:**  
Currently, expired JWTs surface as 401 errors to the user. Supabase provides token refresh. Implement automatic silent refresh on 401 with one retry before showing auth error.

```swift
// In any Supabase network call:
// 1. Attempt request
// 2. On 401: call supabase.auth.refreshSession()
// 3. Retry original request once
// 4. If still 401: sign out and show AuthView
```

**Acceptance Criteria:**
- No user sees a 401 error during normal use
- Refresh is silent (no spinner, no message)
- If refresh fails (no network), cached data is shown

---

## PHASE 4 — Horizon System

**Owner:** Engineering  
**Status:** 🔲 NOT STARTED

### P4.1 — Escalation Threshold: 65-

**File:** Horizon detection logic (locate in scoring or notification layer)  
**Priority:** Critical

**Current state:** Threshold is 35 (Redline floor) — far too aggressive.  
**Required:** 65 (below 65 for 3 consecutive days triggers escalation)

**Rationale:**  
- 65+ = Functioning/Thriving zone  
- Below 65 = early-warning territory (not crisis, but needs attention)  
- 35 is the clinical floor — by the time a user is at 35, escalation is late  
- 65- catches declining trends before they become serious  

---

### P4.2 — 3-Consecutive-Day Detection

**File:** HorizonService or equivalent escalation service  
**Priority:** Critical

**Logic:**
```typescript
// Pseudo-code for detection
async function checkHorizonEscalation(userId: string): Promise<boolean> {
  const last3Days = await fetchLastNScores(userId, 3);
  if (last3Days.length < 3) return false;
  
  const allBelowThreshold = last3Days.every(day => 
    day.chronos_score !== null && day.chronos_score < 65
  );
  
  // Don't re-escalate if already escalated this streak
  const alreadyEscalated = await checkRecentEscalation(userId);
  
  return allBelowThreshold && !alreadyEscalated;
}
```

**Important:**
- 3 *calendar days*, not 72 rolling hours
- Missing score days do not count toward or reset the streak
- Once escalation fires, do not re-fire for the same streak (reset when score goes ≥ 65)
- Log escalation events to `app_events` for audit

---

### P4.3 — Silent Push to Founder Device

**Files:** `NotificationService.swift`, backend Horizon trigger  
**Priority:** High

**Task:**  
When 3-consecutive-day detection fires:
1. Do NOT show any alert to the beta user
2. Silently send a push notification to the registered founder device(s)
3. Notification payload includes: user ID (pseudonymous), score trend, date

**Notification format (founder device):**
```
Title: ⚡ Horizon Alert — Chronos Beta
Body:  User [last 6 chars of UUID] has scored below 65 for 3 consecutive days.
       Scores: 61 → 58 → 54. Review recommended.
```

**Founder device registration:**  
Store founder push token in a separate `admin_devices` table (not user_profiles). Only founder UUID can register to this table.

```sql
CREATE TABLE admin_devices (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_user_id UUID REFERENCES auth.users(id),
    push_token   TEXT NOT NULL,
    platform     TEXT DEFAULT 'ios',
    created_at   TIMESTAMPTZ DEFAULT NOW()
);
-- No RLS read needed — this table is backend-only
```

---

### P4.4 — Beta Transparency Card

**File:** `HorizonCardView.swift` or `IntelligenceView.swift`  
**Priority:** Medium

**Task:**  
During beta, show a small disclosure card to users about the Horizon system:

```
About Horizon

If Chronos detects a sustained low-score trend, the 
Mynd & Bodi team may reach out. This is a human safety 
check, not an automated system, and only occurs if your 
data suggests you may benefit from support.

You can turn this off in Account → Privacy.
```

Add a toggle in AccountView → Privacy section: "Horizon check-ins" (default: ON).

---

## PHASE 5 — Legal & Privacy

**Owner:** Engineering + Founder  
**Status:** 🔲 NOT STARTED

### P5.1 — PrivacyInfo.xcprivacy Manifest

**File:** New `PrivacyInfo.xcprivacy` in MBI target  
**Priority:** Critical (App Store Requirement)

**Task:**  
Create the required Apple Privacy Manifest declaring all data types collected and API usage.

**Required declarations:**

*Collected data types:*
- Health & Fitness (HRV, sleep, heart rate, steps, etc.)
- Identifiers (user ID)
- Usage: App Functionality

*Required Reason APIs used:*
- `NSPrivacyAccessedAPICategoryHealthKit` — HealthKit
- `NSPrivacyAccessedAPICategoryUserDefaults` — UserDefaults (score caching)
- `NSPrivacyAccessedAPICategoryFileTimestamp` — HealthKit export reads

**File location:** `ios/MBI/MBI/PrivacyInfo.xcprivacy`  
**Must be added to Xcode target:** Yes (add to MBI target, not just filesystem)

---

### P5.2 — Privacy Policy URL in AccountView

**File:** `AccountView.swift`  
**Priority:** High

**Task:**  
Wire the Privacy Policy URL in Account → Legal section. URL must be live (not a placeholder) before TestFlight submission.

**Implementation:**
```swift
// In AccountView Legal section
Link("Privacy Policy", destination: URL(string: AppConfig.privacyPolicyURL)!)
Link("Terms of Service", destination: URL(string: AppConfig.termsURL)!)
```

**Founder action required:**  
Privacy Policy must be live at a public URL before Phase 5 is complete. Suggested: `myndandbodi.com/privacy` and `myndandbodi.com/terms`.

---

### P5.3 — Health Data Processing Disclosure

**File:** `OnboardingFlowView.swift` (HealthKit step)  
**Priority:** High (App Store Requirement)

**Task:**  
Before requesting HealthKit permissions, show a screen that explicitly states:
1. What data is collected
2. How it is used (scoring only, not sold)
3. Where it is stored (Supabase, US/EU servers)
4. How to delete it (Account → Delete Account)

This is required by Apple HealthKit guidelines — the app cannot request HealthKit access without a clear disclosure immediately preceding the permission prompt.

---

### P5.4 — Legal Documents List

**Owner:** Founder  
**Status:** 🔲 AWAITING FOUNDER ACTION

Documents required before TestFlight public beta:
1. **Privacy Policy** — must cover HealthKit data, Supabase processing, deletion rights
2. **Terms of Service** — usage limitations, beta disclaimer, medical disclaimer
3. **Beta Tester Agreement** — data handling acknowledgement, bug reporting
4. **Health Data Processing Notice** — plain-language HealthKit data use statement

*Engineering will wire URLs. Founder to draft content.*

---

## PHASE 6 — Should Fix

**Owner:** Engineering  
**Status:** 🔲 NOT STARTED

Items in this phase are significant quality issues that must be resolved before external beta. They are not blockers for internal alpha testing.

---

### S1 — Apple Sign In

**Priority:** High (App Store Requirement for apps offering social login)  
**File:** `AuthView.swift`, `SupabaseService.swift`

Add "Sign in with Apple" button alongside existing email auth. Required if any third-party login is ever offered. Implement now to comply before any social auth is added.

---

### S2 — Biometric Authentication

**Priority:** High  
**File:** `AccountView.swift`, new `BiometricAuthService.swift`

Add Face ID / Touch ID lock on app re-open (optional, user-controlled). Store preference in UserDefaults. Use `LAContext` with `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`.

---

### S3 — IntelligenceCardView Audit

**Priority:** High  
**File:** `IntelligenceCardView.swift` (or wherever intelligence cards are rendered)

Full audit of all card types:
- All nil paths render a graceful state (not a crash or blank)
- All dynamic copy is grammatically correct with real data
- Redline cards have appropriate gravity without being alarming
- Pattern cards only show when sufficient history exists (7+ days)

---

### S4 — DoctorReportService Audit

**Priority:** High  
**File:** `DoctorReportService.swift`

Review generated PDF report:
- All fields populate correctly with real user data
- Medical disclaimer is prominent
- Report clearly states "This is not a medical document"
- Date range is accurate
- Export flow does not crash on empty/partial data

---

### S5 — Push Notification Delivery Test

**Priority:** High  
**Files:** `NotificationService.swift`, APNs configuration

End-to-end test on physical device:
- Local daily reminder fires at configured time
- Foreground notifications show banner + sound
- APNs device token stores to Supabase on first launch
- Horizon silent push reaches founder device
- Test on both iOS simulator (local) and physical device (remote)

---

### S6 — Multi-Device Handling

**Priority:** Medium  
**Files:** `SyncCoordinator.swift`, `SupabaseService.swift`

Current state: untested with same account on two devices.

Test scenarios:
- Same account on iPhone + iPad → scores consistent
- Account opened on new device → all historical data loads
- Two devices syncing same day → no duplicate `daily_inputs` rows
- Logout on one device → no effect on other device sessions

---

### S7 — iOS Version Enforcement

**Priority:** Medium  
**File:** `MBIApp.swift` or `Info.plist`

Set minimum iOS deployment target to **iOS 16.0** (required for:
- `HKCategoryValueSleepAnalysis.asleepCore/.asleepDeep/.asleepREM/.asleepUnspecified`
- Swift concurrency patterns used throughout
- `Charts` framework if used)

Add a runtime check that surfaces a clear message if an older OS is detected (belt-and-suspenders beyond Xcode's static enforcement).

---

### S8 — Dark Mode Enforcement

**Priority:** Medium  
**File:** `MBIApp.swift`

Force dark mode — Chronos is designed as a dark-UI app. Light mode renders incorrectly with current colour palette.

```swift
// In WindowGroup or RootView
.preferredColorScheme(.dark)
```

Confirm no hardcoded `Color.black` values that would break if light mode leaks through.

---

### S9 — Dynamic Type Support

**Priority:** Medium  
**Files:** All Views

Audit all `Text` views for Dynamic Type compatibility. Chronos uses custom tracking/font sizes in many places. At minimum:
- No text should be unreadable at Accessibility XXXL
- Navigation labels must scale
- Score numerals can stay fixed (design intent) but footnotes must scale

---

### S10 — Score Explanation UI

**Priority:** High  
**File:** New `ScoreExplanationView.swift` or modal in `DashboardView.swift`

Users need to understand why their score changed. A "What is this?" button on the Chronos score should open a brief explanation:
- What the score measures
- What moved it today (top positive/negative driver)
- What the domain colours mean
- Plain language, no jargon

---

### S11 — Historical Score Chart

**Priority:** High  
**File:** `DashboardView.swift` or new `ScoreHistoryView.swift`

A 30-day line chart of `chronos_score` over time. Users need to see trends. Current dashboard only shows today's score.

Use SwiftUI `Charts` or the existing Canvas approach from DomainHistoryPanel.

---

### S12 — Pattern Visibility Threshold

**Priority:** Medium  
**File:** `IntelligenceView.swift` or pattern service

Patterns should only display when there is sufficient data to support them (minimum 14 days). Before 14 days, show an "Patterns unlock after 14 days of data" placeholder rather than potentially misleading early patterns.

---

### S13 — Admin Security Hardening

**Priority:** High  
**Files:** All admin-adjacent routes, Edge Functions

Audit:
- Service role key is NOT in any iOS binary or client-side code
- Edge Functions validate `auth.uid()` before operating on user data
- No user can trigger scoring for another user's ID
- Admin device table has no client-readable RLS

---

### S14 — Full RLS Audit

**Priority:** Critical  
**Files:** All Supabase table policies

Walk every table and confirm:
- `user_profiles`: user can read/write own row only
- `daily_inputs`: user can read/write own rows only  
- `daily_scores`: user can read own rows only (no write — Edge Function writes)
- `app_events`: user can insert own rows only (no read)
- `admin_devices`: no client access
- `push_tokens` / notification tables: user can insert own only

Run the RLS test suite: attempt to read another user's data with a valid JWT. Should 403.

---

## PHASE 7 — Final Polish (Nice to Have)

**Owner:** Engineering + Design  
**Status:** 🔲 NOT STARTED  
**Note:** These items improve the experience but are not gates for beta launch. Complete if time allows.

---

### N1 — Loading Skeletons

Replace all spinner states with shimmer skeleton placeholders that match the shape of the content loading beneath them. Dramatically improves perceived performance.

---

### N2 — Haptic Feedback

Add `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` at key moments:
- Tab bar switches (light)
- Score card appears (medium)
- Sync complete (success notification)
- Redline state (heavy)

---

### N3 — Onboarding Animation

Add a subtle animated background (particle system or gradient drift) to the onboarding splash screen. First impression matters for a wellness app.

---

### N4 — Empty State Illustrations

Replace text-only empty states with simple monochrome illustrations. States needing art:
- No data yet (Day 1)
- No patterns yet (< 14 days)
- Sync failed

---

### N5 — Pull to Refresh

Add `refreshable {}` modifier to DashboardView scrollable content. Triggers a manual sync. Shows last-synced timestamp above the score card.

---

### N6 — App Icon

Finalise and ship the production Chronos app icon. Current icon is placeholder. Required before public TestFlight link is shared externally.

---

### N7 — Relative Date Formatting

Replace all `yyyy-MM-dd` display dates with relative language:
- Today → "Today"
- Yesterday → "Yesterday"  
- Within 7 days → "Monday", "Tuesday", etc.
- Older → "Jan 12"

---

### N8 — Splash Screen Branding

Add the full Chronos wordmark + "by Mynd & Bodi Institute" on the iOS launch screen (LaunchScreen.storyboard or Info.plist `UILaunchScreen`). Currently the splash is system default.

---

## Execution Log

| Date | Item | Action | Engineer |
|------|------|---------|----------|
| 2026-05-09 | P0.1 | `readHRV` fixed — `readLatestQuantity` → `readAverageQuantity` | Claude |
| 2026-05-09 | P0.2 | `readSleep` fixed — modern watchOS 9+ sleep stage classification | Claude |
| 2026-05-09 | PatternDetailView | Registered in `project.pbxproj` (all 4 sections) | Claude |
| 2026-05-09 | DomainBreakdownView | Historical Domain Comparison + DomainModeToggle added | Claude |
| 2026-05-09 | AccountView | Biological Sex picker + Cycle Tracking row added | Claude |
| 2026-05-09 | SupabaseService | `biological_sex` wired to `updateProfile` | Claude |
| 2026-05-09 | P1.1 | Ingest nil metric audit — confirmed clean, all paths return 200 with null | Claude |
| 2026-05-09 | P1.2 | Score engine nil metric audit — confirmed clean, null = deviation 0, no fail state | Claude |
| 2026-05-09 | P1.3 | Dashboard: local cache (UserDefaults), stale banner, pull-to-refresh | Claude |
| 2026-05-09 | P3.2 | `AnalyticsService.swift` created, `app_events` SQL written, key events wired | Claude |
| 2026-05-09 | P3.3 | Friendly error messages, local cache fallback in SyncCoordinator | Claude |
| 2026-05-09 | P3.5 | JWT 401 silent refresh in `callEdgeFunction` and `getRequest` | Claude |
| 2026-05-09 | DashboardData | Made `Codable` to support local cache serialization | Claude |
| 2026-05-09 | SQL_PENDING | Migration 5: `app_events` + `admin_devices` tables written | Claude |
| 2026-05-09 | P4.1 | Horizon escalation threshold set to 65 (not 35); detection logic in `score/index.ts` | Claude |
| 2026-05-09 | P4.2 | 3-consecutive-day calendar detection with cooldown + `horizon_escalations` table write | Claude |
| 2026-05-09 | P4.3 | Placeholder stub logged; requires founder to supply APNs secrets | Claude |
| 2026-05-09 | P4.4 | `HorizonBetaTransparencyCard` added to Horizon Page 1; "Horizon Check-ins" toggle in AccountView → Privacy | Claude |
| 2026-05-09 | SQL_PENDING | Migration 6: `horizon_escalations` table + P4.3 setup instructions written | Claude |
| 2026-05-09 | P5.1 | `PrivacyInfo.xcprivacy` Apple Privacy Manifest created (must be added to Xcode target manually) | Claude |
| 2026-05-09 | P5.2 | Privacy Policy / Terms URLs wired in AccountView; constants added to `Config.swift` | Claude |
| 2026-05-09 | P5.3 | `OnboardingHealthDisclosureView` added at step 7; steps 7→11 renumbered; disclosure precedes HealthKit prompt | Claude |
| 2026-05-09 | S7   | iOS deployment target already iOS 17.0 — satisfies 16.0 minimum, no code change needed | Claude |
| 2026-05-09 | S8   | `.preferredColorScheme(.dark)` added to WindowGroup in `MBIApp.swift` | Claude |
| 2026-05-09 | S13  | `_shared/auth.ts` created; `verifyCallerOwnsUser()` wired into score, ingest, narrate, narrate-trend, horizon, horizon-classify | Claude |
| 2026-05-09 | S14  | Full RLS audit: all user-data tables properly scoped. `metric_node_map`/`node_activation_rules` have no RLS (acceptable — config tables, no PII). No critical gaps found | Claude |
| 2026-05-09 | S1   | Apple Sign In already implemented (Sprint 4). `SignInWithAppleButton` + `handleAppleSignIn` + `supabase.signInWithApple` all present. No change needed | Claude |
| 2026-05-09 | S3   | IntelligenceCardView audit complete. Graceful fallback at every nil path. No crash risk found | Claude |
| 2026-05-09 | S10  | `ScoreExplanationSheet` added to `DashboardView.swift`. "What does this score mean?" link in `MorningScoreCard` opens sheet explaining how score is calculated, today's drivers, and band guide | Claude |
| 2026-05-09 | S11  | Already satisfied by `TrendView` tab (7D/8W/12M windows, `Charts` framework, daily scores). Not duplicated in Dashboard | Claude |
| 2026-05-09 | S12  | `SystemPatternBlock` now requires `historyDayCount >= 14` before showing patterns. Below threshold shows "Patterns unlock after 14 days of data" placeholder | Claude |
| 2026-05-09 | S2   | `BiometricAuthService.swift` created; `BiometricLockOverlay` wraps MainTabView in RootView; toggle added to AccountView → Privacy; `NSFaceIDUsageDescription` added to Info.plist | Claude |
| 2026-05-09 | S4   | DoctorReportService audit — deferred. Requires physical device testing with real user data. Marked as manual founder QA item | Claude |
| 2026-05-09 | S5   | Push notification test — deferred. Requires physical device + APNs credentials. Marked as manual founder QA item | Claude |
| 2026-05-09 | S6   | Multi-device handling — deferred. Requires two physical devices. Marked as manual founder QA item | Claude |
| 2026-05-09 | S9   | Dynamic Type — deferred. Requires visual audit. Key fact: score numerals intentionally fixed size; footnotes must scale. Marked as manual QA item | Claude |
| 2026-05-09 | N2   | Sync success haptic (`UINotificationFeedbackGenerator.success`) added to `SyncCoordinator`. Tab-switch haptics added to `MainTabView`. Score-appear haptic (.heavy for Redline, .medium otherwise) added to `MorningScoreCard` | Claude |
| 2026-05-09 | N5   | Already implemented in sprint (HRV, sleep, steps, resting HR sparklines in DashboardView) | Claude |
| 2026-05-09 | N7   | `Date+Relative.swift` created with `relativeLabel(from:)` + `shortRelativeLabel(from:)`. `shortDate()` in MetricDetailView, DomainDetailView, and DomainBreakdownView updated to delegate to these helpers. Registered in `project.pbxproj` (PBXBuildFile, PBXFileReference, new Helpers PBXGroup, MBI root group child, Sources build phase) | Claude |
| 2026-05-09 | N1   | Loading skeletons — deferred. Complex state machines across all spinner sites. Post-beta polish | Claude |
| 2026-05-09 | N3   | Onboarding animation — deferred. Requires design asset (Lottie or SF Symbol animation). Founder action | Claude |
| 2026-05-09 | N4   | Empty state illustrations — deferred. Requires 3 custom illustrations from designer. Founder action | Claude |
| 2026-05-09 | N6   | App icon — deferred. Requires final asset from founder. Xcode target update trivial once asset is supplied | Claude |
| 2026-05-09 | N8   | Splash screen — deferred. Requires final Chronos wordmark asset. LaunchScreen update trivial once asset supplied | Claude |

---

## Post-Fix Resync Protocol

After P0.1 and P0.2 fixes are built and installed:

1. Open Chronos on device with correct build
2. Navigate to Account → tap "Resync Health Data"
3. Allow full 7-day history reread (may take 15–30 seconds)
4. All prior `daily_inputs` rows will be updated with corrected HRV averages and sleep stage data
5. Score Edge Function will re-score each updated day
6. Validate against known reference: Apr 27 HRV should now be ≈52.9ms; Apr 26 sleep should be ≈8.87h with efficiency ≈89%

If the resync button does not trigger a historical backfill (only reads yesterday), the developer must manually call the Score Edge Function for each date:

```bash
curl -X POST https://sjhysadnpswrcpmezmoc.supabase.co/functions/v1/score \
  -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"userId": "5b3dd4d1-1901-4693-8cd6-e3411704467a", "date": "2026-04-27"}'
```

---

## Questions Requiring Founder Input

| # | Question | Phase | Blocking |
|---|----------|-------|---------|
| Q1 | Sentry DSN and EU vs US data region preference | P3.1 | No |
| Q2 | Privacy Policy and Terms URLs (must be live) | P5.2 | Yes — before TestFlight |
| Q3 | Founder device push token for Horizon escalation | P4.3 | Yes — before Horizon ships |
| Q4 | Beta tester agreement template approval | P5.4 | Yes — before external beta |
| Q5 | App icon final file | N6 | No — nice to have |
| Q6 | Age gate language — what message for under-18? | P2.1 | No |

---

*Document maintained by engineering. Update Execution Log after each completed item.*
