// ios/MBI/MBI/Views/DriverMetricHelpers.swift
// Shared driver chip helpers — single source of truth.
// Used by DriverChipRow (DashboardView) and RedlineDashboardView (StateView).

import Foundation

// ─────────────────────────────────────────
// DRIVER TAP CONTEXT
// Navigation param passed to IntelligenceSheet.
// ─────────────────────────────────────────

struct DriverTapContext: Identifiable {
    let id: String
    let metric: String
    let isDriver1: Bool
    let todayValue: Double?
    let baselineValue: Double?
    let deviationDirection: DeviationDirection?
    let deviationMagnitudePct: Double?
    let formattedTodayValue: String?
    let p20Value: Double?   // personal 20th-percentile from rolling baselines
    let p80Value: Double?   // personal 80th-percentile from rolling baselines
}

enum DeviationDirection {
    case above, below
}

// ─────────────────────────────────────────
// CHRONOS METRIC HELPERS
// Canonical implementations. Dashboard version is authoritative:
// covers H-01 Tier 1 metrics and behavioral goal framing.
// ─────────────────────────────────────────

enum ChronosMetricHelpers {

    // Maps driver name (as stored in daily_scores) → daily_inputs column key
    static func inputKey(for metricRaw: String) -> String {
        switch metricRaw {
        case "hrv":              return "hrv_ms"
        case "resting_hr":       return "resting_hr_bpm"
        case "respiratory_rate": return "respiratory_rate_rpm"
        case "sleep_duration":   return "sleep_duration_hrs"
        case "sleep_continuity": return "sleep_continuity_pct"
        case "steps":            return "steps"
        case "active_minutes":   return "active_minutes"
        case "distance":         return "distance_km"
        case "spo2":             return "spo2_pct"
        case "resting_energy":   return "resting_energy"
        case "stand_hours":      return "stand_hours"
        default:                 return metricRaw
        }
    }

    static func p20ColumnKey(for metricRaw: String) -> String {
        baselineColumnKey(for: metricRaw).replacingOccurrences(of: "_avg", with: "_p20")
    }

    static func p80ColumnKey(for metricRaw: String) -> String {
        baselineColumnKey(for: metricRaw).replacingOccurrences(of: "_avg", with: "_p80")
    }

    // Maps driver name → baselines table column key
    static func baselineColumnKey(for metricRaw: String) -> String {
        switch metricRaw {
        case "hrv":              return "hrv_avg"
        case "resting_hr":       return "resting_hr_avg"
        case "respiratory_rate": return "respiratory_rate_avg"
        case "sleep_duration":   return "sleep_duration_avg"
        case "sleep_continuity": return "sleep_continuity_avg"
        case "steps":            return "steps_avg"
        case "active_minutes":   return "active_minutes_avg"
        default:                 return "\(metricRaw)_avg"
        }
    }

    // Formats a raw metric value into a display string with units
    static func formatValue(metricRaw: String, value: Double) -> String {
        switch metricRaw {
        case "hrv":
            return "\(Int(value))ms"
        case "resting_hr":
            return "\(Int(value)) bpm"
        case "respiratory_rate":
            return "\(String(format: "%.1f", value)) rpm"
        case "sleep_duration":
            let hrs = Int(value)
            let mins = Int((value - Double(hrs)) * 60)
            return mins > 0 ? "\(hrs)h \(mins)m" : "\(hrs)h"
        case "sleep_continuity":
            return "\(Int(value))%"
        case "steps":
            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            return (fmt.string(from: NSNumber(value: Int(value))) ?? "\(Int(value))") + " steps"
        case "active_minutes":
            return "\(Int(value)) min"
        case "distance":
            return "\(String(format: "%.1f", value)) km"
        case "spo2":
            return "\(String(format: "%.1f", value))%"
        case "resting_energy":
            return "\(Int(value)) kcal"
        case "stand_hours":
            return "\(Int(value)) hrs"
        default:
            return "\(String(format: "%.1f", value))"
        }
    }

    // Signal word + positive/negative flag for chip display.
    // Behavioral metrics use goal framing; physiological use baseline framing.
    static func signalWord(metricRaw: String, value: Double, baseline: Double) -> (String, Bool) {
        let pctDiff = (value - baseline) / baseline
        let higherIsBad   = ["resting_hr", "respiratory_rate"]
        let behavioralGoal = ["steps", "active_minutes"]

        if behavioralGoal.contains(metricRaw) {
            if pctDiff >= 0.10  { return ("above goal", true) }
            if pctDiff >= -0.05 { return ("at goal", true) }
            return ("below goal", false)
        } else if higherIsBad.contains(metricRaw) {
            if pctDiff <= -0.10 { return ("strong", true) }
            if pctDiff <= 0     { return ("at baseline", true) }
            return ("above baseline", false)
        } else {
            if pctDiff >= 0.10  { return ("above baseline", true) }
            if pctDiff >= -0.05 { return ("at baseline", true) }
            return ("below baseline", false)
        }
    }

    // ─────────────────────────────────────────
    // ZONE LABEL — Range Architecture v1.0
    // Maps zone state string from daily_scores → display label + positivity flag.
    // Returns nil when zone is unknown or null (falling back to baseline signal word).
    // ─────────────────────────────────────────
    static func zoneLabelAndPositivity(_ zone: String) -> (label: String, isPositive: Bool)? {
        switch zone {
        case "elevated":          return ("above range", true)
        case "within_range_high": return ("upper range", true)
        case "within_range_low":  return ("lower range", true)
        case "below_range":       return ("below range", false)
        case "flagged":           return ("flagged", false)
        default:                  return nil
        }
    }

    // Builds the full DriverTapContext nav param for the Intelligence Sheet.
    static func buildContext(
        metric: String,
        isDriver1: Bool,
        inputs: [String: Double?],
        baselines: [String: Double]
    ) -> DriverTapContext {
        let key      = inputKey(for: metric)
        let valueOpt = inputs[key].flatMap { $0 }
        let bKey     = baselineColumnKey(for: metric)
        let baseline = baselines[bKey]

        var direction: DeviationDirection? = nil
        var magnitude: Double? = nil
        if let value = valueOpt, let base = baseline, base > 0 {
            direction = value >= base ? .above : .below
            magnitude = abs((value - base) / base) * 100
        }

        return DriverTapContext(
            id:                    metric,
            metric:                metric,
            isDriver1:             isDriver1,
            todayValue:            valueOpt,
            baselineValue:         baseline,
            deviationDirection:    direction,
            deviationMagnitudePct: magnitude,
            formattedTodayValue:   valueOpt.map { formatValue(metricRaw: metric, value: $0) },
            p20Value:              baselines[p20ColumnKey(for: metric)],
            p80Value:              baselines[p80ColumnKey(for: metric)]
        )
    }
}
