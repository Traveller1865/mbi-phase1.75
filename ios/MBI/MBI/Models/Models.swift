// ios/MBI/MBI/Models/Models.swift
// MBI Phase 1 — Swift Data Models
// Mirrors Supabase schema exactly
// Pre-Beta Sprint (v1.5): DailyScore gains zone1, zone2, rangeTrustState from daily_scores.
//   ScoreBand.yellowline now emitted by backend (was client-side detection only in Sprint 1.5).
// Sprint 4: MBIUser gains 6 new profile fields per schema migration

import Foundation
import SwiftUI

// ─────────────────────────────────────────
// USER
// Sprint 4: healthGoal, weightLbs, wakeTime, sleepTime,
//           morningBriefEnabled, biologicalSex added.
//           All match new users table columns exactly.
// ─────────────────────────────────────────
struct MBIUser: Codable, Identifiable {
    let id: String
    var email: String
    var displayName: String?
    var stepGoal: Int
    var onboardingComplete: Bool
    var createdAt: String?

    // Sprint 4 — Profile section fields
    var healthGoal: String          // 'general_wellness' | 'longevity' | 'recovery' | 'stress_management' | 'fitness'
    var weightLbs: Double?          // nullable — user enters on first edit
    var wakeTime: String            // HH:MM 24h e.g. "06:00"
    var sleepTime: String           // HH:MM 24h e.g. "22:00"
    var morningBriefEnabled: Bool
    var biologicalSex: String?      // 'male' | 'female' | 'prefer_not_to_say' — schema only in Sprint 4
    var birthday: String?
    var heightFt: Int?
    var heightIn: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName            = "display_name"
        case stepGoal               = "step_goal"
        case onboardingComplete     = "onboarding_complete"
        case createdAt              = "created_at"
        case healthGoal             = "health_goal"
        case weightLbs              = "weight_lbs"
        case wakeTime               = "wake_time"
        case sleepTime              = "sleep_time"
        case morningBriefEnabled    = "morning_brief_enabled"
        case biologicalSex          = "biological_sex"
        case birthday               = "birthday"
        case heightFt               = "height_ft"
        case heightIn               = "height_in"
    }

    // Provide defaults during decode so existing rows without
    // the new columns (pre-migration) don't crash the decoder.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                    = try c.decode(String.self,  forKey: .id)
        email                 = try c.decode(String.self,  forKey: .email)
        displayName           = try c.decodeIfPresent(String.self,  forKey: .displayName)
        stepGoal              = try c.decodeIfPresent(Int.self,     forKey: .stepGoal)              ?? 8000
        onboardingComplete    = try c.decodeIfPresent(Bool.self,    forKey: .onboardingComplete)    ?? false
        createdAt             = try c.decodeIfPresent(String.self,  forKey: .createdAt)
        healthGoal            = try c.decodeIfPresent(String.self,  forKey: .healthGoal)            ?? "general_wellness"
        weightLbs             = try c.decodeIfPresent(Double.self,  forKey: .weightLbs)
        wakeTime              = try c.decodeIfPresent(String.self,  forKey: .wakeTime)              ?? "06:00"
        sleepTime             = try c.decodeIfPresent(String.self,  forKey: .sleepTime)             ?? "22:00"
        morningBriefEnabled   = try c.decodeIfPresent(Bool.self,    forKey: .morningBriefEnabled)   ?? true
        biologicalSex         = try c.decodeIfPresent(String.self,  forKey: .biologicalSex)
        birthday  = try c.decodeIfPresent(String.self, forKey: .birthday)
        heightFt  = try c.decodeIfPresent(Int.self,    forKey: .heightFt)
        heightIn  = try c.decodeIfPresent(Int.self,    forKey: .heightIn)
        
    }

    // Standard memberwise init for constructing in tests / previews
    init(
        id: String,
        email: String,
        displayName: String? = nil,
        stepGoal: Int = 8000,
        onboardingComplete: Bool = false,
        createdAt: String? = nil,
        healthGoal: String = "general_wellness",
        weightLbs: Double? = nil,
        wakeTime: String = "06:00",
        sleepTime: String = "22:00",
        morningBriefEnabled: Bool = true,
        biologicalSex: String? = nil,
        birthday: String? = nil,
        heightFt: Int? = nil,
        heightIn: Int? = nil
    ) {
        self.id                  = id
        self.email               = email
        self.displayName         = displayName
        self.stepGoal            = stepGoal
        self.onboardingComplete  = onboardingComplete
        self.createdAt           = createdAt
        self.healthGoal          = healthGoal
        self.weightLbs           = weightLbs
        self.wakeTime            = wakeTime
        self.sleepTime           = sleepTime
        self.morningBriefEnabled = morningBriefEnabled
        self.biologicalSex       = biologicalSex
        self.birthday = birthday
        self.heightFt = heightFt
        self.heightIn = heightIn
    }
}

// ─────────────────────────────────────────
// HEALTH GOAL ENUM  (Sprint 4)
// Strongly-typed wrapper around the text column.
// The raw value matches what is stored in Supabase exactly.
// ─────────────────────────────────────────
enum HealthGoal: String, CaseIterable, Identifiable {
    case generalWellness   = "general_wellness"
    case longevity         = "longevity"
    case recovery          = "recovery"
    case stressManagement  = "stress_management"
    case fitness           = "fitness"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .generalWellness:  return "General Wellness"
        case .longevity:        return "Longevity"
        case .recovery:         return "Recovery & Restoration"
        case .stressManagement: return "Stress Management"
        case .fitness:          return "Build Fitness"
        }
    }
}

// ─────────────────────────────────────────
// DAILY SCORE
// ─────────────────────────────────────────
struct DailyScore: Codable, Identifiable {
    let id: String
    let userId: String
    let date: String
    let chronosScore: Double
    let scoreBand: ScoreBand
    let healthScore: Double?
    let riskScore: Double?
    let alpha: Double?
    let d1Autonomic: Double?
    let d2Sleep: Double?
    let d3Activity: Double?
    let d4Stress: Double?
    let d5Allostatic: Double?
    let driver1: String
    let driver2: String
    let deltaOverrideTriggered: Bool
    let failState: String?
    let isProvisional: Bool
    let domainVersion: String
    // Range Architecture v1.0 — populated once trust state ≥ provisional (7+ valid days)
    let zone1: String?          // "elevated" | "within_range_high" | "within_range_low" | "below_range" | "flagged" | null
    let zone2: String?
    let rangeTrustState: String? // "establishing" | "calibrating" | "provisional" | "trusted" | "established"
    let createdAt: String?       // ISO-8601 timestamp — used for 24-hour correction window

    enum CodingKeys: String, CodingKey {
        case id, date
        case userId = "user_id"
        case chronosScore = "chronos_score"
        case scoreBand = "score_band"
        case healthScore = "health_score"
        case riskScore = "risk_score"
        case alpha
        case d1Autonomic = "d1_autonomic"
        case d2Sleep = "d2_sleep"
        case d3Activity = "d3_activity"
        case d4Stress = "d4_stress"
        case d5Allostatic = "d5_allostatic"
        case driver1 = "driver_1"
        case driver2 = "driver_2"
        case deltaOverrideTriggered = "delta_override_triggered"
        case failState = "fail_state"
        case isProvisional = "is_provisional"
        case domainVersion = "domain_version"
        case zone1 = "zone_1"
        case zone2 = "zone_2"
        case rangeTrustState = "range_trust_state"
        case createdAt = "created_at"
    }
}

// ─────────────────────────────────────────
// SCORE BAND
// Sprint 1.5: .yellowline added
// Pre-Beta Sprint: themeColor + themeTint added — canonical band color tokens.
// All views must use these rather than inline Color(red:green:blue:) literals.
// ─────────────────────────────────────────
enum ScoreBand: String, Codable {
    case thriving   = "Thriving"
    case recovering = "Recovering"
    case yellowline = "Yellowline"
    case drifting   = "Drifting"
    case redline    = "Redline"

    var color: String {
        switch self {
        case .thriving:   return "ScoreThriving"
        case .recovering: return "ScoreRecovering"
        case .yellowline: return "ScoreYellowline"
        case .drifting:   return "ScoreDrifting"
        case .redline:    return "ScoreRedline"
        }
    }

    var description: String {
        switch self {
        case .thriving:   return "Strong recovery and adaptation"
        case .recovering: return "Mild stress load, within range"
        case .yellowline: return "Early decline — worth paying attention to"
        case .drifting:   return "Risk accumulating, needs attention"
        case .redline:    return "Acute physiological stress"
        }
    }

    /// Foreground accent color — used for score numerals, band labels, sparklines.
    var themeColor: Color {
        switch self {
        case .thriving:   return Color(red: 0.50, green: 0.90, blue: 0.55)
        case .recovering: return Color(red: 0.55, green: 0.78, blue: 1.00)
        case .yellowline: return Color(red: 1.00, green: 0.72, blue: 0.20)
        case .drifting:   return Color(red: 1.00, green: 0.80, blue: 0.30)
        case .redline:    return Color(red: 1.00, green: 0.42, blue: 0.42)
        }
    }

    /// Background tint — used for card gradient overlays and subtle fills.
    var themeTint: Color {
        switch self {
        case .thriving:   return Color(red: 0.15, green: 0.35, blue: 0.20)
        case .recovering: return Color(red: 0.18, green: 0.20, blue: 0.36)
        case .yellowline: return Color(red: 0.38, green: 0.28, blue: 0.05)
        case .drifting:   return Color(red: 0.36, green: 0.28, blue: 0.10)
        case .redline:    return Color(red: 0.38, green: 0.12, blue: 0.12)
        }
    }
}

// ─────────────────────────────────────────
// EXPLANATION
// ─────────────────────────────────────────
struct Explanation: Codable, Identifiable {
    let id: String
    let scoreId: String
    let userId: String
    let date: String
    let explanationText: String?
    let nudgeText: String?
    let promptVersion: String
    let modelVersion: String
    var eveningExplanationText: String?
    var eveningNudgeText: String?
    var detailExplanationText: String?
    var detailGeneratedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case scoreId = "score_id"
        case userId = "user_id"
        case date
        case explanationText = "explanation_text"
        case nudgeText = "nudge_text"
        case promptVersion = "prompt_version"
        case modelVersion = "model_version"
        case eveningExplanationText = "evening_explanation_text"
        case eveningNudgeText = "evening_nudge_text"
        case detailExplanationText = "detail_explanation_text"
        case detailGeneratedAt = "detail_generated_at"
    }
}

extension Explanation {
    /// Returns the evening brief text after 5pm if available; falls back to morning.
    /// If morning text is null (evening-only row), falls back to evening text at any hour.
    var displayExplanationText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 17, let evening = eveningExplanationText { return evening }
        return explanationText ?? eveningExplanationText ?? ""
    }

    /// Returns the evening nudge text after 5pm if available; falls back to morning.
    /// If morning nudge is null (evening-only row), falls back to evening nudge at any hour.
    var displayNudgeText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 17, let eveningNudge = eveningNudgeText { return eveningNudge }
        return nudgeText ?? eveningNudgeText ?? ""
    }
}

// ─────────────────────────────────────────
// DASHBOARD (combined view model)
// Sprint 1.5: computedBand added — resolves Yellowline client-side
// ─────────────────────────────────────────
// DashboardData is Codable so SyncCoordinator can persist the last known
// dashboard to UserDefaults for offline / failure fallback (P1.3 / P3.3).
// The `isStale` flag is ephemeral — loaded from cache always starts as stale.
// `computedBand` is a computed property and is intentionally excluded from encoding.
struct DashboardData: Codable {
    let score: DailyScore
    let explanation: Explanation?
    let recentScores: [Double]

    var isStale: Bool = false

    enum CodingKeys: String, CodingKey {
        case score, explanation, recentScores
        // isStale excluded — runtime-only flag, always `true` when restored from cache
    }

    // Pre-Beta Sprint v1.5: Backend now emits Yellowline directly via getScoreBand().
    // computedBand defers to score.scoreBand in all cases.
    // The client-side trajectory heuristic (Sprint 1.5) is retired — backend is canonical.
    var computedBand: ScoreBand { score.scoreBand }
}

// ─────────────────────────────────────────
// TREND POINT
// ─────────────────────────────────────────
struct TrendPoint: Identifiable {
    var id: String { date }
    let date: String
    let score: Double
}

// ─────────────────────────────────────────
// METRIC LABELS
// ─────────────────────────────────────────
enum Metric: String {
    case hrv
    case resting_hr
    case respiratory_rate
    case sleep_duration
    case sleep_continuity
    case steps
    case active_minutes
    case distance

    var displayName: String {
        switch self {
        case .hrv:               return "Heart Rate Variability"
        case .resting_hr:        return "Resting Heart Rate"
        case .respiratory_rate:  return "Respiratory Rate"
        case .sleep_duration:    return "Sleep Duration"
        case .sleep_continuity:  return "Sleep Quality"
        case .steps:             return "Daily Steps"
        case .active_minutes:    return "Active Minutes"
        case .distance:          return "Distance"
        }
    }

    var shortName: String {
        switch self {
        case .hrv:               return "HRV"
        case .resting_hr:        return "Resting HR"
        case .respiratory_rate:  return "Resp. Rate"
        case .sleep_duration:    return "Sleep"
        case .sleep_continuity:  return "Sleep Quality"
        case .steps:             return "Steps"
        case .active_minutes:    return "Active Min"
        case .distance:          return "Distance"
        }
    }
}

// ─────────────────────────────────────────
// TREND AGGREGATE  (Sprint 2)
// ─────────────────────────────────────────
struct TrendAggregate: Codable, Identifiable {
    let id: String
    let userId: String
    let windowType: String
    let windowStart: String
    let windowEnd: String

    let chronosAvg: Double?
    let chronosMin: Double?
    let chronosMax: Double?
    let trendDirection: String?
    let daysInWindow: Int

    let hrvAvg: Double?
    let restingHrAvg: Double?
    let respiratoryRateAvg: Double?
    let sleepDurationAvg: Double?
    let sleepContinuityAvg: Double?
    let stepsAvg: Double?
    let activeMinutesAvg: Double?

    let topDriver1: String?
    let topDriver2: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId             = "user_id"
        case windowType         = "window_type"
        case windowStart        = "window_start"
        case windowEnd          = "window_end"
        case chronosAvg         = "chronos_avg"
        case chronosMin         = "chronos_min"
        case chronosMax         = "chronos_max"
        case trendDirection     = "trend_direction"
        case daysInWindow       = "days_in_window"
        case hrvAvg             = "hrv_avg"
        case restingHrAvg       = "resting_hr_avg"
        case respiratoryRateAvg = "respiratory_rate_avg"
        case sleepDurationAvg   = "sleep_duration_avg"
        case sleepContinuityAvg = "sleep_continuity_avg"
        case stepsAvg           = "steps_avg"
        case activeMinutesAvg   = "active_minutes_avg"
        case topDriver1         = "top_driver_1"
        case topDriver2         = "top_driver_2"
    }

    func avg(for metricKey: String) -> Double? {
        switch metricKey {
        case "hrv":               return hrvAvg
        case "resting_hr":        return restingHrAvg
        case "respiratory_rate":  return respiratoryRateAvg
        case "sleep_duration":    return sleepDurationAvg
        case "sleep_continuity":  return sleepContinuityAvg
        case "steps":             return stepsAvg
        case "active_minutes":    return activeMinutesAvg
        default:                  return nil
        }
    }
}

// ─────────────────────────────────────────
// TREND WINDOW  (Sprint 2)
// ─────────────────────────────────────────
enum TrendWindow: String, CaseIterable {
    case sevenDay    = "7D"
    case eightWeek   = "8W"
    case twelveMonth = "12M"

    var apiKey: String {
        switch self {
        case .sevenDay:    return "7d"
        case .eightWeek:   return "8w"
        case .twelveMonth: return "12m"
        }
    }

    var aggregateType: String {
        switch self {
        case .sevenDay:    return "daily"
        case .eightWeek:   return "weekly"
        case .twelveMonth: return "monthly"
        }
    }

    var fetchLimit: Int {
        switch self {
        case .sevenDay:    return 7
        case .eightWeek:   return 8
        case .twelveMonth: return 12
        }
    }

    var headerEyebrow: String {
        switch self {
        case .sevenDay:    return "YOUR WEEK"
        case .eightWeek:   return "YOUR MONTH"
        case .twelveMonth: return "YOUR YEAR"
        }
    }

    var headerTitle: String {
        switch self {
        case .sevenDay:    return "in signal."
        case .eightWeek:   return "in pattern."
        case .twelveMonth: return "in arc."
        }
    }

    var headerSubtitle: String {
        switch self {
        case .sevenDay:    return "Seven days. One story."
        case .eightWeek:   return "Eight weeks. One arc."
        case .twelveMonth: return "Twelve months. One trajectory."
        }
    }

    var dateLabel: String {
        let formatter = DateFormatter()
        switch self {
        case .sevenDay:
            let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
            formatter.dateFormat = "MMMM d"
            return "WEEK OF \(formatter.string(from: weekStart).uppercased())"
        case .eightWeek:
            return "LAST 8 WEEKS"
        case .twelveMonth:
            return "LAST 12 MONTHS"
        }
    }

    var buildingThreshold: Int {
        switch self {
        case .sevenDay:    return 3
        case .eightWeek:   return 2
        case .twelveMonth: return 3
        }
    }

    var buildingLabel: String {
        switch self {
        case .sevenDay:    return "Baseline building"
        case .eightWeek:   return "Building — more weeks needed"
        case .twelveMonth: return "Building — history deepens over time"
        }
    }
}

// ─────────────────────────────────────────
// METRIC TILE DATA  (Sprint 2)
// ─────────────────────────────────────────
struct MetricTileData: Identifiable {
    let id: String
    let displayName: String
    let shortName: String
    let todayValue: Double?
    let sevenDayAvg: Double?
    let thirtyDayAvg: Double?
    let unit: String

    var isChronos: Bool { id == "chronos" }
}

// ─────────────────────────────────────────
// TREND SIGNAL CALLOUT  (Sprint 2)
// ─────────────────────────────────────────
enum CalloutCategory {
    case workingForYou
    case worthWatching
}

struct TrendCallout: Identifiable {
    let id = UUID()
    let category: CalloutCategory
    let text: String
}

// ─────────────────────────────────────────
// HORIZON SIGNAL  (Phase 2 · Epic 3 Sprint 1)
// ─────────────────────────────────────────
// MOMENTUM STATE
// Promoted from HorizonMomentumView — accessible across module.
// Computed from 14-day rolling comparison of daily_scores.
// ─────────────────────────────────────────

enum MomentumState: Equatable {
    case building       // recent 14-day avg > prior 14-day avg by ≥ 2 pts
    case holding        // within ±2 pts
    case shifting       // recent avg below prior by ≥ 2 pts
    case insufficient   // < 14 days of data

    var label: String {
        switch self {
        case .building:     return "Building"
        case .holding:      return "Holding"
        case .shifting:     return "Shifting"
        case .insufficient: return "Calibrating"
        }
    }

    var color: Color {
        switch self {
        case .building:     return Color(red: 0.40, green: 0.82, blue: 0.50)
        case .holding:      return Color(red: 1.0,  green: 0.75, blue: 0.35)
        case .shifting:     return Color(red: 1.0,  green: 0.55, blue: 0.25)
        case .insufficient: return Color.white.opacity(0.28)
        }
    }

    var description: String {
        switch self {
        case .building:     return "Your baseline is trending upward over the last 14 days."
        case .holding:      return "Your baseline is stable — consistent pattern, no meaningful drift."
        case .shifting:     return "Your baseline has trended down over the last 14 days."
        case .insufficient: return "14 days of data needed to compute momentum. Keep going."
        }
    }

    var icon: String {
        switch self {
        case .building:     return "arrow.up.right"
        case .holding:      return "arrow.right"
        case .shifting:     return "arrow.down.right"
        case .insufficient: return "clock"
        }
    }

    var barFill: CGFloat {
        switch self {
        case .building:     return 0.82
        case .holding:      return 0.50
        case .shifting:     return 0.20
        case .insufficient: return 0.0
        }
    }

    /// Compute momentum state from two windows of scores.
    /// - Parameters:
    ///   - recent: the more recent 14-day window (or fewer)
    ///   - prior: the prior 14-day window (may be empty)
    static func compute(recent: [Double], prior: [Double]) -> MomentumState {
        guard recent.count >= 7 else { return .insufficient }
        let recentAvg = recent.reduce(0, +) / Double(recent.count)

        if prior.count < 7 {
            // Only one window — compare first vs second half internally
            let first  = Array(recent.prefix(7)).reduce(0, +) / 7.0
            let second = Array(recent.suffix(7)).reduce(0, +) / 7.0
            let delta  = second - first
            if delta >  1.5 { return .building }
            if delta < -1.5 { return .shifting }
            return .holding
        }

        let priorAvg = prior.reduce(0, +) / Double(prior.count)
        let delta    = recentAvg - priorAvg
        if delta >  2.0 { return .building }
        if delta < -2.0 { return .shifting }
        return .holding
    }
}

// One per pathway per day. Populated by the `horizon` Edge Function.
// conditionClass and trajectoryLabel are nil when the activation gate is not met.
// ─────────────────────────────────────────

struct HorizonSignal {
    let pathway: String
    let conditionClass: String?
    let trajectoryLabel: String?
    let escalationLevel: Int
    let confidenceGate: Double
    let daysInPattern: Int
    let schemaVersion: String
    let calibrationStatus: String
    /// State written by ontology-classify — the authoritative source.
    /// "CALM" | "ELEVATED" | "FLAGGED". Defaults to "CALM" for rows
    /// predating the Ontology Engine v1 migration.
    let dbState: String

    // Trajectory gate — conditionClass present + confidenceGate ≥ 0.3 (within-user baseline)
    var isActive: Bool {
        conditionClass != nil && confidenceGate >= 0.3
    }
}

struct HorizonAssessment {
    let autonomic: HorizonSignal?
    let sleep: HorizonSignal?
    let metabolic: HorizonSignal?

    // Overall 14-day rolling momentum — computed by HorizonModuleView.loadAssessment()
    var momentumState: MomentumState = .insufficient

    // Page 2: Trajectory — always visible (no gate)

    // Page 3: Redirect — conditionClass present, confidenceGate ≥ 0.5
    var page3Active: Bool {
        [autonomic, sleep, metabolic].compactMap { $0 }.contains {
            $0.conditionClass != nil && $0.confidenceGate >= 0.5
        }
    }

    // Page 4: Escalate — escalationLevel == 3 and confidenceGate ≥ 0.75
    var page4Active: Bool {
        [autonomic, sleep, metabolic].compactMap { $0 }.contains {
            $0.escalationLevel == 3 && $0.confidenceGate >= 0.75
        }
    }

    var escalationSignals: [HorizonSignal] {
        [autonomic, sleep, metabolic].compactMap { $0 }.filter {
            $0.escalationLevel == 3 && $0.confidenceGate >= 0.75
        }
    }

    var calmPathwayLabels: [String] {
        var labels: [String] = []
        if let a = autonomic, !a.isActive { labels.append("autonomic recovery") }
        if let s = sleep,     !s.isActive { labels.append("sleep recovery") }
        if let m = metabolic, !m.isActive { labels.append("metabolic balance") }
        return labels
    }

    /// True when at least one pathway has a conditionClass or escalationLevel > 0
    var hasActiveSignal: Bool {
        [autonomic, sleep, metabolic].compactMap { $0 }.contains {
            $0.conditionClass != nil || $0.escalationLevel > 0
        }
    }

    /// Lead signal — highest escalationLevel among pathways with conditionClass or escalationLevel > 0
    var leadSignal: HorizonSignal? {
        [autonomic, sleep, metabolic]
            .compactMap { $0 }
            .filter { $0.conditionClass != nil || $0.escalationLevel > 0 }
            .max(by: { $0.escalationLevel < $1.escalationLevel })
    }

    /// Human-readable name of the lead pathway key
    var leadPathwayName: String? {
        guard let lead = leadSignal else { return nil }
        switch lead.pathway {
        case "autonomic": return "Autonomic"
        case "sleep":     return "Sleep"
        case "metabolic": return "Metabolic"
        default:          return lead.pathway.capitalized
        }
    }

    static let empty = HorizonAssessment(autonomic: nil, sleep: nil, metabolic: nil)
}

// ─────────────────────────────────────────
// HORIZON SCORE CONTEXT
// OI-008: score/driver/zone context passed alongside HorizonAssessment to
// horizon-assist, so the Q&A response can reference the user's current score state.
// ─────────────────────────────────────────
struct HorizonScoreContext {
    let chronosScore: Double
    let scoreBand: String
    let driver1: String?
    let driver2: String?
    let zone1: String?
    let zone2: String?
    let rangeTrustState: String?
    let isProvisional: Bool
}

// ─────────────────────────────────────────
// HORIZON ASSIST RESPONSE
// Sprint 9: Response from callHorizonAssist.
// isStub = true while Edge Function is not yet deployed (Phase 2).
// isStub = false once horizon-assist Edge Function is live (Phase 3).
// ─────────────────────────────────────────
struct HorizonAssistResponse {
    let answer: String
    let isStub: Bool    // true = locally synthesised, false = Edge Function response
}

// ─────────────────────────────────────────
// SCORE CORRECTION  (Step 8)
// ─────────────────────────────────────────
struct ScoreCorrection: Codable, Identifiable {
    let id: String
    let userId: String
    let date: String
    let signalName: String
    let originalValue: Double?
    let correctedValue: Double
    let correctionType: String
    let submittedAt: String
    let windowExpiresAt: String
    let isApplied: Bool
    let dismissed: Bool
    let dismissedAt: String?
    let escalationSent: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId           = "user_id"
        case date
        case signalName       = "signal_name"
        case originalValue    = "original_value"
        case correctedValue   = "corrected_value"
        case correctionType   = "correction_type"
        case submittedAt      = "submitted_at"
        case windowExpiresAt  = "window_expires_at"
        case isApplied        = "is_applied"
        case dismissed
        case dismissedAt      = "dismissed_at"
        case escalationSent   = "escalation_sent"
    }
}

// ─────────────────────────────────────────
// CORRECTION FLAG  (Step 8 — client-side detection result)
// Produced by the correction check; consumed by the banner and sheet.
// ─────────────────────────────────────────
enum CorrectionFlagReason {
    case missing
    case implausible
    case provisional
}

struct CorrectionFlag: Identifiable, Equatable {
    let id: String                   // signal key, e.g. "d1_autonomic"
    let signalKey: String
    let displayName: String
    let reason: CorrectionFlagReason
    let value: Double?               // current recorded value; nil if missing
    let windowExpiresAt: Date

    static func == (lhs: CorrectionFlag, rhs: CorrectionFlag) -> Bool {
        lhs.signalKey == rhs.signalKey
    }

    var signalUnit: String {
        switch signalKey {
        case "d1_autonomic":  return "ms"
        case "d2_sleep":      return "hours"
        case "d3_activity":   return "steps"
        case "d4_stress":     return "0–100 scale"
        case "d5_allostatic": return "0–100 scale"
        default:              return ""
        }
    }

    var missingMessage: String {
        switch signalKey {
        case "d1_autonomic":
            return "Your HRV couldn't be measured last night. Make sure your device is snug above the wrist bone and worn through the night."
        case "d2_sleep":
            return "Your sleep data is missing. For an accurate score, wear your device charged above 30% at bedtime."
        case "d3_activity":
            return "Your activity data is missing. Check that Chronos has permission to read Activity data in your Health settings."
        case "d4_stress":
            return "Your recovery stress data didn't come through. This usually means your device wasn't worn or synced overnight."
        case "d5_allostatic":
            return "Your body load score couldn't be calculated — one or more input signals are missing. Check device wear and sync."
        default:
            return "This signal couldn't be measured. Check device wear and sync."
        }
    }
}
