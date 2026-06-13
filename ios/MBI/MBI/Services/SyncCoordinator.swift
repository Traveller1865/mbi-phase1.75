// ios/MBI/Services/SyncCoordinator.swift
// MBI Phase 1 — Sync Coordinator
// Orchestrates: HealthKit reads → ingest → score → narrate
// iOS client never computes or interprets values.
// Data Tier v1.0: gap detection (§6), gap validation prompt (§7),
//                 escalation threshold (§8), consecutive gap failsafe (§12)

import Foundation
import UIKit

enum SyncState: Equatable {
    case idle
    case syncing(String)
    case complete
    case failed(String)
    case stale // cached data, sync not yet run this session
}

@MainActor
class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()

    @Published var syncState: SyncState = .idle
    @Published var dashboard: DashboardData?
    @Published var trendData: [TrendPoint] = []
    /// Active correction flags for today's score row. Empty when window expired or all resolved.
    @Published var correctionFlags: [CorrectionFlag] = []

    // ── Section 7: Gap validation prompt state ──────────────────────────────
    /// True when today's sync produced a steps_only day that needs user validation.
    @Published var showGapValidationPrompt: Bool = false
    /// Device name shown in the gap validation prompt (e.g. "Apple Watch").
    @Published var gapValidationDeviceName: String = "Apple Watch"
    /// Date string (yyyy-MM-dd) of the pending gap validation day.
    @Published var gapValidationDate: String = ""

    private let healthKit = HealthKitManager.shared
    private let supabase = SupabaseService.shared

    // ── Section 12: Consecutive gap failsafe ────────────────────────────────
    /// Number of consecutive steps_only/unknown days before triggering escalation.
    private let CONSECUTIVE_GAP_THRESHOLD = 5
    private let consecutiveGapKey         = "consecutiveGapCount"
    private let consecutiveGapLastDateKey = "consecutiveGapLastDate"

    // ── Section 8: Sync failure escalation ──────────────────────────────────
    private let syncFailureDatesKey = "syncFailureDates"
    private let escalationFlaggedKey = "escalationFlagged"

    // ─────────────────────────────────────────
    // PERSISTED SYNC DATES
    // Survive app kills. Reset to nil at midnight check.
    // ─────────────────────────────────────────

    private let morningSyncKey  = "lastMorningSyncDate"
    private let eveningNarrateKey = "lastEveningNarrateDate"

    private var lastMorningSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: morningSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: morningSyncKey) }
    }

    private var lastEveningNarrateDate: Date? {
        get { UserDefaults.standard.object(forKey: eveningNarrateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: eveningNarrateKey) }
    }

    // Clears both persisted dates if they are from a previous calendar day.
    private func resetIfNewDay() {
        let cal = Calendar.current
        if let d = lastMorningSyncDate, !cal.isDateInToday(d) {
            lastMorningSyncDate = nil
        }
        if let d = lastEveningNarrateDate, !cal.isDateInToday(d) {
            lastEveningNarrateDate = nil
        }
    }

    // ─────────────────────────────────────────
    // DAILY SYNC — triggered on app open
    // ─────────────────────────────────────────

    func runDailySync(userId: String) async {
        guard syncState != .syncing("") else { return }

        // Capture and persist device timezone at every app launch.
        // Best-effort — failure is silently swallowed. Required by 5pm local fallback.
        Task { await supabase.updateTimezone(userId: userId) }

        resetIfNewDay()

        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let isPastFivePM = hour >= 17

        if !isPastFivePM {
            // ── Morning window ──────────────────────────────────────────
            if lastMorningSyncDate == nil {
                await runFullSync(userId: userId, briefSession: "morning")
                lastMorningSyncDate = Date()
            } else {
                await loadDashboard(userId: userId)
            }

        } else {
            // ── Evening window (5pm+) ───────────────────────────────────
            // Morning sync must have run first — it owns the score row.
            if lastMorningSyncDate == nil {
                await runFullSync(userId: userId, briefSession: "morning")
                lastMorningSyncDate = Date()
            }

            if lastEveningNarrateDate == nil {
                await runEveningNarrate(userId: userId)
                lastEveningNarrateDate = Date()
            } else {
                await loadDashboard(userId: userId)
            }
        }
    }

    // ─────────────────────────────────────────
    // FULL SYNC — ingest + score + narrate(morning)
    // ─────────────────────────────────────────

    private func runFullSync(userId: String, briefSession: String) async {
        AnalyticsService.shared.track(.syncTriggered)
        syncState = .syncing("Reading Apple Health data...")

        do {
            try await healthKit.requestAuthorization()

            // 1. Read yesterday's metrics from HealthKit
            let metrics = try await healthKit.readYesterday()

            syncState = .syncing("Syncing to server...")

            let payload = metrics.toPayloadDict(userId: userId)
            let scoreDate = payload["date"] as? String ?? ""

            // 2. Single orchestrator call — replaces sequential ingest + score + narrate.
            //    The orchestrator runs the full pipeline server-side and returns once complete.
            //    One cold start maximum instead of N sequential cold starts.
            _ = try await supabase.triggerOrchestrator(
                userId: userId,
                date:   scoreDate.isEmpty ? supabase.todayString() : scoreDate,
                payload: payload
            )

            // Post-score verification — detect silent pipeline stalls.
            if !scoreDate.isEmpty {
                let scoreExists = await supabase.checkScoreExists(userId: userId, date: scoreDate)
                if !scoreExists {
                    print("[pipeline] ⚠️ Score missing after orchestrator for \(scoreDate) — " +
                          "baseline still building or scoring failed silently. Check edge function logs.")
                }
            }

            // ── Section 6: Data gap detection ──────────────────────────────────
            let localTier = classifyLocalDataTier(metrics)
            if localTier == "steps_only" && !scoreDate.isEmpty {
                UserDefaults.standard.set(true,      forKey: "pendingGapValidation")
                UserDefaults.standard.set(scoreDate, forKey: "pendingGapValidationDate")
                print("[gap] steps_only day detected for \(scoreDate) — gap validation pending")
            }

            // ── Section 12: Consecutive gap failsafe ───────────────────────────
            updateConsecutiveGapStreak(date: scoreDate, isGap: localTier == "steps_only" || localTier == "unknown")

            // narrate-detail: 7-day system narrative (not in orchestrator — separate cadence)
            await callNarrateDetail(userId: userId, date: supabase.todayString())

            // 3. Load dashboard
            syncState = .syncing("Loading your score...")
            await loadDashboard(userId: userId)

            syncState = .complete
            AnalyticsService.shared.track(.syncComplete)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }

            // ── Section 7: Check if gap validation prompt should be shown ───────
            await checkPendingGapValidation(userId: userId)

        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled { return }

            let raw = error.localizedDescription
            print("[sync] ❌ pipeline failed — raw error: \(raw)")
            print("[sync] ❌ full error: \(error)")
            if raw.contains("404") {
                syncState = .complete
            } else {
                let friendlyMsg: String
                if raw.contains("401") || raw.contains("JWT") || raw.contains("expired") {
                    friendlyMsg = "Session expired. Tap to refresh."
                } else if raw.contains("offline") || raw.contains("network")
                    || raw.contains("connection") || raw.contains("URLError")
                    || raw.contains("timeout") || raw.contains("timed out") {
                    friendlyMsg = "No connection right now.\nYour last score is shown below."
                } else {
                    friendlyMsg = "Something went wrong on our end.\nYour last score is shown below."
                }
                syncState = .failed(friendlyMsg)
                AnalyticsService.shared.track(.syncFailed, properties: ["reason": friendlyMsg])

                // ── Section 8: Record sync failure for escalation check ─────────
                let today = supabase.todayString()
                recordSyncFailure(date: today)
            }
            await loadDashboard(userId: userId)
        }
    }

    // ─────────────────────────────────────────
    // EVENING NARRATE — narrate only, no ingest or score
    // Writes evening_explanation_text + evening_nudge_text.
    // ─────────────────────────────────────────

    private func runEveningNarrate(userId: String) async {
        // Use the score's actual date — HealthKit syncs yesterday's data, so the score
        // row is dated yesterday. todayString() would point to a non-existent row.
        // If dashboard is not yet in memory (evening open after morning sync in a prior session),
        // load it first so scoreDate is available.
        if dashboard == nil {
            await loadDashboard(userId: userId)
        }
        guard let scoreDate = dashboard?.score.date else {
            print("[SyncCoordinator] Evening narrate skipped — no score date available")
            return
        }
        do {
            try await supabase.triggerEveningNarrate(userId: userId, date: scoreDate)
            await callNarrateDetail(userId: userId, date: scoreDate)
            await loadDashboard(userId: userId)
        } catch {
            // Non-fatal — morning brief remains visible if evening call fails.
            print("[SyncCoordinator] Evening narrate failed (non-fatal): \(error)")
            await loadDashboard(userId: userId)
        }
    }

    // ─────────────────────────────────────────
    // BASELINE BOOTSTRAP — first launch
    // Reads full available history, sends all at once.
    // ─────────────────────────────────────────

    func runBaselineBootstrap(userId: String, onProgress: @escaping (Int, Int) -> Void) async throws {
        syncState = .syncing("Reading your Apple Health history...")

        try await healthKit.requestAuthorization()

        let history = try await healthKit.readFullHistory(maxDays: 90)
        let total = max(history.count, 1)

        onProgress(0, total)

        let today = supabase.todayString()

        for (i, day) in history.enumerated() {
            onProgress(i + 1, total)
            let payload = day.toPayloadDict(userId: userId)
            do {
                if day.date == today {
                    // Today's data gets the full pipeline including narrate.
                    try await supabase.triggerDailySync(
                        userId: userId,
                        payload: payload,
                        briefSession: "morning"
                    )
                } else {
                    // Historical days skip narrate — those briefs are never read,
                    // and each Claude call adds 2–4 seconds per day.
                    try await supabase.triggerHistoricalDaySync(userId: userId, payload: payload)
                }
            } catch {
                print("[bootstrap] Day \(day.date) failed: \(error)")
            }
        }

        await loadDashboard(userId: userId)
        lastMorningSyncDate = Date()
        syncState = .complete
    }

    // ─────────────────────────────────────────
    // LOAD DASHBOARD (from Supabase, with local cache fallback)
    // ─────────────────────────────────────────

    func loadDashboard(userId: String) async {
        do {
            if let data = try await supabase.fetchTodayDashboard(userId: userId) {
                dashboard = data
                persistDashboard(data)
                await checkCorrectionFlags(userId: userId)
                return
            }
            if let data = try await supabase.fetchMostRecentDashboard(userId: userId) {
                dashboard = data
                persistDashboard(data)
                await checkCorrectionFlags(userId: userId)
            } else {
                print("[loadDashboard] fetchMostRecentDashboard returned nil — checking cache")
                if let cached = loadCachedDashboard() {
                    var stale = cached
                    stale.isStale = true
                    dashboard = stale
                }
            }
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            print("[loadDashboard] Supabase error: \(error)")
            if let cached = loadCachedDashboard() {
                var stale = cached
                stale.isStale = true
                dashboard = stale
                AnalyticsService.shared.track(.syncCacheServed)
            }
        }
    }

    // ─────────────────────────────────────────
    // LOCAL CACHE — UserDefaults persistence
    // ─────────────────────────────────────────

    private let cacheKey = "chronos_last_dashboard"

    private func persistDashboard(_ data: DashboardData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: cacheKey)
    }

    private func loadCachedDashboard() -> DashboardData? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(DashboardData.self, from: data) else { return nil }
        return decoded
    }

    func loadTrendData(userId: String) async {
        do {
            let points = try await supabase.fetchTrendData(userId: userId)
            trendData = points
        } catch {
            print("[loadTrendData] \(error)")
        }
    }

    // ─────────────────────────────────────────
    // CORRECTION FLAG CHECK  (Step 8, Part B + G)
    // Runs after every loadDashboard. Evaluates the five domain signals,
    // filters out already-dismissed/applied flags, and enforces the 24-hour window.
    // ─────────────────────────────────────────

    func checkCorrectionFlags(userId: String) async {
        guard let score = dashboard?.score else {
            correctionFlags = []
            return
        }

        // Compute window expiry from created_at (ISO-8601) + 24h
        let windowExpiry: Date
        if let createdStr = score.createdAt,
           let createdDate = ISO8601DateFormatter().date(from: createdStr) {
            windowExpiry = createdDate.addingTimeInterval(86_400)
        } else {
            // Fallback: treat score date as start of that calendar day + 24h
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let base = fmt.date(from: score.date) ?? Date()
            windowExpiry = base.addingTimeInterval(86_400)
        }

        let now = Date()

        // Window expired — write auto-dismissed rows for any unresolved flags and clear.
        // We still run detection so we know which signals to auto-dismiss.
        let windowOpen = now < windowExpiry

        // Detect raw flags
        var detected = detectFlaggedSignals(score: score, windowExpiry: windowExpiry)

        guard !detected.isEmpty else {
            correctionFlags = []
            return
        }

        // If window has closed, auto-dismiss any flags that have no resolution yet and return.
        if !windowOpen {
            await autoExpireFlags(userId: userId, score: score, flags: detected, windowExpiry: windowExpiry)
            correctionFlags = []
            return
        }

        // Filter out signals already resolved (dismissed or applied) in the DB
        do {
            let existing = try await supabase.fetchCorrectionsForDate(userId: userId, date: score.date)
            let resolvedSignals = Set(existing.filter { $0.dismissed || $0.isApplied }.map { $0.signalName })
            detected = detected.filter { !resolvedSignals.contains($0.signalKey) }
        } catch {
            print("[correctionCheck] fetch existing corrections failed: \(error)")
        }

        correctionFlags = detected
    }

    /// Pure domain-value analysis — no DB calls. Returns one flag per problematic signal.
    private func detectFlaggedSignals(score: DailyScore, windowExpiry: Date) -> [CorrectionFlag] {
        struct SignalSpec {
            let key: String
            let displayName: String
            let value: Double?
            let minValid: Double
            let maxValid: Double
        }

        let specs: [SignalSpec] = [
            SignalSpec(key: "d1_autonomic",  displayName: "Autonomic Reading", value: score.d1Autonomic,  minValid: 0,   maxValid: 250),
            SignalSpec(key: "d2_sleep",      displayName: "Sleep Data",        value: score.d2Sleep,      minValid: 0,   maxValid: 100),
            SignalSpec(key: "d3_activity",   displayName: "Activity Data",     value: score.d3Activity,   minValid: 0,   maxValid: 100),
            SignalSpec(key: "d4_stress",     displayName: "Recovery Stress",   value: score.d4Stress,     minValid: 0,   maxValid: 100),
            SignalSpec(key: "d5_allostatic", displayName: "Body Load",         value: score.d5Allostatic, minValid: 0,   maxValid: 100),
        ]

        // Provisional / fail state — flag all signals that have no value
        let isProvisionalOrFailed = score.isProvisional || score.failState != nil

        var flags: [CorrectionFlag] = []
        for spec in specs {
            if isProvisionalOrFailed && spec.value == nil {
                flags.append(CorrectionFlag(
                    id: spec.key, signalKey: spec.key,
                    displayName: spec.displayName,
                    reason: .provisional, value: nil,
                    windowExpiresAt: windowExpiry
                ))
                continue
            }

            guard let v = spec.value else {
                flags.append(CorrectionFlag(
                    id: spec.key, signalKey: spec.key,
                    displayName: spec.displayName,
                    reason: .missing, value: nil,
                    windowExpiresAt: windowExpiry
                ))
                continue
            }

            // d1_autonomic: impossible if <= 0 (>250 is also impossible)
            let impossible = spec.key == "d1_autonomic"
                ? (v <= 0 || v > spec.maxValid)
                : (v < spec.minValid || v > spec.maxValid)

            if impossible {
                flags.append(CorrectionFlag(
                    id: spec.key, signalKey: spec.key,
                    displayName: spec.displayName,
                    reason: .implausible, value: v,
                    windowExpiresAt: windowExpiry
                ))
            }
        }
        return flags
    }

    /// After the window closes, writes auto-dismissed rows for any flags with no existing record.
    private func autoExpireFlags(userId: String, score: DailyScore, flags: [CorrectionFlag], windowExpiry: Date) async {
        do {
            let existing = try await supabase.fetchCorrectionsForDate(userId: userId, date: score.date)
            let alreadyRecorded = Set(existing.map { $0.signalName })
            for flag in flags where !alreadyRecorded.contains(flag.signalKey) {
                _ = try? await supabase.insertCorrection(
                    userId: userId,
                    date: score.date,
                    signalName: flag.signalKey,
                    originalValue: flag.value,
                    correctedValue: flag.value ?? 0,
                    correctionType: "missing_acknowledged",
                    windowExpiresAt: windowExpiry,
                    isApplied: false,
                    dismissed: true
                )
            }
        } catch {
            print("[autoExpire] \(error)")
        }
    }

    // ─────────────────────────────────────────
    // NARRATE-DETAIL — 7-day system narrative
    // Called after narrate in every sync path. Failure is non-fatal.
    // bypassCache = true skips the client-side 23-hour check (forceSync path).
    // ─────────────────────────────────────────

    private func callNarrateDetail(userId: String, date: String, bypassCache: Bool = false) async {
        if !bypassCache {
            if let generatedAtStr = dashboard?.explanation?.detailGeneratedAt,
               let generatedAt = ISO8601DateFormatter().date(from: generatedAtStr),
               Date().timeIntervalSince(generatedAt) < 23 * 3_600 {
                return
            }
        }
        do {
            try await supabase.triggerNarrateDetail(userId: userId, date: date)
        } catch {
            print("[SyncCoordinator] narrate-detail failed (non-fatal): \(error)")
        }
    }

    func markStale() {
        syncState = .stale
    }

    /// Pull-to-refresh: refreshes today's data without re-running ingest or score.
    /// Returns quickly so the refreshable gesture is not held open. If the brief
    /// is missing, fires narrate in an unstructured Task so it is not cancelled
    /// when the refreshable Task ends.
    func forceSync(userId: String) async {
        syncState = .syncing("Refreshing...")
        await loadDashboard(userId: userId)
        syncState = .complete  // Return here — releases the refreshable gesture

        guard dashboard?.explanation == nil, let scoreDate = dashboard?.score.date else { return }

        // Narrate call runs independently — not tied to the refreshable Task lifecycle.
        // URLSession respects Swift cooperative cancellation; keeping this outside the
        // refreshable Task prevents the -999 cancelled error.
        Task { [weak self] in
            guard let self else { return }
            let hour = Calendar.current.component(.hour, from: Date())
            let timeOfDay = hour >= 17 ? "evening" : (hour >= 12 ? "daytime" : "morning")
            do {
                // Recovery path always writes to morning columns (explanation_text).
                // Evening narrate is a scheduled path via runEveningNarrate — not recovery.
                // Passing briefSession "morning" with time-aware timeOfDay gives the user
                // contextually framed content while guaranteeing explanation_text is never null.
                try await supabase.triggerNarrateOnly(
                    userId: userId, date: scoreDate,
                    briefSession: "morning", timeOfDay: timeOfDay
                )
                await loadDashboard(userId: userId)
                // User explicitly requested a refresh — bypass the 23-hour client cache.
                await callNarrateDetail(userId: userId, date: scoreDate, bypassCache: true)
                await loadDashboard(userId: userId)
            } catch {
                print("[forceSync] narrate failed (date: \(scoreDate)): \(error)")
            }
        }
    }

    // ─────────────────────────────────────────
    // HISTORICAL BACKFILL
    // One-time operation: reads all available HealthKit history, ingests and scores
    // any dates not already present in daily_inputs. Called from Settings or post-onboarding.
    // ─────────────────────────────────────────

    /// Numeric progress published for the ResyncCard progress bar.
    @Published var backfillDone: Int = 0
    @Published var backfillTotal: Int = 0
    @Published var backfillProgress: String = ""

    func runHistoricalBackfill(userId: String) async {
        syncState = .syncing("Reading health history...")
        backfillProgress = ""
        backfillDone = 0
        backfillTotal = 0

        // DIAGNOSTIC 1 — simulator guard check
        print("[Backfill] isHealthDataAvailable: \(healthKit.isHealthDataAvailable())")
        print("[Backfill] Running on: \(ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "real device")")

        // DIAGNOSTIC 5 — HealthKit authorization status for steps
        let stepsAuthStatus = healthKit.authorizationStatusForSteps()
        print("[Backfill] Steps write-share auth: \(stepsAuthStatus) (1=sharingDenied is normal — HealthKit read auth is not queryable)")

        // 1. Read all available HealthKit history (up to 365 days)
        let allDays: [HealthKitManager.RawDayMetrics]
        do {
            allDays = try await healthKit.readFullHistory(maxDays: 365)
        } catch {
            print("[Backfill] HealthKit read failed: \(error)")
            syncState = .complete
            return
        }

        // DIAGNOSTIC 3 — date range being queried
        let calendar = Calendar.current
        let backfillToday = calendar.startOfDay(for: Date())
        let backfillStart = calendar.date(byAdding: .day, value: -365, to: backfillToday) ?? backfillToday
        print("[Backfill] Date range to fill: \(backfillStart) → \(backfillToday)")
        print("[Backfill] HealthKit days returned: \(allDays.count)")
        if let first = allDays.first, let last = allDays.last {
            print("[Backfill] Earliest HK day: \(first.date), latest HK day: \(last.date)")
        }

        guard !allDays.isEmpty else {
            print("[Backfill] No HealthKit data found.")
            syncState = .complete
            return
        }

        // 2. Fetch all dates already ingested — skip them
        let existingDates: Set<String>
        do {
            existingDates = try await supabase.fetchExistingIngestionDates(userId: userId)
        } catch {
            print("[Backfill] Could not fetch existing dates: \(error)")
            syncState = .complete
            return
        }

        // DIAGNOSTIC 4 — existing dates returned by fetchExistingIngestionDates
        print("[Backfill] Existing dates in DB: \(existingDates.count)")

        let missingDays = allDays.filter { !existingDates.contains($0.date) }

        // DIAGNOSTIC 3 continued — missing dates count
        print("[Backfill] Missing dates count: \(missingDays.count)")

        guard !missingDays.isEmpty else {
            print("[Backfill] All HealthKit dates already ingested — nothing to do.")
            backfillProgress = "All history already up to date."
            syncState = .complete
            return
        }

        print("[Backfill] Found \(missingDays.count) dates to backfill out of \(allDays.count) HealthKit days.")

        // 3. Ingest + score with bounded concurrency (10 days in parallel)
        var ingested = 0
        var failed   = 0

        await MainActor.run { [weak self] in self?.backfillTotal = missingDays.count }

        // Process up to 10 days concurrently — reduces 260 sequential round trips to ~26 rounds
        let concurrencyLimit = 10
        let results = await withTaskGroup(
            of: (index: Int, date: String, error: Error?).self,
            returning: [(index: Int, date: String, error: Error?)].self
        ) { group in
            var inFlight = 0
            var nextIndex = 0
            var collected: [(index: Int, date: String, error: Error?)] = []

            for (index, day) in missingDays.enumerated() {
                // Drain one result before adding more once concurrency limit is reached
                if inFlight >= concurrencyLimit {
                    if let result = await group.next() {
                        collected.append(result)
                        inFlight -= 1
                        await MainActor.run { [weak self] in
                            self?.backfillDone = collected.count
                        }
                    }
                }
                let payload = day.toPayloadDict(userId: userId)
                let dayDate = day.date
                group.addTask { [supabase] in
                    do {
                        try await supabase.triggerHistoricalDaySync(userId: userId, payload: payload)
                        return (index: index, date: dayDate, error: nil)
                    } catch {
                        return (index: index, date: dayDate, error: error)
                    }
                }
                inFlight += 1
                nextIndex = index + 1
            }
            // Drain remaining
            for await result in group {
                collected.append(result)
                await MainActor.run { [weak self] in self?.backfillDone = collected.count }
            }
            _ = nextIndex  // suppress unused warning
            return collected
        }

        ingested = results.filter { $0.error == nil }.count
        failed   = results.filter { $0.error != nil }.count
        for r in results where r.error != nil {
            print("[Backfill] Failed for \(r.date): \(r.error!)")
        }

        let summary = "Backfill complete: \(ingested) days synced, \(failed) failed."
        print("[Backfill] \(summary)")
        backfillProgress = summary
        syncState = .complete
    }

    // ─────────────────────────────────────────
    // SECTION 6 — LOCAL DATA TIER CLASSIFICATION
    // Mirrors classifyDataTier() in ingest/index.ts.
    // Used to detect steps_only days immediately after HealthKit read,
    // before the server response arrives. No server round-trip needed.
    // ─────────────────────────────────────────

    private func classifyLocalDataTier(_ metrics: HealthKitManager.RawDayMetrics) -> String {
        // Wearable-specific signals: require Apple Watch or compatible device.
        // steps and active_minutes are intentionally excluded (iPhone-only capable).
        let wearableSignals: [Any?] = [
            metrics.hrv_ms,
            metrics.resting_hr_bpm,
            metrics.respiratory_rate_rpm,
            metrics.sleep_continuity_pct,
            metrics.spo2_pct,
            metrics.resting_energy,
            metrics.stand_hours
        ]
        let wearableCount = wearableSignals.compactMap { $0 }.count
        if wearableCount >= 4 { return "wearable" }
        if wearableCount >= 1 { return "partial" }
        let hasActivity = metrics.steps != nil || metrics.active_minutes != nil
        return hasActivity ? "steps_only" : "unknown"
    }

    // ─────────────────────────────────────────
    // SECTION 7 — GAP VALIDATION PROMPT
    // Called after sync completes when today's day was steps_only.
    // Loads the device name from users table (or falls back to "Apple Watch")
    // then sets showGapValidationPrompt = true so DashboardView can render
    // the three-button validation sheet.
    // ─────────────────────────────────────────

    func checkPendingGapValidation(userId: String) async {
        guard UserDefaults.standard.bool(forKey: "pendingGapValidation"),
              let pendingDate = UserDefaults.standard.string(forKey: "pendingGapValidationDate"),
              !pendingDate.isEmpty else { return }

        let deviceName = await supabase.fetchConnectedDeviceName(userId: userId)
        gapValidationDeviceName = deviceName
        gapValidationDate = pendingDate
        showGapValidationPrompt = true
    }

    /// Call after user responds to the gap validation prompt.
    /// Clears the pending validation flags and updates gap_reason in daily_inputs.
    func resolveGapValidation(userId: String, response: GapValidationResponse) async {
        let date = gapValidationDate

        UserDefaults.standard.removeObject(forKey: "pendingGapValidation")
        UserDefaults.standard.removeObject(forKey: "pendingGapValidationDate")
        showGapValidationPrompt = false

        guard !date.isEmpty else { return }
        if response == .checkLater { return }  // User deferred — leave gap_reason nil

        let gapReason: String?
        switch response {
        case .wornDevice:  gapReason = nil                 // Watch was worn — sync issue, not user choice
        case .didNotWear:  gapReason = "device_not_worn"
        case .checkLater:  gapReason = nil                 // handled above
        }

        await supabase.updateGapReason(userId: userId, date: date, gapReason: gapReason)
        print("[gap] gap_reason updated for \(date): '\(gapReason ?? "nil")'")
    }

    // ─────────────────────────────────────────
    // SECTION 8 — SYNC FAILURE ESCALATION
    // Tracks sync failure dates in UserDefaults. If ≥3 failures occur within
    // a 7-day window, sets escalation_flag to 'persistent_sync_failure' in the
    // users table. Non-fatal — errors are logged and swallowed.
    // ─────────────────────────────────────────

    private func recordSyncFailure(date: String) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var failures = UserDefaults.standard.stringArray(forKey: syncFailureDatesKey) ?? []

        // Prune failures older than 7 days
        failures = failures.filter {
            guard let d = fmt.date(from: $0) else { return false }
            return d > cutoffDate
        }
        failures.append(date)
        UserDefaults.standard.set(failures, forKey: syncFailureDatesKey)

        print("[escalation] Sync failure recorded for \(date). Failures in last 7 days: \(failures.count)")

        if failures.count >= 3 && !UserDefaults.standard.bool(forKey: escalationFlaggedKey) {
            checkEscalationThreshold()
        }
    }

    private func checkEscalationThreshold() {
        UserDefaults.standard.set(true, forKey: escalationFlaggedKey)
        print("[escalation] ⚠️ Persistent sync failure threshold reached (≥3 failures in 7 days). " +
              "Consider checking Apple Watch pairing and HealthKit permissions.")
        // Phase 2: Write escalation_flag = 'persistent_sync_failure' to users table
        // via REST PATCH. Deferred to Phase 2 when admin alerting is wired.
        // The UserDefaults flag above ensures this fires only once until resolved.
    }

    // ─────────────────────────────────────────
    // SECTION 9 — BATTERY WARNING
    // Phase 2: Requires WatchKit companion app to read Apple Watch battery level.
    // The WCSession framework provides battery state only within a paired Watch app —
    // iOS cannot directly query Watch battery without a WatchKit extension.
    // Implementation deferred post-beta. Placeholder only.
    // ─────────────────────────────────────────
    // func checkWatchBattery() { /* Phase 2: WCSession.default.delegate */ }

    // ─────────────────────────────────────────
    // SECTION 12 — CONSECUTIVE GAP FAILSAFE
    // Tracks the current streak of consecutive steps_only/unknown days.
    // If streak reaches CONSECUTIVE_GAP_THRESHOLD (5), logs prominently.
    // Phase 2: Show in-app nudge and log to ingest_errors for admin review.
    // ─────────────────────────────────────────

    private func updateConsecutiveGapStreak(date: String, isGap: Bool) {
        let lastGapDate = UserDefaults.standard.string(forKey: consecutiveGapLastDateKey)
        var currentStreak = UserDefaults.standard.integer(forKey: consecutiveGapKey)

        if isGap {
            // Only extend streak if this is the next calendar day after the last gap
            let isConsecutive = isNextCalendarDay(after: lastGapDate, current: date)
            currentStreak = isConsecutive ? currentStreak + 1 : 1
            UserDefaults.standard.set(currentStreak,  forKey: consecutiveGapKey)
            UserDefaults.standard.set(date,           forKey: consecutiveGapLastDateKey)

            if currentStreak >= CONSECUTIVE_GAP_THRESHOLD {
                print("[gap] ⚠️ \(CONSECUTIVE_GAP_THRESHOLD)+ consecutive gap days detected. " +
                      "Last gap date: \(date). Check Apple Watch pairing and HealthKit sync settings.")
                // Phase 2: Show in-app alert and write to ingest_errors table
            }
        } else {
            // Non-gap day — reset streak
            UserDefaults.standard.set(0,    forKey: consecutiveGapKey)
            UserDefaults.standard.set(date, forKey: consecutiveGapLastDateKey)
        }
    }

    private func isNextCalendarDay(after previous: String?, current: String) -> Bool {
        guard let prev = previous else { return false }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        guard let prevDate = fmt.date(from: prev),
              let currDate = fmt.date(from: current) else { return false }
        let diff = Calendar.current.dateComponents([.day], from: prevDate, to: currDate).day ?? 0
        return diff == 1
    }
}

// ─────────────────────────────────────────
// GAP VALIDATION RESPONSE
// Section 7 — User's response to the gap validation prompt.
// ─────────────────────────────────────────

enum GapValidationResponse: Equatable {
    case wornDevice   // "Yes, I wore my {device}" → investigate sync issue (gap_reason nil)
    case didNotWear   // "No, I didn't wear it"    → gap_reason = device_not_worn
    case checkLater   // "I'll check later"         → defer, leave gap_reason nil
}
