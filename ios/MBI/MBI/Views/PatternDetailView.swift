// ios/MBI/MBI/Views/PatternDetailView.swift
// MBI Phase 2 — Pattern Block Drill-Through
//
// Opened by tapping "Why this pattern →" on the System Pattern Block in DomainBreakdownView.
// Explains: why this pattern was detected (threshold logic in plain English),
//           which metrics contributed (domain score breakdown with roles),
//           any cross-domain conflicts expanded, and what it means sustained over time.
//
// All content is deterministic — no Edge Function call needed.
// PatternDetailSnapshot bundles the data from DomainBreakdownView at tap time.

import SwiftUI

// ─────────────────────────────────────────
// WINDOW CONTEXT — today vs 30-day mode
// ─────────────────────────────────────────

enum PatternWindow {
    case today
    case thirtyDay
}

// ─────────────────────────────────────────
// SNAPSHOT — data bundle passed at tap time
// Captures everything needed so the sheet doesn't need async fetches.
// ─────────────────────────────────────────

struct PatternDetailSnapshot {
    let patternResult:  PatternResult
    let narrative:      DomainPatternNarrative?
    let conflicts:      [ConflictResult]
    let score:          DailyScore
    let historyDayCount: Int
    var window:          PatternWindow = .today
}

// ─────────────────────────────────────────
// PATTERN DETAIL VIEW
// ─────────────────────────────────────────

struct PatternDetailView: View {
    let snapshot: PatternDetailSnapshot
    @Environment(\.dismiss) private var dismiss

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

                        // Pattern header — full narrative if available
                        PDPatternHeader(snapshot: snapshot)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)

                        // Detection logic — why this pattern fired
                        PDDetectionLogic(snapshot: snapshot)
                            .padding(.horizontal, 20)

                        // Domain contributions — score bars with roles
                        PDDomainContributions(snapshot: snapshot)
                            .padding(.horizontal, 20)

                        // Conflicts — expanded if any exist
                        if !snapshot.conflicts.isEmpty {
                            PDConflictSection(conflicts: snapshot.conflicts)
                                .padding(.horizontal, 20)
                        }

                        // 30-day context note
                        PDSustainedNote(pattern: snapshot.patternResult.pattern)
                            .padding(.horizontal, 20)

                        Spacer(minLength: 56)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("PATTERN LOGIC")
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
    }
}

// ─────────────────────────────────────────
// PATTERN HEADER
// Shows full narrative title + body (or fallback)
// ─────────────────────────────────────────

private struct PDPatternHeader: View {
    let snapshot: PatternDetailSnapshot

    private var patternName: String {
        snapshot.narrative?.patternTitle ?? fallbackTitle(snapshot.patternResult.pattern)
    }

    private var patternBody: String {
        snapshot.narrative?.patternBody ?? PatternEngine.fallbackSynthesisLine(for: snapshot.patternResult.pattern)
    }

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
                        .stroke(ChronosTheme.gold.opacity(0.35), lineWidth: 1)
                )

            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, ChronosTheme.gold.opacity(0.55), .clear],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 1)
                    .clipShape(.rect(topLeadingRadius: 18, topTrailingRadius: 18))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("TODAY'S SYSTEM READ")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                    .tracking(3)

                Text(patternName)
                    .font(.cormorant(size: 24, weight: .light))
                    .foregroundColor(ChronosTheme.text)

                Text(patternBody)
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private func fallbackTitle(_ p: DomainPattern) -> String {
        switch p {
        case .loadOutpacingRecovery:   return "Load outpacing recovery"
        case .hiddenStressSignal:      return "Hidden stress signal"
        case .sleepProtectingRecovery: return "Sleep protecting recovery"
        case .systemsInAlignment:      return "Systems in alignment"
        case .recoveryUnderPressure:   return "Recovery under pressure"
        case .defaultPattern:          return "Active system pattern"
        }
    }
}

// ─────────────────────────────────────────
// DETECTION LOGIC
// Plain-English explanation of which thresholds triggered the pattern
// ─────────────────────────────────────────

private struct PDDetectionLogic: View {
    let snapshot: PatternDetailSnapshot

    private struct Condition: Identifiable {
        let id = UUID()
        let label:  String
        let detail: String
        let value:  String
    }

    private var conditions: [Condition] {
        let s = snapshot.score
        let d1 = s.d1Autonomic ?? 0
        let d2 = s.d2Sleep    ?? 0
        let d3 = s.d3Activity ?? 0
        let d4 = s.d4Stress   ?? 0

        switch snapshot.patternResult.pattern {
        case .loadOutpacingRecovery:
            return [
                Condition(label: "Activity load (D3) ≥ 80",
                          detail: "High physical output detected",
                          value: "\(Int(d3))"),
                Condition(label: "Autonomic recovery (D1) < 65",
                          detail: "Nervous system hasn't caught up",
                          value: "\(Int(d1))")
            ]
        case .hiddenStressSignal:
            return [
                Condition(label: "Stress signal (D4) < 65",
                          detail: "Stress accumulation beneath surface",
                          value: "\(Int(d4))"),
                Condition(label: "Sleep quality (D2) ≥ 75",
                          detail: "Sleep quality masking the signal",
                          value: "\(Int(d2))"),
                Condition(label: "Autonomic (D1) < 70",
                          detail: "HRV beginning to register stress",
                          value: "\(Int(d1))")
            ]
        case .sleepProtectingRecovery:
            return [
                Condition(label: "Sleep quality (D2) ≥ 80",
                          detail: "Elevated sleep driving recovery",
                          value: "\(Int(d2))"),
                Condition(label: "Autonomic (D1) < 70",
                          detail: "Nervous system absorbing the benefit",
                          value: "\(Int(d1))")
            ]
        case .systemsInAlignment:
            let scores = [d1, d2, d3].filter { $0 > 0 }
            let spread = Int((scores.max() ?? 0) - (scores.min() ?? 0))
            return [
                Condition(label: "All active domains ≥ 65",
                          detail: "No domain in deficit",
                          value: "✓"),
                Condition(label: "Domain spread ≤ 15 pts",
                          detail: "Systems moving together",
                          value: "\(spread) pts")
            ]
        case .recoveryUnderPressure:
            return [
                Condition(label: "Autonomic recovery (D1) < 60",
                          detail: "Nervous system under load",
                          value: "\(Int(d1))"),
                Condition(label: "Stress signal (D4) < 65",
                          detail: "Compound pressure from stress",
                          value: "\(Int(d4))")
            ]
        case .defaultPattern:
            return [
                Condition(label: "No dominant cross-domain signal",
                          detail: "Systems showing normal variation",
                          value: "—")
            ]
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

            VStack(alignment: .leading, spacing: 14) {
                Text("WHY THIS PATTERN WAS DETECTED")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.70))
                    .tracking(2.5)

                VStack(spacing: 12) {
                    ForEach(Array(conditions.prefix(2).enumerated()), id: \.element.id) { index, c in
                        HStack(alignment: .top, spacing: 12) {
                            // Numbered circle — Chronos Gold border
                            ZStack {
                                Circle()
                                    .stroke(ChronosTheme.gold.opacity(0.60), lineWidth: 1)
                                    .frame(width: 22, height: 22)
                                Text("\(index + 1)")
                                    .font(.jost(size: 10, weight: .medium))
                                    .foregroundColor(ChronosTheme.gold)
                            }
                            .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(c.label)
                                        .font(.jost(size: 12, weight: .medium))
                                        .foregroundColor(ChronosTheme.text)
                                    Spacer()
                                    Text(c.value)
                                        .font(.jost(size: 12, weight: .regular))
                                        .foregroundColor(ChronosTheme.gold)
                                }
                                Text(c.detail)
                                    .font(.jost(size: 11, weight: .light))
                                    .foregroundColor(ChronosTheme.muted)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}

// ─────────────────────────────────────────
// DOMAIN CONTRIBUTIONS
// Score bars for all active domains with role labels
// ─────────────────────────────────────────

private struct PDDomainContributions: View {
    let snapshot: PatternDetailSnapshot

    struct DomainRow: Identifiable {
        let id:     String
        let label:  String
        let title:  String
        let score:  Double?
        let role:   DomainRole
        let active: Bool
    }

    private var rows: [DomainRow] {
        let s  = snapshot.score
        let r  = snapshot.patternResult.roles
        let hd = snapshot.historyDayCount
        return [
            DomainRow(id: "D1", label: "D1", title: "Autonomic",   score: s.d1Autonomic, role: r["D1"] ?? .stable, active: true),
            DomainRow(id: "D2", label: "D2", title: "Sleep",        score: s.d2Sleep,     role: r["D2"] ?? .stable, active: true),
            DomainRow(id: "D3", label: "D3", title: "Activity",     score: s.d3Activity,  role: r["D3"] ?? .stable, active: true),
            DomainRow(id: "D4", label: "D4", title: "Stress",       score: s.d4Stress,    role: r["D4"] ?? .building, active: hd >= 7),
            DomainRow(id: "D5", label: "D5", title: "Allostatic",   score: s.d5Allostatic,role: r["D5"] ?? .building, active: hd >= 30),
        ]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 14) {
                Text("CONTRIBUTING DOMAINS")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.70))
                    .tracking(2.5)

                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        PDDomainBar(row: row)
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct PDDomainBar: View {
    let row: PDDomainContributions.DomainRow

    private var barColor: Color {
        guard let s = row.score else { return ChronosTheme.faint.opacity(0.25) }
        if s >= 80 { return Color(red: 0.29, green: 0.855, blue: 0.50) }
        if s >= 65 { return ChronosTheme.gold }
        if s >= 40 { return Color(red: 0.690, green: 0.576, blue: 0.416) }
        return Color(red: 0.878, green: 0.439, blue: 0.439)
    }

    private var roleLabel: String {
        switch row.role {
        case .driver:           return "DRAG"
        case .buffer:           return "ABOVE BASELINE"
        case .elevated:         return "STRONG"
        case .watch, .stable:   return "STABLE"
        case .building:         return "BUILDING"
        }
    }

    private var roleColor: Color {
        switch row.role {
        case .driver:           return Color(hex: "E07070")
        case .buffer:           return Color(hex: "4ADE80")
        case .elevated:         return Color(hex: "4ADE80").opacity(0.70)
        case .watch, .stable:   return ChronosTheme.muted
        case .building:         return ChronosTheme.faint
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(row.label)
                    .font(.jost(size: 10, weight: .medium))
                    .foregroundColor(ChronosTheme.gold.opacity(0.75))
                    .frame(width: 22, alignment: .leading)
                Text(row.title)
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                Spacer()
                Text(roleLabel)
                    .font(.jost(size: 9, weight: .medium))
                    .foregroundColor(roleColor)
                    .tracking(1)
                if let s = row.score {
                    Text("\(Int(s))")
                        .font(.jost(size: 12, weight: .regular))
                        .foregroundColor(ChronosTheme.text)
                        .frame(width: 30, alignment: .trailing)
                } else {
                    Text(row.active ? "—" : "···")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .frame(width: 30, alignment: .trailing)
                }
            }

            // Score bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ChronosTheme.faint.opacity(0.10))
                        .frame(height: 4)

                    if let s = row.score {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor.opacity(0.70))
                            .frame(width: geo.size.width * CGFloat(min(s / 100, 1.0)), height: 4)
                            .animation(.easeOut(duration: 0.4), value: s)
                    } else if !row.active {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ChronosTheme.faint.opacity(0.08))
                            .frame(width: geo.size.width * 0.35, height: 4)
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

// ─────────────────────────────────────────
// CONFLICT SECTION
// Expanded explanations of any cross-domain conflicts
// ─────────────────────────────────────────

private struct PDConflictSection: View {
    let conflicts: [ConflictResult]

    private func explanation(for conflict: ConflictResult) -> String {
        switch conflict.conflictType {
        case "compensation":
            return "When \(domainName(conflict.withDomain)) lags while \(domainName(conflict.hasDomain)) leads, the body is relying on one system to compensate for another. This can sustain performance short-term but creates a debt that accumulates if the gap isn't closed."
        case "suppression":
            return "\(domainName(conflict.hasDomain)) is elevated while \(domainName(conflict.withDomain)) is under pressure. High output in one system is actively taxing another — the pattern is self-limiting unless recovery keeps pace."
        default:
            return "Two systems are moving in opposing directions. Monitor whether the gap narrows over the next 2–3 days."
        }
    }

    private func domainName(_ label: String) -> String {
        switch label {
        case "D1": return "autonomic recovery"
        case "D2": return "sleep"
        case "D3": return "activity load"
        case "D4": return "stress"
        case "D5": return "allostatic trend"
        default:   return label
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.14, green: 0.10, blue: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(hex: "C9A84C").opacity(0.30), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 14) {
                Text("CROSS-DOMAIN TENSIONS")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(Color(hex: "C9A84C").opacity(0.80))
                    .tracking(2.5)

                VStack(spacing: 12) {
                    ForEach(conflicts, id: \.hasDomain) { conflict in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(conflict.badgeText)
                                .font(.jost(size: 12, weight: .medium))
                                .foregroundColor(ChronosTheme.text)

                            Text(explanation(for: conflict))
                                .font(.jost(size: 12, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}

// ─────────────────────────────────────────
// SUSTAINED PATTERN NOTE
// What this pattern means if it continues — deterministic copy
// ─────────────────────────────────────────

private struct PDSustainedNote: View {
    let pattern: DomainPattern

    private var noteText: String {
        switch pattern {
        case .loadOutpacingRecovery:
            return "If this pattern holds for more than 5–7 consecutive days, the autonomic deficit typically deepens. HRV suppression and elevated resting HR are early indicators. Chronos tracks this daily — the Horizon tab surfaces multi-day trajectory."
        case .hiddenStressSignal:
            return "Hidden stress signals are often masked by good sleep until HRV crosses a suppression threshold. If D4 remains below 65 for more than a week while D1 continues declining, the pattern moves from hidden to active. Watch the Autonomic domain for acceleration."
        case .sleepProtectingRecovery:
            return "Sleep-protected recovery patterns usually self-resolve within 3–5 days as the nervous system catches up. If D1 doesn't begin tracking toward D2 within that window, the pattern may indicate a chronic autonomic load that sleep alone cannot resolve."
        case .systemsInAlignment:
            return "Sustained alignment across all domains is the optimal state for training adaptation, cognitive output, and long-term health. This pattern indicates your recovery inputs are well-matched to your daily demands."
        case .recoveryUnderPressure:
            return "When both autonomic and stress systems are simultaneously suppressed, the recovery window shortens significantly. Prioritise sleep quality, reduce training load if applicable, and watch for continued D4 and D1 decline over the next 48 hours."
        case .defaultPattern:
            return "Normal daily variation. One domain is leading today's pattern without triggering a cross-domain signal. Chronos continues monitoring for emerging patterns across your full 5-domain profile."
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
                    Text("WHAT THIS MEANS TODAY")
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
