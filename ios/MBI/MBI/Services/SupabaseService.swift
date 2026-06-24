// ios/MBI/MBI/Services/SupabaseService.swift
// MBI Phase 1.5 — Supabase Client & API Layer

import Foundation
import Security
import UIKit

struct AuthSession: Codable {
    let accessToken: String
    let refreshToken: String
    let userId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case userId = "user_id"
    }
}

@MainActor
class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    @Published var session: AuthSession?
    @Published var currentUser: MBIUser?
    /// Stores the nudge_event_id returned by the most recent narrate call.
    /// Reset (in-memory) at the start of each daily sync; written once narrate responds.
    /// Persisted scoped to today's local date so it survives app relaunch and cache-only
    /// dashboard loads — without this, the nudge response buttons are dead in any session
    /// that didn't run the once-daily full sync. See restoreLatestNudgeEventId().
    /// Used by FeedbackView + nudge response buttons to link to the nudge event.
    @Published var latestNudgeEventId: String? = nil {
        didSet {
            // Persist only real ids — the transient nil at sync-start must not wipe an
            // id that is still valid for today.
            guard let id = latestNudgeEventId else { return }
            UserDefaults.standard.set(id, forKey: Self.nudgeEventIdKey)
            UserDefaults.standard.set(Self.todayStamp(), forKey: Self.nudgeEventIdDateKey)
        }
    }

    private static let nudgeEventIdKey     = "latestNudgeEventId"
    private static let nudgeEventIdDateKey = "latestNudgeEventIdDate"

    init() {
        restoreLatestNudgeEventId()
    }

    /// Local-day stamp ("yyyy-MM-dd") used to scope the persisted nudge_event_id to today.
    private static func todayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        return f.string(from: Date())
    }

    /// Restores today's persisted nudge_event_id into the in-memory value on launch.
    /// Ignores a stale cross-day stamp so a response is never linked to the wrong event.
    private func restoreLatestNudgeEventId() {
        let d = UserDefaults.standard
        guard d.string(forKey: Self.nudgeEventIdDateKey) == Self.todayStamp(),
              let id = d.string(forKey: Self.nudgeEventIdKey) else { return }
        latestNudgeEventId = id
    }

    /// Reads the most recent nudge_event_id for `date` straight from nudge_events and
    /// publishes it to latestNudgeEventId. This is the authoritative source for the nudge
    /// response buttons: the id is fetched whenever the dashboard loads, so it is present on
    /// cache/Keychain launches where no narrate ran this session (the row already exists in
    /// the DB). Best-effort — leaves the current value untouched on any failure.
    func refreshLatestNudgeEventId(userId: String, date: String) async {
        guard let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/nudge_events?user_id=eq.\(userId)&date=eq.\(date)&select=id&order=shown_at.desc&limit=1"
        ) else { return }
        guard let raw = try? await getRequest(url: url),
              let rows = raw as? [[String: Any]],
              let id = rows.first?["id"] as? String else { return }
        latestNudgeEventId = id
    }

    private var accessToken: String? { session?.accessToken }

    // MARK: - Auth

    func signUp(email: String, password: String) async throws -> AuthSession {
        let body: [String: Any] = ["email": email, "password": password]
        let data = try await post(path: "/auth/v1/signup", body: body, auth: false)
        let sess = try parseAuthSession(from: data)
        self.session = sess
        saveSession(sess)
        try await createUserRow(userId: sess.userId, email: email)
        return sess
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        let body: [String: Any] = ["email": email, "password": password]
        let data = try await post(path: "/auth/v1/token?grant_type=password", body: body, auth: false)
        let sess = try parseAuthSession(from: data)
        self.session = sess
        saveSession(sess)
        try await loadCurrentUser(userId: sess.userId)
        return sess
    }

    func signOut() {
        clearSavedSession()
    }

    // MARK: - Session Refresh

    func refreshSessionIfNeeded() async {
        guard let stored = loadSavedSession() else { return }
        let body: [String: Any] = ["refresh_token": stored.refreshToken]
        do {
            let data = try await post(
                path: "/auth/v1/token?grant_type=refresh_token",
                body: body,
                auth: false
            )
            let newSession = try parseAuthSession(from: data)
            self.session = newSession
            saveSession(newSession)
            try await loadCurrentUser(userId: newSession.userId)
        } catch {
            clearSavedSession()
        }
    }

    // MARK: - Auth Response Parser

    private func parseAuthSession(from data: [String: Any]) throws -> AuthSession {
        guard
            let accessToken = data["access_token"] as? String,
            let refreshToken = data["refresh_token"] as? String,
            let userDict = data["user"] as? [String: Any],
            let userId = userDict["id"] as? String
        else {
            throw MBIError.authFailed("Auth response malformed — missing tokens or user id")
        }
        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId
        )
    }

    // MARK: - User Profile

    func createUserRow(userId: String, email: String) async throws {
        let body: [String: Any] = [
            "id": userId,
            "email": email,
            "step_goal": Config.defaultStepGoal,
            "onboarding_complete": false,
        ]
        try await postToTable(table: "users", body: body)
    }

    func updateUser(userId: String, displayName: String, stepGoal: Int) async throws {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/users?id=eq.\(userId)")!
        let body: [String: Any] = ["display_name": displayName, "step_goal": stepGoal]
        try await patchRequest(url: url, body: body)
        try await loadCurrentUser(userId: userId)
    }
    func updateOnboardingProfile(
            userId: String,
            displayName: String,
            birthday: String?,
            heightFt: Int?,
            heightIn: Int?,
            weightLbs: Double?,
            biologicalSex: String? = nil
        ) async throws {
            var body: [String: Any] = ["display_name": displayName]
            if let v = birthday      { body["birthday"]       = v }
            if let v = heightFt      { body["height_ft"]      = v }
            if let v = heightIn      { body["height_in"]      = v }
            if let v = weightLbs     { body["weight_lbs"]     = v }
            if let v = biologicalSex { body["biological_sex"] = v }
            let url = URL(string: "\(Config.supabaseURL)/rest/v1/users?id=eq.\(userId)")!
            try await patchRequest(url: url, body: body)
            try await loadCurrentUser(userId: userId)
        }
    
    func updateProfile(
            userId: String,
            stepGoal: Int? = nil,
            healthGoal: String? = nil,
            weightLbs: Double? = nil,
            wakeTime: String? = nil,
            sleepTime: String? = nil,
            morningBriefEnabled: Bool? = nil,
            biologicalSex: String? = nil
        ) async throws {
            var body: [String: Any] = [:]
            if let v = stepGoal            { body["step_goal"]              = v }
            if let v = healthGoal          { body["health_goal"]            = v }
            if let v = weightLbs           { body["weight_lbs"]             = v }
            if let v = wakeTime            { body["wake_time"]              = v }
            if let v = sleepTime           { body["sleep_time"]             = v }
            if let v = morningBriefEnabled { body["morning_brief_enabled"]  = v }
            if let v = biologicalSex       { body["biological_sex"]         = v }
     
            guard !body.isEmpty else { return }
     
            let url = URL(string: "\(Config.supabaseURL)/rest/v1/users?id=eq.\(userId)")!
            try await patchRequest(url: url, body: body)
            try await loadCurrentUser(userId: userId)  // refresh @Published currentUser
        }

    func markOnboardingComplete(userId: String) async throws {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/users?id=eq.\(userId)")!
        try await patchRequest(url: url, body: ["onboarding_complete": true])
    }

    @discardableResult
    func loadCurrentUser(userId: String) async throws -> MBIUser {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/users?id=eq.\(userId)&select=*")!
        let data = try await getRequest(url: url)
        guard let users = data as? [[String: Any]], let first = users.first else {
            throw MBIError.notFound("User not found")
        }
        let user = try decode(MBIUser.self, from: first)
        self.currentUser = user
        return user
    }

    // MARK: - Dashboard

    func fetchTodayDashboard(userId: String) async throws -> DashboardData? {
        let today = todayString()
        let scoreURL = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&date=eq.\(today)&select=*")!
        let scoreData = try await getRequest(url: scoreURL)
        guard let scores = scoreData as? [[String: Any]], let first = scores.first else { return nil }
        let score: DailyScore
        do {
            score = try decode(DailyScore.self, from: first)
        } catch {
            print("[fetchMostRecentDashboard] decode failed: \(error)")
            throw error
        }

        let explURL = URL(string: "\(Config.supabaseURL)/rest/v1/explanations?user_id=eq.\(userId)&date=eq.\(today)&select=*")!
        let explData = try await getRequest(url: explURL)
        var explanation: Explanation?
        if let expls = explData as? [[String: Any]], let firstExpl = expls.first {
            explanation = try? decode(Explanation.self, from: firstExpl)
        }

        let trendURL = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&select=chronos_score,date&order=date.desc&limit=7")!
        let trendData = try await getRequest(url: trendURL)
        let recentScores = ((trendData as? [[String: Any]]) ?? [])
            .compactMap { $0["chronos_score"] as? Double }
            .reversed()
            .map { $0 }

        return DashboardData(score: score, explanation: explanation, recentScores: recentScores)
    }
    
    func fetchMostRecentDashboard(userId: String) async throws -> DashboardData? {
        let scoreURL = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&select=*&order=date.desc&limit=1")!
        let scoreData = try await getRequest(url: scoreURL)
        guard let scores = scoreData as? [[String: Any]], let first = scores.first else { return nil }
        let score = try decode(DailyScore.self, from: first)
        let date = score.date

        let explURL = URL(string: "\(Config.supabaseURL)/rest/v1/explanations?user_id=eq.\(userId)&date=eq.\(date)&select=*")!
        let explData = try await getRequest(url: explURL)
        var explanation: Explanation?
        if let expls = explData as? [[String: Any]], let firstExpl = expls.first {
            explanation = try? decode(Explanation.self, from: firstExpl)
        }

        let trendURL = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&select=chronos_score,date&order=date.desc&limit=7")!
        let trendData = try await getRequest(url: trendURL)
        let recentScores = ((trendData as? [[String: Any]]) ?? [])
            .compactMap { $0["chronos_score"] as? Double }
            .reversed()
            .map { $0 }

        return DashboardData(score: score, explanation: explanation, recentScores: recentScores)
    }
    
    func fetchTrendData(userId: String) async throws -> [TrendPoint] {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&select=chronos_score,date&order=date.desc&limit=7")!
        let data = try await getRequest(url: url)
        let rows = (data as? [[String: Any]]) ?? []
        return rows.compactMap { row -> TrendPoint? in
            guard let date = row["date"] as? String,
                  let score = row["chronos_score"] as? Double else { return nil }
            return TrendPoint(date: date, score: score)
        }.reversed()
    }

    func triggerDailySync(userId: String, payload: [String: Any], briefSession: String = "morning") async throws {
        // Extract the date from the payload so score/narrate use the same date as ingest
        guard let payloadDate = (payload["metrics"] as? [String: Any]).flatMap({ _ in payload["date"] as? String })
                    ?? (payload["date"] as? String) else {
            throw MBIError.syncFailed("Payload missing date")
        }

        // Reset nudge event ID at start of each sync cycle
        latestNudgeEventId = nil

        _ = try await callEdgeFunction(url: Config.ingestURL, body: ["payload": payload])
        _ = try await callEdgeFunction(url: Config.scoreURL, body: ["userId": userId, "date": payloadDate])

        // Capture nudge_event_id from narrate response (learning foundation — FeedbackView linkage)
        let narrateResult = try await callEdgeFunction(url: Config.narrateURL, body: [
            "userId":       userId,
            "date":         payloadDate,
            "timeOfDay":    TimeOfDay.current.rawValue,  // E-09: morning | daytime | evening
            "briefSession": briefSession                  // "morning" | "evening"
        ])
        if let nudgeId = narrateResult["nudge_event_id"] as? String {
            latestNudgeEventId = nudgeId
        }
    }

    /// Ingest + score only — no narrate. Used during baseline bootstrap for historical days.
    /// Narrate is skipped because historical briefs are never read and each Claude call
    /// adds 2–4 seconds per day, making 90-day bootstrap unnecessarily slow.
    func triggerHistoricalDaySync(userId: String, payload: [String: Any]) async throws {
        guard let payloadDate = (payload["metrics"] as? [String: Any]).flatMap({ _ in payload["date"] as? String })
                    ?? (payload["date"] as? String) else {
            throw MBIError.syncFailed("Payload missing date")
        }
        _ = try await callEdgeFunction(url: Config.ingestURL, body: ["payload": payload])
        _ = try await callEdgeFunction(url: Config.scoreURL, body: ["userId": userId, "date": payloadDate])
    }

    /// Checks whether a daily_scores row exists for the given user and date.
    /// Used by SyncCoordinator after each ingest+score cycle to detect silent pipeline stalls.
    /// A successful score function call does not guarantee a row was written — confidence_tier "none"
    /// returns HTTP 200 with {baseline_building: true} without inserting into daily_scores.
    /// Returns false on network error (caller logs accordingly).
    func checkScoreExists(userId: String, date: String) async -> Bool {
        let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId
        let encodedDate   = date.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? date
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(encodedUserId)&date=eq.\(encodedDate)&select=id&limit=1") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        return !rows.isEmpty
    }

    /// Calls narrate only — no ingest or score. Used for pull-to-refresh recovery and evening brief.
    func triggerNarrateOnly(userId: String, date: String, briefSession: String, timeOfDay: String) async throws {
        let result = try await callEdgeFunction(url: Config.narrateURL, body: [
            "userId":       userId,
            "date":         date,
            "timeOfDay":    timeOfDay,
            "briefSession": briefSession
        ])
        // Keep the nudge response-button linkage live on the refresh / recovery path too
        // (mirrors triggerDailySync). Persisted via the latestNudgeEventId didSet.
        if let nudgeId = result["nudge_event_id"] as? String {
            latestNudgeEventId = nudgeId
        }
    }

    /// Calls narrate with briefSession "evening" only — no ingest or score.
    /// Writes evening_explanation_text and evening_nudge_text to the existing row.
    func triggerEveningNarrate(userId: String, date: String) async throws {
        try await triggerNarrateOnly(userId: userId, date: date, briefSession: "evening", timeOfDay: "evening")
    }

    /// Calls narrate-detail — generates the full 7-day system narrative.
    /// Writes detail_explanation_text to the existing explanations row.
    /// Server-side 23-hour cache check prevents redundant Claude calls.
    func triggerNarrateDetail(userId: String, date: String) async throws {
        _ = try await callEdgeFunction(url: Config.narrateDetailURL, body: [
            "user_id": userId,
            "date":    date
        ])
    }

    // MARK: - Feedback

    func submitFeedback(
        scoreId: String,
        userId: String,
        date: String,
        feltAccurate: Bool,
        note: String?,
        nudgeEventId: String? = nil
    ) async throws {
        var body: [String: Any] = [
            "score_id":     scoreId,
            "user_id":      userId,
            "date":         date,
            "felt_accurate": feltAccurate
        ]
        if let note = note, !note.isEmpty { body["note"] = note }
        if let nudgeId = nudgeEventId     { body["nudge_event_id"] = nudgeId }
        try await postToTable(table: "feedback", body: body)
    }

    /// Three-dimension feedback — Step 7 redesign.
    /// Writes to user_feedback table. All three dimension flags are optional;
    /// at least one must be non-nil (enforced in the UI, not here).
    func submitDimensionedFeedback(
        scoreId: String,
        userId: String,
        date: String,
        scoreAccuracy: String?,
        briefQuality: String?,
        nudgeRelevance: String?,
        noteText: String?
    ) async throws {
        var body: [String: Any] = [
            "score_id": scoreId,
            "user_id":  userId,
            "date":     date,
        ]
        if let v = scoreAccuracy  { body["score_accuracy"]  = v }
        if let v = briefQuality   { body["brief_quality"]   = v }
        if let v = nudgeRelevance { body["nudge_relevance"] = v }
        if let v = noteText, !v.isEmpty { body["note_text"] = v }
        try await postToTable(table: "user_feedback", body: body)
    }

    // MARK: - Score Corrections (Step 8)

    /// Fetches the 30 most recent daily_scores rows for outlier SD computation.
    func fetchRecentDomainScores(userId: String, limit: Int = 30) async throws -> [[String: Any]] {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&select=d1_autonomic,d2_sleep,d3_activity,d4_stress,d5_allostatic&order=date.desc&limit=\(limit)")!
        let data = try await getRequest(url: url)
        return (data as? [[String: Any]]) ?? []
    }

    /// Fetches all score_corrections for this user + date to determine dismissed/applied state.
    func fetchCorrectionsForDate(userId: String, date: String) async throws -> [ScoreCorrection] {
        let encoded = date.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? date
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/score_corrections?user_id=eq.\(userId)&date=eq.\(encoded)&select=*")!
        let data = try await getRequest(url: url)
        let rows = (data as? [[String: Any]]) ?? []
        return rows.compactMap { try? decode(ScoreCorrection.self, from: $0) }
    }

    /// Inserts a score_corrections row. Returns the inserted row id.
    @discardableResult
    func insertCorrection(
        userId: String,
        date: String,
        signalName: String,
        originalValue: Double?,
        correctedValue: Double,
        correctionType: String,
        windowExpiresAt: Date,
        isApplied: Bool,
        dismissed: Bool
    ) async throws -> String {
        let iso = ISO8601DateFormatter()
        var body: [String: Any] = [
            "user_id":           userId,
            "date":              date,
            "signal_name":       signalName,
            "corrected_value":   correctedValue,
            "correction_type":   correctionType,
            "window_expires_at": iso.string(from: windowExpiresAt),
            "is_applied":        isApplied,
            "dismissed":         dismissed
        ]
        if let v = originalValue { body["original_value"] = v }
        if dismissed             { body["dismissed_at"]   = iso.string(from: Date()) }

        let url = URL(string: "\(Config.supabaseURL)/rest/v1/score_corrections")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPStatus(response)
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return rows.first?["id"] as? String ?? UUID().uuidString
    }

    /// Sets escalation_sent = true on a correction row after alert email fires.
    func markEscalationSent(correctionId: String) async {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/score_corrections?id=eq.\(correctionId)")!
        _ = try? await {
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["escalation_sent": true])
            return try await URLSession.shared.data(for: request)
        }()
    }

    /// Fetches recent applied corrections for a signal to evaluate repeat escalation threshold.
    func fetchRecentAppliedCorrections(userId: String, signalName: String, days: Int = 14) async throws -> [ScoreCorrection] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let iso = ISO8601DateFormatter()
        let cutoffStr = iso.string(from: cutoff).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/score_corrections?user_id=eq.\(userId)&signal_name=eq.\(signalName)&correction_type=eq.user_edit&is_applied=eq.true&submitted_at=gte.\(cutoffStr)&select=*&order=submitted_at.desc&limit=3")!
        let data = try await getRequest(url: url)
        let rows = (data as? [[String: Any]]) ?? []
        return rows.compactMap { try? decode(ScoreCorrection.self, from: $0) }
    }

    /// Fire-and-forget escalation email. Does not block the UI.
    func sendEscalationAlert(userId: String, signalName: String, corrections: [ScoreCorrection]) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await callEdgeFunction(url: Config.escalationAlertURL, body: [
                "userId":      userId,
                "signalName":  signalName,
                "corrections": corrections.map { [
                    "date":             $0.date,
                    "original_value":   $0.originalValue as Any,
                    "corrected_value":  $0.correctedValue
                ]}
            ])
        }
    }

    /// Calls the score edge function with an override for a corrected signal.
    func triggerScoreWithOverride(userId: String, date: String, signalName: String, correctedValue: Double) async throws {
        _ = try await callEdgeFunction(url: Config.scoreURL, body: [
            "userId":    userId,
            "date":      date,
            "overrides": [signalName: correctedValue]
        ])
    }

    // MARK: - Admin

    func fetchAdminData() async throws -> [[String: Any]] {
        let data = try await callEdgeFunction(url: Config.adminURL, body: [:])
        return (data["users"] as? [[String: Any]]) ?? []
    }

    // MARK: - Analytics Events (P3.2)
    // Fire-and-forget insert into `app_events` table.
    // Drops silently on failure — analytics must never affect UX.
    // Called exclusively by AnalyticsService.shared.track(_:).

    func insertAnalyticsEvent(userId: String, name: String, properties: [String: Any]) async {
        let body: [String: Any] = [
            "user_id":     userId,
            "event_name":  name,
            "properties":  properties,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "os_version":  UIDevice.current.systemVersion,
        ]
        // Silently drop if serialization or network fails
        guard let _ = try? JSONSerialization.data(withJSONObject: body) else { return }

        let url = URL(string: "\(Config.supabaseURL)/rest/v1/app_events")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
        // Intentional: ignore all errors — analytics must not crash or surface to user
    }

    // MARK: - HTTP Helpers

    private func post(path: String, body: [String: Any], auth: Bool) async throws -> [String: Any] {
        let url = URL(string: "\(Config.supabaseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if auth, let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPStatus(response)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postToTable(table: String, body: [String: Any]) async throws {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/\(table)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        try checkHTTPStatus(response)
    }

    private func patchRequest(url: URL, body: [String: Any]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        try checkHTTPStatus(response)
    }

    private func getRequest(url: URL, isRetry: Bool = false) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)

        // P3.5: Silent JWT refresh on 401 — retry once
        if let http = response as? HTTPURLResponse, http.statusCode == 401, !isRetry {
            await refreshSessionIfNeeded()
            return try await getRequest(url: url, isRetry: true)
        }

        try checkHTTPStatus(response)
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    private func callEdgeFunction(url: URL, body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await callEdgeFunctionData(url: url, bodyData: bodyData)
    }

    // P3.5: JWT 401 silent refresh — build request, execute, retry once on 401.
    // Keeps the retry logic centralized here so every Edge Function call benefits.
    @discardableResult
    private func callEdgeFunctionData(url: URL, bodyData: Data, isRetry: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401, !isRetry {
            // Silent refresh — user never sees this
            await refreshSessionIfNeeded()
            // Retry once with the fresh token
            return try await callEdgeFunctionData(url: url, bodyData: bodyData, isRetry: true)
        }

        try checkHTTPStatus(response)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func checkHTTPStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode >= 400 { throw MBIError.httpError(http.statusCode) }
    }

    private func decode<T: Codable>(_ type: T.Type, from dict: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(type, from: data)
    }

    func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

enum MBIError: Error, LocalizedError {
    case authFailed(String)
    case notFound(String)
    case httpError(Int)
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .authFailed(let msg): return "Auth failed: \(msg)"
        case .notFound(let msg): return msg
        case .httpError(let code): return "HTTP error \(code)"
        case .syncFailed(let msg): return "Sync failed: \(msg)"
        }
    }
}

// MARK: - Session Persistence (Keychain + UserDefaults fallback)
extension SupabaseService {
    private static let keychainService = "com.mbi.chronos"
    private static let keychainAccount = "mbi_session"
    private static let udKey = "mbi_session_v2"
    
    func saveSession(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        
        // Try Keychain
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        
        if status != errSecSuccess {
            print("[MBI] Keychain write failed (\(status)), using UserDefaults fallback")
        }
        
        // Always write UserDefaults as fallback
        UserDefaults.standard.set(data, forKey: Self.udKey)
    }
    
    @discardableResult
    func loadSavedSession() -> AuthSession? {
        // Try Keychain first
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
            print("[MBI] Session loaded from Keychain")
            return session
        }
        
        // Fall back to UserDefaults
        if let data = UserDefaults.standard.data(forKey: Self.udKey),
           let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
            print("[MBI] Session loaded from UserDefaults fallback")
            return session
        }
        
        print("[MBI] No stored session found")
        return nil
    }
    
    func clearSavedSession() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.udKey)
        self.session = nil
        self.currentUser = nil
    }
    
    // MARK: - Baselines (for Trend deviation callouts — R-02)
    
    func fetchLatestBaselines(userId: String) async throws -> [String: Double] {
        // Column is "computed_on", not "computed_at"
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/baselines?user_id=eq.\(userId)&order=computed_on.desc&limit=1&select=*")!
        let data = try await getRequest(url: url)
        guard let rows = data as? [[String: Any]], let row = rows.first else { return [:] }

        let skip = Set(["id", "user_id", "computed_on", "window_days", "domain_version", "created_at"])
        var result: [String: Double] = [:]
        for (key, val) in row {
            guard !skip.contains(key) else { continue }
            // Values may arrive as Double or as String — handle both
            if let v = val as? Double {
                result[key] = v
            } else if let s = val as? String, let v = Double(s) {
                result[key] = v
            }
        }
        return result
    }
    
    // MARK: - Driver Streak (for contextual education trigger — E-11)

        func fetchDriverStreak(userId: String, todayDriver: String) async throws -> Int {
            let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&select=driver_1,date&order=date.desc&limit=10")!
            let data = try await getRequest(url: url)
            guard let rows = data as? [[String: Any]] else { return 0 }

            var streak = 0
            for row in rows {
                guard let d1 = row["driver_1"] as? String else { break }
                if d1 == todayDriver { streak += 1 } else { break }
            }
            return streak
        }

        // MARK: - D5 History (for Allostatic Portrait — E-11)

        func fetchAllostaticHistory(userId: String) async throws -> [(date: String, value: Double)] {
            let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_scores?user_id=eq.\(userId)&d5_allostatic=not.is.null&select=date,d5_allostatic&order=date.asc&limit=90")!
            let data = try await getRequest(url: url)
            guard let rows = data as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard let date = row["date"] as? String,
                      let val = row["d5_allostatic"] as? Double else { return nil }
                return (date: date, value: val)
            }
        }
    // MARK: - Raw Inputs for a specific date (for driver chip data points)

    func fetchInputs(userId: String, date: String) async throws -> [String: Double?] {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_inputs?user_id=eq.\(userId)&date=eq.\(date)&select=*&limit=1")!
        let data = try await getRequest(url: url)
        guard let rows = data as? [[String: Any]], let row = rows.first else { return [:] }

        let skip = Set(["id", "user_id", "date", "source_version", "created_at", "data_quality_flags"])
        var result: [String: Double?] = [:]
        for (key, val) in row {
            guard !skip.contains(key) else { continue }
            if let v = val as? Double { result[key] = v }
            else if let v = val as? Int { result[key] = Double(v) }
            else { result[key] = nil }
        }
        return result
    }

    // MARK: - History Day Count (for D5 progress indicator — item 4)

    func fetchHistoryDayCount(userId: String) async throws -> Int {
        let today = todayString()
        // Count distinct dates in daily_inputs before today
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_inputs?user_id=eq.\(userId)&date=lt.\(today)&select=date")!
        let data = try await getRequest(url: url)
        guard let rows = data as? [[String: Any]] else { return 0 }
        return rows.count
    }

    /// Counts days with non-null HRV readings in daily_inputs for a user.
    /// HRV is Apple Watch-only — used post-backfill to determine WearableDataTier.
    func fetchHRVDayCount(userId: String) async throws -> Int {
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_inputs" +
            "?user_id=eq.\(userId)" +
            "&hrv_ms=not.is.null" +
            "&select=date"
        )!
        let data = try await getRequest(url: url)
        guard let rows = data as? [[String: Any]] else { return 0 }
        return rows.count
    }

    /// Section 14: Counts days classified as 'wearable' in daily_inputs.
    /// Replaces fetchHRVDayCount post-migration — wearable tier (≥4 Watch signals)
    /// is a more precise discriminator than HRV alone, and works when HRV is sparse.
    func fetchWearableDayCount(userId: String) async throws -> Int {
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_inputs" +
            "?user_id=eq.\(userId)" +
            "&data_tier=eq.wearable" +
            "&select=date"
        )!
        let data = try await getRequest(url: url)
        guard let rows = data as? [[String: Any]] else { return 0 }
        return rows.count
    }

    /// Section 7: Fetches the user's connected device name from the users table.
    /// Returns "Apple Watch" as fallback when column is null or not yet set.
    func fetchConnectedDeviceName(userId: String) async -> String {
        guard let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/users" +
            "?id=eq.\(userId)" +
            "&select=connected_device_name" +
            "&limit=1"
        ) else { return "Apple Watch" }
        guard let token = session?.accessToken else { return "Apple Watch" }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)",     forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",     forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let name = rows.first?["connected_device_name"] as? String,
              !name.isEmpty else {
            return "Apple Watch"
        }
        return name
    }

    /// Section 7: Patches gap_reason in daily_inputs for a given user/date.
    /// Called by SyncCoordinator.resolveGapValidation() after user responds to gap prompt.
    func updateGapReason(userId: String, date: String, gapReason: String?) async {
        guard let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_inputs" +
            "?user_id=eq.\(userId)" +
            "&date=eq.\(date)"
        ) else { return }
        guard let token = session?.accessToken else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)",     forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",     forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal",       forHTTPHeaderField: "Prefer")
        // PATCH body: write gap_reason (null is valid — means "not set")
        var body: [String: Any] = [:]
        if let reason = gapReason { body["gap_reason"] = reason }
        else { body["gap_reason"] = NSNull() }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
        print("[SupabaseService] gap_reason updated to '\(gapReason ?? "null")' for \(date)")
    }

    /// Returns the set of date strings (yyyy-MM-dd) that already have an ingested row.
    /// Checks daily_inputs — a row here means HealthKit data was successfully received
    /// for that date. The 241-date gap between daily_inputs (385) and daily_scores (124)
    /// is expected: historical scoring is handled by the Learning Foundation Audit, not backfill.
    func fetchExistingIngestionDates(userId: String) async throws -> Set<String> {
        let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_inputs?user_id=eq.\(userId)&select=date")!
        let data = try await getRequest(url: url)
        guard let rows = data as? [[String: Any]] else { return [] }
        return Set(rows.compactMap { $0["date"] as? String })
    }

    // MARK: - Trend Aggregates (Sprint 2)
     
    /// Fetches pre-computed weekly or monthly aggregate rows for the Trend tab.
    /// The iOS client never aggregates raw daily_scores rows — this is the only
    /// approved source for 8W and 12M window data.
    /// Fetches the most recent `limit` aggregate windows, ordered DESC then reversed for chronological display.
    /// DESC + reverse ensures we get the N most recent weeks/months, not the earliest N.
    func fetchTrendAggregates(userId: String, windowType: String, limit: Int) async throws -> [[String: Any]] {
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/trend_aggregates" +
            "?user_id=eq.\(userId)" +
            "&window_type=eq.\(windowType)" +
            "&order=window_start.desc" +
            "&limit=\(limit)" +
            "&select=*"
        )!
        let data = try await getRequest(url: url)
        return ((data as? [[String: Any]]) ?? []).reversed()
    }
     
    /// Fetches daily_scores for the 7D window using a date range.
    /// Returns rows ordered ascending (oldest first) for chart rendering.
    /// Uses WHERE date >= today-7 instead of LIMIT 7 so gaps and unsynced today don't break the window.
    func fetchRecentDailyScores(userId: String, limit: Int = 7) async throws -> [[String: Any]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let startStr = fmt.string(from: windowStart)
        let endStr   = fmt.string(from: today)
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_scores" +
            "?user_id=eq.\(userId)" +
            "&date=gte.\(startStr)" +
            "&date=lte.\(endStr)" +
            "&order=date.asc" +
            "&select=date,chronos_score,score_band,driver_1,driver_2,data_tier"
        )!
        let data = try await getRequest(url: url)
        return (data as? [[String: Any]]) ?? []
    }

    /// Fetches daily_inputs for the 7D window using a date range.
    /// Returns rows ordered ascending for chart rendering.
    func fetchRecentDailyInputs(userId: String, limit: Int = 7) async -> [[String: Any]] {
        do {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let windowStart = cal.date(byAdding: .day, value: -7, to: today) ?? today
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let startStr = fmt.string(from: windowStart)
            let endStr   = fmt.string(from: today)
            let url = URL(string:
                "\(Config.supabaseURL)/rest/v1/daily_inputs" +
                "?user_id=eq.\(userId)" +
                "&date=gte.\(startStr)" +
                "&date=lte.\(endStr)" +
                "&order=date.asc" +
                "&select=date,hrv_ms,resting_hr_bpm,respiratory_rate_rpm,sleep_duration_hrs,sleep_continuity_pct,steps,active_minutes,data_tier"
            )!
            let data = try await getRequest(url: url)
            return (data as? [[String: Any]]) ?? []
        } catch {
            print("[SupabaseService] fetchRecentDailyInputs empty: \(error)")
            return []
        }
    }
     
    /// Calls the narrate-trend Edge Function and returns the generated narrative string.
    /// The iOS client caches the result — this must not be called on every tab switch.
    func fetchTrendNarrative(
        userId: String,
        windowType: String,
        windowStart: String,
        windowEnd: String,
        chronosAvg: Double,
        chronosMin: Double,
        chronosMax: Double,
        trendDirection: String,
        topDrivers: [String],
        daysInWindow: Int,
        windowKey: String? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "userId":          userId,
            "window_type":     windowType,
            "window_start":    windowStart,
            "window_end":      windowEnd,
            "chronos_avg":     chronosAvg,
            "chronos_min":     chronosMin,
            "chronos_max":     chronosMax,
            "trend_direction": trendDirection,
            "top_drivers":     topDrivers,
            "days_in_window":  daysInWindow,
        ]
        if let windowKey { body["window_key"] = windowKey }
        let result = try await callEdgeFunction(url: Config.narrateTrendURL, body: body)
        guard let narrative = result["narrative"] as? String, !narrative.isEmpty else {
            throw MBIError.syncFailed("Trend narrative response empty")
        }
        return narrative
    }

    // ─────────────────────────────────────────
    // HORIZON  (Phase 2 · Epic 3 Sprint 1–6)
    // ─────────────────────────────────────────

    // ─────────────────────────────────────────
    // PIPELINE PERFORMANCE ARCHITECTURE (June 2026)
    // Single orchestrator call replaces sequential ingest → score → narrate chain.
    // ─────────────────────────────────────────

    /// Calls score-orchestrator with the full HealthKit payload.
    /// Single round-trip replaces: ingest + score + narrate + narrate-trend +
    /// narrate-domains-pattern. Returns { computed, cached, score_date, crs }.
    @discardableResult
    func triggerOrchestrator(userId: String, date: String, payload: [String: Any]) async throws -> [String: Any] {
        return try await callEdgeFunction(url: Config.orchestratorURL, body: [
            "userId":   userId,
            "date":     date,
            "payload":  payload,
            "timezone": TimeZone.current.identifier,
        ])
    }

    /// Persists the device's IANA timezone string to the users table and detects travel.
    /// If the device UTC offset has shifted ≥ 3 hours from the stored timezone, sets
    /// timezone_shift_detected = true and timezone_shift_date = today.
    /// Called at every app launch. No-op on failure — timezone capture is best-effort.
    func updateTimezone(userId: String) async {
        let currentTZ = TimeZone.current
        let currentTZId = currentTZ.identifier

        // Fetch the currently stored timezone to detect a shift
        var storedTZId: String? = nil
        if let url = URL(string: "\(Config.supabaseURL)/rest/v1/users?id=eq.\(userId)&select=timezone") {
            var req = URLRequest(url: url)
            req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = rows.first,
               let tz = first["timezone"] as? String {
                storedTZId = tz
            }
        }

        // Build the patch payload — always update timezone string
        var patch: [String: Any] = ["timezone": currentTZId]

        // Detect ≥ 3h UTC offset shift
        if let storedId = storedTZId,
           let storedTZ = TimeZone(identifier: storedId) {
            let now = Date()
            let currentOffset = currentTZ.secondsFromGMT(for: now)
            let storedOffset  = storedTZ.secondsFromGMT(for: now)
            let shiftHours    = abs(currentOffset - storedOffset) / 3600
            if shiftHours >= 3 {
                patch["timezone_shift_detected"] = true
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                patch["timezone_shift_date"] = df.string(from: now)
            }
        }

        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/users?id=eq.\(userId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        guard let body = try? JSONSerialization.data(withJSONObject: patch) else { return }
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Checks whether a context check response already exists for this user + escalation event.
    /// Returns true if a row exists (context already responded for this date + pathway combination).
    func escalationContextExists(userId: String, escalationDate: String, pathwayKey: String) async -> Bool {
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/user_escalation_context?user_id=eq.\(userId)&escalation_date=eq.\(escalationDate)&pathway_key=eq.\(pathwayKey)&select=id&limit=1") else { return false }
        var request = URLRequest(url: url)
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return !rows.isEmpty
    }

    /// Logs the user's pre-escalation context check response.
    /// context_flags: array of selected exception strings. Empty if dismissed or 'nothing unusual'.
    func logEscalationContext(userId: String, escalationDate: String, pathwayKey: String, contextFlags: [String]) async {
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/user_escalation_context") else { return }
        let contextFlagActive = !contextFlags.isEmpty && contextFlags != ["nothing_unusual"]
        let payload: [String: Any] = [
            "user_id":             userId,
            "escalation_date":     escalationDate,
            "pathway_key":         pathwayKey,
            "context_flags":       contextFlags,
            "context_flag_active": contextFlagActive,
            "responded_at":        ISO8601DateFormatter().string(from: Date()),
            "ontology_version":    "phase1_75-v1.0",
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Triggers the `horizon` Edge Function for today's date.
    /// Runs after narrate in the daily sync pipeline.
    func triggerHorizon(userId: String, date: String) async throws {
        _ = try await callEdgeFunction(
            url: Config.horizonURL,
            body: ["userId": userId, "date": date]
        )
    }

    /// Triggers the `horizon-classify` Ontology Engine Edge Function.
    /// Sprint 6: classifies pathway_classifications for today's date.
    /// Called after daily sync completes. Best-effort — swallows errors so
    /// a classification failure never blocks the user's morning brief.
    func triggerHorizonClassify(userId: String, date: String) async {
        _ = try? await callEdgeFunction(
            url: Config.horizonClassifyURL,
            body: ["userId": userId, "date": date]
        )
    }

    /// Fetches today's HorizonAssessment from `pathway_classifications`.
    /// Phase 2 Sprint 6: migrated from deprecated `horizon_signals` table.
    /// Column names are identical — parse logic unchanged.
    /// Returns `.empty` when no rows exist yet (first sync before horizon-classify has run).
    func fetchHorizonSignals(userId: String, date: String) async throws -> HorizonAssessment {
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/pathway_classifications?user_id=eq.\(userId)&classification_date=eq.\(date)&select=*") else {
            throw MBIError.syncFailed("Invalid pathway classifications URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MBIError.syncFailed("pathway_classifications fetch failed")
        }

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .empty
        }

        func parseSignal(_ row: [String: Any]) -> HorizonSignal {
            HorizonSignal(
                pathway:           row["pathway_key"]        as? String ?? "",
                conditionClass:    row["condition_class"]    as? String,
                trajectoryLabel:   row["trajectory_label"]   as? String,
                escalationLevel:   row["escalation_level"]   as? Int ?? 0,
                confidenceGate:    (row["confidence_gate"]   as? NSNumber)?.doubleValue ?? 0.0,
                daysInPattern:     row["days_in_pattern"]    as? Int ?? 0,
                schemaVersion:     row["schema_version"]     as? String ?? "v1.0-derived",
                calibrationStatus: row["calibration_status"] as? String ?? "pending_biomarker_validation",
                dbState:           row["state"]              as? String ?? "CALM"
            )
        }

        var autonomic: HorizonSignal? = nil
        var sleep:     HorizonSignal? = nil
        var metabolic: HorizonSignal? = nil

        for row in rows {
            let signal = parseSignal(row)
            switch signal.pathway {
            case "autonomic": autonomic = signal
            case "sleep":     sleep     = signal
            case "metabolic": metabolic = signal
            default: break
            }
        }

        return HorizonAssessment(autonomic: autonomic, sleep: sleep, metabolic: metabolic)
    }

    /// Calls `narrate-horizon` for a single active pathway.
    /// Returns the wellness narrative string or nil on failure.
    func fetchHorizonNarrative(
        pathway: String,
        conditionClass: String,
        trajectoryLabel: String,
        daysInPattern: Int,
        escalationLevel: Int,
        confidenceGate: Double,
        protectivePathway: String?
    ) async throws -> String {
        var body: [String: Any] = [
            "userId":          session?.userId ?? "",
            "pathway":         pathway,
            "conditionClass":  conditionClass,
            "trajectoryLabel": trajectoryLabel,
            "daysInPattern":   daysInPattern,
            "escalationLevel": escalationLevel,
            "confidenceGate":  confidenceGate,
        ]
        if let p = protectivePathway { body["protectivePathway"] = p }

        let result = try await callEdgeFunction(url: Config.narrateHorizonURL, body: body)
        guard let narrative = result["narrative"] as? String, !narrative.isEmpty else {
            throw MBIError.syncFailed("narrate-horizon response empty")
        }
        return narrative
    }

    /// Fetches 28 days of daily_scores including domain columns for Momentum page computation.
    /// Returns rows ordered ascending (oldest first). Domain columns may be nil on older rows.
    func fetchMomentumScores(userId: String) async throws -> [[String: Any]] {
        guard let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_scores" +
            "?user_id=eq.\(userId)" +
            "&order=date.desc" +
            "&limit=28" +
            "&select=date,chronos_score,d1_autonomic,d2_sleep,d3_activity"
        ) else { throw MBIError.syncFailed("Invalid momentum scores URL") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MBIError.syncFailed("momentum scores fetch failed")
        }
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return rows.reversed() // ascending for window comparison
    }

    /// Upserts a feature waitlist enrollment into user_feature_waitlist.
    /// Best-effort — swallows errors to avoid blocking UI interaction.
    func enrollFeatureWaitlist(userId: String, featureSlug: String, sourcePage: String) async {
        guard !userId.isEmpty,
              let url = URL(string: "\(Config.supabaseURL)/rest/v1/user_feature_waitlist")
        else { return }

        let body: [String: Any] = [
            "user_id":      userId,
            "feature_slug": featureSlug,
            "source_page":  sourcePage,
            "enrolled_at":  ISO8601DateFormatter().string(from: Date())
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = bodyData

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Push Token Storage

    /// Upserts the APNs device token to the push_tokens table.
    /// Keyed on (user_id, device_id) — safe to call on every launch after token refresh.
    /// Best-effort — swallows all errors so token failure never blocks the user.
    func storePushToken(tokenString: String, deviceId: String, userId: String) async {
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/push_tokens") else { return }
        let body: [String: Any] = [
            "user_id":    userId,
            "device_id":  deviceId,
            "token":      tokenString,
            "platform":   "ios",
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)",
                         forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",     forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = bodyData
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Sign In with Apple

    /// Authenticates with Supabase using an Apple identity token (OIDC flow).
    /// Call from the ASAuthorizationControllerDelegate success path.
    /// Nonce must be the raw (un-hashed) value — Supabase verifies using the SHA256 hash.
    func signInWithApple(idToken: String, nonce: String?) async throws -> AuthSession {
        var body: [String: Any] = ["provider": "apple", "id_token": idToken]
        if let nonce { body["nonce"] = nonce }
        let data = try await post(path: "/auth/v1/token?grant_type=id_token", body: body, auth: false)
        let sess = try parseAuthSession(from: data)
        self.session = sess
        saveSession(sess)
        try await loadCurrentUser(userId: sess.userId)
        return sess
    }

    // MARK: - Password Reset

    /// Sends a password reset email via Supabase Auth.
    /// Supabase delivers the link; no token needed on the client side.
    func sendPasswordReset(email: String) async throws {
        let body: [String: Any] = ["email": email]
        _ = try await post(path: "/auth/v1/recover", body: body, auth: false)
    }

    // MARK: - Delete Account

    /// Permanently deletes the authenticated user's Auth record.
    /// Cascades to all user-owned rows via ON DELETE CASCADE foreign keys.
    /// Signs the client out after deletion regardless of API result.
    func deleteCurrentUser() async throws {
        guard let token = accessToken,
              let url   = URL(string: "\(Config.supabaseURL)/auth/v1/user")
        else { throw MBIError.authFailed("Not authenticated") }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)",       forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        try checkHTTPStatus(response)
        clearSavedSession()
    }

    // MARK: - Sprint 7: Engagement Streak

    /// Counts consecutive days (ending on today or yesterday) where daily_inputs
    /// has a row for this user. Uses the server-side date column to avoid device
    /// timezone drift. Best-effort — returns 0 on any failure.
    func fetchEngagementStreak(userId: String) async -> Int {
        guard let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_inputs" +
            "?user_id=eq.\(userId)" +
            "&order=date.desc" +
            "&limit=90" +
            "&select=date"
        ) else { return 0 }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)",
                         forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",     forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 0 }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let today     = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        var streak = 0
        var expectedDate: Date? = nil

        for row in rows {
            guard let dateStr = row["date"] as? String,
                  let rowDate = formatter.date(from: dateStr)
            else { continue }
            let rowDay = cal.startOfDay(for: rowDate)

            if streak == 0 {
                // First row: accept today or yesterday (HealthKit data has a 1-day lag)
                guard rowDay == today || rowDay == yesterday else { break }
                streak = 1
                expectedDate = cal.date(byAdding: .day, value: -1, to: rowDay)
            } else {
                guard let expected = expectedDate, rowDay == expected else { break }
                streak += 1
                expectedDate = cal.date(byAdding: .day, value: -1, to: rowDay)
            }
        }

        return streak
    }

    // MARK: - Sprint 7: Consistency Score

    /// Rolling 30-day completeness: (days with daily_inputs) / 30.
    /// Returns 0.0–1.0. Best-effort — returns 0 on failure.
    func fetchConsistencyScore(userId: String) async -> Double {
        let cutoff = ISO8601DateFormatter().string(
            from: Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        ).prefix(10)

        guard let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_inputs" +
            "?user_id=eq.\(userId)" +
            "&date=gte.\(cutoff)" +
            "&select=date"
        ) else { return 0 }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)",
                         forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",     forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 0 }

        return min(Double(rows.count) / 30.0, 1.0)
    }

    // MARK: - Sprint 7: Workout Logging

    /// Logs a manually entered workout to logged_workouts. Best-effort.
    func logWorkout(userId: String, type: String, durationMinutes: Int, date: String) async {
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/logged_workouts") else { return }
        let body: [String: Any] = [
            "user_id":          userId,
            "workout_type":     type,
            "duration_minutes": durationMinutes,
            "date":             date,
            "logged_at":        ISO8601DateFormatter().string(from: Date())
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)",
                         forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",     forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Sprint 9: Horizon Assist

    /// Calls the `horizon-assist` Edge Function to answer a user question
    /// grounded in their current Horizon pathway signals.
    ///
    /// Architecture:
    ///   • Edge Function holds the Claude API key — key never touches the iOS client.
    ///   • Request includes signals as structured context + the user's free-text question.
    ///   • Response is a wellness-framed answer with embedded disclaimer flag.
    ///
    /// Phase 2 status: Edge Function wiring is a TODO — returns a stub response.
    /// When `horizon-assist` is deployed, remove the guard below.
    ///
    /// Legal requirement: caller MUST display the disclaimer before every response.
    func callHorizonAssist(
        userId: String,
        question: String,
        assessment: HorizonAssessment
    ) async throws -> HorizonAssistResponse {
        // TODO (Sprint 9 / Phase 3): Deploy `horizon-assist` Edge Function.
        // When deployed, replace the stub below with:
        //   let body: [String: Any] = [
        //       "userId":   userId,
        //       "question": question,
        //       "signals":  signalsPayload(assessment)
        //   ]
        //   let result = try await callEdgeFunction(url: Config.horizonAssistURL, body: body)
        //   guard let answer = result["answer"] as? String else {
        //       throw MBIError.syncFailed("horizon-assist: empty response")
        //   }
        //   return HorizonAssistResponse(answer: answer, isStub: false)

        // Phase 2 stub: synthesise a contextual response from the assessment locally.
        let stubAnswer = buildStubAnswer(question: question, assessment: assessment)
        return HorizonAssistResponse(answer: stubAnswer, isStub: true)
    }

    private func buildStubAnswer(question: String, assessment: HorizonAssessment) -> String {
        let active = [assessment.autonomic, assessment.sleep, assessment.metabolic]
            .compactMap { $0 }
            .filter { $0.isActive }

        guard !active.isEmpty else {
            return "Your current Horizon patterns are within baseline range — no elevated patterns are active right now. Keep tracking and Horizon will surface changes as they emerge."
        }

        let pathwayNames = active.map { signal -> String in
            switch signal.pathway {
            case "autonomic": return "autonomic regulation"
            case "sleep":     return "sleep architecture"
            default:          return "metabolic activity"
            }
        }.joined(separator: " and ")

        let maxDays = active.map { $0.daysInPattern }.max() ?? 0
        return "Horizon is currently tracking an elevated pattern in your \(pathwayNames) \(active.count == 1 ? "pathway" : "pathways"). This pattern has been present for \(maxDays) days. The signal reflects data collected through Apple HealthKit — not a clinical assessment. If this pattern continues, consider reviewing it with a licensed healthcare professional."
    }

    // MARK: - Learning Foundation: Nudge Response Logging

    /// Logs how the user interacted with a nudge card to nudge_responses table.
    /// response_type: "accepted" | "ignored" | "dismissed" | "completed"
    /// nudge_event_id is returned in the narrate API response and stored by the caller.
    /// Best-effort — never throws. Failure is swallowed silently.
    func logNudgeResponse(
        nudgeEventId: String,
        responseType: String,
        latencySeconds: Int?,
        respondedAt: Date = Date()
    ) async {
        // NOTE: nudge_responses has NO scoring_version column — that lives on nudge_events.
        // Traceability to DOMAIN_VERSION is via the nudge_event_id FK, not a column here.
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/nudge_responses") else { return }
        var body: [String: Any] = [
            "nudge_event_id": nudgeEventId,
            "user_id":        session?.userId ?? "",
            "response_type":  responseType,
            "responded_at":   ISO8601DateFormatter().string(from: respondedAt),
        ]
        if let latency = latencySeconds {
            body["latency_seconds"] = latency
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)",
                         forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",     forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Sprint 7: Daily Check-In

    /// Upserts a daily check-in (mood/energy/stress) to daily_checkins. Best-effort.
    /// Keyed on (user_id, date) — safe to call multiple times per day.
    func logCheckIn(userId: String, mood: Int, energy: Int, stress: Int, date: String) async {
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/daily_checkins") else { return }
        let body: [String: Any] = [
            "user_id": userId,
            "date":    date,
            "mood":    mood,
            "energy":  energy,
            "stress":  stress
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session?.accessToken ?? Config.supabaseAnonKey)",
                         forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json",          forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = bodyData
        _ = try? await URLSession.shared.data(for: request)
    }
}

