// ios/MBI/MBI/Views/MetricDetailView.swift
// MBI Phase 2 — Metric Detail Drill-Through
//
// Opened by long-pressing any MetricTileView in TrendView (grid or banner layout).
// Shows: 90-day history line chart, baseline reference line, today vs baseline delta,
//        trend direction label, contextual note (Phase 2 stub — narrate-metric in Phase 3).
//
// Data flow:
//   MetricTileData passed from TrendView — already has today/7D/30D values.
//   fetchMetricHistory fetches 90 days from daily_inputs or daily_scores.
//   Baseline read from MetricTileData.thirtyDayAvg (30D rolling avg = personal baseline proxy).

import SwiftUI

// ─────────────────────────────────────────
// METRIC DETAIL VIEW
// ─────────────────────────────────────────

struct MetricDetailView: View {
    let tile: MetricTileData

    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var history: [(date: String, value: Double)] = []
    @State private var isLoading = true

    // Maps tile.id → (table, column) for the 90-day fetch
    private static let historySource: [String: (table: String, column: String)] = [
        "chronos":          ("daily_scores", "chronos_score"),
        "hrv":              ("daily_inputs",  "hrv_ms"),
        "resting_hr":       ("daily_inputs",  "resting_hr_bpm"),
        "respiratory_rate": ("daily_inputs",  "respiratory_rate_rpm"),
        "sleep_duration":   ("daily_inputs",  "sleep_duration_hrs"),
        "sleep_continuity": ("daily_inputs",  "sleep_continuity_pct"),
        "steps":            ("daily_inputs",  "steps"),
        "active_minutes":   ("daily_inputs",  "active_minutes"),
    ]

    private var source: (table: String, column: String)? {
        Self.historySource[tile.id]
    }

    private var baseline: Double? { tile.thirtyDayAvg }

    private var trendLabel: String {
        guard history.count >= 14 else { return "BUILDING" }
        let recent = history.suffix(7).map { $0.value }
        let prior  = Array(history.dropLast(7).suffix(7)).map { $0.value }
        guard !prior.isEmpty else { return "BUILDING" }
        let delta = (recent.reduce(0, +) / Double(recent.count)) -
                    (prior.reduce(0, +)  / Double(prior.count))
        let threshold = (baseline ?? 1) * 0.02   // 2% of baseline = meaningful
        if delta >  threshold { return "IMPROVING" }
        if delta < -threshold { return "DECLINING" }
        return "STABLE"
    }

    private var trendColor: Color {
        switch trendLabel {
        case "IMPROVING": return Color(red: 0.29, green: 0.855, blue: 0.50)
        case "DECLINING": return Color(red: 1.0,  green: 0.55,  blue: 0.25)
        default:          return ChronosTheme.gold.opacity(0.65)
        }
    }

    private var deltaVsBaseline: String? {
        guard let today = tile.todayValue, let base = baseline, base > 0 else { return nil }
        let pct = ((today - base) / base) * 100
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", pct))% vs your 30D avg"
    }

    var body: some View {
        NavigationView {
            ZStack {
                ChronosTheme.ink.ignoresSafeArea()

                RadialGradient(
                    colors: [ChronosTheme.gold.opacity(0.035), .clear],
                    center: .top, startRadius: 0, endRadius: 260
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {

                        // Header
                        MDHeader(tile: tile, deltaVsBaseline: deltaVsBaseline)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)

                        // 90-day chart
                        MDHistoryChart(
                            history: history,
                            baseline: baseline,
                            isLoading: isLoading,
                            trendLabel: trendLabel,
                            trendColor: trendColor
                        )
                        .padding(.horizontal, 20)

                        // Summary stats row
                        if !isLoading {
                            MDStatsRow(tile: tile)
                                .padding(.horizontal, 20)
                        }

                        // Contextual note (Phase 2 stub)
                        MDContextualNote(tile: tile, trendLabel: trendLabel, baseline: baseline)
                            .padding(.horizontal, 20)

                        Spacer(minLength: 56)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(tile.displayName.uppercased())
                        .font(.jost(size: 10, weight: .medium))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(2)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                }
            }
        }
        .task {
            guard let userId = supabase.session?.userId,
                  let src = source else {
                isLoading = false; return
            }
            history = (try? await supabase.fetchMetricHistory(
                userId: userId, table: src.table, column: src.column
            )) ?? []
            isLoading = false
        }
    }
}

// ─────────────────────────────────────────
// HEADER
// ─────────────────────────────────────────

private struct MDHeader: View {
    let tile: MetricTileData
    let deltaVsBaseline: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(
                    colors: [Color(red: 0.11, green: 0.10, blue: 0.18),
                             Color(red: 0.07, green: 0.07, blue: 0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(ChronosTheme.gold.opacity(0.18), lineWidth: 1)
                )

            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, ChronosTheme.gold.opacity(0.40), .clear],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 1)
                    .clipShape(.rect(topLeadingRadius: 18, topTrailingRadius: 18))
                Spacer()
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tile.displayName)
                        .font(.cormorant(size: 24, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                    if !tile.unit.isEmpty {
                        Text("90-day personal history · \(tile.unit)")
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    } else {
                        Text("90-day personal history")
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    if let delta = deltaVsBaseline {
                        Text(delta)
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(ChronosTheme.faint.opacity(0.70))
                            .padding(.top, 2)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let v = tile.todayValue {
                        Text(formattedValue(v, unit: tile.unit))
                            .font(.cormorant(size: 44, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                        Text("today")
                            .font(.jost(size: 9, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    } else {
                        Text("—")
                            .font(.cormorant(size: 44, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                }
            }
            .padding(20)
        }
    }

    private func formattedValue(_ v: Double, unit: String) -> String {
        switch unit {
        case "ms":  return "\(Int(v))"
        case "bpm": return "\(Int(v))"
        case "rpm": return "\(Int(v))"
        case "hrs":
            let h = Int(v); let m = Int((v - Double(h)) * 60)
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        case "%":   return "\(Int(v))%"
        case "min": return "\(Int(v))"
        default:
            return v >= 1000 ? "\(Int(v / 1000))k" : "\(Int(v))"
        }
    }
}

// ─────────────────────────────────────────
// 90-DAY HISTORY CHART
// Draws the line + gradient fill + optional baseline reference.
// ─────────────────────────────────────────

private struct MDHistoryChart: View {
    let history:    [(date: String, value: Double)]
    let baseline:   Double?
    let isLoading:  Bool
    let trendLabel: String
    let trendColor: Color

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("90-DAY HISTORY")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.gold.opacity(0.70))
                        .tracking(2.5)
                    Spacer()
                    if !isLoading && !history.isEmpty {
                        Text(trendLabel)
                            .font(.jost(size: 9, weight: .medium))
                            .foregroundColor(trendColor)
                            .tracking(1.5)
                    }
                }

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.6).tint(ChronosTheme.gold.opacity(0.4))
                        Text("Loading history…")
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    .frame(height: 100)
                } else if history.isEmpty {
                    Text("Not enough history yet — keep syncing daily.")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .lineSpacing(4)
                        .frame(height: 100, alignment: .topLeading)
                } else {
                    MDHistoryLine(
                        history: history,
                        baseline: baseline,
                        lineColor: ChronosTheme.gold
                    )
                    .frame(height: 100)
                }
            }
            .padding(18)
        }
    }
}

private struct MDHistoryLine: View {
    let history:  [(date: String, value: Double)]
    let baseline: Double?
    let lineColor: Color

    var body: some View {
        GeometryReader { geo in
            let values = history.map { $0.value }
            let w      = geo.size.width
            let h      = geo.size.height
            let count  = values.count
            let (minV, maxV): (Double, Double) = {
                var lo = values.min() ?? 0
                var hi = values.max() ?? 100
                if let b = baseline { lo = min(lo, b); hi = max(hi, b) }
                lo -= max((hi - lo) * 0.1, 1)
                hi += max((hi - lo) * 0.1, 1)
                return (lo, hi)
            }()
            let range  = max(maxV - minV, 1)
            let step   = count > 1 ? w / CGFloat(count - 1) : w

            let points: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step,
                        y: h - CGFloat((v - minV) / range) * h)
            }

            ZStack {
                // Gradient fill under line
                Canvas { ctx, size in
                    guard points.count > 1 else { return }
                    var fill = Path()
                    fill.move(to: CGPoint(x: points[0].x, y: size.height))
                    fill.addLine(to: points[0])
                    for pt in points.dropFirst() { fill.addLine(to: pt) }
                    fill.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(
                        Gradient(colors: [lineColor.opacity(0.18), .clear]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                }

                // Baseline reference dashed line
                if let b = baseline {
                    let baselineY = h - CGFloat((b - minV) / range) * h
                    Canvas { ctx, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: baselineY))
                        path.addLine(to: CGPoint(x: size.width, y: baselineY))
                        ctx.stroke(path, with: .color(ChronosTheme.gold.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }

                // Main line
                Canvas { ctx, _ in
                    guard points.count > 1 else { return }
                    var path = Path()
                    path.move(to: points[0])
                    for pt in points.dropFirst() { path.addLine(to: pt) }
                    ctx.stroke(path, with: .color(lineColor.opacity(0.85)), lineWidth: 1.5)
                }

                // Today dot
                if let last = points.last {
                    Circle()
                        .fill(lineColor)
                        .frame(width: 6, height: 6)
                        .position(last)
                }

                // Date labels
                if let first = history.first, let latest = history.last {
                    VStack {
                        Spacer()
                        HStack {
                            Text(shortDate(first.date))
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                            Spacer()
                            if let b = baseline {
                                Text("avg \(formattedBaseline(b))")
                                    .font(.jost(size: 8, weight: .light))
                                    .foregroundColor(ChronosTheme.gold.opacity(0.50))
                            }
                            Spacer()
                            Text(shortDate(latest.date))
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                        }
                    }
                }
            }
        }
    }

    // N7: Relative date labels
    private func shortDate(_ s: String) -> String {
        Date.relativeLabel(from: s)
    }

    private func formattedBaseline(_ v: Double) -> String {
        v >= 1000 ? "\(Int(v / 1000))k" : (v < 10 ? String(format: "%.1f", v) : "\(Int(v))")
    }
}

// ─────────────────────────────────────────
// SUMMARY STATS ROW
// ─────────────────────────────────────────

private struct MDStatsRow: View {
    let tile: MetricTileData

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )
            HStack {
                statColumn(label: "TODAY",   value: tile.todayValue,    unit: tile.unit)
                Divider().frame(height: 28).opacity(0.3)
                statColumn(label: "7D AVG",  value: tile.sevenDayAvg,   unit: tile.unit)
                Divider().frame(height: 28).opacity(0.3)
                statColumn(label: "30D AVG", value: tile.thirtyDayAvg,  unit: tile.unit)
            }
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func statColumn(label: String, value: Double?, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.jost(size: 8, weight: .light))
                .foregroundColor(ChronosTheme.faint)
                .tracking(1.5)
            if let v = value {
                Text(formatted(v, unit: unit))
                    .font(.jost(size: 14, weight: .medium))
                    .foregroundColor(ChronosTheme.text)
            } else {
                Text("—")
                    .font(.jost(size: 14, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func formatted(_ v: Double, unit: String) -> String {
        switch unit {
        case "hrs":
            let h = Int(v); let m = Int((v - Double(h)) * 60)
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        case "%":  return "\(Int(v))%"
        case "ms", "bpm", "rpm", "min": return "\(Int(v)) \(unit)"
        default: return v >= 1000 ? "\(Int(v / 1000))k" : "\(Int(v))"
        }
    }
}

// ─────────────────────────────────────────
// CONTEXTUAL NOTE  (Phase 2 stub)
// Phase 3: replace with narrate-metric Edge Function call.
// ─────────────────────────────────────────

private struct MDContextualNote: View {
    let tile: MetricTileData
    let trendLabel: String
    let baseline: Double?

    private var noteText: String {
        guard let base = baseline, let today = tile.todayValue else {
            return "Keep syncing daily to build your personal \(tile.displayName.lowercased()) baseline. Chronos uses 30 days of history to establish what's normal for your body."
        }
        let pct = ((today - base) / base) * 100
        let metricName = tile.displayName.lowercased()

        switch trendLabel {
        case "IMPROVING":
            return "Your \(metricName) has been trending upward over the past week — a signal your body is adapting positively. Current readings are \(String(format: "%.0f", abs(pct)))% \(pct >= 0 ? "above" : "below") your 30-day average."
        case "DECLINING":
            return "Your \(metricName) has been trending lower recently. At \(String(format: "%.0f", abs(pct)))% \(pct >= 0 ? "above" : "below") your 30-day average, this is worth monitoring — consider whether sleep, stress, or training load may be contributing."
        default:
            return "Your \(metricName) is holding stable relative to your 30-day baseline. Today's reading is \(String(format: "%.0f", abs(pct)))% \(pct >= 0 ? "above" : "below") your personal average — within normal variation for your body."
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SIGNAL CONTEXT")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.gold.opacity(0.70))
                        .tracking(2.5)
                    Spacer()
                    Text("CHRONOS")
                        .font(.jost(size: 8, weight: .light))
                        .foregroundColor(ChronosTheme.faint.opacity(0.50))
                        .tracking(1.5)
                }

                Text(noteText)
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }
}
