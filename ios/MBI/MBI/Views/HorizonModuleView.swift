// ios/MBI/MBI/Views/HorizonModuleView.swift
// MBI Phase 2 — Horizon Module Container
// Horizon Redesign Sprint — 2-4 page architecture
//
// Page layout:
//   Page 1 (tag 0): HorizonSignalView      — always visible
//   Page 2 (tag 1): HorizonTrajectoryView  — always visible (was conditional page4Active)
//   Page 3 (tag 2): HorizonRedirectView    — page3Active (conditionClass + confidenceGate ≥ 0.5)
//   Page 4 (tag 3): HorizonEscalateView    — page4Active (escalationLevel == 3 + confidenceGate ≥ 0.75)
//
// Dot indicator: min 2 dots always. Active = filled (white/amber). Inactive = outlined grey.
// Conditional dots (pages 3-4) use amber treatment when escalation is unlocked (page4Active).
// Edge peek: one-time swipe reveal on first launch, peeks Trajectory (page 1).
//
// ⚠️ Page 4 (HorizonEscalateView) requires legal review before external release.
//
// Retired from page array: HorizonMomentumView, HorizonFoundationsView.
//   HorizonFoundationsView is now presented as a sheet from HorizonSignalView's info button.

import SwiftUI

struct HorizonModuleView: View {
    @EnvironmentObject var sync: SyncCoordinator
    @EnvironmentObject var supabase: SupabaseService

    @State private var currentPage = 0
    @State private var assessment  = HorizonAssessment.empty

    // Pre-escalation context check (Change 4)
    @State private var showContextCheck    = false
    @State private var contextFlagActive   = false
    @State private var contextCheckChecked = false   // avoids re-triggering after first check

    @AppStorage("horizonEdgePeekShown") private var edgePeekShown = false

    var totalPages: Int {
        var count = 2   // Signal + Trajectory always present
        if assessment.page3Active { count += 1 }
        if assessment.page4Active { count += 1 }
        return count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $currentPage) {

                // ─── Page 1: Signal (always) ───
                HorizonSignalView(assessment: assessment)
                    .environmentObject(sync)
                    .environmentObject(supabase)
                    .tag(0)
                    .ignoresSafeArea()

                // ─── Page 2: Trajectory (always) ───
                HorizonTrajectoryView(assessment: assessment)
                    .environmentObject(supabase)
                    .tag(1)
                    .ignoresSafeArea()

                // ─── Page 3: Redirect (conditional) ───
                if assessment.page3Active {
                    HorizonRedirectView(assessment: assessment)
                        .tag(2)
                        .ignoresSafeArea()
                }

                // ─── Page 4: Escalate (conditional) ───
                // ⚠️ Legal gate — do not expose to external users until attorney review complete.
                if assessment.page4Active {
                    HorizonEscalateView(assessment: assessment, contextFlagActive: contextFlagActive)
                        .environmentObject(supabase)
                        .environmentObject(sync)
                        .tag(3)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .ignoresSafeArea()

            HorizonPageIndicator(
                currentPage: currentPage,
                totalPages: totalPages,
                escalationActive: assessment.page4Active
            )
            .padding(.bottom, 16)
        }
        .task(id: "load") {
            await loadAssessment()
        }
        .task(id: "peek") {
            await runEdgePeekIfNeeded()
        }
        .onChange(of: assessment.page3Active) { _, active in
            if !active && currentPage >= 2 { currentPage = 0 }
        }
        .onChange(of: assessment.page4Active) { _, active in
            if !active && currentPage >= 3 { currentPage = 0 }
        }
        .onChange(of: currentPage) { _, page in
            // When user navigates to page 4 (Escalate), check if context check is needed
            if page == 3 && assessment.page4Active && !contextCheckChecked {
                contextCheckChecked = true
                Task { await checkAndTriggerContextCheck() }
            }
        }
        .sheet(isPresented: $showContextCheck) {
            EscalationContextCheckModal(
                signals: assessment.escalationSignals,
                onComplete: { flags in
                    contextFlagActive = !flags.isEmpty && flags != ["nothing_unusual"]
                    showContextCheck  = false
                    guard let userId = supabase.session?.userId,
                          let lead   = assessment.escalationSignals.first else { return }
                    let today = supabase.todayString()
                    Task { await supabase.logEscalationContext(userId: userId, escalationDate: today, pathwayKey: lead.pathway, contextFlags: flags) }
                }
            )
        }
    }

    private func checkAndTriggerContextCheck() async {
        guard let userId = supabase.session?.userId,
              let lead   = assessment.escalationSignals.first else { return }
        let today = supabase.todayString()
        let alreadyResponded = await supabase.escalationContextExists(userId: userId, escalationDate: today, pathwayKey: lead.pathway)
        if !alreadyResponded {
            showContextCheck = true
        }
        // If already responded, contextFlagActive stays at its default (false) —
        // a future improvement can load the stored value to restore persistent state.
    }

    private func loadAssessment() async {
        guard let userId = supabase.session?.userId else { return }
        let today = supabase.todayString()

        // Fetch pathway classifications
        if let fetched = try? await supabase.fetchHorizonSignals(userId: userId, date: today) {
            assessment = fetched
        }

        // Compute overall momentum and attach to assessment
        if let rows = try? await supabase.fetchMomentumScores(userId: userId),
           rows.count >= 14 {
            let recent = Array(rows.suffix(14))
            let prior  = rows.count >= 28 ? Array(rows.prefix(rows.count - 14)) : []
            let overall = MomentumState.compute(
                recent: recent.compactMap { ($0["chronos_score"] as? NSNumber)?.doubleValue },
                prior:  prior.compactMap  { ($0["chronos_score"] as? NSNumber)?.doubleValue }
            )
            assessment.momentumState = overall
        }
    }

    // One-time swipe reveal — communicates that more pages exist beyond Page 1.
    // Peeks Page 2 (Trajectory) briefly then snaps back to Page 1.
    private func runEdgePeekIfNeeded() async {
        guard !edgePeekShown else { return }
        try? await Task.sleep(nanoseconds: 900_000_000)
        withAnimation(.easeInOut(duration: 0.55)) { currentPage = 1 }
        try? await Task.sleep(nanoseconds: 680_000_000)
        withAnimation(.easeInOut(duration: 0.55)) { currentPage = 0 }
        edgePeekShown = true
    }
}

// ─────────────────────────────────────────
// PAGE INDICATOR
// Min 2 dots (Signal + Trajectory always visible).
// Active dot: filled — white for pages 0-1, amber for pages 2-3 when escalation unlocked.
// Inactive dot: stroke circle — grey for pages 0-1, amber-tinted for pages 2-3.
// ─────────────────────────────────────────

struct HorizonPageIndicator: View {
    let currentPage: Int
    let totalPages: Int
    let escalationActive: Bool

    private let dotSize:    CGFloat = 6
    private let dotSpacing: CGFloat = 8
    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<totalPages, id: \.self) { index in
                let isActive      = index == currentPage
                let isConditional = index >= 2

                if isActive {
                    Circle()
                        .fill(isConditional && escalationActive
                              ? amber
                              : Color.white.opacity(0.82))
                        .frame(width: dotSize, height: dotSize)
                } else {
                    Circle()
                        .stroke(isConditional && escalationActive
                                ? amber.opacity(0.36)
                                : Color.white.opacity(0.20),
                                lineWidth: 1)
                        .frame(width: dotSize, height: dotSize)
                }
            }
        }
        .padding(.top, 12)
    }
}

// ─────────────────────────────────────────
// PRE-ESCALATION CONTEXT CHECK MODAL (Change 4)
// Soft-interrupt presented before Horizon Page 4 (Escalate) renders.
// Multi-select — any exception flag downgrades display copy to 'monitor and recalibrate'.
// Dismissing without selection is equivalent to 'nothing unusual — proceed'.
// ─────────────────────────────────────────

private struct EscalationContextCheckModal: View {
    let signals: [HorizonSignal]
    let onComplete: ([String]) -> Void

    @State private var selected: Set<String> = []

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    private let options: [(key: String, label: String)] = [
        ("travel",        "Travel or timezone change"),
        ("illness",       "Illness or recovery"),
        ("training",      "Intense training or unusual physical activity"),
        ("device",        "Poor device wear or charging gaps"),
        ("medication",    "Medication change"),
        ("life_event",    "Major life event or schedule disruption"),
        ("nothing_unusual", "Nothing unusual — proceed"),
    ]

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Before we surface this —")
                            .font(.cormorant(size: 28, weight: .regular))
                            .foregroundColor(ChronosTheme.text)
                        Text("anything unusual lately?")
                            .font(.cormorant(size: 28, weight: .light))
                            .foregroundColor(amber.opacity(0.85))
                    }

                    Text("Chronos has noticed a sustained pattern. Before surfacing a detailed signal, we want to check: has anything been different recently?")
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(4)

                    VStack(spacing: 10) {
                        ForEach(options, id: \.key) { option in
                            let isSelected = selected.contains(option.key)
                            Button {
                                if option.key == "nothing_unusual" {
                                    selected = ["nothing_unusual"]
                                } else {
                                    selected.remove("nothing_unusual")
                                    if isSelected { selected.remove(option.key) }
                                    else           { selected.insert(option.key) }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 16, weight: .light))
                                        .foregroundColor(isSelected ? amber : ChronosTheme.faint.opacity(0.50))
                                    Text(option.label)
                                        .font(.jost(size: 14, weight: isSelected ? .medium : .light))
                                        .foregroundColor(isSelected ? ChronosTheme.text : ChronosTheme.muted)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(isSelected
                                              ? amber.opacity(0.08)
                                              : Color(red: 0.09, green: 0.09, blue: 0.13))
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(isSelected ? amber.opacity(0.40) : Color.white.opacity(0.08), lineWidth: 1))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        onComplete(Array(selected))
                    } label: {
                        Text("Continue")
                            .font(.jost(size: 15, weight: .medium))
                            .foregroundColor(ChronosTheme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(RoundedRectangle(cornerRadius: 14).fill(amber))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
