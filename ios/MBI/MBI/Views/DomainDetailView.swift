// ios/MBI/MBI/Views/DomainDetailView.swift
// MBI Domains Tab Redesign Sprint — §3.7 Domain Detail Sheet
//
// Redesigned layout per build handoff v1.0:
//   Section 1 — Score Header (today score, avg, direction label, role tag)
//   Section 2 — Metric Rows (SF Symbol icon, today value, avg value)
//   Section 3 — Observational Card (info.circle + Claude sentence)
//   Section 4 — 30-Day History Chart (with baseline reference line)
//   Section 5 — OTHER SYSTEMS TODAY (other 4 domains, tappable rows)
//   Section 6 — Footer ([N] days · Updated today)
//
// Data flow:
//   rawMetrics, perMetricBaselines, expandedNarratives passed from DomainBreakdownView.
//   domainHistory fetched locally via fetchDomainHistory.
//   Other domain scores from allScores (passed in), no new fetch.

import SwiftUI

// ─────────────────────────────────────────
// DOMAIN DETAIL VIEW
// ─────────────────────────────────────────

struct DomainDetailView: View {

    // Identity
    let label: String           // "D1" | "D2" | "D3" | "D4" | "D5"
    let title: String           // "Autonomic Recovery"
    let subtitle: String        // "HRV · Resting HR"

    // Score context
    let score: Double?
    let domainBaseline: Double?
    let role: DomainRole
    let conflict: ConflictResult?

    // Metric data — provided by parent (already fetched)
    let rawMetrics: DomainRawMetrics
    let perMetricBaselines: [String: Double]
    let expandedNarrative: DomainExpandedNarrative?

    // Cross-system context (for OTHER SYSTEMS TODAY)
    var historyDayCount: Int = 0
    var allScores: DailyScore? = nil
    var allRoles: [String: DomainRole] = [:]
    var allBaselines: DomainBaselines = .empty

    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var domainHistory: [(date: String, value: Double)] = []
    @State private var isLoadingHistory = true

    // Navigation to other domain sheets from OTHER SYSTEMS TODAY
    @State private var navigationTarget: DomainDetailContext? = nil

    private var domainColumnKey: String {
        switch label {
        case "D1": return "d1_autonomic"
        case "D2": return "d2_sleep"
        case "D3": return "d3_activity"
        case "D4": return "d4_stress"
        case "D5": return "d5_allostatic"
        default:   return "d1_autonomic"
        }
    }

    private var scoreColor: Color {
        guard let s = score else { return Color(hex: "7A8FA6") }
        if s >= 80 { return Color(hex: "4ADE80") }
        if s >= 60 { return Color(hex: "C9A84C") }
        if s >= 40 { return Color(hex: "B0936A") }
        return Color(hex: "E07070")
    }

    // avg domain score from 30-day history
    private var domainAvg: Double? {
        guard !domainHistory.isEmpty else { return domainBaseline }
        let vals = domainHistory.map { $0.value }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // "above baseline" / "below baseline" direction label
    private var directionLabel: String? {
        guard let s = score, let base = domainBaseline ?? domainAvg, base > 0 else { return nil }
        return s >= base ? "above baseline" : "below baseline"
    }
    private var directionColor: Color {
        guard let s = score, let base = domainBaseline ?? domainAvg else { return ChronosTheme.faint }
        return s >= base ? Color(hex: "4ADE80") : Color(hex: "E07070")
    }

    var body: some View {
        NavigationView {
            ZStack {
                ChronosTheme.ink.ignoresSafeArea()

                RadialGradient(
                    colors: [ChronosTheme.gold.opacity(0.035), .clear],
                    center: .top, startRadius: 0, endRadius: 280
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {

                        // ── Section 1: Score Header ─────────────────────────────
                        DDScoreHeader(
                            label: label, title: title, subtitle: subtitle,
                            score: score, domainAvg: domainAvg,
                            directionLabel: directionLabel, directionColor: directionColor,
                            role: role, scoreColor: scoreColor
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                        // ── Section 2: Metric Rows ──────────────────────────────
                        let metrics = metricRows()
                        if !metrics.isEmpty {
                            DDMetricCard(rows: metrics, scoreColor: scoreColor)
                                .padding(.horizontal, 20)
                        }

                        // ── Section 3: Observational Card ───────────────────────
                        DDObservationalCard(narrative: expandedNarrative)
                            .padding(.horizontal, 20)

                        // ── Section 4: 30-Day History Chart ─────────────────────
                        DDHistoryChart(
                            history: domainHistory,
                            isLoading: isLoadingHistory,
                            scoreColor: scoreColor,
                            baselineAvg: domainBaseline
                        )
                        .padding(.horizontal, 20)

                        // ── Section 5: OTHER SYSTEMS TODAY ──────────────────────
                        DDOtherSystemsSection(
                            currentLabel: label,
                            allScores: allScores ?? sync.dashboard?.score,
                            allRoles: allRoles,
                            historyDayCount: historyDayCount,
                            onTap: { ctx in navigationTarget = ctx }
                        )
                        .padding(.horizontal, 20)

                        // ── Section 6: Footer ────────────────────────────────────
                        DDFooter(historyDayCount: historyDayCount)
                            .padding(.horizontal, 20)

                        Spacer(minLength: 56)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(label)
                        .font(.jost(size: 11, weight: .medium))
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
            guard let userId = supabase.session?.userId else {
                isLoadingHistory = false; return
            }
            domainHistory = (try? await supabase.fetchDomainHistory(
                userId: userId, column: domainColumnKey
            )) ?? []
            isLoadingHistory = false
        }
        // OTHER SYSTEMS TODAY tap navigation — open sibling domain sheet
        .sheet(item: $navigationTarget) { ctx in
            let siblingScore: Double? = {
                let s = allScores ?? sync.dashboard?.score
                switch ctx.label {
                case "D1": return s?.d1Autonomic
                case "D2": return s?.d2Sleep
                case "D3": return s?.d3Activity
                case "D4": return s?.d4Stress
                case "D5": return s?.d5Allostatic
                default:   return nil
                }
            }()
            let siblingBase: Double? = {
                switch ctx.label {
                case "D1": return allBaselines.d1Autonomic
                case "D2": return allBaselines.d2Sleep
                case "D3": return allBaselines.d3Activity
                case "D4": return allBaselines.d4Stress
                case "D5": return allBaselines.d5Allostatic
                default:   return nil
                }
            }()
            DomainDetailView(
                label:             ctx.label,
                title:             ctx.title,
                subtitle:          ctx.subtitle,
                score:             siblingScore,
                domainBaseline:    siblingBase,
                role:              allRoles[ctx.label] ?? .stable,
                conflict:          nil,
                rawMetrics:        rawMetrics,
                perMetricBaselines: perMetricBaselines,
                expandedNarrative: nil,
                historyDayCount:   historyDayCount,
                allScores:         allScores ?? sync.dashboard?.score,
                allRoles:          allRoles,
                allBaselines:      allBaselines
            )
            .environmentObject(supabase)
            .environmentObject(sync)
        }
    }

    // ─────────────────────────────────────────
    // METRIC ROW DATA
    // ─────────────────────────────────────────

    struct MetricRow: Identifiable {
        let id   = UUID()
        let metric:   String
        let icon:     String     // SF Symbol name
        let value:    Double?
        let baseline: Double?
        let unit:     String
    }

    private func metricRows() -> [MetricRow] {
        switch label {
        case "D1":
            return [
                MetricRow(metric: "HRV",
                          icon: "waveform.path.ecg",
                          value: rawMetrics.hrv_ms,
                          baseline: perMetricBaselines["hrv_avg"],
                          unit: "ms"),
                MetricRow(metric: "Resting HR",
                          icon: "heart",
                          value: rawMetrics.resting_hr_bpm,
                          baseline: perMetricBaselines["resting_hr_avg"],
                          unit: "bpm")
            ]
        case "D2":
            return [
                MetricRow(metric: "Sleep Duration",
                          icon: "bed.double",
                          value: rawMetrics.sleep_duration_hrs,
                          baseline: perMetricBaselines["sleep_duration_avg"],
                          unit: "hrs"),
                MetricRow(metric: "Sleep Continuity",
                          icon: "moon.stars",
                          value: rawMetrics.sleep_continuity_pct,
                          baseline: perMetricBaselines["sleep_continuity_avg"],
                          unit: "%")
            ]
        case "D3":
            return [
                MetricRow(metric: "Steps",
                          icon: "figure.walk",
                          value: rawMetrics.steps,
                          baseline: perMetricBaselines["steps_avg"],
                          unit: "steps"),
                MetricRow(metric: "Active Minutes",
                          icon: "timer",
                          value: rawMetrics.active_minutes,
                          baseline: perMetricBaselines["active_minutes_avg"],
                          unit: "min")
            ]
        default:
            return []
        }
    }
}

// ─────────────────────────────────────────
// SECTION 1: SCORE HEADER
// ─────────────────────────────────────────

private struct DDScoreHeader: View {
    let label:          String
    let title:          String
    let subtitle:       String
    let score:          Double?
    let domainAvg:      Double?
    let directionLabel: String?
    let directionColor: Color
    let role:           DomainRole
    let scoreColor:     Color

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(
                    colors: [Color(red: 0.11, green: 0.10, blue: 0.18),
                             Color(red: 0.07, green: 0.07, blue: 0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(scoreColor.opacity(0.25), lineWidth: 1)
                )

            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, scoreColor.opacity(0.55), .clear],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 1)
                    .clipShape(.rect(topLeadingRadius: 18, topTrailingRadius: 18))
                Spacer()
            }

            HStack(alignment: .top) {
                // Left: domain name, subtitle, direction label
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.cormorant(size: 24, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                    Text(subtitle)
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                    if let dir = directionLabel {
                        Text(dir)
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(directionColor.opacity(0.80))
                            .padding(.top, 2)
                    }
                }

                Spacer()

                // Right: today score + avg + role tag
                VStack(alignment: .trailing, spacing: 6) {
                    if let s = score {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let avg = domainAvg {
                                Text("avg \(Int(avg.rounded()))")
                                    .font(.jost(size: 11, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                            }
                            Text("\(Int(s))")
                                .font(.cormorant(size: 52, weight: .light))
                                .foregroundColor(scoreColor)
                        }
                    } else {
                        Text("—")
                            .font(.cormorant(size: 52, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    RoleTagView(role: role)
                }
            }
            .padding(20)
        }
    }
}

// ─────────────────────────────────────────
// SECTION 2: METRIC CARD WITH SF SYMBOL ICONS
// ─────────────────────────────────────────

private struct DDMetricCard: View {
    let rows: [DomainDetailView.MetricRow]
    let scoreColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )
                .shadow(color: ChronosTheme.ink.opacity(0.5), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 14) {
                Text("TODAY'S METRICS")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.70))
                    .tracking(2.5)

                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        DDMetricIconRow(row: row, scoreColor: scoreColor)
                        if row.id != rows.last?.id {
                            Rectangle()
                                .fill(ChronosTheme.faint.opacity(0.08))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct DDMetricIconRow: View {
    let row: DomainDetailView.MetricRow
    let scoreColor: Color

    private var formattedValue: String {
        guard let v = row.value else { return "—" }
        switch row.unit {
        case "hrs":
            let hrs = Int(v); let mins = Int((v - Double(hrs)) * 60)
            return mins > 0 ? "\(hrs)h \(mins)m" : "\(hrs)h"
        case "steps":
            let fmt = NumberFormatter(); fmt.numberStyle = .decimal
            return (fmt.string(from: NSNumber(value: Int(v))) ?? "\(Int(v))") + " steps"
        case "%": return "\(Int(v))%"
        default:  return "\(Int(v)) \(row.unit)"
        }
    }

    private var formattedAvg: String? {
        guard let b = row.baseline else { return nil }
        switch row.unit {
        case "hrs":
            let hrs = Int(b); let mins = Int((b - Double(hrs)) * 60)
            return "avg " + (mins > 0 ? "\(hrs)h \(mins)m" : "\(hrs)h")
        case "steps":
            let fmt = NumberFormatter(); fmt.numberStyle = .decimal
            return "avg " + (fmt.string(from: NSNumber(value: Int(b))) ?? "\(Int(b))")
        case "%": return "avg \(Int(b.rounded()))%"
        default:  return "avg \(Int(b.rounded())) \(row.unit)"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.icon)
                .font(.system(size: 16, weight: .ultraLight))
                .foregroundColor(scoreColor.opacity(0.70))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.metric)
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
                if let avg = formattedAvg {
                    Text(avg)
                        .font(.jost(size: 10, weight: .light))
                        .foregroundColor(ChronosTheme.faint.opacity(0.55))
                }
            }

            Spacer()

            Text(formattedValue)
                .font(.cormorant(size: 22, weight: .light))
                .foregroundColor(scoreColor)
        }
    }
}

// ─────────────────────────────────────────
// SECTION 3: OBSERVATIONAL CARD
// ─────────────────────────────────────────

private struct DDObservationalCard: View {
    let narrative: DomainExpandedNarrative?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )
                .shadow(color: ChronosTheme.ink.opacity(0.5), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold.opacity(0.70))
                    Text("SIGNAL CONTEXT")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.gold.opacity(0.70))
                        .tracking(2.5)
                }

                if let n = narrative {
                    Text(n.observationalLine)
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    if let elab = n.conflictElaboration {
                        Rectangle()
                            .fill(ChronosTheme.gold.opacity(0.15))
                            .frame(height: 1)
                        Text(elab)
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted.opacity(0.80))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(ChronosTheme.gold.opacity(0.35))
                        Text("Reading signals…")
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                }
            }
            .padding(18)
        }
    }
}

// ─────────────────────────────────────────
// SECTION 4: 30-DAY HISTORY CHART
// Includes baseline dotted reference line.
// ─────────────────────────────────────────

private struct DDHistoryChart: View {
    let history:     [(date: String, value: Double)]
    let isLoading:   Bool
    let scoreColor:  Color
    var baselineAvg: Double? = nil

    private var trendLabel: String {
        guard history.count >= 7 else { return "BUILDING" }
        let recent = history.suffix(7).map { $0.value }
        let older  = history.dropLast(7).map { $0.value }
        let recentAvg = recent.reduce(0, +) / Double(recent.count)
        let olderAvg  = older.isEmpty ? recentAvg : older.reduce(0, +) / Double(older.count)
        let delta = recentAvg - olderAvg
        if delta >  2 { return "IMPROVING" }
        if delta < -2 { return "DECLINING" }
        return "STABLE"
    }

    private var trendColor: Color {
        switch trendLabel {
        case "IMPROVING": return Color(hex: "4ADE80")
        case "DECLINING": return Color(hex: "E07070").opacity(0.80)
        default:          return ChronosTheme.gold.opacity(0.65)
        }
    }

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
                    Text("30-DAY TREND")
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
                    .frame(height: 80)
                } else if history.isEmpty {
                    Text("Not enough history yet — keep syncing daily.")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .lineSpacing(4)
                        .frame(height: 80, alignment: .topLeading)
                } else {
                    DDHistoryLine(history: history, lineColor: scoreColor, baselineAvg: baselineAvg)
                        .frame(height: 90)
                }

                // Baseline reference label
                if let base = baselineAvg {
                    HStack(spacing: 5) {
                        Rectangle()
                            .fill(ChronosTheme.gold.opacity(0.35))
                            .frame(width: 16, height: 1)
                            .overlay(
                                HStack(spacing: 2) {
                                    ForEach(0..<4) { _ in
                                        Rectangle().fill(Color.clear).frame(width: 2, height: 1)
                                    }
                                }
                            )
                        Text("Your baseline (\(Int(base.rounded())))")
                            .font(.jost(size: 9, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct DDHistoryLine: View {
    let history:     [(date: String, value: Double)]
    let lineColor:   Color
    var baselineAvg: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let values = history.map { $0.value }
            let w      = geo.size.width
            let h      = geo.size.height - 16  // leave room for date labels
            let count  = values.count
            let minV   = (values.min() ?? 0) - 5
            let maxV   = (values.max() ?? 100) + 5
            let range  = max(maxV - minV, 1)
            let step   = count > 1 ? w / CGFloat(count - 1) : w

            let points: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step,
                        y: h - CGFloat((v - minV) / range) * h)
            }

            ZStack {
                // Baseline dotted reference line
                if let base = baselineAvg {
                    let baseY = h - CGFloat((base - minV) / range) * h
                    Canvas { ctx, _ in
                        var path = Path()
                        var x: CGFloat = 0
                        while x < w {
                            path.move(to: CGPoint(x: x, y: baseY))
                            path.addLine(to: CGPoint(x: min(x + 6, w), y: baseY))
                            x += 10
                        }
                        ctx.stroke(path, with: .color(ChronosTheme.gold.opacity(0.35)), lineWidth: 1)
                    }
                }

                // Fill area
                Canvas { ctx, size in
                    guard points.count > 1 else { return }
                    var fill = Path()
                    fill.move(to: CGPoint(x: points[0].x, y: h))
                    fill.addLine(to: points[0])
                    for pt in points.dropFirst() { fill.addLine(to: pt) }
                    fill.addLine(to: CGPoint(x: points.last!.x, y: h))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(
                        Gradient(colors: [lineColor.opacity(0.14), .clear]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: h)
                    ))
                }

                // Line
                Canvas { ctx, _ in
                    guard points.count > 1 else { return }
                    var path = Path()
                    path.move(to: points[0])
                    for pt in points.dropFirst() { path.addLine(to: pt) }
                    ctx.stroke(path, with: .color(lineColor.opacity(0.80)), lineWidth: 1.5)
                }

                // Today's dot
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
                            Text(Date.relativeLabel(from: first.date))
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                            Spacer()
                            Text(Date.relativeLabel(from: latest.date))
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                        }
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// SECTION 5: OTHER SYSTEMS TODAY
// Compact list of the other 4 domains. Tappable → sibling sheet.
// ─────────────────────────────────────────

private struct DDOtherSystemsSection: View {

    let currentLabel:   String
    let allScores:      DailyScore?
    let allRoles:       [String: DomainRole]
    let historyDayCount: Int
    let onTap:          (DomainDetailContext) -> Void

    private struct DomainDef {
        let label: String; let title: String; let subtitle: String
    }

    private let allDomains: [DomainDef] = [
        DomainDef(label: "D1", title: "Autonomic Recovery", subtitle: "HRV · Resting HR"),
        DomainDef(label: "D2", title: "Sleep Recovery",     subtitle: "Duration · Quality"),
        DomainDef(label: "D3", title: "Activity Load",      subtitle: "Steps · Active min"),
        DomainDef(label: "D4", title: "Inferred Stress",    subtitle: "7-day pattern"),
        DomainDef(label: "D5", title: "Allostatic Trend",   subtitle: "30-day composite"),
    ]

    private func score(for label: String) -> Double? {
        switch label {
        case "D1": return allScores?.d1Autonomic
        case "D2": return allScores?.d2Sleep
        case "D3": return allScores?.d3Activity
        case "D4": return allScores?.d4Stress
        case "D5": return allScores?.d5Allostatic
        default:   return nil
        }
    }

    private func isActive(_ label: String) -> Bool {
        switch label {
        case "D4": return historyDayCount >= 7
        case "D5": return historyDayCount >= 30
        default:   return true
        }
    }

    private var others: [DomainDef] {
        allDomains.filter { $0.label != currentLabel }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 12) {
                Text("OTHER SYSTEMS TODAY")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.70))
                    .tracking(2.5)

                VStack(spacing: 0) {
                    ForEach(others, id: \.label) { def in
                        let active = isActive(def.label)
                        let domainScore = score(for: def.label)
                        let role = allRoles[def.label] ?? (active ? .stable : .building)

                        Button {
                            guard active else { return }
                            onTap(DomainDetailContext(
                                id: def.label, label: def.label,
                                title: def.title, subtitle: def.subtitle
                            ))
                        } label: {
                            HStack(spacing: 12) {
                                // D badge
                                Text(def.label)
                                    .font(.jost(size: 8, weight: active ? .medium : .light))
                                    .foregroundColor(active ? ChronosTheme.gold : ChronosTheme.faint)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(active ? ChronosTheme.goldDim : ChronosTheme.ink)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(active ? ChronosTheme.gold.opacity(0.20) : ChronosTheme.border, lineWidth: 1)
                                            )
                                    )

                                // Domain name
                                Text(def.title)
                                    .font(.jost(size: 12, weight: .light))
                                    .foregroundColor(active ? ChronosTheme.text : ChronosTheme.muted)

                                Spacer()

                                // Score
                                if let s = domainScore {
                                    Text("\(Int(s))")
                                        .font(.jost(size: 13, weight: .regular))
                                        .foregroundColor(active ? ChronosTheme.text : ChronosTheme.faint)
                                }

                                // Role pill
                                if active {
                                    RoleTagView(role: role)
                                }

                                // Chevron
                                if active {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .light))
                                        .foregroundColor(ChronosTheme.faint)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(!active)

                        if def.label != others.last?.label {
                            Rectangle()
                                .fill(ChronosTheme.faint.opacity(0.08))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}

// ─────────────────────────────────────────
// SECTION 6: FOOTER
// ─────────────────────────────────────────

private struct DDFooter: View {
    let historyDayCount: Int

    private var updatedLabel: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .none
        return "Updated \(fmt.string(from: Date()))"
    }

    var body: some View {
        HStack {
            Text("\(historyDayCount) days available · \(updatedLabel)")
                .font(.jost(size: 10, weight: .light))
                .foregroundColor(ChronosTheme.faint.opacity(0.55))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}
