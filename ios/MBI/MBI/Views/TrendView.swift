// ios/MBI/MBI/Views/TrendView.swift
// MBI Phase 1.5 — Trend Tab · Sprint 2 · Epic 1
// Full redesign: window toggle, line chart, window narrative, metric selector, signal callouts
// Replaces: ScoreRibbon (bar chart), WeeklyNarrativeCard (today's explanation),
//           DeviationCalloutCard (threshold-based), WeekAnalysis (old logic)

import SwiftUI
import Charts

// ─────────────────────────────────────────
// TREND VIEW MODEL
// Owns all window state, fetches, and narrative caching.
// Single source of truth for the Trend tab.
// ─────────────────────────────────────────

@MainActor
class TrendViewModel: ObservableObject {

    // Window state
    @Published var selectedWindow: TrendWindow = .sevenDay

    // Chart data
    @Published var chartPoints: [TrendChartPoint] = []
    @Published var selectedMetricKey: String = "chronos"    // "chronos" or a metric key

    // Narrative
    @Published var narrativeText: String = ""
    @Published var isLoadingNarrative: Bool = false

    // Metric selector
    @Published var metricTiles: [MetricTileData] = []

    // Signal callouts
    @Published var workingCallouts: [TrendCallout] = []
    @Published var watchCallouts: [TrendCallout] = []

    // Aggregate cache — keyed by window type string
    private var aggregateCache: [String: [TrendAggregate]] = [:]
    // Narrative cache — keyed by window type string
    private var narrativeCache: [String: String] = [:]
    // Raw daily rows cache
    private var dailyScoresCache: [[String: Any]] = []
    private var dailyInputsCache: [[String: Any]] = []

    // Building state
    @Published var isBuilding: Bool = false
    @Published var buildingLabel: String = ""

    // Direction & pattern (Section 1, 4, 6)
    @Published var trendDirection: String = "stable"
    @Published var twelveMonthPattern: String = "stable"

    // Staleness indicator (Section 3)
    @Published var stalenessDate: String? = nil

    // Baseline ranges — keyed by selectedMetricKey value (e.g. "chronos", "hrv", "resting_hr")
    @Published var baselineRanges: [String: BaselineRange] = [:]

    // Error
    @Published var loadError: String? = nil

    private var supabase: SupabaseService?

    func attach(supabase: SupabaseService) {
        self.supabase = supabase
    }

    // ── Initial load ─────────────────────────────────────────────────
    func initialLoad(userId: String) async {
        guard let supabase else { return }

        // Scores fetch — primary, but non-fatal if it fails
        do {
            let scoresResult = try await supabase.fetchRecentDailyScores(userId: userId, limit: 7)
            dailyScoresCache = scoresResult
        } catch {
            print("[TrendViewModel] scores fetch failed: \(error)")
            // Continue — chart will show building state
        }

        // Inputs fetch — always non-fatal
        dailyInputsCache = await supabase.fetchRecentDailyInputs(userId: userId, limit: 7)

        // Monthly aggregates for 30D tile column — non-fatal
        do {
            let monthlyResult = try await supabase.fetchTrendAggregates(userId: userId, windowType: "monthly", limit: 1)
            if let m = monthlyResult.first,
               let agg = try? decodeAggregate(from: m) {
                aggregateCache["monthly_latest"] = [agg]
            }
        } catch {
            print("[TrendViewModel] monthly fetch failed: \(error)")
        }

        buildMetricTiles()
        await loadBaselineRanges(userId: userId)
        await switchWindow(to: .sevenDay, userId: userId)
        updateTrendDirection()
        updateStalenessIndicator()
    }

    // ── Window switch ────────────────────────────────────────────────
    func switchWindow(to window: TrendWindow, userId: String) async {
        let previousMetricKey = selectedMetricKey
        selectedWindow = window
        loadError = nil

        switch window {
        case .sevenDay:
            load7DWindow()
        case .eightWeek:
            await loadAggregateWindow(userId: userId, windowType: "weekly", limit: 8)
        case .twelveMonth:
            await loadAggregateWindow(userId: userId, windowType: "monthly", limit: 12)
        }

        // Restore metric selection if the new window has data for it; otherwise reset
        if previousMetricKey != "chronos" && metricHasData(key: previousMetricKey, for: window) {
            selectMetric(previousMetricKey)
        } else if previousMetricKey != "chronos" {
            selectedMetricKey = "chronos"
        }

        updateTrendDirection()
        updateStalenessIndicator()
        await loadNarrative(for: window, userId: userId)
        computeCallouts(for: window)
    }

    // ── 7D window ────────────────────────────────────────────────────
    // Section 10: Gap-aware chart rendering.
    // steps_only days have no daily_scores row (scoring engine skips them).
    // We detect these gaps from dailyInputsCache (data_tier == 'steps_only'),
    // then inject carry-forward points at the last valid score value so the
    // line chart does not have abrupt discontinuities.
    private func load7DWindow() {
        let rows = dailyScoresCache
        isBuilding = rows.count < TrendWindow.sevenDay.buildingThreshold
        buildingLabel = TrendWindow.sevenDay.buildingLabel

        // Build lookups from caches
        let scoreByDate: [String: (score: Double, tier: String)] = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row -> (String, (Double, String))? in
                guard let date  = row["date"]          as? String,
                      let score = row["chronos_score"] as? Double else { return nil }
                let tier = row["data_tier"] as? String ?? "wearable"
                return (date, (score, tier))
            }
        )
        let tierByDate: [String: String] = Dictionary(
            uniqueKeysWithValues: dailyInputsCache.compactMap { row -> (String, String)? in
                guard let date = row["date"] as? String else { return nil }
                return (date, row["data_tier"] as? String ?? "unknown")
            }
        )
        let gapReasonByDate: [String: String] = Dictionary(
            uniqueKeysWithValues: dailyInputsCache.compactMap { row -> (String, String)? in
                guard let date   = row["date"]       as? String,
                      let reason = row["gap_reason"] as? String else { return nil }
                return (date, reason)
            }
        )

        // Generate the full 7-day date range (D-6 through today inclusive)
        let calendar = Calendar.current
        let sevenDayRange: [String] = (0..<7).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: -(6 - offset), to: Date())
            else { return nil }
            return formatDate(date)
        }

        var lastValidValue: Double = rows.compactMap { $0["chronos_score"] as? Double }.first ?? 0
        var points: [TrendChartPoint] = []

        for dateStr in sevenDayRange {
            if let entry = scoreByDate[dateStr] {
                // Valid scored day
                lastValidValue = entry.score
                points.append(TrendChartPoint(
                    date: dateStr, value: entry.score, metricKey: "chronos",
                    isGap: false, gapReason: nil
                ))
            } else {
                // No score row — check if it's a classified steps_only gap
                let tier = tierByDate[dateStr] ?? "unknown"
                if tier == "steps_only" && lastValidValue > 0 {
                    points.append(TrendChartPoint(
                        date: dateStr, value: lastValidValue, metricKey: "chronos",
                        isGap: true, gapReason: gapReasonByDate[dateStr]
                    ))
                }
                // If no input row exists for this date at all, skip it
            }
        }

        chartPoints = points
    }

    // ── 8W / 12M aggregate windows ──────────────────────────────────
    private func loadAggregateWindow(userId: String, windowType: String, limit: Int) async {
        guard let supabase else { return }

        // Use cache if available
        if let cached = aggregateCache[windowType], !cached.isEmpty {
            applyAggregates(cached, windowType: windowType, limit: limit)
            return
        }

        do {
            let rows = try await supabase.fetchTrendAggregates(userId: userId, windowType: windowType, limit: limit)
            let aggregates = rows.compactMap { try? decodeAggregate(from: $0) }
            aggregateCache[windowType] = aggregates
            applyAggregates(aggregates, windowType: windowType, limit: limit)
        } catch {
            loadError = "Could not load \(windowType) data."
            print("[TrendViewModel] aggregate load failed: \(error)")
        }
    }

    private func applyAggregates(_ aggregates: [TrendAggregate], windowType: String, limit: Int) {
        let threshold = windowType == "weekly"
            ? TrendWindow.eightWeek.buildingThreshold
            : TrendWindow.twelveMonth.buildingThreshold

        isBuilding = aggregates.count < threshold
        buildingLabel = windowType == "weekly"
            ? TrendWindow.eightWeek.buildingLabel
            : TrendWindow.twelveMonth.buildingLabel

        chartPoints = aggregates.compactMap { agg -> TrendChartPoint? in
            guard let avg = agg.chronosAvg else { return nil }
            return TrendChartPoint(date: agg.windowStart, value: avg, metricKey: "chronos")
        }
    }

    // ── Metric selector filter ────────────────────────────────────────
    func selectMetric(_ key: String) {
        selectedMetricKey = key

        if key == "chronos" {
            // Restore composite chart for current window
            switch selectedWindow {
            case .sevenDay:
                load7DWindow()
            case .eightWeek:
                if let cached = aggregateCache["weekly"] {
                    applyAggregates(cached, windowType: "weekly", limit: 8)
                }
            case .twelveMonth:
                if let cached = aggregateCache["monthly"] {
                    applyAggregates(cached, windowType: "monthly", limit: 12)
                }
            }
            return
        }

        // Per-metric chart data
        switch selectedWindow {
        case .sevenDay:
            chartPoints = dailyInputsCache.compactMap { row -> TrendChartPoint? in
                guard let date = row["date"] as? String else { return nil }
                let value = metricValue(from: row, key: key)
                guard let v = value else { return nil }
                return TrendChartPoint(date: date, value: v, metricKey: key)
            }

        case .eightWeek:
            if let cached = aggregateCache["weekly"] {
                chartPoints = cached.compactMap { agg -> TrendChartPoint? in
                    guard let v = agg.avg(for: key) else { return nil }
                    return TrendChartPoint(date: agg.windowStart, value: v, metricKey: key)
                }
            }

        case .twelveMonth:
            if let cached = aggregateCache["monthly"] {
                chartPoints = cached.compactMap { agg -> TrendChartPoint? in
                    guard let v = agg.avg(for: key) else { return nil }
                    return TrendChartPoint(date: agg.windowStart, value: v, metricKey: key)
                }
            }
        }
    }

    // ── Narrative ────────────────────────────────────────────────────
    private func loadNarrative(for window: TrendWindow, userId: String) async {
        guard let supabase else { return }
        let cacheKey = window.apiKey

        // Serve from cache if available — do not regenerate on tab switch
        if let cached = narrativeCache[cacheKey], !cached.isEmpty {
            narrativeText = cached
            return
        }

        isLoadingNarrative = true
        defer { isLoadingNarrative = false }

        // Build inputs from available data
        let (avg, min, max, direction, drivers) = narrativeInputs(for: window)

        guard avg > 0 else {
            narrativeText = ""
            return
        }

        let windowStart: String
        let windowEnd: String
        let daysInWindow: Int
        let today = todayString()

        switch window {
        case .sevenDay:
            let startDate = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
            windowStart = formatDate(startDate)
            windowEnd = today
            daysInWindow = dailyScoresCache.count

        case .eightWeek:
            let aggs = aggregateCache["weekly"] ?? []
            windowStart = aggs.first?.windowStart ?? ""
            windowEnd = aggs.last?.windowEnd ?? today
            daysInWindow = aggs.reduce(0) { $0 + $1.daysInWindow }

        case .twelveMonth:
            let aggs = aggregateCache["monthly"] ?? []
            windowStart = aggs.first?.windowStart ?? ""
            windowEnd = aggs.last?.windowEnd ?? today
            daysInWindow = aggs.reduce(0) { $0 + $1.daysInWindow }
        }

        // Build deterministic window_key for server-side cache (Fix 6)
        let windowKey = "\(windowStart)_\(windowEnd)_avg\(Int(avg.rounded()))_\(direction)"

        do {
            let text = try await supabase.fetchTrendNarrative(
                userId: userId,
                windowType: window.apiKey,
                windowStart: windowStart,
                windowEnd: windowEnd,
                chronosAvg: avg,
                chronosMin: min,
                chronosMax: max,
                trendDirection: direction,
                topDrivers: drivers,
                daysInWindow: daysInWindow,
                windowKey: windowKey
            )
            narrativeCache[cacheKey] = text
            narrativeText = text
        } catch {
            narrativeText = ""
            print("[TrendViewModel] narrative fetch failed: \(error)")
        }
    }

    // ── Metric tiles ─────────────────────────────────────────────────
    private func buildMetricTiles() {
        let todayRow = dailyInputsCache.last
        let monthlyLatest = aggregateCache["monthly_latest"]?.first

        // Chronos tile — always first
        let chronosScores = dailyScoresCache.compactMap { $0["chronos_score"] as? Double }
        let chronos7DAvg = chronosScores.isEmpty ? nil : chronosScores.reduce(0, +) / Double(chronosScores.count)
        let chronos30DAvg = monthlyLatest?.chronosAvg

        var tiles: [MetricTileData] = [
            MetricTileData(
                id: "chronos",
                displayName: "Chronos",
                shortName: "Chronos",
                todayValue: chronosScores.last,
                sevenDayAvg: chronos7DAvg,
                thirtyDayAvg: chronos30DAvg,
                unit: ""
            )
        ]

        // Per-metric tiles — only show if data exists
        let metricDefs: [(key: String, name: String, short: String, unit: String, inputKey: String)] = [
            ("hrv",               "HRV",          "HRV",        "ms",  "hrv_ms"),
            ("resting_hr",        "Resting HR",   "HR",         "bpm", "resting_hr_bpm"),
            ("respiratory_rate",  "Resp. Rate",   "Resp",       "rpm", "respiratory_rate_rpm"),
            ("sleep_duration",    "Sleep",        "Sleep",      "hrs", "sleep_duration_hrs"),
            ("sleep_continuity",  "Sleep Quality","Quality",    "%",   "sleep_continuity_pct"),
            ("steps",             "Steps",        "Steps",      "",    "steps"),
            ("active_minutes",    "Active Min",   "Active",     "min", "active_minutes"),
        ]

        let sevenDayInputValues: [String: [Double]] = metricDefs.reduce(into: [:]) { acc, def in
            let vals = dailyInputsCache.compactMap { row -> Double? in
                metricValue(from: row, key: def.key)
            }
            if !vals.isEmpty { acc[def.key] = vals }
        }

        for def in metricDefs {
            guard let vals = sevenDayInputValues[def.key], !vals.isEmpty else { continue }
            let todayVal = todayRow.flatMap { metricValue(from: $0, key: def.key) }
            let avg7D = vals.reduce(0, +) / Double(vals.count)
            let avg30D = monthlyLatest?.avg(for: def.key)

            tiles.append(MetricTileData(
                id: def.key,
                displayName: def.name,
                shortName: def.short,
                todayValue: todayVal,
                sevenDayAvg: avg7D,
                thirtyDayAvg: avg30D,
                unit: def.unit
            ))
        }

        metricTiles = tiles
    }

    // ── Signal callouts (deterministic) ─────────────────────────────
    private func computeCallouts(for window: TrendWindow) {
        var working: [TrendCallout] = []
        var watching: [TrendCallout] = []

        switch window {
        case .sevenDay:
            compute7DCallouts(working: &working, watching: &watching)
        case .eightWeek:
            computeAggregateCallouts(aggs: aggregateCache["weekly"] ?? [],
                                     prevAggs: nil,
                                     working: &working, watching: &watching)
        case .twelveMonth:
            compute12MCallouts(working: &working, watching: &watching)
        }

        // Enforce minimum 2 bullets per section (Section 8 rule)
        workingCallouts = working.count >= 2 ? Array(working.prefix(3)) : []
        watchCallouts   = watching.count >= 2 ? Array(watching.prefix(3)) : []
    }

    private func compute7DCallouts(working: inout [TrendCallout], watching: inout [TrendCallout]) {
        let scores = dailyScoresCache.compactMap { $0["chronos_score"] as? Double }
        guard scores.count >= 7 else { return }

        let avg = scores.reduce(0, +) / Double(scores.count)

        // Best day
        if let maxScore = scores.max(),
           let maxIdx = scores.firstIndex(of: maxScore) {
            let dayRow = dailyScoresCache[maxIdx]
            let dayLabel = shortDayLabel(from: dayRow["date"] as? String ?? "")
            working.append(TrendCallout(category: .workingForYou,
                text: "Best day: \(dayLabel) at \(Int(maxScore)) — your highest score this week"))
        }

        // Consistency: fewer than 2 days more than 10 pts below average
        let deviationFlags = scores.filter { abs($0 - avg) > 10 && $0 < avg }.count
        if deviationFlags < 2 {
            let aboveCount = scores.filter { $0 >= avg }.count
            working.append(TrendCallout(category: .workingForYou,
                text: "\(aboveCount) of 7 days at or above your personal baseline"))
        }

        // Score range
        if let maxS = scores.max(), let minS = scores.min() {
            let range = maxS - minS
            if range > 20 {
                watching.append(TrendCallout(category: .worthWatching,
                    text: "Score ranged \(Int(range)) points this week — high variability can mask your trend"))
            }
        }

        // Per-metric deviation — use daily inputs
        let metricKeys = ["hrv", "resting_hr", "sleep_duration", "sleep_continuity", "steps"]
        for key in metricKeys {
            let vals = dailyInputsCache.compactMap { metricValue(from: $0, key: key) }
            guard vals.count >= 4 else { continue }
            let metricAvg = vals.reduce(0, +) / Double(vals.count)
            guard metricAvg > 0 else { continue }
            let first3Avg = vals.prefix(3).reduce(0, +) / 3.0
            let last3Avg  = vals.suffix(3).reduce(0, +) / 3.0
            let changePct = ((last3Avg - first3Avg) / metricAvg) * 100

            let label = metricDisplayName(for: key)
            if changePct > 10 {
                let higherIsBad = ["resting_hr", "respiratory_rate"]
                if higherIsBad.contains(key) {
                    watching.append(TrendCallout(category: .worthWatching,
                        text: "\(label) up \(Int(changePct))% this week — a signal worth watching"))
                } else {
                    working.append(TrendCallout(category: .workingForYou,
                        text: "\(label) up \(Int(changePct))% this week — adding momentum to your score"))
                }
            } else if changePct < -10 {
                let higherIsBad = ["resting_hr", "respiratory_rate"]
                if higherIsBad.contains(key) {
                    working.append(TrendCallout(category: .workingForYou,
                        text: "\(label) down \(Int(abs(changePct)))% this week — easing strain on your system"))
                } else {
                    watching.append(TrendCallout(category: .worthWatching,
                        text: "\(label) down \(Int(abs(changePct)))% this week — the primary drag this week"))
                }
            }
        }
    }

    private func computeAggregateCallouts(
        aggs: [TrendAggregate],
        prevAggs: [TrendAggregate]?,
        working: inout [TrendCallout],
        watching: inout [TrendCallout]
    ) {
        guard aggs.count >= 2 else { return }

        let chronosVals = aggs.compactMap { $0.chronosAvg }
        guard !chronosVals.isEmpty else { return }

        // Trend direction
        if let direction = aggs.last?.trendDirection {
            switch direction {
            case "improving":
                working.append(TrendCallout(category: .workingForYou,
                    text: "Chronos trend is improving across this window — momentum is compounding"))
            case "declining":
                let decliningCount = aggs.suffix(3).filter { $0.trendDirection == "declining" }.count
                if decliningCount >= 2 {
                    watching.append(TrendCallout(category: .worthWatching,
                        text: "\(decliningCount)-window declining trend in Chronos — consistent pressure on your system"))
                } else {
                    watching.append(TrendCallout(category: .worthWatching,
                        text: "Chronos trend declined this window — worth monitoring over the next window"))
                }
            default: break
            }
        }

        // Score variability — fires regardless of direction
        if let hi = chronosVals.max(), let lo = chronosVals.min(), (hi - lo) > 10 {
            watching.append(TrendCallout(category: .worthWatching,
                text: "Score range of \(Int(hi - lo)) points across this window — high variability can mask your trend"))
        }

        // Most improved metric vs prior half of window
        let halfIdx = aggs.count / 2
        let firstHalf = Array(aggs.prefix(halfIdx))
        let secondHalf = Array(aggs.suffix(aggs.count - halfIdx))

        let metricKeys = ["hrv", "resting_hr", "sleep_duration", "sleep_continuity", "steps"]
        for key in metricKeys {
            let firstAvgs = firstHalf.compactMap { $0.avg(for: key) }
            let secondAvgs = secondHalf.compactMap { $0.avg(for: key) }
            guard !firstAvgs.isEmpty, !secondAvgs.isEmpty else { continue }

            let firstMean = firstAvgs.reduce(0, +) / Double(firstAvgs.count)
            let secondMean = secondAvgs.reduce(0, +) / Double(secondAvgs.count)
            guard firstMean > 0 else { continue }

            let changePct = ((secondMean - firstMean) / firstMean) * 100
            let label = metricDisplayName(for: key)
            let higherIsBad = ["resting_hr", "respiratory_rate"]

            if changePct > 10 {
                if higherIsBad.contains(key) {
                    watching.append(TrendCallout(category: .worthWatching,
                        text: "\(label) up \(Int(changePct))% in the second half of this window — a signal worth watching"))
                } else {
                    working.append(TrendCallout(category: .workingForYou,
                        text: "\(label) up \(Int(changePct))% in the second half of this window — adding momentum"))
                }
            } else if changePct < -10 {
                if higherIsBad.contains(key) {
                    working.append(TrendCallout(category: .workingForYou,
                        text: "\(label) down \(Int(abs(changePct)))% in the second half of this window — easing strain"))
                } else {
                    watching.append(TrendCallout(category: .worthWatching,
                        text: "\(label) down \(Int(abs(changePct)))% in the second half of this window — the primary drag this window"))
                }
            }
        }
    }

    private func compute12MCallouts(working: inout [TrendCallout], watching: inout [TrendCallout]) {
        let aggs = aggregateCache["monthly"] ?? []
        let vals = aggs.compactMap { $0.chronosAvg }
        guard vals.count >= 4 else { return }

        let mean = vals.reduce(0, +) / Double(vals.count)
        let n = Double(vals.count)
        let variance = vals.map { pow($0 - mean, 2) }.reduce(0, +) / n
        let stdDev = variance.squareRoot()

        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"
        let monthFmt = DateFormatter(); monthFmt.dateFormat = "MMMM"

        // ── Working For You ───────────────────────────────────────────

        // Best month
        if let maxVal = vals.max(), let maxIdx = vals.firstIndex(of: maxVal) {
            let monthLabel = parser.date(from: aggs[maxIdx].windowStart)
                .map { monthFmt.string(from: $0) } ?? "That month"
            working.append(TrendCallout(category: .workingForYou,
                text: "\(monthLabel) was your strongest month — avg \(Int(maxVal))"))
        }

        // Consistency
        if stdDev < 5 {
            let range = Int((vals.max() ?? 0) - (vals.min() ?? 0))
            working.append(TrendCallout(category: .workingForYou,
                text: "Your score held within a \(range)-point range across \(aggs.count) months — that kind of consistency compounds"))
        }

        // Improving second half
        if vals.count >= 6 {
            let half = vals.count / 2
            let firstHalfAvg  = vals.prefix(half).reduce(0, +) / Double(half)
            let secondHalfAvg = vals.suffix(vals.count - half).reduce(0, +) / Double(vals.count - half)
            if secondHalfAvg > firstHalfAvg {
                let diff = Int((secondHalfAvg - firstHalfAvg).rounded())
                working.append(TrendCallout(category: .workingForYou,
                    text: "Your second half of the year averaged \(diff) points higher than the first — momentum is building"))
            }
        }

        // ── Worth Watching ─────────────────────────────────────────────

        // Weakest month (if >8 pts below mean)
        if let minVal = vals.min(), let minIdx = vals.firstIndex(of: minVal), (mean - minVal) > 8 {
            let monthLabel = parser.date(from: aggs[minIdx].windowStart)
                .map { monthFmt.string(from: $0) } ?? "That month"
            watching.append(TrendCallout(category: .worthWatching,
                text: "\(monthLabel) was your softest month — \(Int((mean - minVal).rounded())) points below your year average"))
        }

        // Declining second half (>3 pts)
        if vals.count >= 6 {
            let half = vals.count / 2
            let firstHalfAvg  = vals.prefix(half).reduce(0, +) / Double(half)
            let secondHalfAvg = vals.suffix(vals.count - half).reduce(0, +) / Double(vals.count - half)
            if firstHalfAvg - secondHalfAvg > 3 {
                let diff = Int((firstHalfAvg - secondHalfAvg).rounded())
                watching.append(TrendCallout(category: .worthWatching,
                    text: "Your score has eased \(diff) points on average across the second half of the year"))
            }
        }

        // High volatility
        if stdDev > 5 {
            let range = Int((vals.max() ?? 0) - (vals.min() ?? 0))
            watching.append(TrendCallout(category: .worthWatching,
                text: "Score varied \(range) points across the year — some months are significantly shaping the average"))
        }
    }

    // ── Narrative inputs helper ──────────────────────────────────────
    private func narrativeInputs(for window: TrendWindow) -> (avg: Double, min: Double, max: Double, direction: String, drivers: [String]) {
        switch window {
        case .sevenDay:
            let scores = dailyScoresCache.compactMap { $0["chronos_score"] as? Double }
            guard !scores.isEmpty else { return (0, 0, 0, "stable", []) }
            let avg = scores.reduce(0, +) / Double(scores.count)
            let minS = scores.min() ?? 0
            let maxS = scores.max() ?? 0
            let trend = (scores.last ?? 0) - (scores.first ?? 0)
            // Bug #4 fix: tightened deadband from ±5 to ±3 to reduce over-classification as "stable"
            let direction = trend > 3 ? "improving" : trend < -3 ? "declining" : "stable"
            // Top drivers by frequency
            var driverFreq: [String: Int] = [:]
            for row in dailyScoresCache {
                if let d1 = row["driver_1"] as? String { driverFreq[d1, default: 0] += 1 }
                if let d2 = row["driver_2"] as? String { driverFreq[d2, default: 0] += 1 }
            }
            let topDrivers = driverFreq.sorted { $0.value > $1.value }.prefix(2).map { $0.key }
            return (avg, minS, maxS, direction, Array(topDrivers))

        case .eightWeek:
            let aggs = aggregateCache["weekly"] ?? []
            return aggregateNarrativeInputs(aggs)

        case .twelveMonth:
            let aggs = aggregateCache["monthly"] ?? []
            return aggregateNarrativeInputs(aggs)
        }
    }

    private func aggregateNarrativeInputs(_ aggs: [TrendAggregate]) -> (avg: Double, min: Double, max: Double, direction: String, drivers: [String]) {
        let vals = aggs.compactMap { $0.chronosAvg }
        guard !vals.isEmpty else { return (0, 0, 0, "stable", []) }
        let avg = vals.reduce(0, +) / Double(vals.count)
        let minV = vals.min() ?? 0
        let maxV = vals.max() ?? 0
        let direction = aggs.last?.trendDirection ?? "stable"
        var driverFreq: [String: Int] = [:]
        for agg in aggs {
            if let d = agg.topDriver1 { driverFreq[d, default: 0] += 1 }
            if let d = agg.topDriver2 { driverFreq[d, default: 0] += 1 }
        }
        let topDrivers = driverFreq.sorted { $0.value > $1.value }.prefix(2).map { $0.key }
        return (avg, minV, maxV, direction, Array(topDrivers))
    }

    // ── Helpers ──────────────────────────────────────────────────────
    private func metricValue(from row: [String: Any], key: String) -> Double? {
        let inputKey: String
        switch key {
        case "hrv":              inputKey = "hrv_ms"
        case "resting_hr":       inputKey = "resting_hr_bpm"
        case "respiratory_rate": inputKey = "respiratory_rate_rpm"
        case "sleep_duration":   inputKey = "sleep_duration_hrs"
        case "sleep_continuity": inputKey = "sleep_continuity_pct"
        case "steps":            inputKey = "steps"
        case "active_minutes":   inputKey = "active_minutes"
        default: return nil
        }
        if let v = row[inputKey] as? Double { return v }
        if let v = row[inputKey] as? Int { return Double(v) }
        return nil
    }

    private func metricDisplayName(for key: String) -> String {
        switch key {
        case "hrv":               return "HRV"
        case "resting_hr":        return "Resting HR"
        case "respiratory_rate":  return "Resp. rate"
        case "sleep_duration":    return "Sleep duration"
        case "sleep_continuity":  return "Sleep continuity"
        case "steps":             return "Steps"
        case "active_minutes":    return "Active minutes"
        default:                  return key
        }
    }

    private func shortDayLabel(from dateString: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateString) else { return "" }
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func decodeAggregate(from dict: [String: Any]) throws -> TrendAggregate {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(TrendAggregate.self, from: data)
    }

    // ── Direction & helpers (Section 1, 3, 4, 6, 9) ──────────────────

    private func updateTrendDirection() {
        let (_, _, _, direction, _) = narrativeInputs(for: selectedWindow)
        trendDirection = direction
        if selectedWindow == .twelveMonth {
            let aggs = aggregateCache["monthly"] ?? []
            twelveMonthPattern = compute12MPattern(aggs)
        }
    }

    private func updateStalenessIndicator() {
        // 12M: monthly aggregates update continuously — day-level timestamp is misleading
        guard selectedWindow != .twelveMonth else {
            stalenessDate = nil
            return
        }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let lastDate = chartPoints.compactMap({ parser.date(from: $0.date) }).max() else {
            stalenessDate = nil
            return
        }
        let daysDiff = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
        if daysDiff > 1 {
            let display = DateFormatter()
            display.dateFormat = "MMMM d"
            stalenessDate = display.string(from: lastDate)
        } else {
            stalenessDate = nil
        }
    }

    private func metricHasData(key: String, for window: TrendWindow) -> Bool {
        switch window {
        case .sevenDay:
            return !dailyInputsCache.compactMap { metricValue(from: $0, key: key) }.isEmpty
        case .eightWeek:
            return !(aggregateCache["weekly"] ?? []).compactMap { $0.avg(for: key) }.isEmpty
        case .twelveMonth:
            return !(aggregateCache["monthly"] ?? []).compactMap { $0.avg(for: key) }.isEmpty
        }
    }

    func compute12MPattern(_ aggs: [TrendAggregate]) -> String {
        let vals = aggs.compactMap { $0.chronosAvg }
        guard vals.count >= 4 else { return "insufficient" }

        let n = Double(vals.count)
        let mean = vals.reduce(0, +) / n
        let variance = vals.map { pow($0 - mean, 2) }.reduce(0, +) / n
        if variance.squareRoot() > 8 { return "volatile" }

        // Seasonal: at least one month ≥5 above AND one ≥5 below mean, non-adjacent
        let highIdxs = vals.enumerated().filter { $0.element >= mean + 5 }.map { $0.offset }
        let lowIdxs  = vals.enumerated().filter { $0.element <= mean - 5 }.map { $0.offset }
        if !highIdxs.isEmpty && !lowIdxs.isEmpty {
            let notAdjacent = highIdxs.contains { h in lowIdxs.contains { l in abs(h - l) > 1 } }
            if notAdjacent { return "seasonal" }
        }

        // Linear regression slope
        let xMean = (n - 1) / 2
        let numerator   = vals.enumerated().map { (Double($0.offset) - xMean) * ($0.element - mean) }.reduce(0, +)
        let denominator = vals.enumerated().map { pow(Double($0.offset) - xMean, 2) }.reduce(0, +)
        let slope = denominator > 0 ? numerator / denominator : 0

        if slope > 0.5  { return "improving" }
        if slope < -0.5 { return "declining" }
        return "stable"
    }

    // Window avg for DirectionSignalView
    var windowChronosAvg: Int {
        let vals: [Double]
        switch selectedWindow {
        case .sevenDay:    vals = dailyScoresCache.compactMap { $0["chronos_score"] as? Double }
        case .eightWeek:   vals = (aggregateCache["weekly"]  ?? []).compactMap { $0.chronosAvg }
        case .twelveMonth: vals = (aggregateCache["monthly"] ?? []).compactMap { $0.chronosAvg }
        }
        guard !vals.isEmpty else { return 0 }
        return Int((vals.reduce(0, +) / Double(vals.count)).rounded())
    }

    // Date range string for DirectionSignalView
    var signalDateLabel: String {
        let parser  = DateFormatter(); parser.dateFormat  = "yyyy-MM-dd"
        let display = DateFormatter()
        switch selectedWindow {
        case .sevenDay:
            let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
            display.dateFormat = "MMM d"
            return "Week of \(display.string(from: weekStart))"
        case .eightWeek:
            let aggs = aggregateCache["weekly"] ?? []
            guard let s = aggs.first.flatMap({ parser.date(from: $0.windowStart) }),
                  let e = aggs.last.flatMap({ parser.date(from: $0.windowEnd) }) else { return "Last 8 weeks" }
            display.dateFormat = "MMM d"
            return "\(display.string(from: s)) – \(display.string(from: e))"
        case .twelveMonth:
            let aggs = aggregateCache["monthly"] ?? []
            guard let s = aggs.first.flatMap({ parser.date(from: $0.windowStart) }),
                  let e = aggs.last.flatMap({ parser.date(from: $0.windowEnd) }) else { return "Last 12 months" }
            display.dateFormat = "MMM yyyy"
            return "\(display.string(from: s)) – \(display.string(from: e))"
        }
    }

    // Dynamic 12M label (Section 9)
    var dynamicDateLabel: String {
        switch selectedWindow {
        case .sevenDay, .eightWeek:
            return selectedWindow.dateLabel
        case .twelveMonth:
            let aggs = aggregateCache["monthly"] ?? []
            if aggs.count >= 12 { return "LAST 12 MONTHS" }
            if aggs.count >= 4 {
                let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"
                let display = DateFormatter(); display.dateFormat = "MMM yyyy"
                let startStr = aggs.first.flatMap { parser.date(from: $0.windowStart) }.map { display.string(from: $0) } ?? ""
                let endStr   = aggs.last.flatMap  { parser.date(from: $0.windowEnd)   }.map { display.string(from: $0) } ?? ""
                return "AVAILABLE HISTORY · \(startStr) – \(endStr)"
            }
            let count = aggs.count
            return "HISTORY BUILDING · \(count) MONTH\(count == 1 ? "" : "S") RECORDED"
        }
    }

    // ── Baseline range fetch ─────────────────────────────────────────
    // Direct URLSession — avoids modifying SupabaseService (constraint).
    // baselines table is a single wide row per user (latest computed_on).
    // Range columns: p20_hrv_7d / p80_hrv_7d, p20_resting_hr / p80_resting_hr,
    // p20_sleep_duration / p80_sleep_duration, p20_sleep_continuity / p80_sleep_continuity,
    // p20_steps_weekday / p80_steps_weekday, p20_active_minutes_weekday / p80_active_minutes_weekday.
    // No Chronos or respiratory_rate range — those metrics have no band.
    func loadBaselineRanges(userId: String) async {
        guard let token = supabase?.session?.accessToken else { return }

        let cols = [
            "hrv_avg", "p20_hrv_7d", "p80_hrv_7d",
            "resting_hr_avg", "p20_resting_hr", "p80_resting_hr",
            "sleep_duration_avg", "p20_sleep_duration", "p80_sleep_duration",
            "sleep_continuity_avg", "p20_sleep_continuity", "p80_sleep_continuity",
            "steps_avg", "p20_steps_weekday", "p80_steps_weekday",
            "active_minutes_avg", "p20_active_minutes_weekday", "p80_active_minutes_weekday",
            "range_trust_state", "range_valid_days"
        ].joined(separator: ",")

        // range_valid_days=gt.0 skips establishing rows (nulls) and gets the most
        // recent row that actually has computed range data.
        let params = "select=\(cols)&user_id=eq.\(userId)&range_valid_days=gt.0&order=computed_on.desc&limit=1"
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/baselines?\(params)") else { return }

        var request = URLRequest(url: url)
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)",      forHTTPHeaderField: "Authorization")
        request.setValue("application/json",     forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row  = rows.first else { return }

            let trust   = (row["range_trust_state"] as? String) ?? "establishing"
            let samples = (row["range_valid_days"]  as? Int)    ?? 0

            func dbl(_ k: String) -> Double? {
                if let v = row[k] as? Double { return v }
                if let v = row[k] as? Int    { return Double(v) }
                if let v = row[k] as? String { return Double(v) }
                return nil
            }

            var result: [String: BaselineRange] = [:]

            // HRV
            if let avg = dbl("hrv_avg"), let p20 = dbl("p20_hrv_7d"), let p80 = dbl("p80_hrv_7d") {
                result["hrv"] = BaselineRange(p20: p20, p80: p80, mean: avg,
                                              trustState: trust, sampleCount: samples)
            }
            // Resting HR
            if let avg = dbl("resting_hr_avg"), let p20 = dbl("p20_resting_hr"), let p80 = dbl("p80_resting_hr") {
                result["resting_hr"] = BaselineRange(p20: p20, p80: p80, mean: avg,
                                                     trustState: trust, sampleCount: samples)
            }
            // Sleep Duration
            if let avg = dbl("sleep_duration_avg"), let p20 = dbl("p20_sleep_duration"), let p80 = dbl("p80_sleep_duration") {
                result["sleep_duration"] = BaselineRange(p20: p20, p80: p80, mean: avg,
                                                         trustState: trust, sampleCount: samples)
            }
            // Sleep Continuity
            if let avg = dbl("sleep_continuity_avg"), let p20 = dbl("p20_sleep_continuity"), let p80 = dbl("p80_sleep_continuity") {
                result["sleep_continuity"] = BaselineRange(p20: p20, p80: p80, mean: avg,
                                                           trustState: trust, sampleCount: samples)
            }
            // Steps (weekday band — most representative for 7D and 8W charts)
            if let avg = dbl("steps_avg"), let p20 = dbl("p20_steps_weekday"), let p80 = dbl("p80_steps_weekday") {
                result["steps"] = BaselineRange(p20: p20, p80: p80, mean: avg,
                                                trustState: trust, sampleCount: samples)
            }
            // Active Minutes (weekday band)
            if let avg = dbl("active_minutes_avg"), let p20 = dbl("p20_active_minutes_weekday"), let p80 = dbl("p80_active_minutes_weekday") {
                result["active_minutes"] = BaselineRange(p20: p20, p80: p80, mean: avg,
                                                         trustState: trust, sampleCount: samples)
            }

            baselineRanges = result
            print("[TrendViewModel] baseline ranges loaded — keys: \(result.keys.sorted()), trust: \(trust), validDays: \(samples)")
        } catch {
            print("[TrendViewModel] baseline range fetch failed: \(error)")
        }
    }

    // Stat line kept for internal use; Direction Signal Chip replaces its UI role
    var statLine: String {
        let scores: [Double]
        switch selectedWindow {
        case .sevenDay:
            scores = dailyScoresCache.compactMap { $0["chronos_score"] as? Double }
        case .eightWeek:
            scores = (aggregateCache["weekly"] ?? []).compactMap { $0.chronosAvg }
        case .twelveMonth:
            scores = (aggregateCache["monthly"] ?? []).compactMap { $0.chronosAvg }
        }
        guard !scores.isEmpty else { return "" }
        let avg = scores.reduce(0, +) / Double(scores.count)
        let trend = (scores.last ?? 0) - (scores.first ?? 0)
        let direction = trend > 5 ? "improving" : trend < -5 ? "declining" : "stable"
        let windowLabel: String
        switch selectedWindow {
        case .sevenDay:    windowLabel = "7-day"
        case .eightWeek:   windowLabel = "8-week"
        case .twelveMonth: windowLabel = "12-month"
        }
        return "\(windowLabel) average \(Int(avg)) · \(direction)"
    }
}

// ─────────────────────────────────────────
// TREND CHART POINT
// Unified point model for TrendLineChart across all windows and metrics.
// Section 10: isGap = true when the day had no wearable data (steps_only tier).
// Gap points carry forward the last valid score value for visual continuity.
// Rendered as grey dots. A "Data gap · N days" label appears below the chart.
// ─────────────────────────────────────────
struct TrendChartPoint: Identifiable {
    let id = UUID()
    let date: String
    let value: Double
    let metricKey: String
    var isGap: Bool = false       // Section 10: true when data_tier == 'steps_only'
    var gapReason: String? = nil  // Section 10: "device_not_worn" | "sync_failure" | nil
}

// ─────────────────────────────────────────
// BASELINE RANGE — p20/p80 personal band
// Fetched from baselines table by TrendViewModel.
// ─────────────────────────────────────────

struct BaselineRange {
    let p20: Double
    let p80: Double
    let mean: Double
    let trustState: String
    let sampleCount: Int
}

enum RangeStatus: Equatable {
    case aboveRange   // value > p80
    case withinRange  // p20 … p80
    case belowRange   // value < p20
    case noBaseline
}

func baselineBandOpacity(for baseline: BaselineRange?) -> Double {
    guard let b = baseline else { return 0 }
    switch b.trustState {
    case "establishing": return 0
    case "calibrating":  return 0.08
    case "provisional":  return 0.12
    default:             return 0.15
    }
}

func pointRangeStatus(value: Double, baseline: BaselineRange?) -> RangeStatus {
    guard let b = baseline else { return .noBaseline }
    if value > b.p80 { return .aboveRange }
    if value < b.p20 { return .belowRange }
    return .withinRange
}

func rangePointColor(status: RangeStatus, fallback: Color) -> Color {
    switch status {
    case .aboveRange:  return Color(red: 0.298, green: 0.686, blue: 0.490)
    case .belowRange:  return Color(red: 0.910, green: 0.659, blue: 0.220)
    case .withinRange: return ChronosTheme.gold
    case .noBaseline:  return fallback
    }
}

func rangeStatusLabel(_ status: RangeStatus) -> String? {
    switch status {
    case .aboveRange:  return "Above your range"
    case .withinRange: return "Within your range"
    case .belowRange:  return "Below your range"
    case .noBaseline:  return nil
    }
}

// ─────────────────────────────────────────
// TREND VIEW
// ─────────────────────────────────────────

struct TrendView: View {
    @EnvironmentObject var sync: SyncCoordinator
    @EnvironmentObject var supabase: SupabaseService
    @StateObject private var vm = TrendViewModel()

    // Phase 2: Grid/Banner layout toggle — persisted in UserDefaults
    @AppStorage("trend_metric_layout_is_grid") private var useGrid: Bool = true

    // Phase 2: Metric detail sheet
    @State private var selectedDetailTile: MetricTileData? = nil

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [ChronosTheme.gold.opacity(0.04), .clear],
                center: .top, startRadius: 0, endRadius: 320
            )
            .ignoresSafeArea()

            if let _ = sync.dashboard {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {

                        // ── Header ───────────────────────────────
                        TrendHeaderView(
                            window: vm.selectedWindow,
                            trendDirection: vm.trendDirection,
                            isBuilding: vm.isBuilding,
                            twelveMonthPattern: vm.twelveMonthPattern
                        )

                        // ── Window toggle ────────────────────────
                        WindowToggle(selectedWindow: $vm.selectedWindow) { newWindow in
                            guard let userId = supabase.session?.userId else { return }
                            Task { await vm.switchWindow(to: newWindow, userId: userId) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)

                        // ── Chart + Metric Banner (Section 3) ────
                        ChartMetricCard(
                            points: vm.chartPoints,
                            window: vm.selectedWindow,
                            selectedMetricKey: vm.selectedMetricKey,
                            scoreBand: sync.dashboard?.score.scoreBand ?? .recovering,
                            isBuilding: vm.isBuilding,
                            buildingLabel: vm.buildingLabel,
                            tiles: vm.metricTiles,
                            stalenessDate: vm.stalenessDate,
                            dynamicDateLabel: vm.dynamicDateLabel,
                            baselineRanges: vm.baselineRanges,
                            onSelectMetric: { key in vm.selectMetric(key) },
                            onDetailMetric: { tile in selectedDetailTile = tile }
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                        // ── Direction signal chip (Section 4) ────
                        if !vm.isBuilding && vm.windowChronosAvg > 0 {
                            DirectionSignalView(
                                trendDirection: vm.trendDirection,
                                windowAvg: vm.windowChronosAvg,
                                windowDateLabel: vm.signalDateLabel,
                                window: vm.selectedWindow
                            )
                            .padding(.bottom, 4)
                        }

                        // ── Narrative block ──────────────────────
                        if vm.isLoadingNarrative {
                            NarrativeLoadingCard()
                                .padding(.horizontal, 20).padding(.bottom, 16)
                        } else {
                            TrendNarrativeCard(
                                window: vm.selectedWindow,
                                narrativeText: vm.narrativeText,
                                dynamicDateLabel: vm.dynamicDateLabel
                            )
                            .id(vm.selectedWindow)   // force @State reset on window switch
                            .padding(.horizontal, 20).padding(.bottom, 16)
                        }

                        // ── Metric detail grid (Section 7) ───────
                        if !vm.metricTiles.isEmpty {
                            HStack {
                                Text("METRICS")
                                    .font(.jost(size: 9, weight: .light))
                                    .foregroundColor(ChronosTheme.gold.opacity(0.70))
                                    .tracking(3)
                                Spacer()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { useGrid.toggle() }
                                } label: {
                                    Image(systemName: useGrid ? "rectangle.grid.1x2" : "square.grid.2x2")
                                        .font(.system(size: 13, weight: .light))
                                        .foregroundColor(ChronosTheme.gold.opacity(0.65))
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)

                            if useGrid {
                                MetricSelectorGrid(
                                    tiles: vm.metricTiles,
                                    selectedKey: vm.selectedMetricKey,
                                    onSelect: { key in vm.selectMetric(key) },
                                    onDetail: { tile in selectedDetailTile = tile }
                                )
                                .padding(.horizontal, 20)
                                .padding(.bottom, 20)
                            } else {
                                MetricSelectorBanner(
                                    tiles: vm.metricTiles,
                                    selectedKey: vm.selectedMetricKey,
                                    onSelect: { key in vm.selectMetric(key) },
                                    onDetail: { tile in selectedDetailTile = tile }
                                )
                                .padding(.bottom, 20)
                            }
                        }

                        // ── Signal callouts ──────────────────────
                        let hasCallouts = !vm.workingCallouts.isEmpty || !vm.watchCallouts.isEmpty
                        if hasCallouts {
                            SignalCallouts(
                                working: vm.workingCallouts,
                                watching: vm.watchCallouts
                            )
                            .padding(.horizontal, 20)
                            .padding(.bottom, 40)
                        }

                        // Placeholder only if fewer than 7 days of history
                        if !hasCallouts && (sync.dashboard?.recentScores.count ?? 0) < 7 {
                            TrendSignalPlaceholder()
                                .padding(.horizontal, 20).padding(.bottom, 40)
                        }
                    }
                }
            } else {
                TrendEmptyView().padding(.top, 60)
            }
        }
        .task {
            guard let userId = supabase.session?.userId else { return }
            vm.attach(supabase: supabase)
            await vm.initialLoad(userId: userId)
        }
        // Phase 2: Metric detail sheet
        .sheet(item: $selectedDetailTile) { tile in
            MetricDetailView(tile: tile)
                .environmentObject(supabase)
        }
    }
}

// ─────────────────────────────────────────
// HEADER — window adaptive
// ─────────────────────────────────────────

struct TrendHeaderView: View {
    let window: TrendWindow
    let trendDirection: String
    let isBuilding: Bool
    let twelveMonthPattern: String

    private var directionSubtitle: String {
        if isBuilding {
            switch window {
            case .sevenDay:    return "Building your baseline. Check back soon."
            case .eightWeek:   return "Your arc is forming. More weeks ahead."
            case .twelveMonth: return "History is building. Check back as more months complete."
            }
        }
        switch window {
        case .sevenDay:
            switch trendDirection {
            case "improving": return "Momentum is building."
            case "declining": return "Worth a closer look."
            default:          return "One story."
            }
        case .eightWeek:
            switch trendDirection {
            case "improving": return "Momentum is compounding."
            case "declining": return "Something is drawing on reserves."
            default:          return "One arc."
            }
        case .twelveMonth:
            switch twelveMonthPattern {
            case "improving":    return "The arc is rising."
            case "declining":    return "A gradual shift worth understanding."
            case "seasonal":     return "A pattern is emerging."
            case "volatile":     return "High variation — signal and noise."
            case "insufficient": return "History is building. Check back as more months complete."
            default:             return "One trajectory."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window.headerEyebrow)
                .font(.jost(size: 10, weight: .light))
                .foregroundColor(ChronosTheme.gold)
                .tracking(3)

            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(window.headerTitle)
                    .font(.cormorant(size: 32, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                Text(" ")
                Text(directionSubtitle)
                    .font(.cormorantItalic(size: 16))
                    .foregroundColor(ChronosTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .animation(.easeInOut(duration: 0.2), value: window)
        .animation(.easeInOut(duration: 0.2), value: trendDirection)
    }
}

// ─────────────────────────────────────────
// WINDOW TOGGLE — 3-segment pill
// ─────────────────────────────────────────

struct WindowToggle: View {
    @Binding var selectedWindow: TrendWindow
    var onSelect: (TrendWindow) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TrendWindow.allCases, id: \.self) { window in
                Button {
                    guard window != selectedWindow else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedWindow = window
                    }
                    onSelect(window)
                } label: {
                    Text(window.rawValue)
                        .font(.jost(size: 12, weight: selectedWindow == window ? .medium : .light))
                        .foregroundColor(selectedWindow == window ? ChronosTheme.ink : ChronosTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedWindow == window ? ChronosTheme.gold : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1))
        )
    }
}

// ─────────────────────────────────────────
// TREND LINE CHART
// Replaces ScoreRibbon bar chart across all three windows.
// ─────────────────────────────────────────

struct TrendLineChart: View {
    let points: [TrendChartPoint]
    let window: TrendWindow
    let selectedMetricKey: String
    let scoreBand: ScoreBand
    let isBuilding: Bool
    let buildingLabel: String
    var stalenessDate: String? = nil
    var dynamicDateLabel: String? = nil  // overrides window.dateLabel when set
    var baseline: BaselineRange? = nil   // Part 2–7: p20/p80 range band

    @State private var selectedPointIdx: Int? = nil  // Part 4: tap tooltip

    private var unitLabel: String {
        switch selectedMetricKey {
        case "chronos":          return "pts"
        case "hrv":              return "ms"
        case "resting_hr":       return "bpm"
        case "respiratory_rate": return "br/min"
        case "sleep_duration":   return "hrs"
        case "sleep_continuity": return "%"
        case "steps":            return "k"
        case "active_minutes":   return "min"
        default:                 return ""
        }
    }

    private var lineColor: Color {
        switch scoreBand {
        case .thriving:   return Color(red: 0.35, green: 0.80, blue: 0.45)
        case .recovering: return ChronosTheme.gold
        case .yellowline: return Color(red: 0.95, green: 0.80, blue: 0.30)
        case .drifting:   return Color(red: 0.90, green: 0.55, blue: 0.30)
        case .redline:    return Color(red: 0.85, green: 0.30, blue: 0.30)
        }
    }

    private var windowAvg: Double {
        guard !points.isEmpty else { return 0 }
        return points.map { $0.value }.reduce(0, +) / Double(points.count)
    }

    // Y-scale includes baseline p20/p80 endpoints (when the band is visible) so the
    // band never clips to the chart floor or ceiling.
    // Excluding them caused the bottom edge of the HRV band to be cut off because
    // p20 (26.6ms) was below the data-only lower bound (28.6ms).
    private var yRange: ClosedRange<Double> {
        guard !points.isEmpty else { return 0...100 }
        var vals = points.map { $0.value }
        if let b = baseline, bandOpacity > 0 {
            vals.append(b.p20)
            vals.append(b.p80)
        }
        let minV = (vals.min() ?? 0) - 5
        let maxV = (vals.max() ?? 100) + 5
        return max(0, minV)...max(minV + 10, maxV)
    }

    // Pre-computed to avoid inline complexity
    private var bandOpacity: Double { baselineBandOpacity(for: baseline) }
    // When the band is visible, use the band midpoint for the dashed rule.
    // baseline.mean (hrv_avg) is the mean of raw daily readings; p20/p80 are
    // percentiles of the 7-day rolling average — a different, smoother distribution.
    // For HRV this causes mean (48ms) > p80 (40ms), rendering the rule above the band.
    // The midpoint is semantically correct and always falls inside the band.
    private var ruleY: Double {
        if let b = baseline, bandOpacity > 0 {
            return (b.p20 + b.p80) / 2
        }
        return windowAvg
    }
    private var hi: Double? { points.map { $0.value }.max() }
    private var lo: Double? { points.map { $0.value }.min() }

    // Section 10: Count consecutive gap runs for the cluster label
    private var gapClusterLabel: String? {
        let gapCount = points.filter { $0.isGap }.count
        guard gapCount > 0 else { return nil }
        return "Data gap · \(gapCount) \(gapCount == 1 ? "day" : "days") without wearable data"
    }

    var body: some View {
        VStack(spacing: 12) {
            labelRow
            if !points.isEmpty { statsRow }
            chartRegion
            // Section 10: Gap cluster label — shown below chart when any gap days exist
            if let gapLabel = gapClusterLabel {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 6, height: 6)
                    Text(gapLabel)
                        .font(.jost(size: 10, weight: .light))
                        .foregroundColor(Color.white.opacity(0.35))
                        .italic()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            insightChip
            if isBuilding {
                Text(buildingLabel)
                    .font(.jost(size: 10, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(20)
        .animation(.easeInOut(duration: 0.25), value: points.map { $0.id })
        .onChange(of: selectedMetricKey) { selectedPointIdx = nil }
        .onChange(of: window)            { selectedPointIdx = nil }
    }

    // ── Sub-views ────────────────────────────────────────────────────

    private var labelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dynamicDateLabel ?? window.dateLabel)
                .font(.jost(size: 9, weight: .light))
                .foregroundColor(ChronosTheme.muted)
                .tracking(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let stale = stalenessDate {
                Text("Last updated \(stale)")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
                    .tracking(1)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            if let h = hi {
                VStack(spacing: 2) {
                    Text("HIGH").font(.jost(size: 7, weight: .light)).foregroundColor(ChronosTheme.faint).tracking(1.5)
                    Text("\(Int(h))").font(.jost(size: 14, weight: .medium)).foregroundColor(lineColor)
                }
            }
            Spacer()
            VStack(spacing: 2) {
                Text("AVG").font(.jost(size: 7, weight: .light)).foregroundColor(ChronosTheme.faint).tracking(1.5)
                Text("\(Int(windowAvg))").font(.jost(size: 14, weight: .medium)).foregroundColor(ChronosTheme.muted)
            }
            Spacer()
            if let l = lo {
                VStack(spacing: 2) {
                    Text("LOW").font(.jost(size: 7, weight: .light)).foregroundColor(ChronosTheme.faint).tracking(1.5)
                    Text("\(Int(l))").font(.jost(size: 14, weight: .medium)).foregroundColor(ChronosTheme.faint)
                }
            }
        }
    }

    @ViewBuilder
    private var chartRegion: some View {
        if points.isEmpty && !isBuilding {
            Spacer().frame(height: 100)
        } else {
            chartZStack
        }
    }

    private var chartZStack: some View {
        ZStack(alignment: .topLeading) {
            lineChart
            tooltipOverlay
            if !unitLabel.isEmpty {
                Text(unitLabel)
                    .font(.jost(size: 8, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .padding(.leading, 4)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var lineChart: some View {
        Chart {
            // Part 2: p20–p80 range band (bottom layer)
            if let b = baseline, points.count >= 2, bandOpacity > 0 {
                // x-span slightly beyond first/last point so band fills edge-to-edge
                RectangleMark(
                    xStart: .value("Start", 0),
                    xEnd:   .value("End",   points.count - 1),
                    yStart: .value("P20",   b.p20),
                    yEnd:   .value("P80",   b.p80)
                )
                .foregroundStyle(ChronosTheme.gold.opacity(bandOpacity))
            }
            // Dashed rule — baseline mean when available, else window avg
            if ruleY > 0 {
                RuleMark(y: .value("Average", ruleY))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(0.20))
            }
            // Section 10: Data line — only connect non-gap points
            // Gap points use a dashed line segment to visually signal data absence.
            ForEach(Array(points.enumerated()), id: \.offset) { i, point in
                LineMark(x: .value("Date", i), y: .value("Score", point.value))
                    .foregroundStyle(point.isGap ? Color.white.opacity(0.15) : lineColor)
                    .lineStyle(point.isGap
                               ? StrokeStyle(lineWidth: 1, dash: [3, 4])
                               : StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                // Section 10: gap points → grey dot; valid points → color-coded dot
                PointMark(x: .value("Date", i), y: .value("Score", point.value))
                    .foregroundStyle(point.isGap
                                     ? Color.white.opacity(0.25)
                                     : rangePointColor(
                                         status: pointRangeStatus(value: point.value, baseline: baseline),
                                         fallback: lineColor))
                    .symbolSize(point.isGap ? 18
                                : (i == selectedPointIdx ? 80
                                   : (i == points.count - 1 ? 60 : 30)))
            }
        }
        .chartYScale(domain: yRange)
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisValueLabel {
                    if let idx = value.as(Int.self), idx >= 0, idx < points.count {
                        Text(xAxisLabel(for: idx, total: points.count))
                            .font(.jost(size: 8, weight: idx == points.count - 1 ? .medium : .light))
                            .foregroundStyle(idx == points.count - 1 ? ChronosTheme.gold : ChronosTheme.muted)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 100)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                let plotOriginX: CGFloat = proxy.plotFrame.map { geo[$0].origin.x } ?? 0
                                let xInPlot = val.location.x - plotOriginX
                                if let rawIdx: Int = proxy.value(atX: xInPlot) {
                                    withAnimation(.interactiveSpring()) {
                                        selectedPointIdx = max(0, min(rawIdx, points.count - 1))
                                    }
                                }
                            }
                            .onEnded { _ in
                                withAnimation(.easeOut(duration: 0.3)) { selectedPointIdx = nil }
                            }
                    )
            }
        }
    }

    @ViewBuilder
    private var tooltipOverlay: some View {
        if let idx = selectedPointIdx, idx < points.count {
            let pt = points[idx]
            PointTooltipView(
                date: pt.date,
                value: pt.value,
                metricKey: selectedMetricKey,
                status: pointRangeStatus(value: pt.value, baseline: baseline),
                baseline: baseline,
                window: window
            )
            .frame(maxWidth: .infinity,
                   alignment: idx < points.count / 2 ? .trailing : .leading)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
        }
    }

    @ViewBuilder
    private var insightChip: some View {
        if let b = baseline, bandOpacity > 0, !points.isEmpty, !isBuilding {
            RangeSummaryInsightView(
                points: points,
                baseline: b,
                metricKey: selectedMetricKey,
                window: window
            )
        }
    }

    private func xAxisLabel(for index: Int, total: Int) -> String {
        guard index >= 0, index < points.count else { return "" }
        let dateString = points[index].date
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return "" }

        switch window {
        case .sevenDay:
            formatter.dateFormat = "E"
            return String(formatter.string(from: date).prefix(1)).uppercased()
        case .eightWeek:
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        case .twelveMonth:
            formatter.dateFormat = "MMM"
            return formatter.string(from: date)
        }
    }
}

// ─────────────────────────────────────────
// POINT TOOLTIP VIEW — tap-to-inspect overlay
// Part 4: shown on drag over chart; dismisses on release.
// ─────────────────────────────────────────

struct PointTooltipView: View {
    let date: String
    let value: Double
    let metricKey: String
    let status: RangeStatus
    let baseline: BaselineRange?
    let window: TrendWindow

    private var formattedDate: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let d = parser.date(from: date) else { return date }
        let display = DateFormatter()
        switch window {
        case .sevenDay:    display.dateFormat = "EEEE"       // "Monday"
        case .eightWeek:   display.dateFormat = "MMM d"      // "Jan 14"
        case .twelveMonth: display.dateFormat = "MMMM yyyy"  // "January 2025"
        }
        return display.string(from: d)
    }

    private var formattedValue: String {
        switch metricKey {
        case "chronos":          return "\(Int(value)) pts"
        case "hrv":              return "\(Int(value)) ms"
        case "resting_hr":       return "\(Int(value)) bpm"
        case "respiratory_rate": return String(format: "%.1f br/min", value)
        case "sleep_duration":   return String(format: "%.1f hrs", value)
        case "sleep_continuity": return "\(Int(value))%"
        case "steps":            return value >= 1000 ? String(format: "%.1fk", value / 1000) : "\(Int(value))"
        case "active_minutes":   return "\(Int(value)) min"
        default:                 return "\(Int(value))"
        }
    }

    private var deltaFromMean: String? {
        guard let b = baseline else { return nil }
        let delta = value - b.mean
        let sign = delta >= 0 ? "+" : ""
        switch metricKey {
        case "chronos":          return "\(sign)\(Int(delta)) pts vs mean"
        case "hrv":              return "\(sign)\(Int(delta)) ms vs mean"
        case "resting_hr":       return "\(sign)\(Int(delta)) bpm vs mean"
        case "respiratory_rate": return String(format: "\(sign)%.1f br/min vs mean", delta)
        case "sleep_duration":   return String(format: "\(sign)%.1f hrs vs mean", delta)
        case "sleep_continuity": return "\(sign)\(Int(delta))% vs mean"
        case "steps":            return "\(sign)\(Int(delta)) vs mean"
        case "active_minutes":   return "\(sign)\(Int(delta)) min vs mean"
        default:                 return "\(sign)\(Int(delta)) vs mean"
        }
    }

    private var valueColor: Color {
        rangePointColor(status: status, fallback: ChronosTheme.gold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formattedDate)
                .font(.jost(size: 10, weight: .medium))
                .foregroundColor(ChronosTheme.text)
                .tracking(0.5)

            Text(formattedValue)
                .font(.jost(size: 16, weight: .medium))
                .foregroundColor(valueColor)

            if let label = rangeStatusLabel(status) {
                Text(label)
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(valueColor.opacity(0.75))
                    .tracking(0.3)
            }

            if let delta = deltaFromMean {
                Text(delta)
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
                    .tracking(0.3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.145, green: 0.145, blue: 0.208))  // #252535
                .shadow(color: .black.opacity(0.40), radius: 8, x: 0, y: 4)
        )
        .fixedSize()
    }
}

// ─────────────────────────────────────────
// RANGE SUMMARY INSIGHT VIEW — chip below chart
// Part 5: classifies how this window's points sit against the baseline band.
// ─────────────────────────────────────────

struct RangeSummaryInsightView: View {
    let points: [TrendChartPoint]
    let baseline: BaselineRange
    let metricKey: String
    let window: TrendWindow

    private var insight: String? {
        guard !points.isEmpty else { return nil }
        let statuses = points.map { pointRangeStatus(value: $0.value, baseline: baseline) }
        let total       = statuses.count
        let withinCount = statuses.filter { $0 == .withinRange }.count
        let aboveCount  = statuses.filter { $0 == .aboveRange  }.count
        let belowCount  = statuses.filter { $0 == .belowRange  }.count
        let withinPct = Double(withinCount) / Double(total)
        let abovePct  = Double(aboveCount)  / Double(total)
        let belowPct  = Double(belowCount)  / Double(total)

        let unit: String
        switch window {
        case .sevenDay:    unit = total == 1 ? "day"   : "days"
        case .eightWeek:   unit = total == 1 ? "week"  : "weeks"
        case .twelveMonth: unit = total == 1 ? "month" : "months"
        }

        if withinPct >= 0.70 {
            return "\(withinCount) of \(total) \(unit) within your personal range — consistent performance."
        } else if abovePct >= 0.50 {
            return "\(aboveCount) of \(total) \(unit) above your baseline range — a strong period."
        } else if belowPct >= 0.50 {
            return "\(belowCount) of \(total) \(unit) below your baseline range — worth attention."
        } else if abovePct > belowPct {
            return "More \(unit) above range than below — trending up against your baseline."
        } else if belowPct > abovePct {
            return "More \(unit) below range than above — a softer period against your baseline."
        } else {
            return "\(withinCount) of \(total) \(unit) within your personal range."
        }
    }

    var body: some View {
        if let text = insight {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.65))
                    .padding(.top, 1)
                Text(text)
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(ChronosTheme.gold.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(ChronosTheme.gold.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }
}

// ─────────────────────────────────────────
// CHART METRIC CARD — chart + metric banner in one boundary
// Section 3: no scroll needed to see chart and switch metrics simultaneously.
// ─────────────────────────────────────────

struct ChartMetricCard: View {
    let points: [TrendChartPoint]
    let window: TrendWindow
    let selectedMetricKey: String
    let scoreBand: ScoreBand
    let isBuilding: Bool
    let buildingLabel: String
    let tiles: [MetricTileData]
    let stalenessDate: String?
    let dynamicDateLabel: String
    let baselineRanges: [String: BaselineRange]   // Part 6: range band data
    var onSelectMetric: (String) -> Void
    var onDetailMetric: (MetricTileData) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.09, green: 0.09, blue: 0.16),
                        Color(red: 0.06, green: 0.06, blue: 0.10)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(ChronosTheme.border, lineWidth: 1))

            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, ChronosTheme.gold, .clear],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 1)
                    .clipShape(.rect(topLeadingRadius: 20, topTrailingRadius: 20))
                Spacer()
            }

            VStack(spacing: 0) {
                TrendLineChart(
                    points: points,
                    window: window,
                    selectedMetricKey: selectedMetricKey,
                    scoreBand: scoreBand,
                    isBuilding: isBuilding,
                    buildingLabel: buildingLabel,
                    stalenessDate: stalenessDate,
                    dynamicDateLabel: dynamicDateLabel,
                    baseline: baselineRanges[selectedMetricKey]  // Part 6: pass per-metric baseline
                )
                .background(Color.clear)

                Rectangle()
                    .fill(Color(red: 0.227, green: 0.227, blue: 0.306))
                    .frame(height: 1)

                if !tiles.isEmpty {
                    MetricSelectorBanner(
                        tiles: tiles,
                        selectedKey: selectedMetricKey,
                        onSelect: onSelectMetric,
                        onDetail: onDetailMetric
                    )
                    .padding(.vertical, 10)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: points.map { $0.id })
    }
}

// ─────────────────────────────────────────
// DIRECTION SIGNAL VIEW — chip between chart and narrative
// Section 4: first thing read after the chart.
// ─────────────────────────────────────────

struct DirectionSignalView: View {
    let trendDirection: String
    let windowAvg: Int
    let windowDateLabel: String
    let window: TrendWindow

    private var directionLabel: String {
        switch trendDirection {
        case "improving": return "IMPROVING"
        case "declining": return "DECLINING"
        default:          return "HOLDING"
        }
    }

    private var dotColor: Color {
        switch trendDirection {
        case "improving": return Color(red: 0.298, green: 0.686, blue: 0.490)
        case "declining": return Color(red: 0.910, green: 0.659, blue: 0.220)
        default:          return ChronosTheme.gold
        }
    }

    private var windowLabel: String {
        switch window {
        case .sevenDay:    return "7-day"
        case .eightWeek:   return "8-week"
        case .twelveMonth: return "12-month"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(directionLabel)
                .font(.jost(size: 13, weight: .medium))
                .foregroundColor(dotColor)
            Text("·")
                .font(.jost(size: 13, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
            Text("\(windowLabel) avg \(windowAvg)")
                .font(.jost(size: 13, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
            Text("·")
                .font(.jost(size: 13, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
            Text(windowDateLabel)
                .font(.jost(size: 13, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: trendDirection)
    }
}

// ─────────────────────────────────────────
// TREND NARRATIVE CARD — window synthesis
// Replaces WeeklyNarrativeCard (which showed today's explanation).
// ─────────────────────────────────────────

struct TrendNarrativeCard: View {
    let window: TrendWindow
    let narrativeText: String
    let dynamicDateLabel: String

    @State private var isExpanded: Bool = false

    private var fallbackText: String {
        switch window {
        case .sevenDay:    return "Your week's pattern is being read — check back shortly."
        case .eightWeek:   return "Your eight-week arc is being read — check back shortly."
        case .twelveMonth: return "Your year's trajectory is being read — check back shortly."
        }
    }

    private var displayText: String {
        narrativeText.isEmpty ? fallbackText : narrativeText
    }

    private var isActualNarrative: Bool { !narrativeText.isEmpty }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.08, blue: 0.14),
                        Color(red: 0.06, green: 0.06, blue: 0.10)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(ChronosTheme.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 14) {
                Text(dynamicDateLabel)
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                    .tracking(3)
                    .textCase(.uppercase)

                Rectangle().fill(ChronosTheme.gold.opacity(0.2)).frame(height: 1)

                // Collapsed or expanded narrative
                ZStack(alignment: .bottom) {
                    Text(displayText)
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .lineSpacing(7)
                        .lineLimit(isExpanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isExpanded && isActualNarrative {
                        LinearGradient(
                            colors: [.clear, Color(red: 0.08, green: 0.08, blue: 0.14)],
                            startPoint: .init(x: 0.5, y: 0.2),
                            endPoint: .bottom
                        )
                        .frame(height: 28)
                        .allowsHitTesting(false)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)

                if isActualNarrative {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "Show less ↑" : "Read more →")
                            .font(.jost(size: 13, weight: .regular))
                            .foregroundColor(ChronosTheme.gold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .animation(.easeInOut(duration: 0.2), value: window)
        .onChange(of: window) { isExpanded = false }
    }
}

// Loading state for narrative while Claude API call is in-flight
struct NarrativeLoadingCard: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(ChronosTheme.border, lineWidth: 1))

            Text("Reading the pattern...")
                .font(.jost(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.muted.opacity(opacity))
                .italic()
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        opacity = 1.0
                    }
                }
        }
        .frame(height: 72)
    }
}

// ─────────────────────────────────────────
// METRIC SELECTOR BANNER
// Horizontally scrolling tile row.
// Chronos always first. Data-driven — no hardcoded list.
// Narrative does NOT update when a metric tile is selected.
// ─────────────────────────────────────────

// ─────────────────────────────────────────
// METRIC SELECTOR — GRID LAYOUT (default)
// ─────────────────────────────────────────

struct MetricSelectorGrid: View {
    let tiles: [MetricTileData]
    let selectedKey: String
    var onSelect: (String) -> Void
    var onDetail: (MetricTileData) -> Void

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(tiles) { tile in
                MetricTileView(
                    tile: tile,
                    isSelected: selectedKey == tile.id,
                    onTap:   { onSelect(tile.id) },
                    onDetail: { onDetail(tile) }
                )
            }
        }
    }
}

// ─────────────────────────────────────────
// METRIC SELECTOR — BANNER LAYOUT (Phase 2 toggle)
// Horizontal scroll of compact metric chips.
// ─────────────────────────────────────────

struct MetricSelectorBanner: View {
    let tiles: [MetricTileData]
    let selectedKey: String
    var onSelect: (String) -> Void
    var onDetail: (MetricTileData) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tiles) { tile in
                    let isSel = selectedKey == tile.id
                    Button { onSelect(tile.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tile.shortName)
                                .font(.jost(size: 10, weight: .medium))
                                .foregroundColor(isSel ? ChronosTheme.gold : ChronosTheme.text)
                            if let v = tile.todayValue {
                                Text(formattedValue(v, unit: tile.unit))
                                    .font(.jost(size: 13, weight: .regular))
                                    .foregroundColor(ChronosTheme.text)
                            } else {
                                Text("—")
                                    .font(.jost(size: 13, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(ChronosTheme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isSel ? ChronosTheme.gold : ChronosTheme.border,
                                                lineWidth: isSel ? 1.5 : 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in onDetail(tile) }
                    )
                    .animation(.easeInOut(duration: 0.15), value: isSel)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func formattedValue(_ v: Double, unit: String) -> String {
        switch unit {
        case "ms":  return "\(Int(v))ms"
        case "bpm": return "\(Int(v)) bpm"
        case "hrs": return String(format: "%.1fh", v)
        case "%":   return "\(Int(v))%"
        case "min": return "\(Int(v))m"
        default:    return v >= 1000 ? "\(Int(v / 1000))k" : "\(Int(v))"
        }
    }
}

// ─────────────────────────────────────────
// METRIC TILE VIEW
// Used by MetricSelectorGrid. Tap = select; long-press = detail.
// ─────────────────────────────────────────

struct MetricTileView: View {
    let tile: MetricTileData
    let isSelected: Bool
    var onTap: () -> Void
    var onDetail: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tile.shortName)
                    .font(.jost(size: 11, weight: .medium))
                    .foregroundColor(ChronosTheme.text)

                HStack(spacing: 0) {
                    tileColumn(label: "Today", value: tile.todayValue, unit: tile.unit)
                    Spacer()
                    tileColumn(label: "7D",    value: tile.sevenDayAvg,   unit: tile.unit)
                    Spacer()
                    tileColumn(label: "30D",   value: tile.thirtyDayAvg,  unit: tile.unit)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(ChronosTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                isSelected ? ChronosTheme.gold : ChronosTheme.border,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.gold.opacity(0.06))
                    : nil
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onDetail() }
        )
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private func tileColumn(label: String, value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.jost(size: 8, weight: .light))
                .foregroundColor(ChronosTheme.muted)
                .tracking(1)
            if let v = value {
                HStack(spacing: 3) {
                    Text(formattedValue(v, unit: unit))
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(ChronosTheme.text)
                    if label == "7D" {
                        directionArrow(for: tile, avg7D: v)
                    }
                }
            } else {
                Text("—")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
            }
        }
    }

    @ViewBuilder
    private func directionArrow(for tile: MetricTileData, avg7D: Double) -> some View {
        let excluded = Set(["sleep_continuity", "respiratory_rate", "chronos"])
        if !excluded.contains(tile.id), let avg30D = tile.thirtyDayAvg, avg30D > 0 {
            let pct = (avg7D - avg30D) / avg30D * 100
            let higherIsBad = tile.id == "resting_hr"
            if pct > 3 {
                Image(systemName: "arrow.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(!higherIsBad
                        ? Color(red: 0.298, green: 0.686, blue: 0.490)
                        : Color(red: 0.910, green: 0.659, blue: 0.220))
            } else if pct < -3 {
                Image(systemName: "arrow.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(higherIsBad
                        ? Color(red: 0.298, green: 0.686, blue: 0.490)
                        : Color(red: 0.910, green: 0.659, blue: 0.220))
            }
        }
    }

    private func formattedValue(_ v: Double, unit: String) -> String {
        switch unit {
        case "ms":  return "\(Int(v))ms"
        case "bpm": return "\(Int(v))"
        case "rpm": return "\(Int(v))"
        case "hrs": return String(format: "%.1fh", v)
        case "%":   return "\(Int(v))%"
        case "min": return "\(Int(v))m"
        default:    return v >= 1000 ? "\(Int(v / 1000))k" : "\(Int(v))"
        }
    }
}

// ─────────────────────────────────────────
// SIGNAL CALLOUTS — deterministic, two-section
// Computed by TrendViewModel — Claude does not generate these.
// If no callout conditions are met, the section is absent entirely.
// ─────────────────────────────────────────

struct SignalCallouts: View {
    let working: [TrendCallout]
    let watching: [TrendCallout]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !working.isEmpty {
                calloutSection(
                    title: "WORKING FOR YOU",
                    callouts: working,
                    accentColor: Color(red: 0.35, green: 0.80, blue: 0.45)
                )
            }
            if !watching.isEmpty {
                calloutSection(
                    title: "WORTH WATCHING",
                    callouts: watching,
                    accentColor: Color(red: 0.90, green: 0.65, blue: 0.30)
                )
            }
        }
    }

    @ViewBuilder
    private func calloutSection(title: String, callouts: [TrendCallout], accentColor: Color) -> some View {
        if callouts.count >= 2 {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)
                    .clipShape(.rect(topLeadingRadius: 14, bottomLeadingRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(accentColor)
                        .tracking(2.5)

                    ForEach(callouts) { callout in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(accentColor)
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(callout.text)
                                .font(.jost(size: 13, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChronosTheme.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accentColor.opacity(0.18), lineWidth: 1)
            )
        }
    }
}

// ─────────────────────────────────────────
// TREND SIGNAL PLACEHOLDER
// Only shown when user has fewer than 7 days of history.
// Retired after 7 days — never shown as a permanent state.
// ─────────────────────────────────────────

struct TrendSignalPlaceholder: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.faint)
            Text("Signal callouts appear once your baseline has enough data.")
                .font(.jost(size: 12, weight: .light))
                .foregroundColor(ChronosTheme.faint)
                .lineSpacing(4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(ChronosTheme.border, lineWidth: 1))
        )
    }
}

// ─────────────────────────────────────────
// EMPTY STATE — no dashboard data at all
// ─────────────────────────────────────────

struct TrendEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            ChronosLogoMark()
                .frame(width: 52, height: 52)
                .opacity(0.3)

            Text("No trend yet")
                .font(.cormorant(size: 24))
                .foregroundColor(ChronosTheme.muted)

            Text("Your weekly trend will appear after\nyour first few days of data are scored.")
                .font(.jost(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.faint)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.horizontal, 48)
        }
    }
}
