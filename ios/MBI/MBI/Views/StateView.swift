// ios/MBI/MBI/Views/StateView.swift
// MBI Phase 1.5 — State UI
// Renamed from FailStateView.swift — Sprint 1.5
// Rationale: Yellowline completes the state architecture. This file now houses
// all non-normal dashboard states. "FailState" was no longer accurate.
//
// States housed here:
//   GhostAtRiskView       — Ghost Mode At-Risk intervention
//   RedlineDashboardView  — Full red tone shift (score 0–39)
//   RedlineScoreCard      — Score card for Redline state
//   RedlineDriverChip     — Driver chip for Redline state
//   DriftNudgeCard        — Drift mode nudge (used inline in DashboardView)
//
// States routed from DashboardView (not housed here):
//   Yellowline            — Uses normal layout + YellowlineNudgeCard (in DashboardView.swift)
//   Ghost-Healthy         — System goes quiet, no UI needed

import SwiftUI

// ─────────────────────────────────────────
// GHOST MODE — AT RISK
// Full-screen soft intervention
// Triggered: 3+ days no engagement + score declining
// Non-negotiable: never silent during deterioration
// ─────────────────────────────────────────

struct GhostAtRiskView: View {
    let score: DailyScore
    let recentScores: [Double]
    let onSeeWhatHappened: () -> Void
    @State private var pulsing = false

    // Truthful decline length — the trailing run of consecutive daily drops.
    // recentScores is ascending (oldest → newest); the last element is today.
    // Returns nil when the latest move is not a decline (so the line is hidden).
    private var declineDescriptor: String? {
        guard recentScores.count >= 2 else { return nil }
        var days = 0
        var i = recentScores.count - 1
        while i > 0 && recentScores[i] < recentScores[i - 1] {
            days += 1
            i -= 1
        }
        return days >= 1 ? "\(days)-day decline" : nil
    }

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [Color(red: 0.55, green: 0.35, blue: 0.10).opacity(0.12), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(ChronosTheme.gold.opacity(pulsing ? 0.25 : 0.08), lineWidth: 1)
                        .frame(width: 90, height: 90)
                        .scaleEffect(pulsing ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: pulsing)

                    Circle()
                        .stroke(ChronosTheme.gold.opacity(0.15), lineWidth: 1)
                        .frame(width: 70, height: 70)

                    Image(systemName: "clock")
                        .font(.system(size: 26, weight: .ultraLight))
                        .foregroundColor(ChronosTheme.gold.opacity(0.7))
                }
                .padding(.bottom, 36)

                VStack(spacing: 10) {
                    Text("It's been a few days.")
                        .font(.cormorant(size: 30, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .multilineTextAlignment(.center)

                    Text("Your score has been declining.\nChronos won't go quiet while that's happening.")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .padding(.horizontal, 40)
                }
                .padding(.bottom, 36)

                VStack(spacing: 6) {
                    Text("YOUR SCORE · TODAY")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(3)

                    Text("\(Int(score.chronosScore))")
                        .font(.cormorant(size: 64, weight: .light))
                        .foregroundColor(ChronosTheme.goldLight)

                    Text(score.scoreBand.rawValue.uppercased())
                        .font(.jost(size: 10, weight: .medium))
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.28))
                        .tracking(3)

                    if let descriptor = declineDescriptor {
                        Text(descriptor)
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.35))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(ChronosTheme.goldDim)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(ChronosTheme.gold.opacity(0.2), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 40)
                .padding(.bottom, 40)

                Spacer()

                ChronosPrimaryButton(title: "See what happened") {
                    onSeeWhatHappened()
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .onAppear { pulsing = true }
    }
}

// ─────────────────────────────────────────
// REDLINE CHIP DATA
// Top-level so both RedlineDashboardView and RedlineDriverChip can reference it
// ─────────────────────────────────────────

struct RedlineChipData {
    let formattedValue: String?
    let signalWord: String?
    let signalIsPositive: Bool
    let isBuilding: Bool
}

// ─────────────────────────────────────────
// REDLINE DASHBOARD
// Full UI tone shift to deep red
// Replaces normal morning brief content
// Triggered: score 0–39 or any Redline condition
// ─────────────────────────────────────────

struct RedlineDashboardView: View {
    let score: DailyScore
    let explanation: Explanation?
    let recentScores: [Double]

    @EnvironmentObject var supabase: SupabaseService
    @State private var intelligenceCache: [String: IntelligenceContent] = [:]
    @State private var activeDriverTap: DriverTapContext? = nil
    @State private var showFeedback = false
    @State private var inputs: [String: Double?] = [:]
    @State private var baselines: [String: Double] = [:]

    var body: some View {
        VStack(spacing: 0) {

            // ── Redline score card ──
            RedlineScoreCard(score: score, recentScores: recentScores)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            // ── Redline driver chips — now tap-capable, match Sprint 1 pattern ──
            HStack(spacing: 12) {
                RedlineDriverChip(
                    label: "Driver 1",
                    metricRaw: score.driver1,
                    chipData: chipData(for: score.driver1),
                    onTap: { activeDriverTap = buildContext(for: score.driver1, isDriver1: true) }
                )
                RedlineDriverChip(
                    label: "Driver 2",
                    metricRaw: score.driver2,
                    chipData: chipData(for: score.driver2),
                    onTap: { activeDriverTap = buildContext(for: score.driver2, isDriver1: false) }
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // ── Explanation letter ──
            if let explanation = explanation {
                LetterCard(score: score, explanation: explanation)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                ChronosNudgeCard(nudge: explanation.displayNudgeText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }

            // ── Feedback prompt — present in all states per regression checklist ──
            FeedbackPromptCard(score: score) { showFeedback = true }
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackView(score: score, nudgeEventId: supabase.latestNudgeEventId)
        }
        .task {
            guard let userId = supabase.session?.userId else { return }
            async let i = supabase.fetchInputs(userId: userId, date: score.date)
            async let b = supabase.fetchLatestBaselines(userId: userId)
            inputs = (try? await i) ?? [:]
            baselines = (try? await b) ?? [:]
        }
        // §3.4: Intelligence sheet — receives full deviation context, same as normal state
        .sheet(item: $activeDriverTap) { context in
            IntelligenceSheet(
                metric: context.metric,
                score: score,
                driverContext: context,
                bandColor: ScoreDisplayBand.from(score: score.chronosScore).color,
                cachedContent: $intelligenceCache
            )
        }
    }

    // ── Chip data helpers — delegate to ChronosMetricHelpers ──

    private func chipData(for metricRaw: String) -> RedlineChipData {
        let key = ChronosMetricHelpers.inputKey(for: metricRaw)
        guard let valueOpt = inputs[key], let value = valueOpt else {
            return RedlineChipData(formattedValue: nil, signalWord: nil, signalIsPositive: false, isBuilding: false)
        }
        let formatted   = ChronosMetricHelpers.formatValue(metricRaw: metricRaw, value: value)
        let bKey        = ChronosMetricHelpers.baselineColumnKey(for: metricRaw)
        if let baseline = baselines[bKey], baseline > 0 {
            let (signal, isPositive) = ChronosMetricHelpers.signalWord(metricRaw: metricRaw, value: value, baseline: baseline)
            return RedlineChipData(formattedValue: formatted, signalWord: signal, signalIsPositive: isPositive, isBuilding: false)
        }
        return RedlineChipData(formattedValue: formatted, signalWord: "building", signalIsPositive: true, isBuilding: true)
    }

    private func buildContext(for metricRaw: String, isDriver1: Bool) -> DriverTapContext {
        ChronosMetricHelpers.buildContext(metric: metricRaw, isDriver1: isDriver1, inputs: inputs, baselines: baselines)
    }
}

// ─────────────────────────────────────────
// REDLINE SCORE CARD
// Standalone score display for Redline state
// ─────────────────────────────────────────

private struct RedlineScoreCard: View {
    let score: DailyScore
    let recentScores: [Double]

    var yesterdayScore: Double? {
        guard recentScores.count >= 2 else { return nil }
        return recentScores[recentScores.count - 2]
    }

    var deltaText: String? {
        guard let yesterday = yesterdayScore else { return nil }
        let diff = Int(score.chronosScore) - Int(yesterday)
        if diff == 0 { return "— no change from yesterday (\(Int(yesterday)))" }
        return "\(diff > 0 ? "↑" : "↓") \(abs(diff)) from yesterday (\(Int(yesterday)))"
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.06, blue: 0.06),
                        Color(red: 0.12, green: 0.04, blue: 0.04)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 20)
                    .stroke(Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.2), lineWidth: 1))

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("\(Int(score.chronosScore))")
                        .font(.cormorant(size: 96, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("REDLINE")
                            .font(.jost(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                            .tracking(3)

                        if let delta = deltaText {
                            Text(delta)
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.55))
                        }

                        Text("Rest is the priority today.")
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.7))
                    }
                    .padding(.bottom, 10)
                }
                .padding(.top, 22).padding(.horizontal, 24)

                if recentScores.count > 1 {
                    // Redline state uses its own red sparkline color
                    ChronosSparkline(
                        scores: recentScores,
                        lineColor: Color(red: 1.0, green: 0.42, blue: 0.42)
                    )
                    .frame(height: 52)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                } else {
                    Spacer().frame(height: 20)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// RED SPARKLINE
// Retained for any legacy callers — now delegates to ChronosSparkline
// with the appropriate red color token. Safe to remove once all callers updated.
// ─────────────────────────────────────────

struct RedSparkline: View {
    let scores: [Double]

    var body: some View {
        ChronosSparkline(
            scores: scores,
            lineColor: Color(red: 1.0, green: 0.50, blue: 0.50)
        )
    }
}

// ─────────────────────────────────────────
// REDLINE DRIVER CHIP  — Sprint 1 updated
// Now matches DriverChip pattern: value + signal word + tap → IntelligenceSheet
// ─────────────────────────────────────────

struct RedlineDriverChip: View {
    let label: String
    let metricRaw: String
    let chipData: RedlineChipData      // top-level type
    let onTap: () -> Void

    var metricName: String {
        Metric(rawValue: metricRaw)?.shortName
            ?? metricRaw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // In Redline state: signal color is always in the red/amber range
    var signalColor: Color {
        chipData.isBuilding
            ? ChronosTheme.gold.opacity(0.6)
            : chipData.signalIsPositive
                ? Color(red: 0.50, green: 0.90, blue: 0.55)
                : Color(red: 1.0, green: 0.42, blue: 0.42)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.14, green: 0.06, blue: 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(red: 1.0, green: 0.35, blue: 0.35).opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 5) {
                    Text(label.uppercased())
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.7))
                        .tracking(2)

                    Text(metricName)
                        .font(.cormorant(size: 20, weight: .medium))
                        .foregroundColor(Color(red: 0.965, green: 0.870, blue: 0.870))

                    // Value — own line
                    if let value = chipData.formattedValue {
                        Text(value)
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(Color(red: 0.965, green: 0.870, blue: 0.870).opacity(0.85))
                            .lineLimit(1)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.15))
                            .frame(width: 60, height: 10)
                    }

                    // Signal word — own line, direction-aware color
                    if let signal = chipData.signalWord {
                        Text(signal)
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(signalColor)
                            .lineLimit(1)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.15))
                            .frame(width: 80, height: 10)
                    }

                    // Learn more
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .light))
                            .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.5))
                        Text("Learn more")
                            .font(.jost(size: 9, weight: .light))
                            .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42).opacity(0.5))
                            .tracking(0.5)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// ─────────────────────────────────────────
// DRIFT MODE NUDGE CARD
// Used inline in DashboardView when failState == "Drift"
// Unchanged from E-07
// ─────────────────────────────────────────

struct DriftNudgeCard: View {
    let nudge: String

    private var timeContextLabel: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 5 && hour < 12 { return "This morning" }
        if hour >= 12 && hour < 17 { return "This afternoon" }
        return "Tonight"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.12, blue: 0.05),
                        Color(red: 0.11, green: 0.09, blue: 0.04)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(red: 1.0, green: 0.78, blue: 0.28).opacity(0.2), lineWidth: 1))

            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.78, blue: 0.28).opacity(0.5),
                            Color(red: 1.0, green: 0.88, blue: 0.45)
                        ],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 3).padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("One thing today")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.28))
                        .tracking(2.5).textCase(.uppercase)

                    Text(nudge)
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(timeContextLabel)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.28))
                }
            }
            .padding(20)
        }
    }
}
