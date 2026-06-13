// ios/MBI/MBI/Views/HorizonTrajectoryView.swift
// MBI Phase 2 — Horizon · Trajectory Page
// Horizon Redesign Sprint — Page 2 (always visible, was conditional page4Active)
//
// Now always visible. Two modes:
//   CALM mode  — no active pathway signals. Shows AllostaticMomentumBar + compact PathwayMomentumRows.
//                Fully deterministic — no Claude call.
//   ACTIVE mode — 1+ active pathway signals. Shows existing TrajectoryPathwayCards (with Claude
//                 narrative) + compact CALM pathway rows below active cards.
//                 SystemRelationshipCard shown when 2+ pathways share non-HOLDING momentum state.
//
// Momentum computation migrated from HorizonMomentumView (retired from page array).
// Swipe discovery prompt rendered at bottom when page3Active (Redirect unlocked).
// Frame disclosure sentence required per Legal Framework §4.2.
// Hard constraints: no scores, no charts, no disease names, no backward language.

import SwiftUI

struct HorizonTrajectoryView: View {
    let assessment: HorizonAssessment

    @EnvironmentObject var supabase: SupabaseService

    // Narrative state — ACTIVE mode only
    @State private var narratives: [String: String] = [:]
    @State private var loadingNarratives: Set<String> = []

    // Momentum state — computed on appear
    @State private var overallMomentum:   MomentumState = .insufficient
    @State private var autonomicMomentum: MomentumState = .insufficient
    @State private var sleepMomentum:     MomentumState = .insufficient
    @State private var metabolicMomentum: MomentumState = .insufficient
    @State private var windowDays = 0
    @State private var isLoadingMomentum = true

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)
    private let green = Color(red: 0.40, green: 0.82, blue: 0.50)

    private var activeSignals: [(pathway: String, signal: HorizonSignal)] {
        [
            assessment.autonomic.map { ("autonomic", $0) },
            assessment.sleep.map     { ("sleep",     $0) },
            assessment.metabolic.map { ("metabolic", $0) }
        ]
        .compactMap { $0 }
        .filter { $0.signal.isActive }
    }

    private var isCalm: Bool { activeSignals.isEmpty }

    // SYSTEM RELATIONSHIP card: 2+ pathways in non-HOLDING momentum state
    private var shiftingStates: [MomentumState] {
        [autonomicMomentum, sleepMomentum, metabolicMomentum]
            .filter { $0 == .shifting || $0 == .building }
    }
    private var showSystemRelationship: Bool {
        !isLoadingMomentum && shiftingStates.count >= 2
    }

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [amber.opacity(0.04), .clear],
                center: .top, startRadius: 0, endRadius: 320
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    TrajectoryHeader(isCalm: isCalm)


                    if isCalm {
                        // ── CALM MODE ──────────────────────────────────────────

                        // Macro momentum bar
                        AllostaticMomentumBar(
                            state: overallMomentum,
                            isLoading: isLoadingMomentum,
                            windowDays: windowDays
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                        // Per-pathway compact rows
                        VStack(spacing: 10) {
                            PathwayMomentumRow(
                                pathway: "AUTONOMIC",
                                subtitle: "Nervous system · HRV · Heart rate",
                                state: autonomicMomentum,
                                isLoading: isLoadingMomentum,
                                signal: assessment.autonomic
                            )
                            PathwayMomentumRow(
                                pathway: "SLEEP",
                                subtitle: "Recovery · Duration · Quality",
                                state: sleepMomentum,
                                isLoading: isLoadingMomentum,
                                signal: assessment.sleep
                            )
                            PathwayMomentumRow(
                                pathway: "METABOLIC",
                                subtitle: "Activity · Movement · Energy",
                                state: metabolicMomentum,
                                isLoading: isLoadingMomentum,
                                signal: assessment.metabolic
                            )

                            if showSystemRelationship {
                                SystemRelationshipCard(
                                    autonomic: autonomicMomentum,
                                    sleep: sleepMomentum,
                                    metabolic: metabolicMomentum,
                                    assessment: assessment
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)

                    } else {
                        // ── ACTIVE MODE ─────────────────────────────────────────

                        // Active pathway cards with Claude narrative
                        VStack(spacing: 14) {
                            ForEach(activeSignals, id: \.pathway) { item in
                                TrajectoryPathwayCard(
                                    pathway: item.pathway,
                                    signal: item.signal,
                                    narrative: narratives[item.pathway],
                                    isLoadingNarrative: loadingNarratives.contains(item.pathway)
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                        // CALM pathways as compact rows (working in your favor)
                        if !assessment.calmPathwayLabels.isEmpty {
                            TrajectoryCounterweightSection(labels: assessment.calmPathwayLabels)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                        }

                        // Momentum rows below active cards
                        VStack(spacing: 10) {
                            PathwayMomentumRow(
                                pathway: "AUTONOMIC",
                                subtitle: "Nervous system · HRV · Heart rate",
                                state: autonomicMomentum,
                                isLoading: isLoadingMomentum,
                                signal: assessment.autonomic
                            )
                            PathwayMomentumRow(
                                pathway: "SLEEP",
                                subtitle: "Recovery · Duration · Quality",
                                state: sleepMomentum,
                                isLoading: isLoadingMomentum,
                                signal: assessment.sleep
                            )
                            PathwayMomentumRow(
                                pathway: "METABOLIC",
                                subtitle: "Activity · Movement · Energy",
                                state: metabolicMomentum,
                                isLoading: isLoadingMomentum,
                                signal: assessment.metabolic
                            )

                            if showSystemRelationship {
                                SystemRelationshipCard(
                                    autonomic: autonomicMomentum,
                                    sleep: sleepMomentum,
                                    metabolic: metabolicMomentum,
                                    assessment: assessment
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }

                    // Swipe discovery prompt — shown when Redirect page is unlocked
                    if assessment.page3Active {
                        TrajectorySwipePrompt()
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }
                }
            }
            .contentMargins(.top, 56, for: .scrollContent)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 32) }
        }
        .task {
            await fetchNarratives()
            await computeMomentum()
        }
    }

    // ─────────────────────────────────────────
    // NARRATIVE FETCH — ACTIVE mode only
    // ─────────────────────────────────────────

    private func fetchNarratives() async {
        let signals = activeSignals.filter { $0.signal.conditionClass != nil }
        guard !signals.isEmpty else { return }
        loadingNarratives = Set(signals.map { $0.pathway })
        let protectiveLabel = assessment.calmPathwayLabels.first

        await withTaskGroup(of: (String, String?).self) { group in
            for item in signals {
                guard let conditionClass = item.signal.conditionClass else { continue }
                let pathway = item.pathway
                let signal  = item.signal

                group.addTask {
                    let text = try? await supabase.fetchHorizonNarrative(
                        pathway: pathway,
                        conditionClass: conditionClass,
                        trajectoryLabel: signal.trajectoryLabel ?? "stable",
                        daysInPattern: signal.daysInPattern,
                        escalationLevel: signal.escalationLevel,
                        confidenceGate: signal.confidenceGate,
                        protectivePathway: protectiveLabel
                    )
                    return (pathway, text)
                }
            }

            for await (pathway, text) in group {
                loadingNarratives.remove(pathway)
                if let text { narratives[pathway] = text }
            }
        }
    }

    // ─────────────────────────────────────────
    // MOMENTUM COMPUTATION
    // Migrated from HorizonMomentumView.
    // ─────────────────────────────────────────

    private func computeMomentum() async {
        isLoadingMomentum = true
        defer { isLoadingMomentum = false }

        guard let userId = supabase.session?.userId,
              let rows = try? await supabase.fetchMomentumScores(userId: userId)
        else { return }

        windowDays = min(rows.count, 28)
        guard rows.count >= 14 else { return }

        let recent = Array(rows.suffix(14))
        let prior  = rows.count >= 28 ? Array(rows.prefix(rows.count - 14)) : []

        overallMomentum = MomentumState.compute(
            recent: recent.compactMap { ($0["chronos_score"] as? NSNumber)?.doubleValue },
            prior:  prior.compactMap  { ($0["chronos_score"] as? NSNumber)?.doubleValue }
        )
        autonomicMomentum = MomentumState.compute(
            recent: recent.compactMap { ($0["d1_autonomic"] as? NSNumber)?.doubleValue },
            prior:  prior.compactMap  { ($0["d1_autonomic"] as? NSNumber)?.doubleValue }
        )
        sleepMomentum = MomentumState.compute(
            recent: recent.compactMap { ($0["d2_sleep"] as? NSNumber)?.doubleValue },
            prior:  prior.compactMap  { ($0["d2_sleep"] as? NSNumber)?.doubleValue }
        )
        metabolicMomentum = MomentumState.compute(
            recent: recent.compactMap { ($0["d3_activity"] as? NSNumber)?.doubleValue },
            prior:  prior.compactMap  { ($0["d3_activity"] as? NSNumber)?.doubleValue }
        )
    }
}

// ─────────────────────────────────────────
// TRAJECTORY HEADER
// Adapts copy for CALM vs ACTIVE mode.
// ─────────────────────────────────────────

private struct TrajectoryHeader: View {
    let isCalm: Bool

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRAJECTORY")
                .font(.jost(size: 11, weight: .medium))
                .foregroundColor(amber)
                .tracking(3)

            Text(isCalm ? "How the pattern is moving." : "Where does this lead.")
                .font(.cormorant(size: 34, weight: .regular))
                .foregroundColor(ChronosTheme.text)

            Text(isCalm
                 ? "14-day rolling comparison against your own baseline. Not a score — a direction."
                 : "Patterns that persist become pathways. Here's what's forming — and what changes the outcome.")
                .font(.jost(size: 15, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            // Frame disclosure — Legal Framework §4.2
            Text("Chronos identifies changes in wellness measurements you choose to track. This screen does not diagnose, treat, or assess disease.")
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(ChronosTheme.faint.opacity(0.55))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 24)
    }
}

// ─────────────────────────────────────────
// ALLOSTATIC MOMENTUM BAR (migrated from HorizonMomentumView)
// ─────────────────────────────────────────

struct AllostaticMomentumBar: View {
    let state: MomentumState
    let isLoading: Bool
    let windowDays: Int

    @State private var barProgress: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack {
                Text("ALLOSTATIC MOMENTUM")
                    .font(.jost(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.28))
                    .tracking(2)
                Spacer()
                if windowDays > 0 && !isLoading {
                    Text("\(min(windowDays, 28))-day window")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(Color.white.opacity(0.20))
                }
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.55).tint(Color.white.opacity(0.22))
                    Text("Computing...")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: state.icon)
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundColor(state.color)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.label.uppercased())
                            .font(.jost(size: 28, weight: .semibold))
                            .foregroundColor(state.color)
                            .tracking(2)
                        Text(state.description)
                            .font(.jost(size: 15, weight: .regular))
                            .foregroundColor(ChronosTheme.faint)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Animated directional fill bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(state.color)
                            .frame(width: geo.size.width * barProgress, height: 6)
                            .shadow(color: state.color.opacity(0.38), radius: 6, x: 0, y: 0)
                    }
                }
                .frame(height: 6)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.85).delay(0.12)) {
                        barProgress = state.barFill
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(state.color.opacity(isLoading ? 0.08 : 0.22), lineWidth: 1.5)
                )
        )
    }
}

// ─────────────────────────────────────────
// PATHWAY MOMENTUM ROW (migrated from HorizonMomentumView)
// ─────────────────────────────────────────

struct PathwayMomentumRow: View {
    let pathway: String
    let subtitle: String
    let state: MomentumState
    let isLoading: Bool
    let signal: HorizonSignal?

    private var trajectoryStatement: String? {
        let s = signal
        let days = s?.daysInPattern ?? 0
        let dayWord = days == 1 ? "day" : "days"

        switch state {
        case .shifting:
            if let active = s, active.isActive, days > 0 {
                if let label = active.trajectoryLabel {
                    return "\(label) · \(days) \(dayWord)"
                }
                return "Shifting for \(days) \(dayWord)"
            }
            return days > 0 ? "Shifting · \(days) \(dayWord)" : nil

        case .building:
            return days > 0 ? "Improving · \(days) \(dayWord)" : nil

        case .holding:
            if let active = s, active.isActive { return nil }
            return days > 0 ? "Stable · \(days) \(dayWord)" : nil

        case .insufficient:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isLoading ? Color.white.opacity(0.10) : state.color.opacity(0.70))
                .frame(width: 4, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(pathway)
                    .font(.jost(size: 13, weight: .semibold))
                    .foregroundColor(ChronosTheme.text)
                    .tracking(1.2)
                Text(subtitle)
                    .font(.jost(size: 12, weight: .regular))
                    .foregroundColor(ChronosTheme.faint)
            }

            Spacer()

            if isLoading {
                ProgressView().scaleEffect(0.48).tint(Color.white.opacity(0.20))
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: state.icon)
                            .font(.system(size: 10, weight: .light))
                            .foregroundColor(state.color)
                        Text(state.label)
                            .font(.jost(size: 12, weight: .regular))
                            .foregroundColor(state.color)
                    }
                    if let stmt = trajectoryStatement {
                        Text(stmt)
                            .font(.jost(size: 9, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }
}

// ─────────────────────────────────────────
// SYSTEM RELATIONSHIP CARD
// Promoted from CompoundingEffectNote (was a footnote in HorizonMomentumView).
// Shown when 2+ pathways share same non-HOLDING momentum state.
// Chronos Gold left border treatment.
// ─────────────────────────────────────────

struct SystemRelationshipCard: View {
    let autonomic: MomentumState
    let sleep:     MomentumState
    let metabolic: MomentumState
    let assessment: HorizonAssessment

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    private var compoundText: String? {
        let shifting = [autonomic, sleep, metabolic].filter { $0 == .shifting }.count
        let building = [autonomic, sleep, metabolic].filter { $0 == .building }.count
        let nonHolding = [autonomic, sleep, metabolic].filter { $0 != .holding && $0 != .insufficient }

        guard nonHolding.count >= 2 else { return nil }

        // Horizon compound class takes priority when available
        let signals = [assessment.autonomic, assessment.sleep, assessment.metabolic]
            .compactMap { $0 }
            .filter { $0.isActive }

        if let compound = signals.first(where: {
            $0.conditionClass == "full_system_load" ||
            $0.conditionClass == "combined_autonomic_sleep" ||
            $0.conditionClass == "combined_metabolic_sleep"
        }) {
            switch compound.conditionClass {
            case "full_system_load":
                return "All three systems shifting simultaneously — systemic resilience is under pressure. When pathways compound, the downstream effect exceeds the sum of individual signals."
            case "combined_autonomic_sleep":
                return "Autonomic and sleep pathways shifting together — recovery capacity is compounding. These two systems regulate each other; disruption in one accelerates the other."
            case "combined_metabolic_sleep":
                return "Sleep and metabolic pathways shifting together — restorative load is accumulating. Sleep is when metabolic repair occurs; fragmentation here compounds the metabolic signal."
            default:
                break
            }
        }

        // Momentum-only fallbacks
        if shifting >= 2 {
            if shifting == 3 { return "All three systems shifting simultaneously. Compound signals carry greater weight than isolated pathway changes." }
            let aS = autonomic == .shifting
            let sS = sleep == .shifting
            let mS = metabolic == .shifting
            if aS && sS { return "Autonomic and sleep shifting together — recovery capacity compounds when both are under pressure." }
            if aS && mS { return "Autonomic and metabolic shifting together — load accumulation across systems is building." }
            if sS && mS { return "Sleep and metabolic shifting together — restorative capacity is under compounding pressure." }
        }
        if building >= 2 {
            return "Multiple systems building simultaneously. Compound momentum amplifies resilience gains."
        }

        return nil
    }

    var body: some View {
        if let text = compoundText {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(amber)
                    .frame(width: 4)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("SYSTEM RELATIONSHIP")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(amber.opacity(0.65))
                        .tracking(1.8)
                    Text(text)
                        .font(.jost(size: 15, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(amber.opacity(0.20), lineWidth: 1)
                    )
            )
        }
    }
}

// ─────────────────────────────────────────
// TRAJECTORY SWIPE PROMPT
// Shown at bottom of Trajectory when Redirect (page3Active) is unlocked.
// Tapping does not navigate — communicates swipe gesture availability.
// ─────────────────────────────────────────

private struct TrajectorySwipePrompt: View {
    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Text("Redirect options available")
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(ChronosTheme.faint)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .light))
                .foregroundColor(amber.opacity(0.50))
        }
        .padding(.trailing, 4)
    }
}

// ─────────────────────────────────────────
// TRAJECTORY PATHWAY CARD (unchanged from prior sprint)
// One card per active HorizonSignal — ACTIVE mode only.
// ─────────────────────────────────────────

private struct TrajectoryPathwayCard: View {
    let pathway: String
    let signal: HorizonSignal
    let narrative: String?
    let isLoadingNarrative: Bool

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    private var pathwayInfo: (label: String, subtitle: String) {
        switch pathway {
        case "autonomic": return ("AUTONOMIC", "Nervous system · HRV · Heart rate")
        case "sleep":     return ("SLEEP",     "Recovery · Duration · Quality")
        case "metabolic": return ("METABOLIC", "Activity · Movement · Energy")
        default:          return (pathway.uppercased(), "")
        }
    }

    private var wellnessLabel: String {
        switch signal.conditionClass ?? "" {
        case "autonomic_stress_load":         return "Autonomic System Under Pressure"
        case "sleep_architecture_disruption": return "Sleep Architecture Under Pressure"
        case "metabolic_inactivity_load":     return "Metabolic Recovery Window"
        case "combined_autonomic_sleep":      return "Recovery Capacity Under Pressure"
        case "combined_metabolic_sleep":      return "Restorative Load Accumulating"
        case "full_system_load":              return "Systemic Resilience Under Pressure"
        case "autonomic_dysfunction_early":   return "Autonomic Load Accumulating"
        case "sleep_fragmentation_early":     return "Sleep Architecture Under Pressure"
        case "metabolic_risk_inferred":       return "Metabolic Stress Building"
        default: return signal.trajectoryLabel ?? "Pattern Detected"
        }
    }

    private var escalationPhrase: String {
        switch signal.escalationLevel {
        case 1:  return "PATTERN DETECTED"
        case 2:  return "PATTERN SUSTAINED"
        case 3:  return "PATTERN DEEPENING"
        default: return "MONITORING"
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(amber.opacity(0.40), lineWidth: 1.5)
                )
                .shadow(color: amber.opacity(0.06), radius: 12, x: 0, y: 4)

            HStack(alignment: .top, spacing: 14) {

                RoundedRectangle(cornerRadius: 3)
                    .fill(amber)
                    .frame(width: 6)
                    .padding(.vertical, 6)
                    .shadow(color: amber.opacity(0.4), radius: 4, x: -2, y: 0)

                VStack(alignment: .leading, spacing: 12) {

                    HStack(alignment: .center, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pathwayInfo.label)
                                .font(.jost(size: 13, weight: .semibold))
                                .foregroundColor(ChronosTheme.text)
                                .tracking(1.5)
                            Text(pathwayInfo.subtitle)
                                .font(.jost(size: 12, weight: .regular))
                                .foregroundColor(ChronosTheme.faint)
                        }
                        Spacer()
                        Text(escalationPhrase)
                            .font(.jost(size: 11, weight: .semibold))
                            .foregroundColor(amber)
                            .tracking(1.2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(amber.opacity(0.15))
                                    .overlay(Capsule().stroke(amber.opacity(0.40), lineWidth: 1))
                            )
                    }

                    Text(wellnessLabel)
                        .font(.cormorant(size: 24, weight: .regular))
                        .foregroundColor(amber.opacity(0.90))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .light))
                            .foregroundColor(amber.opacity(0.55))
                        Text("Building for \(signal.daysInPattern) \(signal.daysInPattern == 1 ? "day" : "days")")
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(amber.opacity(0.70))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("SIGNAL CONFIDENCE")
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                                .tracking(1.2)
                            Spacer()
                            Text("\(Int(signal.confidenceGate * 100))%")
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(amber.opacity(0.55))
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 3)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(amber.opacity(0.55))
                                    .frame(width: geo.size.width * signal.confidenceGate, height: 3)
                            }
                        }
                        .frame(height: 3)
                    }

                    Rectangle()
                        .fill(amber.opacity(0.12))
                        .frame(height: 1)

                    if isLoadingNarrative {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.55)
                                .tint(amber.opacity(0.4))
                            Text("Reading trajectory...")
                                .font(.jost(size: 12, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    } else if let text = narrative {
                        Text(text)
                            .font(.jost(size: 15, weight: .regular))
                            .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.85))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 16)
            }
            .padding(.vertical, 16)
            .padding(.leading, 14)
        }
    }
}

// ─────────────────────────────────────────
// COUNTERWEIGHT SECTION (unchanged — ACTIVE mode only)
// ─────────────────────────────────────────

private struct TrajectoryCounterweightSection: View {
    let labels: [String]

    private let green = Color(red: 0.40, green: 0.82, blue: 0.50)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(green)
                        .frame(width: 5, height: 5)
                    Text("WORKING IN YOUR FAVOR")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(green)
                        .tracking(2)
                }
                Text("These signals are actively countering the pattern above.")
                    .font(.jost(size: 15, weight: .regular))
                    .foregroundColor(ChronosTheme.faint)
                    .lineSpacing(3)
            }

            VStack(spacing: 10) {
                ForEach(labels, id: \.self) { label in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(green.opacity(0.70))
                        Text(label.capitalized)
                            .font(.jost(size: 15, weight: .regular))
                            .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.80))
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.06, green: 0.12, blue: 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(green.opacity(0.20), lineWidth: 1)
                    )
            )
        }
    }
}
