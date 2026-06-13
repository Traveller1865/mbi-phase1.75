// ios/MBI/MBI/Views/HorizonView.swift
// MBI Phase 1.5 — Horizon · Signal Surface
// Epic 1 Sprint 3 — Page 1 Redesign
//
// HorizonSignalView is Page 1 of HorizonModuleView.
// This file owns: HorizonSignalView, HorizonPathwayCard (+ model),
// HorizonHeader, AlphaBadge, SignalSectionHeader, HorizonSignalCardView,
// HorizonEmptyView, LaneState.
//
// What changed in Sprint 3:
//   - PathwaySection / PathwayLane replaced by three HorizonPathwayCards
//   - Score numbers removed from pathway cards entirely (hard requirement)
//   - "BASED ON TODAY'S DATA" → "READING YOUR CURRENT TRAJECTORY"
//   - ELEVATED card treatment: 6pt amber bar + glow + 1.5pt amber border (Option B)
//   - CALM card treatment: 4pt green bar, standard 1pt border
//   - Unique trajectory line + CTA per pathway per state (spec copy locked)
//   - HorizonPathwayCard data model extended with Phase 1.75 fields (all nil in Sprint 3)
//   - Duplicate CTA copy ("Keep this going — it's actively countering accumulated load.")
//     replaced with unique per-pathway CTAs per handoff §4.3.3

import SwiftUI

// ─────────────────────────────────────────
// LANE STATE
// Derived from domain score threshold only.
// CALM ≥ 70 | ELEVATED 50–69 | FLAGGED < 50
// ─────────────────────────────────────────

enum LaneState {
    case calm
    case elevated   // renamed from .active for clarity — maps to ELEVATED badge
    case flagged

    init(score: Double?) {
        guard let s = score else { self = .calm; return }
        if s >= 70      { self = .calm }
        else if s >= 50 { self = .elevated }
        else            { self = .flagged }
    }

    // Sprint 3 card treatment
    var isAlert: Bool {
        switch self {
        case .calm:              return false
        case .elevated, .flagged: return true
        }
    }

    var accentColor: Color {
        switch self {
        case .calm:              return Color(red: 0.40, green: 0.82, blue: 0.50)
        case .elevated, .flagged: return Color(red: 1.0, green: 0.75, blue: 0.35)
        }
    }

    // Accent bar width per Option B spec
    var barWidth: CGFloat {
        switch self {
        case .calm:              return 4
        case .elevated, .flagged: return 6
        }
    }

    var badgeLabel: String {
        switch self {
        case .calm:    return "CALM"
        case .elevated: return "ELEVATED"
        case .flagged:  return "FLAGGED"
        }
    }
}

// ─────────────────────────────────────────
// HORIZON PATHWAY CARD MODEL
// Sprint 3 fields are populated.
// Phase 1.75 fields are all nil — card renders identically when nil.
// Do not add display logic for Phase 1.75 fields in this sprint.
// ─────────────────────────────────────────

struct HorizonPathwayCardData: Identifiable {
    let id = UUID()

    // Sprint 3 — required
    let pathwayKey: String       // "autonomic" | "sleep" | "metabolic"
    let pathwayLabel: String     // "AUTONOMIC"
    let pathwaySubtitle: String  // "Nervous system · HRV · Heart rate"
    let score: Double?           // used only for state derivation — never displayed
    let trajectoryLine: String   // forward-facing sentence
    let ctaLine: String          // domain-specific closing line

    // Phase 1.75 — all nil in Sprint 3
    // When populated, card gains additional display logic without rebuild.
    var trajectoryLabel: String? = nil   // e.g. "Metabolic load building"
    var conditionClass: String? = nil    // e.g. "metabolic_stress_early"
    var escalationLevel: Int? = nil      // 0=none 1=self-redirect 2=monitor 3=doctor
    var confidenceGate: Double? = nil    // 0.0–1.0 min confidence for ontology output
    var daysInPattern: Int? = nil        // consecutive days pattern detected

    /// Authoritative state from pathway_classifications.state (Ontology Engine v1).
    /// When present, this overrides the score-derived LaneState.
    var dbState: String? = nil           // "CALM" | "ELEVATED" | "FLAGGED"

    /// State used for card rendering.
    /// Reads dbState first (written by ontology-classify).
    /// Falls back to score-derived threshold only when dbState is absent.
    var state: LaneState {
        switch dbState {
        case "ELEVATED": return .elevated
        case "FLAGGED":  return .flagged
        case "CALM":     return .calm
        default:         return LaneState(score: score)
        }
    }
}

// ─────────────────────────────────────────
// HORIZON SIGNAL CARD MODEL (watch / protective sections)
// Unchanged from prior sprint — kept for signal card sections below pathway cards.
// ─────────────────────────────────────────

struct HorizonSignalCard: Identifiable {
    let id = UUID()
    let metricKey: String
    let metricLabel: String
    let direction: String
    let daysCount: Int
    let isWatch: Bool
    let bodyText: String
    let ctaText: String
}

// ─────────────────────────────────────────
// HORIZON SIGNAL VIEW — Page 1
// ─────────────────────────────────────────

struct HorizonSignalView: View {
    let assessment: HorizonAssessment

    @EnvironmentObject var sync: SyncCoordinator
    @EnvironmentObject var supabase: SupabaseService

    @State private var baselines: [String: Double] = [:]
    @State private var streaks: [String: Int] = [:]
    @State private var isLoading = true
    @State private var showFoundations = false

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [ChronosTheme.gold.opacity(0.04), .clear],
                center: .top, startRadius: 0, endRadius: 340
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    HorizonHeader(onInfoTap: { showFoundations = true })


                    // Alpha banner — always visible, never hidden
                    AlphaBadge()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                    // Beta transparency strip — collapsible, persists via AppStorage
                    HorizonBetaTransparencyStrip()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)

                    if let score = sync.dashboard?.score {

                        // ── Primary Read Card — CALM or FLAGGED ──────────────
                        PrimaryHorizonReadCard(assessment: assessment)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)

                        // ── Three Pathway Cards (Sprint 3 redesign) ──────────
                        VStack(spacing: 10) {
                            ForEach(buildPathwayCards(score: score)) { card in
                                HorizonPathwayCardView(data: card)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)

                        if isLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .scaleEffect(0.65)
                                    .tint(ChronosTheme.gold.opacity(0.4))
                                Text("Reading your signals...")
                                    .font(.jost(size: 12, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)

                        } else {
                            let watchCards = buildWatchCards(score: score)
                            let protectiveCards = buildProtectiveCards(score: score)

                            // ── Patterns Worth Watching ──────────────────────
                            if !watchCards.isEmpty {
                                SignalSectionHeader(
                                    title: "Patterns worth watching",
                                    subtitle: "Building early. Still fully reversible.",
                                    isWatch: true
                                )
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)

                                VStack(spacing: 10) {
                                    ForEach(watchCards) { card in
                                        HorizonSignalCardView(card: card)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 20)
                            }

                            // ── Working In Your Favor ────────────────────────
                            SignalSectionHeader(
                                title: "Working in your favor",
                                subtitle: "These signals are actively countering load.",
                                isWatch: false
                            )
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)

                            VStack(spacing: 10) {
                                ForEach(protectiveCards) { card in
                                    HorizonSignalCardView(card: card)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 64) // extra bottom pad for page indicator clearance
                        }

                    } else {
                        HorizonEmptyView()
                            .padding(.top, 60)
                    }
                }
            }
            .contentMargins(.top, 56, for: .scrollContent)
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 32) }
        .task {
            guard let userId = supabase.session?.userId else {
                isLoading = false
                return
            }
            await loadSignalData(userId: userId)
        }
        .sheet(isPresented: $showFoundations) {
            HorizonFoundationsView()
        }
    }

    // ─────────────────────────────────────────
    // PATHWAY CARD BUILDER
    // Sprint 3: copy is locked per handoff §4.3.3.
    // State derived from domain scores — never displayed as numbers.
    // ─────────────────────────────────────────

    private func buildPathwayCards(score: DailyScore) -> [HorizonPathwayCardData] {
        [
            autonomicCard(score: score.d1Autonomic, dbState: assessment.autonomic?.dbState),
            sleepCard(score: score.d2Sleep,         dbState: assessment.sleep?.dbState),
            metabolicCard(score: score.d3Activity,  dbState: assessment.metabolic?.dbState)
        ]
    }

    private func autonomicCard(score: Double?, dbState: String?) -> HorizonPathwayCardData {
        let resolvedState = resolveState(dbState: dbState, score: score)
        return HorizonPathwayCardData(
            pathwayKey: "autonomic",
            pathwayLabel: "AUTONOMIC",
            pathwaySubtitle: "Nervous system · HRV · Heart rate",
            score: score,
            trajectoryLine: resolvedState.isAlert
                ? "Your nervous system is carrying elevated load. This pattern, if sustained, compounds into systemic stress."
                : "Your nervous system is balanced. This is building resilience that compounds over time.",
            ctaLine: resolvedState.isAlert
                ? "Early redirection is still fully available."
                : "Keep this going — autonomic balance is your body's primary defense against load accumulation.",
            dbState: dbState
        )
    }

    private func sleepCard(score: Double?, dbState: String?) -> HorizonPathwayCardData {
        let resolvedState = resolveState(dbState: dbState, score: score)
        return HorizonPathwayCardData(
            pathwayKey: "sleep",
            pathwayLabel: "SLEEP",
            pathwaySubtitle: "Recovery · Duration · Quality",
            score: score,
            trajectoryLine: resolvedState.isAlert
                ? "Your recovery window is incomplete. Sleep debt compounds faster than it resolves."
                : "Your body is completing its repair window. Sleep quality is the foundation everything else builds on.",
            ctaLine: resolvedState.isAlert
                ? "Early redirection is still fully available."
                : "Keep this going — consistent sleep quality is the single highest-leverage signal in your health trajectory.",
            dbState: dbState
        )
    }

    private func metabolicCard(score: Double?, dbState: String?) -> HorizonPathwayCardData {
        let resolvedState = resolveState(dbState: dbState, score: score)
        return HorizonPathwayCardData(
            pathwayKey: "metabolic",
            pathwayLabel: "METABOLIC",
            pathwaySubtitle: "Activity · Movement · Energy",
            score: score,
            trajectoryLine: resolvedState.isAlert
                ? "Your activity load has been reduced. This pattern, if it continues, begins compounding metabolic load upstream."
                : "Your activity and movement signals are balanced. This is actively protecting your metabolic trajectory.",
            ctaLine: resolvedState.isAlert
                ? "Early redirection is still fully available."
                : "Keep this going — sustained movement consistency is your primary metabolic upstream defense.",
            dbState: dbState
        )
    }

    /// Resolves the display state for copy selection.
    /// Uses dbState (ontology engine) when present; falls back to score threshold.
    private func resolveState(dbState: String?, score: Double?) -> LaneState {
        switch dbState {
        case "ELEVATED": return .elevated
        case "FLAGGED":  return .flagged
        case "CALM":     return .calm
        default:         return LaneState(score: score)
        }
    }

    // ─────────────────────────────────────────
    // DATA LOADING
    // ─────────────────────────────────────────

    private func loadSignalData(userId: String) async {
        do {
            baselines = try await supabase.fetchLatestBaselines(userId: userId)
        } catch {
            print("[HorizonSignalView] baselines load failed: \(error)")
        }

        // Streak fetch is best-effort — failure does not block signal card rendering.
        // Cards render with daysCount = 1 if streak is unavailable.
        if let score = sync.dashboard?.score {
            do {
                let d1Streak = try await supabase.fetchDriverStreak(
                    userId: userId, todayDriver: score.driver1)
                streaks[score.driver1] = d1Streak
            } catch {
                print("[HorizonSignalView] d1 streak load failed (non-blocking): \(error)")
            }
            do {
                let d2Streak = try await supabase.fetchDriverStreak(
                    userId: userId, todayDriver: score.driver2)
                streaks[score.driver2] = d2Streak
            } catch {
                print("[HorizonSignalView] d2 streak load failed (non-blocking): \(error)")
            }
        }

        isLoading = false
    }

    // ─────────────────────────────────────────
    // WATCH CARD BUILDER (unchanged logic)
    // ─────────────────────────────────────────

    private func buildWatchCards(score: DailyScore) -> [HorizonSignalCard] {
        var cards: [HorizonSignalCard] = []
        let candidates: [(key: String, label: String, metricKey: String, score: Double?)] = [
            ("autonomic", "Autonomic Recovery",   "hrv",            score.d1Autonomic),
            ("sleep",     "Sleep Recovery",       "sleep_duration", score.d2Sleep),
            ("activity",  "Activity Load",        "steps",          score.d3Activity),
        ]
        for c in candidates {
            let state = LaneState(score: c.score)
            let streak = streaks[c.metricKey] ?? 0
            guard state.isAlert || streak >= 3 else { continue }
            let days = max(streak, 1)
            let direction: String = {
                switch c.key {
                case "autonomic": return "suppressed"
                case "sleep":     return "shortened"
                case "activity":  return "reduced"
                default:          return "elevated"
                }
            }()
            cards.append(HorizonSignalCard(
                metricKey: c.metricKey,
                metricLabel: c.label,
                direction: direction,
                daysCount: days,
                isWatch: true,
                bodyText: "Your \(c.label.lowercased()) has been \(direction) for \(days) \(days == 1 ? "day" : "days"). This pattern is early and still fully reversible.",
                ctaText: watchCTA(for: c.key)
            ))
            if cards.count >= 3 { break }
        }
        return cards
    }

    // ─────────────────────────────────────────
    // PROTECTIVE CARD BUILDER
    // Sprint 3: unique CTA per pathway (fixes duplicate copy from prior sprint)
    // ─────────────────────────────────────────

    private func buildProtectiveCards(score: DailyScore) -> [HorizonSignalCard] {
        var cards: [HorizonSignalCard] = []
        let candidates: [(key: String, label: String, metricKey: String, score: Double?)] = [
            ("autonomic", "Autonomic Recovery",   "hrv",            score.d1Autonomic),
            ("sleep",     "Sleep Recovery",       "sleep_duration", score.d2Sleep),
            ("activity",  "Activity Load",        "steps",          score.d3Activity),
        ]
        for c in candidates {
            guard LaneState(score: c.score) == .calm else { continue }
            cards.append(HorizonSignalCard(
                metricKey: c.metricKey,
                metricLabel: c.label,
                direction: "above baseline",
                daysCount: 1,
                isWatch: false,
                bodyText: protectiveBody(for: c.key),
                ctaText: protectiveCTA(for: c.key)
            ))
        }
        // Fallback: if no domain is calm, surface the strongest
        if cards.isEmpty, let best = candidates.filter({ $0.score != nil })
            .max(by: { ($0.score ?? 0) < ($1.score ?? 0) }) {
            cards.append(HorizonSignalCard(
                metricKey: best.metricKey,
                metricLabel: best.label,
                direction: "leading",
                daysCount: 1,
                isWatch: false,
                bodyText: "Your \(best.label.lowercased()) is your strongest signal right now. Building on this is the fastest path back to full recovery.",
                ctaText: "One good session here shifts the trajectory."
            ))
        }
        return cards
    }

    // ─────────────────────────────────────────
    // COPY HELPERS
    // ─────────────────────────────────────────

    private func watchCTA(for key: String) -> String {
        switch key {
        case "autonomic": return "Early redirection is still fully available."
        case "sleep":     return "Early redirection is still fully available."
        case "activity":  return "Early redirection is still fully available."
        default:          return "Small, consistent actions are what move this signal."
        }
    }

    private func protectiveBody(for key: String) -> String {
        switch key {
        case "autonomic":
            return "Your autonomic recovery is working in your favor. Strong HRV means your nervous system is balanced and adaptive — this is actively building your resilience."
        case "sleep":
            return "Your sleep recovery is working in your favor. Your body is completing its repair window — this is the foundation everything else builds on."
        case "activity":
            return "Your activity load is working in your favor. Consistent movement is keeping your metabolic and cardiovascular systems engaged and resilient."
        default:
            return "This signal is working in your favor. It is actively countering accumulated load."
        }
    }

    private func protectiveCTA(for key: String) -> String {
        switch key {
        case "autonomic": return "Keep this going — autonomic balance is your body's primary defense against load accumulation."
        case "sleep":     return "Keep this going — consistent sleep quality is the single highest-leverage signal in your health trajectory."
        case "activity":  return "Keep this going — sustained movement consistency is your primary metabolic upstream defense."
        default:          return "Keep this going — it's actively countering accumulated load."
        }
    }
}

// ─────────────────────────────────────────
// HORIZON PATHWAY CARD VIEW
// Option B treatment:
//   CALM: 4pt green bar, 1pt border white@10%
//   ELEVATED/FLAGGED: 6pt amber bar + glow, 1.5pt amber border@50%
// Score numbers: NEVER rendered.
// ─────────────────────────────────────────

struct HorizonPathwayCardView: View {
    let data: HorizonPathwayCardData

    @State private var isExpanded = false

    private var state: LaneState { data.state }
    private var accent: Color { state.accentColor }

    var body: some View {
        ZStack(alignment: .leading) {
            // Card background
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            state.isAlert
                                ? accent.opacity(0.50)
                                : Color.white.opacity(0.10),
                            lineWidth: state.isAlert ? 1.5 : 1.0
                        )
                )

            HStack(alignment: .top, spacing: 14) {

                // Left accent bar
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .frame(width: state.barWidth)
                    .padding(.vertical, 6)
                    .shadow(color: state.isAlert ? accent.opacity(0.4) : .clear,
                            radius: 4, x: -2, y: 0)

                VStack(alignment: .leading, spacing: 10) {

                    // Header row — always visible (tap target)
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
                    } label: {
                        HStack(alignment: .center, spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(data.pathwayLabel)
                                    .font(.jost(size: 13, weight: .semibold))
                                    .foregroundColor(ChronosTheme.text)
                                    .tracking(1.5)
                                Text(data.pathwaySubtitle)
                                    .font(.jost(size: 12, weight: .regular))
                                    .foregroundColor(ChronosTheme.faint)
                            }
                            Spacer()
                            // State badge
                            Text(state.badgeLabel)
                                .font(.jost(size: 11, weight: .semibold))
                                .foregroundColor(accent)
                                .tracking(1.5)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(accent.opacity(0.15))
                                        .overlay(
                                            Capsule()
                                                .stroke(
                                                    accent.opacity(state.isAlert ? 0.5 : 0.25),
                                                    lineWidth: state.isAlert ? 1 : 0
                                                )
                                        )
                                )
                            // Chevron
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                                .padding(.leading, 10)
                        }
                    }
                    .buttonStyle(.plain)

                    // Expanded content
                    if isExpanded {
                        Rectangle()
                            .fill(accent.opacity(0.12))
                            .frame(height: 1)

                        // Trajectory line
                        Text(data.trajectoryLine)
                            .font(.jost(size: 15, weight: .regular))
                            .foregroundColor(
                                state.isAlert
                                    ? accent.opacity(0.90)
                                    : Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.85)
                            )
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)

                        // CTA line
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: state.isAlert
                                  ? "arrow.triangle.turn.up.right.diamond"
                                  : "checkmark.circle")
                                .font(.system(size: 10, weight: .light))
                                .foregroundColor(accent.opacity(0.7))
                                .padding(.top, 1)
                            Text(data.ctaLine)
                                .font(.jost(size: 14, weight: .regular))
                                .foregroundColor(accent.opacity(0.85))
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.trailing, 16)
            }
            .padding(.vertical, 14)
            .padding(.leading, 14)
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }
}

// ─────────────────────────────────────────
// HORIZON HEADER
// "BASED ON TODAY'S DATA" → "READING YOUR CURRENT TRAJECTORY"
// All other copy unchanged — locked per handoff §4.3.1
// ─────────────────────────────────────────

struct HorizonHeader: View {
    var onInfoTap: (() -> Void)? = nil

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Eyebrow row — info button sits inline on the right
            HStack(alignment: .center, spacing: 0) {
                Text("HORIZON")
                    .font(.jost(size: 11, weight: .medium))
                    .foregroundColor(ChronosTheme.gold)
                    .tracking(3)

                Spacer()

                if let tap = onInfoTap {
                    Button(action: tap) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(amber.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("What's building upstream.")
                .font(.cormorant(size: 34, weight: .regular))
                .foregroundColor(ChronosTheme.text)

            Text("Patterns today that become conditions tomorrow — surfaced early, while they're still reversible.")
                .font(.jost(size: 15, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }
}

// ─────────────────────────────────────────
// ALPHA BADGE — unchanged, always visible
// ─────────────────────────────────────────

// ─────────────────────────────────────────
// HORIZON BETA TRANSPARENCY STRIP
// Replaces HorizonBetaTransparencyCard.
// Collapsible — first launch: expanded. After first collapse: stays collapsed.
// Persisted via @AppStorage("horizonDisclosureCollapsed").
// ─────────────────────────────────────────

struct HorizonBetaTransparencyStrip: View {
    @AppStorage("horizonDisclosureCollapsed") private var collapsed = false

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header row — always visible ──
            Button {
                withAnimation(.easeInOut(duration: 0.20)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.shield.checkmark")
                        .font(.system(size: 11, weight: .light))
                        .foregroundColor(amber.opacity(0.65))
                    Text("ABOUT HORIZON")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(amber.opacity(0.65))
                        .tracking(2)
                    Spacer()
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)

            // ── Expanded body ──
            if !collapsed {
                Rectangle()
                    .fill(amber.opacity(0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 8) {
                    Text("If Chronos detects a sustained low-score trend, the Mynd & Bodi team may reach out. This is a human safety check — it only occurs if your data suggests you may benefit from support.")
                        .font(.jost(size: 15, weight: .regular))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("You can turn this off in Account → Privacy.")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 13)
                .padding(.top, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(amber.opacity(0.16), lineWidth: 1)
                )
        )
    }
}

// ─────────────────────────────────────────
// PRIMARY HORIZON READ CARD
// Above pathway cards on Page 1.
// CALM state: green border, all-systems-calm copy driven by momentumState.
// FLAGGED state: gold border, lead signal name, escalation context.
// ─────────────────────────────────────────

struct PrimaryHorizonReadCard: View {
    let assessment: HorizonAssessment

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)
    private let green = Color(red: 0.40, green: 0.82, blue: 0.50)

    private var isActive: Bool { assessment.hasActiveSignal }

    var body: some View {
        if isActive {
            activeCard
        } else {
            calmCard
        }
    }

    // FLAGGED — lead signal name + escalation context
    private var activeCard: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 3)
                .fill(amber)
                .frame(width: 5)
                .padding(.vertical, 4)
                .shadow(color: amber.opacity(0.40), radius: 4, x: -2, y: 0)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 10, weight: .light))
                        .foregroundColor(amber.opacity(0.65))
                    Text("HORIZON SIGNAL")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(amber.opacity(0.65))
                        .tracking(1.8)
                }

                if let name = assessment.leadPathwayName {
                    Text("\(name) pathway — pattern building.")
                        .font(.cormorant(size: 24, weight: .regular))
                        .foregroundColor(amber.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lead = assessment.leadSignal {
                    Text(escalationContext(lead))
                        .font(.jost(size: 15, weight: .regular))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.11, green: 0.09, blue: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(amber.opacity(0.40), lineWidth: 1.5)
                )
        )
    }

    // CALM — all-systems-calm copy, momentumState color and label
    private var calmCard: some View {
        let momentum = assessment.momentumState

        return HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 3)
                .fill(green)
                .frame(width: 5)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10, weight: .light))
                        .foregroundColor(green.opacity(0.70))
                    Text("ALL SYSTEMS CALM")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(green.opacity(0.70))
                        .tracking(1.8)
                }

                Text(calmHeadline(momentum: momentum))
                    .font(.cormorant(size: 24, weight: .regular))
                    .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.90))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Image(systemName: momentum.icon)
                        .font(.system(size: 9, weight: .light))
                        .foregroundColor(momentum.color.opacity(0.70))
                    Text(momentum.label)
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(momentum.color.opacity(0.85))
                }
            }
            .padding(.trailing, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.06, green: 0.11, blue: 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(green.opacity(0.30), lineWidth: 1.5)
                )
        )
    }

    private func calmHeadline(momentum: MomentumState) -> String {
        switch momentum {
        case .building:     return "No patterns of concern. Your baseline is trending upward."
        case .holding:      return "No patterns of concern. Your baseline is stable."
        case .shifting:     return "No active signals. Your momentum has softened slightly."
        case .insufficient: return "No patterns of concern. Keep building your baseline."
        }
    }

    private func escalationContext(_ signal: HorizonSignal) -> String {
        let days = signal.daysInPattern
        let dayWord = days == 1 ? "day" : "days"
        switch signal.escalationLevel {
        case 1:  return "Detected for \(days) \(dayWord). Early — still fully reversible."
        case 2:  return "Sustained for \(days) \(dayWord). Patterns deepening."
        case 3:  return "Deepening over \(days) \(dayWord). Swipe for redirection options."
        default: return "Pattern building for \(days) \(dayWord)."
        }
    }
}

// ─────────────────────────────────────────
// HORIZON BETA TRANSPARENCY CARD (legacy — kept for AppStorage key migration)
// ─────────────────────────────────────────

// NOTE: HorizonBetaTransparencyCard replaced by HorizonBetaTransparencyStrip above.

struct AlphaBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ChronosTheme.gold.opacity(0.5))
                .frame(width: 5, height: 5)
            Text("Alpha · Signal deepens with your baseline")
                .font(.jost(size: 10, weight: .light))
                .foregroundColor(ChronosTheme.gold.opacity(0.7))
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ChronosTheme.goldDim.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(ChronosTheme.gold.opacity(0.15), lineWidth: 1))
        )
    }
}

// ─────────────────────────────────────────
// SIGNAL SECTION HEADER — unchanged
// ─────────────────────────────────────────

struct SignalSectionHeader: View {
    let title: String
    let subtitle: String
    let isWatch: Bool

    var accentColor: Color {
        isWatch
            ? Color(red: 1.0, green: 0.75, blue: 0.35)
            : Color(red: 0.40, green: 0.82, blue: 0.50)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 5, height: 5)
                Text(title.uppercased())
                    .font(.jost(size: 11, weight: .medium))
                    .foregroundColor(accentColor)
                    .tracking(2)
            }
            Text(subtitle)
                .font(.jost(size: 15, weight: .regular))
                .foregroundColor(ChronosTheme.faint)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ─────────────────────────────────────────
// HORIZON SIGNAL CARD VIEW
// Compact by default — tapping expands to full body + CTA.
// ─────────────────────────────────────────

struct HorizonSignalCardView: View {
    let card: HorizonSignalCard

    @State private var isExpanded = false

    var accentColor: Color {
        card.isWatch
            ? Color(red: 1.0, green: 0.75, blue: 0.35)
            : Color(red: 0.40, green: 0.82, blue: 0.50)
    }

    var cardBackground: Color {
        card.isWatch
            ? Color(red: 0.14, green: 0.10, blue: 0.06)
            : Color(red: 0.06, green: 0.12, blue: 0.08)
    }

    /// First sentence of bodyText for the compact summary line.
    private var compactSummary: String {
        let sentences = card.bodyText.components(separatedBy: ". ")
        return sentences.first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? card.bodyText
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [cardBackground, ChronosTheme.ink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(accentColor.opacity(0.20), lineWidth: 1))

            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [accentColor.opacity(0.5), accentColor],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 3)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {

                    // Header row — always visible (tap target)
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(card.metricLabel.uppercased())
                                .font(.jost(size: 13, weight: .semibold))
                                .foregroundColor(accentColor)
                                .tracking(2)
                            Spacer()
                            if card.isWatch && card.daysCount > 1 {
                                Text("building for \(card.daysCount) days".uppercased())
                                    .font(.jost(size: 11, weight: .regular))
                                    .foregroundColor(accentColor.opacity(0.6))
                                    .tracking(1)
                            }
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .light))
                                .foregroundColor(accentColor.opacity(0.40))
                        }
                    }
                    .buttonStyle(.plain)

                    // Compact summary — hidden when expanded (Bug 2 fix)
                    if !isExpanded {
                        Text(compactSummary)
                            .font(.jost(size: 14, weight: .regular))
                            .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    // Expanded content
                    if isExpanded {
                        Rectangle()
                            .fill(accentColor.opacity(0.15))
                            .frame(height: 1)

                        Text(card.bodyText)
                            .font(.jost(size: 15, weight: .regular))
                            .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.85))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: card.isWatch
                                  ? "arrow.triangle.turn.up.right.diamond"
                                  : "checkmark.circle")
                                .font(.system(size: 10, weight: .light))
                                .foregroundColor(accentColor.opacity(0.7))
                                .padding(.top, 1)
                            Text(card.ctaText)
                                .font(.jost(size: 14, weight: .regular))
                                .foregroundColor(accentColor.opacity(0.85))
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(16)
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }
}

// ─────────────────────────────────────────
// EMPTY STATE — unchanged
// ─────────────────────────────────────────

struct HorizonEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(ChronosTheme.gold.opacity(0.10), lineWidth: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: "scope")
                    .font(.system(size: 20, weight: .ultraLight))
                    .foregroundColor(ChronosTheme.gold.opacity(0.35))
            }
            Text("No signal yet")
                .font(.cormorant(size: 24))
                .foregroundColor(ChronosTheme.muted)
            Text("Horizon reads your domain scores.\nSync your Apple Watch data to activate.")
                .font(.jost(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.faint)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.horizontal, 48)
        }
    }
}
