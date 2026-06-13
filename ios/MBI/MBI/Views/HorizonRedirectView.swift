// ios/MBI/MBI/Views/HorizonRedirectView.swift
// MBI Phase 2 — Horizon · Redirect Page
// Epic 3 Sprint 3 — Page 5 (conditional, page5Active gate)
//
// The only prescriptive surface in the product.
// Intervention cards are built deterministically from HorizonAssessment.
// No LLM generation on this page — copy is templated per pathway × time-of-day.
// Primary card = active pathway with highest escalationLevel.
// Supporting cards are always rendered (collapsed by default) — upstream prevention
// is relevant even for pathways not yet at gate threshold.
// Frame disclosure sentence required per Legal Framework §4.2.

import SwiftUI

// ─────────────────────────────────────────
// INTERVENTION CARD MODEL
// Fully deterministic — no async, no fetch.
// ─────────────────────────────────────────

struct HorizonInterventionCard: Identifiable {
    let id = UUID()
    let tier: Int              // 1 = primary/lead, 2 = supporting, 3 = preventive
    let pathwayKey: String
    let pathwayLabel: String
    let title: String
    let description: String
    let action: String
    let targetNodeLabel: String
    let timingAnchor: String
    let isActivePath: Bool     // true when this pathway's gate is currently met
}

// ─────────────────────────────────────────
// HORIZON REDIRECT VIEW — Page 3
// ─────────────────────────────────────────

struct HorizonRedirectView: View {
    let assessment: HorizonAssessment

    @State private var expandedTiers: Set<Int> = [1]

    private var cards: [HorizonInterventionCard] { buildInterventionCards() }

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [Color(red: 1.0, green: 0.75, blue: 0.35).opacity(0.03), .clear],
                center: .top, startRadius: 0, endRadius: 300
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    RedirectHeader()

                    VStack(spacing: 12) {
                        ForEach(cards) { card in
                            InterventionCardView(
                                card: card,
                                isExpanded: expandedTiers.contains(card.tier)
                            ) {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    if expandedTiers.contains(card.tier) {
                                        expandedTiers.remove(card.tier)
                                    } else {
                                        expandedTiers.insert(card.tier)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    RedirectFootnote()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 64)
                }
            }
            .contentMargins(.top, 56, for: .scrollContent)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 32) }
        }
    }

    // ─────────────────────────────────────────
    // CARD BUILDER
    // Sorts pathways: active (by escalationLevel DESC) then inactive.
    // Tier 1 = primary lead. Tiers 2-3 = supporting/preventive.
    // ─────────────────────────────────────────

    private func buildInterventionCards() -> [HorizonInterventionCard] {
        let anchor = timeAnchor()
        let pathways: [(String, HorizonSignal?)] = [
            ("autonomic", assessment.autonomic),
            ("sleep",     assessment.sleep),
            ("metabolic", assessment.metabolic)
        ]

        let sorted = pathways.sorted { a, b in
            let aActive = a.1?.isActive ?? false
            let bActive = b.1?.isActive ?? false
            if aActive != bActive { return aActive }
            return (a.1?.escalationLevel ?? 0) > (b.1?.escalationLevel ?? 0)
        }

        return sorted.enumerated().map { idx, item in
            buildCard(pathway: item.0, tier: idx + 1,
                      isActive: item.1?.isActive ?? false, anchor: anchor)
        }
    }

    private enum TimeAnchor { case morning, afternoon, evening }

    private func timeAnchor() -> TimeAnchor {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return .morning
        case 12..<17: return .afternoon
        default:      return .evening
        }
    }

    private func buildCard(pathway: String, tier: Int,
                           isActive: Bool, anchor: TimeAnchor) -> HorizonInterventionCard {
        switch pathway {
        case "autonomic":
            return HorizonInterventionCard(
                tier: tier,
                pathwayKey: "autonomic",
                pathwayLabel: "AUTONOMIC",
                title: "Autonomic Reset",
                description: "Your nervous system is carrying more load than it's clearing.",
                action: autonomicAction(anchor),
                targetNodeLabel: "Sympathetic load → Autonomic pathway",
                timingAnchor: autonomicTiming(anchor),
                isActivePath: isActive
            )
        case "sleep":
            return HorizonInterventionCard(
                tier: tier,
                pathwayKey: "sleep",
                pathwayLabel: "SLEEP",
                title: "Sleep Window Protection",
                description: "Your sleep architecture is fragmenting before full repair cycles complete.",
                action: sleepAction(anchor),
                targetNodeLabel: "Sleep quality → Recovery architecture",
                timingAnchor: sleepTiming(anchor),
                isActivePath: isActive
            )
        default: // metabolic
            return HorizonInterventionCard(
                tier: tier,
                pathwayKey: "metabolic",
                pathwayLabel: "METABOLIC",
                title: "Movement Prescription",
                description: "Your activity load has been below the threshold for metabolic efficiency.",
                action: metabolicAction(anchor),
                targetNodeLabel: "Physical inactivity → Metabolic pathway",
                timingAnchor: metabolicTiming(anchor),
                isActivePath: isActive
            )
        }
    }

    // ─────────────────────────────────────────
    // ACTION COPY — time-anchored per pathway
    // ─────────────────────────────────────────

    private func autonomicAction(_ a: TimeAnchor) -> String {
        switch a {
        case .morning:   return "10 minutes of slow breathing before your first high-demand commitment today."
        case .afternoon: return "A 10-minute screen break and cognitive rest in the next hour."
        case .evening:   return "A 10-minute stillness or slow breathing practice before sleep tonight."
        }
    }
    private func autonomicTiming(_ a: TimeAnchor) -> String {
        switch a {
        case .morning: return "This morning"
        case .afternoon: return "In the next hour"
        case .evening: return "Tonight"
        }
    }

    private func sleepAction(_ a: TimeAnchor) -> String {
        switch a {
        case .morning:   return "Set a fixed sleep onset time for tonight — the same as your best recent night."
        case .afternoon: return "Protect your wind-down window. No screens or stimulants after 8pm tonight."
        case .evening:   return "Start reducing light exposure now. Your repair window opens within the next two hours."
        }
    }
    private func sleepTiming(_ a: TimeAnchor) -> String {
        switch a {
        case .morning: return "Tonight"
        case .afternoon: return "Before 8pm tonight"
        case .evening: return "Starting now"
        }
    }

    private func metabolicAction(_ a: TimeAnchor) -> String {
        switch a {
        case .morning:   return "20 minutes of continuous movement before noon. The mechanism is sustained movement, not intensity."
        case .afternoon: return "20 minutes of continuous movement before 3pm. After this window the metabolic benefit requires more time to activate."
        case .evening:   return "Schedule tomorrow's first 20 minutes for movement — before the day creates friction."
        }
    }
    private func metabolicTiming(_ a: TimeAnchor) -> String {
        switch a {
        case .morning: return "This morning"
        case .afternoon: return "Before 3pm today"
        case .evening: return "Tomorrow morning"
        }
    }
}

// ─────────────────────────────────────────
// REDIRECT HEADER
// ─────────────────────────────────────────

private struct RedirectHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REDIRECT")
                .font(.jost(size: 11, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.35))
                .tracking(3)

            Text("What changes this.")
                .font(.cormorant(size: 34, weight: .regular))
                .foregroundColor(ChronosTheme.text)

            Text("One specific action per pathway. Lead action is highest priority based on your current pattern.")
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
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }
}

// ─────────────────────────────────────────
// INTERVENTION CARD VIEW
// Tier 1 (primary): always expanded, amber treatment
// Tiers 2-3 (supporting): collapsed by default, tap to expand
// ─────────────────────────────────────────

private struct InterventionCardView: View {
    let card: HorizonInterventionCard
    let isExpanded: Bool
    let onToggle: () -> Void

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    private var accentColor: Color {
        card.isActivePath ? amber : Color.white.opacity(0.35)
    }

    private var cardBackground: Color {
        card.tier == 1
            ? Color(red: 0.11, green: 0.09, blue: 0.06)
            : Color(red: 0.09, green: 0.09, blue: 0.13)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            accentColor.opacity(card.tier == 1 ? 0.45 : 0.18),
                            lineWidth: card.tier == 1 ? 1.5 : 1.0
                        )
                )

            HStack(alignment: .top, spacing: 14) {

                // Left accent bar — full height when expanded, 6pt stub when collapsed
                RoundedRectangle(cornerRadius: 3)
                    .fill(accentColor.opacity(card.tier == 1 ? 1.0 : 0.5))
                    .frame(width: card.tier == 1 ? 6 : 4)
                    .padding(.vertical, 6)
                    .shadow(color: card.tier == 1 ? accentColor.opacity(0.35) : .clear,
                            radius: 4, x: -2, y: 0)

                VStack(alignment: .leading, spacing: 10) {

                    // Header row — always visible
                    Button(action: onToggle) {
                        HStack(alignment: .center, spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    if card.tier == 1 {
                                        Text("PRIMARY")
                                            .font(.jost(size: 11, weight: .semibold))
                                            .foregroundColor(accentColor.opacity(0.60))
                                            .tracking(1.5)
                                    }
                                    Text(card.pathwayLabel)
                                        .font(.jost(size: 13, weight: .semibold))
                                        .foregroundColor(ChronosTheme.text)
                                        .tracking(1.5)
                                }
                                Text(card.title)
                                    .font(.jost(size: 12, weight: .regular))
                                    .foregroundColor(card.tier == 1
                                                     ? accentColor.opacity(0.90)
                                                     : ChronosTheme.muted)
                            }
                            Spacer()
                            if card.tier > 1 {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // Expanded content
                    if isExpanded {
                        Rectangle()
                            .fill(accentColor.opacity(0.10))
                            .frame(height: 1)

                        Text(card.description)
                            .font(.jost(size: 15, weight: .regular))
                            .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.85))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)

                        // Action block
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(card.timingAnchor.uppercased())
                                    .font(.jost(size: 11, weight: .medium))
                                    .foregroundColor(accentColor.opacity(0.65))
                                    .tracking(1.5)
                                Rectangle()
                                    .fill(accentColor.opacity(0.20))
                                    .frame(height: 1)
                            }
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                                    .font(.system(size: 10, weight: .light))
                                    .foregroundColor(accentColor.opacity(0.70))
                                    .padding(.top, 1)
                                Text(card.action)
                                    .font(.jost(size: 14, weight: .regular))
                                    .foregroundColor(accentColor.opacity(0.90))
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(accentColor.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(accentColor.opacity(0.15), lineWidth: 1))
                        )

                        // Target node
                        HStack(spacing: 6) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                            Text(card.targetNodeLabel)
                                .font(.jost(size: 10, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                                .lineSpacing(2)
                        }
                    }
                }
                .padding(.trailing, 16)
            }
            .padding(.vertical, 14)
            .padding(.leading, 14)
        }
    }
}

// ─────────────────────────────────────────
// REDIRECT FOOTNOTE
// Preserves the observe-then-prescribe framing.
// ─────────────────────────────────────────

private struct RedirectFootnote: View {
    var body: some View {
        Text("These actions target the upstream signals driving the pattern — not symptoms. Consistency over intensity.")
            .font(.jost(size: 11, weight: .light))
            .foregroundColor(ChronosTheme.faint.opacity(0.6))
            .lineSpacing(4)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
