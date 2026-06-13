// ios/MBI/MBI/Services/SupabaseService+Domains.swift
// MBI Phase 1.5 — SupabaseService extension · Sprint 3B
// Domain-scoped data fetches for DomainBreakdownView.
//
// Three additions:
//   callDomainEdgeFunction  — internal wrapper for domain narrative Edge Function calls
//                             (callEdgeFunction is private in SupabaseService.swift)
//   fetchLatestDailyInputs  — most recent daily_inputs row for expanded card metric values
//   fetchDomainBaselines    — 30-day per-domain score averages for semantic progress bar
//
// PATTERN NOTE: This extension uses the same raw URLSession / getRequest pattern as
// SupabaseService.swift. The Supabase Swift SDK is not used in this codebase.

import Foundation

// ─────────────────────────────────────────
// DOMAIN RAW METRICS  (daily_inputs)
// ─────────────────────────────────────────

struct DomainRawMetrics {
    let hrv_ms: Double?
    let resting_hr_bpm: Double?
    let sleep_duration_hrs: Double?
    let sleep_continuity_pct: Double?
    let steps: Double?
    let active_minutes: Double?
    let respiratory_rate_rpm: Double?
    let distance_km: Double?

    static let empty = DomainRawMetrics(
        hrv_ms: nil, resting_hr_bpm: nil,
        sleep_duration_hrs: nil, sleep_continuity_pct: nil,
        steps: nil, active_minutes: nil,
        respiratory_rate_rpm: nil, distance_km: nil
    )
}

// ─────────────────────────────────────────
// DOMAIN BASELINE AVERAGES
// ─────────────────────────────────────────

struct DomainBaselines {
    let d1Autonomic: Double?
    let d2Sleep: Double?
    let d3Activity: Double?
    let d4Stress: Double?
    let d5Allostatic: Double?

    static let empty = DomainBaselines(
        d1Autonomic: nil, d2Sleep: nil, d3Activity: nil,
        d4Stress: nil, d5Allostatic: nil
    )
}

// ─────────────────────────────────────────
// EXTENSION
// ─────────────────────────────────────────

extension SupabaseService {

    // ── Edge Function wrapper — internal access for domain narrative calls ──
    // callEdgeFunction is private in SupabaseService.swift. This wrapper
    // exposes the same URLSession pattern with internal access so
    // DomainBreakdownView can call the two new narrative Edge Functions
    // without modifying SupabaseService.swift.

    func callDomainEdgeFunction(url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = session?.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MBIError.httpError(code)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // ── Private GET helper — mirrors getRequest in SupabaseService.swift ─────
    // getRequest is private in SupabaseService, so the extension owns its copy.

    private func domainGetRequest(url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        if let token = session?.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MBIError.httpError(code)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // ── Fetch most recent daily_inputs row ──────────────────────────────────

    func fetchLatestDailyInputs(userId: String) async throws -> DomainRawMetrics {
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_inputs" +
            "?user_id=eq.\(userId)" +
            "&order=date.desc" +
            "&limit=1" +
            "&select=hrv_ms,resting_hr_bpm,sleep_duration_hrs,sleep_continuity_pct,steps,active_minutes,respiratory_rate_rpm,distance_km"
        )!
        let data = try await domainGetRequest(url: url)
        guard let rows = data as? [[String: Any]], let row = rows.first else { return .empty }

        func toDouble(_ val: Any?) -> Double? {
            if let v = val as? Double { return v }
            if let v = val as? Int    { return Double(v) }
            if let s = val as? String { return Double(s) }
            return nil
        }

        return DomainRawMetrics(
            hrv_ms:               toDouble(row["hrv_ms"]),
            resting_hr_bpm:       toDouble(row["resting_hr_bpm"]),
            sleep_duration_hrs:   toDouble(row["sleep_duration_hrs"]),
            sleep_continuity_pct: toDouble(row["sleep_continuity_pct"]),
            steps:                toDouble(row["steps"]),
            active_minutes:       toDouble(row["active_minutes"]),
            respiratory_rate_rpm: toDouble(row["respiratory_rate_rpm"]),
            distance_km:          toDouble(row["distance_km"])
        )
    }

    // ── Fetch 30-day history for a single domain column ─────────────────────
    // column: "d1_autonomic" | "d2_sleep" | "d3_activity" | "d4_stress" | "d5_allostatic"

    func fetchDomainHistory(userId: String, column: String) async throws -> [(date: String, value: Double)] {
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_scores" +
            "?user_id=eq.\(userId)" +
            "&order=date.desc" +
            "&limit=30" +
            "&select=date,\(column)"
        )!
        let data = try await domainGetRequest(url: url)
        guard let rows = data as? [[String: Any]] else { return [] }
        return rows.reversed().compactMap { row in
            guard let date  = row["date"] as? String,
                  let value = (row[column] as? NSNumber)?.doubleValue
            else { return nil }
            return (date: date, value: value)
        }
    }

    // ── Fetch 90-day per-metric history for MetricDetailView (Phase 2) ────────

    /// Returns up to 90 days of (date, value) pairs for a single metric.
    /// table: "daily_inputs" | "daily_scores"
    /// column: the exact column name in that table (e.g. "hrv_ms", "chronos_score")
    func fetchMetricHistory(
        userId: String,
        table: String,
        column: String
    ) async throws -> [(date: String, value: Double)] {
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/\(table)" +
            "?user_id=eq.\(userId)" +
            "&order=date.desc" +
            "&limit=90" +
            "&select=date,\(column)"
        )!
        let data = try await domainGetRequest(url: url)
        guard let rows = data as? [[String: Any]] else { return [] }
        return rows.reversed().compactMap { row in
            guard let date  = row["date"] as? String,
                  let value = (row[column] as? NSNumber)?.doubleValue
            else { return nil }
            return (date: date, value: value)
        }
    }

    // ── Fetch 30-day per-domain score averages ──────────────────────────────

    func fetchDomainBaselines(userId: String) async throws -> DomainBaselines {
        let url = URL(string:
            "\(Config.supabaseURL)/rest/v1/daily_scores" +
            "?user_id=eq.\(userId)" +
            "&order=date.desc" +
            "&limit=30" +
            "&select=d1_autonomic,d2_sleep,d3_activity,d4_stress,d5_allostatic"
        )!
        let data = try await domainGetRequest(url: url)
        guard let rows = data as? [[String: Any]], rows.count >= 3 else { return .empty }

        func avg(_ key: String) -> Double? {
            let vals: [Double] = rows.compactMap { row in
                if let v = row[key] as? Double { return v }
                if let s = row[key] as? String { return Double(s) }
                return nil
            }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }

        return DomainBaselines(
            d1Autonomic:  avg("d1_autonomic"),
            d2Sleep:      avg("d2_sleep"),
            d3Activity:   avg("d3_activity"),
            d4Stress:     avg("d4_stress"),
            d5Allostatic: avg("d5_allostatic")
        )
    }
}
