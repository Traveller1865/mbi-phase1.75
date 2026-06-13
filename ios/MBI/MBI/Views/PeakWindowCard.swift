// ios/MBI/MBI/Views/PeakWindowCard.swift
// MBI Phase 1.5 — Peak Window Card (Step 4 of 10)
// Position: between driver chips and narrative brief on the Today tab.
// Tap navigates directly to the Horizon tab.

import SwiftUI

// ─────────────────────────────────────────
// CONTENT MODEL
// ─────────────────────────────────────────

struct PeakWindowContent {
    let headline: String
    let body: String
    let sustainedAction: String
}

// ─────────────────────────────────────────
// PEAK WINDOW CARD
// ─────────────────────────────────────────

struct PeakWindowCard: View {
    let score: DailyScore
    @Binding var cachedContent: PeakWindowContent?
    let onHorizonTap: () -> Void

    @EnvironmentObject var supabase: SupabaseService
    @State private var isLoading = false
    @State private var inputs: [String: Double?] = [:]
    @State private var baselines: [String: Double] = [:]

    private var content: PeakWindowContent? { cachedContent }

    private var windowLabel: String {
        switch ScoreDisplayBand.from(score: score.chronosScore) {
        case .thriving:   return "PEAK WINDOW"
        case .strong:     return "CAPACITY WINDOW"
        case .recovering: return "RECOVERY WINDOW"
        case .yellowline: return "CAUTION WINDOW"
        case .drifting:   return "RESET WINDOW"
        case .redline:    return "STABILIZATION WINDOW"
        }
    }

    var body: some View {
        Button(action: onHorizonTap) {
            VStack(alignment: .leading, spacing: 12) {

                // 1. Label
                Text(windowLabel)
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                    .tracking(2.5)

                if isLoading || content == nil {
                    // Loading skeleton
                    VStack(alignment: .leading, spacing: 10) {
                        skeletonLine(width: 200, height: 18)
                        skeletonLine(width: .infinity, height: 14)
                        skeletonLine(width: 240, height: 14)
                        skeletonLine(width: 180, height: 14)
                    }
                    .padding(.top, 4)

                } else if let content {
                    // 2. Headline
                    Text(content.headline)
                        .font(.jost(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    // 3. Body
                    Text(content.body)
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white.opacity(0.85))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    // 4. Sustained action + inline chevron
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(content.sustainedAction)
                            .font(.jost(size: 15, weight: .light))
                            .foregroundColor(ChronosTheme.gold)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text("›")
                            .font(.system(size: 20, weight: .light))
                            .foregroundColor(ChronosTheme.gold.opacity(0.60))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.118, green: 0.102, blue: 0.078))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.gold.opacity(0.15), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .task {
            guard let userId = supabase.session?.userId else { return }
            async let i = supabase.fetchInputs(userId: userId, date: score.date)
            async let b = supabase.fetchLatestBaselines(userId: userId)
            inputs = (try? await i) ?? [:]
            baselines = (try? await b) ?? [:]
            await loadIfNeeded()
        }
    }

    // ── Skeleton helper ──

    @ViewBuilder
    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        if width == .infinity {
            RoundedRectangle(cornerRadius: 3)
                .fill(ChronosTheme.faint.opacity(0.12))
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(ChronosTheme.faint.opacity(0.12))
                .frame(width: width, height: height)
        }
    }

    // ── Data load ──

    private func loadIfNeeded() async {
        if cachedContent != nil { return }
        isLoading = true
        do {
            cachedContent = try await fetchPeakWindow()
        } catch {
            cachedContent = fallbackContent()
        }
        isLoading = false
    }

    private func fallbackContent() -> PeakWindowContent {
        PeakWindowContent(
            headline: "Your body is carrying more demand than it received last night.",
            body: "Both key signals are running below your personal baselines, which can lower your tolerance for high-demand tasks and decisions today.",
            sustainedAction: "Protect your sleep window and keep your evening rhythm consistent tonight and tomorrow."
        )
    }

    // ── Claude API call ──

    private func fetchPeakWindow() async throws -> PeakWindowContent {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")

        let d1 = driverInfo(metric: score.driver1, isDriver1: true)
        let d2 = driverInfo(metric: score.driver2, isDriver1: false)
        let timeOfDay = TimeOfDay.current.rawValue

        let prompt = """
        You are the voice of Mynd & Bodi Institute, a prevention-first health intelligence platform.

        ABSOLUTE RULES — NEVER VIOLATE:
        - Never use em dashes. Use commas, periods, or new sentences instead.
        - Never use hedging language ("may be", "could suggest", "might", "possibly"). Be direct.
        - Never reference score band names (no "Recovering", "Yellow Line", "Thriving", "Drifting", "Redline").
        - No clinical or diagnostic language. No "consult a physician".
        - Wellness framing: recovery, energy, capacity, resilience, patterns.
        - BODY must describe the combined signal pattern, not individual metric values or deviations.

        CONTEXT:
        - Time of day: \(timeOfDay)
        - Primary driver: \(d1.name), \(d1.deviation) \(d1.direction) 7-day baseline
        - Secondary driver: \(d2.name), \(d2.deviation) \(d2.direction) 7-day baseline
        - Score band context (do NOT output): \(score.scoreBand.rawValue)

        Output exactly three sections labeled HEADLINE, BODY, and SUSTAINED_ACTION. Each section on its own line with its label. Do not add any other sections or text.

        HEADLINE: One short declarative sentence, max 12 words. Describes what the body is doing right now. Not the score. Not a recommendation. A state description.
        BODY: 1-2 sentences. What the headline means for the user's day. Describe the combined signal pattern. No individual metric values or deviations.
        SUSTAINED_ACTION: One sentence, max 15 words. Starts with a time anchor (Tonight:, This week:, or For the next few days:). A sustained behavioral anchor for 2-3 days.
        """

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (json?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""

        func extract(_ label: String, from lines: [String]) -> String {
            let prefix = "\(label):"
            return lines
                .first(where: { $0.hasPrefix(prefix) })
                .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
                ?? ""
        }

        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let headline        = extract("HEADLINE", from: lines)
        let bodyText        = extract("BODY", from: lines)
        let sustainedAction = extract("SUSTAINED_ACTION", from: lines)

        guard !headline.isEmpty, !bodyText.isEmpty, !sustainedAction.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        return PeakWindowContent(
            headline:        headline,
            body:            bodyText,
            sustainedAction: sustainedAction
        )
    }

    // ── Driver info helpers ──

    private struct DriverInfo {
        let name: String
        let value: String
        let deviation: String
        let direction: String
    }

    private func driverInfo(metric: String, isDriver1: Bool) -> DriverInfo {
        let metricNames: [String: String] = [
            "hrv": "Heart Rate Variability", "resting_hr": "Resting Heart Rate",
            "respiratory_rate": "Respiratory Rate", "sleep_duration": "Sleep Duration",
            "sleep_continuity": "Sleep Quality", "steps": "Daily Steps",
            "active_minutes": "Active Minutes",
        ]
        let name = metricNames[metric] ?? metric.replacingOccurrences(of: "_", with: " ").capitalized

        let inputKey = ChronosMetricHelpers.inputKey(for: metric)
        let rawVal = inputs[inputKey].flatMap { $0 }
        let baselineVal = baselines[ChronosMetricHelpers.baselineColumnKey(for: metric)]

        let value = rawVal.map { ChronosMetricHelpers.formatValue(metricRaw: metric, value: $0) } ?? "unavailable"
        var deviation = "unknown"
        var direction = "from"
        if let rv = rawVal, let bv = baselineVal, bv > 0 {
            let pct = Int((abs(rv - bv) / bv * 100).rounded())
            deviation = "\(pct)%"
            direction = rv >= bv ? "above" : "below"
        }
        return DriverInfo(name: name, value: value, deviation: deviation, direction: direction)
    }
}
