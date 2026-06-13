// ios/MBI/MBI/Views/IntelligenceCardView.swift
// MBI Phase 1.5 — Driver Detail Screen
// Corrections Pass 2: em dash fix, signal body from Claude, range bar rebuild,
// section reorder, prompt rules, icon removal, takeaway color.

import SwiftUI

// ─────────────────────────────────────────
// CONTENT MODEL
// ─────────────────────────────────────────

struct IntelligenceContent {
    let signalBody: String      // Section 1 body text (Claude)
    let whyDriver: String       // Section 3
    let takeaway: String        // Section 5
    let closingTagline: String
}

// ─────────────────────────────────────────
// INTELLIGENCE SHEET  — top-level container
// ─────────────────────────────────────────

struct IntelligenceSheet: View {
    let metric: String
    let score: DailyScore
    let driverContext: DriverTapContext
    let bandColor: Color
    @Binding var cachedContent: [String: IntelligenceContent]
    @Environment(\.dismiss) var dismiss

    private let metricDisplayNames: [String: String] = [
        "hrv":               "Heart Rate Variability",
        "resting_hr":        "Resting Heart Rate",
        "respiratory_rate":  "Respiratory Rate",
        "sleep_duration":    "Sleep Duration",
        "sleep_continuity":  "Sleep Quality",
        "steps":             "Daily Steps",
        "active_minutes":    "Active Minutes",
    ]

    var metricName: String {
        metricDisplayNames[metric]
            ?? metric.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [bandColor.opacity(0.04), .clear],
                center: .top, startRadius: 0, endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Dismiss ──
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                            .padding(10)
                            .background(Circle().fill(ChronosTheme.surface))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

                // ── Header ──
                VStack(alignment: .leading, spacing: 6) {
                    Text("CHRONOS · HEALTH INTELLIGENCE")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(2.5)

                    Text(metricName)
                        .font(.cormorant(size: 32, weight: .bold))
                        .foregroundColor(ChronosTheme.text)

                    // C1: comma, not em dash
                    Text("What this metric is telling your body, and you.")
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white.opacity(0.70))
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                // ── Thin gold divider ──
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, ChronosTheme.gold.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .padding(.bottom, 20)

                // ── Scrollable content ──
                ScrollView(showsIndicators: false) {
                    IntelligenceCard(
                        metric: metric,
                        metricName: metricName,
                        score: score,
                        driverContext: driverContext,
                        bandColor: bandColor,
                        cachedContent: $cachedContent
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 56)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// INTELLIGENCE CARD  — full section stack
// C4: Section order — Signal → Range → Why Driver → What It Measures → Takeaway → Closing
// ─────────────────────────────────────────

struct IntelligenceCard: View {
    let metric: String
    let metricName: String
    let score: DailyScore
    let driverContext: DriverTapContext
    let bandColor: Color
    @Binding var cachedContent: [String: IntelligenceContent]

    @State private var isLoading = false

    var content: IntelligenceContent? { cachedContent[metric] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Section 1 — Today's Signal
            TodaySignalSection(
                metric: metric,
                metricName: metricName,
                context: driverContext,
                bandColor: bandColor,
                rangeTrustState: score.rangeTrustState,
                signalBody: content?.signalBody
            )

            // Section 2 — Your Range
            RangeBarSection(metric: metric, context: driverContext)

            // Section 3 — Why This Is Your Driver Today (Claude)
            if isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(ChronosTheme.gold.opacity(0.5))
                    Text("Preparing your intelligence brief...")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if let content {
                WhyDriverSection(text: content.whyDriver)
            }

            // Section 4 — What It Measures (hardcoded, always visible)
            WhatItMeasuresSection(metric: metric, metricName: metricName)

            // Section 5 — Key Takeaway + Closing (Claude)
            if let content {
                KeyTakeawaySection(text: content.takeaway)

                HStack(spacing: 10) {
                    Image(systemName: closingSymbol(for: metric))
                        .font(.system(size: 14, weight: .ultraLight))
                        .foregroundColor(.white.opacity(0.35))
                    Text(content.closingTagline)
                        .font(.cormorantItalic(size: 16))
                        .foregroundColor(.white.opacity(0.50))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .task { await loadIfNeeded() }
    }

    private func closingSymbol(for metric: String) -> String {
        switch metric {
        case "hrv":              return "waveform.path.ecg"
        case "resting_hr":       return "heart"
        case "respiratory_rate": return "lungs"
        case "sleep_duration":   return "moon.stars"
        case "sleep_continuity": return "bed.double"
        case "steps":            return "figure.walk"
        case "active_minutes":   return "bolt.heart"
        default:                 return "sparkles"
        }
    }

    private func loadIfNeeded() async {
        if cachedContent[metric] != nil { return }
        isLoading = true
        do {
            cachedContent[metric] = try await fetchIntelligence()
        } catch {
            cachedContent[metric] = fallbackContent()
        }
        isLoading = false
    }

    private func fallbackContent() -> IntelligenceContent {
        let todayVal = driverContext.formattedTodayValue ?? "your reading"
        let baselineVal = driverContext.baselineValue.map {
            ChronosMetricHelpers.formatValue(metricRaw: metric, value: $0)
        } ?? "your baseline"
        let pct = driverContext.deviationMagnitudePct.map { "\(Int($0.rounded()))%" } ?? "a notable amount"
        let dirWord = driverContext.deviationDirection == .above ? "above" : "below"

        return IntelligenceContent(
            signalBody: "Your \(metricName.lowercased()) is \(pct) \(dirWord) your 7-day average of \(baselineVal). This shift places it as your primary driver today.",
            whyDriver: "\(metricName) is your primary driver because today's reading of \(todayVal) is \(pct) \(dirWord) your personal baseline of \(baselineVal). Deviations at this level affect your body's energy availability and recovery output.",
            takeaway: "Focus on the factors most directly linked to \(metricName.lowercased()) tonight: consistent sleep timing, reduced stimulants, and a calm wind-down window.",
            closingTagline: "\(metricName) is a window into your body's current capacity."
        )
    }

    private func fetchIntelligence() async throws -> IntelligenceContent {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")

        let todayVal = driverContext.formattedTodayValue ?? "unavailable"
        let baselineVal = driverContext.baselineValue.map {
            ChronosMetricHelpers.formatValue(metricRaw: metric, value: $0)
        } ?? "not yet established"
        let deviationPct = driverContext.deviationMagnitudePct.map { "\(Int($0.rounded()))%" } ?? "unknown"
        let driverRank = driverContext.isDriver1 ? "Primary Driver" : "Secondary Driver"
        let dirWord = driverContext.deviationDirection == .above ? "above" : "below"

        let prompt = """
        You are the voice of Mynd & Bodi Institute, a prevention-first health intelligence platform.

        ABSOLUTE RULES — NEVER VIOLATE:
        - Never use em dashes. Use commas or restructure the sentence.
        - Never use hedging language: "may be", "could suggest", "might", "possibly". Be direct.
        - Never reference the score band, Chronos score, or any scoring system. No mentions of Recovering, Yellow Line, Thriving, Drifting, Redline.
        - Never use clinical or diagnostic language.
        - Never say "consult a physician".
        - Wellness framing only: recovery, energy, capacity, patterns, balance.

        CONTEXT:
        - Metric: \(metricName)
        - Driver rank: \(driverRank)
        - Today's value: \(todayVal)
        - 7-day baseline: \(baselineVal)
        - Deviation: \(deviationPct) \(dirWord) baseline

        Respond in this exact JSON format with no extra text:
        {
          "signal_body": "1-2 sentences. State what the deviation means for the body today using the actual value and percentage. Reference the 7-day average. No em dashes. No hedging language. No score band mentions. Example style: 'Your sleep was 27% below your 7-day average of 7h 2m. This gap directly reduces energy availability and recovery capacity for the day.'",
          "why_driver": "1-3 sentences maximum. Explain why this metric is the driver today using the actual value, baseline, and deviation percentage. Describe what this deviation means for the body in metric-specific terms. Be direct. No em dashes. No hedging. No score band mentions.",
          "takeaway": "1-2 sentences. A specific, actionable instruction. Tell the user exactly what to do. A colon as a list separator is acceptable. No em dashes. No hedging.",
          "closing_tagline": "One poetic phrase under 12 words capturing what \(metricName) ultimately reveals about the body."
        }
        """

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 600,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (json?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""

        guard let jsonRange = text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
              let parsed = try? JSONSerialization.jsonObject(
                with: Data(text[jsonRange].utf8)) as? [String: Any]
        else { throw URLError(.cannotParseResponse) }

        return IntelligenceContent(
            signalBody:     parsed["signal_body"]     as? String ?? "",
            whyDriver:      parsed["why_driver"]      as? String ?? "",
            takeaway:       parsed["takeaway"]        as? String ?? "",
            closingTagline: parsed["closing_tagline"] as? String ?? ""
        )
    }
}

// ─────────────────────────────────────────
// SECTION 1 — TODAY'S SIGNAL
// C2: Row 2 right col adds descriptor line; Row 3 uses Claude body text
// ─────────────────────────────────────────

struct TodaySignalSection: View {
    let metric: String
    let metricName: String
    let context: DriverTapContext
    let bandColor: Color
    let rangeTrustState: String?
    let signalBody: String?      // Claude-generated; nil until loaded

    private var deviationIsPositive: Bool {
        let higherIsBad = ["resting_hr", "respiratory_rate"].contains(metric)
        guard let dir = context.deviationDirection else { return true }
        return higherIsBad ? (dir == .below) : (dir == .above)
    }

    private var deviationPctLabel: String {
        guard let magnitude = context.deviationMagnitudePct,
              let direction = context.deviationDirection else { return "" }
        let pct = Int(magnitude.rounded())
        let arrow = direction == .above ? "↑" : "↓"
        return "\(arrow) \(pct)%"
    }

    private var deviationDirectionLabel: String {
        guard let direction = context.deviationDirection else { return "" }
        return direction == .below ? "below 7-day average" : "above 7-day average"
    }

    // Deterministic fallback shown while Claude loads
    private var fallbackBodyText: String {
        guard let direction = context.deviationDirection,
              let magnitude = context.deviationMagnitudePct,
              let _ = context.formattedTodayValue,
              let baseline = context.baselineValue else {
            return "Wear your watch consistently to build baseline context for this metric."
        }
        let pct = Int(magnitude.rounded())
        let baselineFmt = ChronosMetricHelpers.formatValue(metricRaw: metric, value: baseline)
        let dirWord = direction == .above ? "above" : "below"
        if deviationIsPositive {
            return "Your \(metricName.lowercased()) is \(pct)% \(dirWord) your 7-day average of \(baselineFmt). This reflects strong current capacity."
        } else {
            return "Your \(metricName.lowercased()) is \(pct)% \(dirWord) your 7-day average of \(baselineFmt). This places additional demand on your body's recovery systems today."
        }
    }

    private var patternInsight: String {
        switch rangeTrustState {
        case "establishing", nil:
            return "Your baseline is still being established. Keep wearing your watch each night to build your personal reference."
        case "calibrating", "provisional":
            return "Your baseline is forming. Patterns are becoming clearer with each night of consistent data."
        default:
            return "Your baseline is well-established. This deviation reflects a meaningful shift from your personal norm."
        }
    }

    private var valueParts: (value: String, unit: String) {
        guard let raw = context.todayValue else {
            return (context.formattedTodayValue ?? "--", "")
        }
        switch metric {
        case "hrv":              return ("\(Int(raw))", "ms")
        case "resting_hr":       return ("\(Int(raw))", "bpm")
        case "respiratory_rate": return (String(format: "%.1f", raw), "rpm")
        case "sleep_duration":
            let hrs = Int(raw); let mins = Int((raw - Double(hrs)) * 60)
            return mins > 0 ? ("\(hrs)h \(mins)m", "") : ("\(hrs)", "h")
        case "sleep_continuity": return ("\(Int(raw))", "%")
        case "steps":
            let fmt = NumberFormatter(); fmt.numberStyle = .decimal
            return (fmt.string(from: NSNumber(value: Int(raw))) ?? "\(Int(raw))", "steps")
        case "active_minutes":   return ("\(Int(raw))", "min")
        default:                 return (String(format: "%.1f", raw), "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Top zone ──
            VStack(alignment: .leading, spacing: 14) {
                intelSectionLabel("TODAY'S SIGNAL")

                // Row 2: large value (left) | arrow + % + descriptor (right)
                HStack(alignment: .top, spacing: 8) {
                    // Left: large metric value
                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text(valueParts.value)
                            .font(.cormorant(size: 52, weight: .bold))
                            .foregroundColor(ChronosTheme.gold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        if !valueParts.unit.isEmpty {
                            Text(valueParts.unit)
                                .font(.cormorant(size: 24, weight: .light))
                                .foregroundColor(ChronosTheme.gold.opacity(0.75))
                        }
                    }

                    Spacer()

                    // Right: deviation % + descriptor line
                    if !deviationPctLabel.isEmpty {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(deviationPctLabel)
                                .font(.jost(size: 20, weight: .bold))
                                .foregroundColor(ChronosTheme.gold)

                            Text(deviationDirectionLabel)
                                .font(.jost(size: 12, weight: .light))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        .padding(.top, 8)
                    }
                }

                // Row 3: full-width body text (Claude when ready, deterministic while loading)
                Text(signalBody ?? fallbackBodyText)
                    .font(.jost(size: 15, weight: .light))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)

            // ── Divider ──
            Rectangle()
                .fill(ChronosTheme.border)
                .frame(height: 1)
                .padding(.horizontal, 16)

            // ── Bottom zone: pattern insight ──
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.55))
                    .padding(.top, 1)

                Text(patternInsight)
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(ChronosTheme.border, lineWidth: 1))
        )
    }
}

// ─────────────────────────────────────────
// SECTION 2 — YOUR RANGE
// C3: Rebuilt per spec — 3-zone bar, callout bubble, zone labels above track
// ─────────────────────────────────────────

private struct ZoneConfig {
    let rangeMin: Double
    let optimalMin: Double
    let optimalMax: Double
    let rangeMax: Double
    let leftLabel: String
    let leftValue: String
    let midLabel: String
    let midValue: String
    let rightLabel: String
    let rightValue: String
}

struct RangeBarSection: View {
    let metric: String
    let context: DriverTapContext

    private var cfg: ZoneConfig {
        switch metric {
        case "sleep_duration":
            return ZoneConfig(rangeMin: 0, optimalMin: 6, optimalMax: 9, rangeMax: 12,
                              leftLabel: "Short",   leftValue: "< 6h",
                              midLabel: "Optimal",  midValue: "6 – 9h",
                              rightLabel: "Long",   rightValue: "> 9h")
        case "hrv":
            return ZoneConfig(rangeMin: 0, optimalMin: 30, optimalMax: 70, rangeMax: 100,
                              leftLabel: "Low",     leftValue: "< 30ms",
                              midLabel: "Optimal",  midValue: "30 – 70ms",
                              rightLabel: "High",   rightValue: "> 70ms")
        case "active_minutes":
            return ZoneConfig(rangeMin: 0, optimalMin: 15, optimalMax: 60, rangeMax: 80,
                              leftLabel: "Low",     leftValue: "< 15 min",
                              midLabel: "Optimal",  midValue: "15 – 60 min",
                              rightLabel: "High",   rightValue: "> 60 min")
        case "steps":
            return ZoneConfig(rangeMin: 0, optimalMin: 3000, optimalMax: 10000, rangeMax: 14000,
                              leftLabel: "Low",     leftValue: "< 3,000",
                              midLabel: "Optimal",  midValue: "3,000 – 10,000",
                              rightLabel: "High",   rightValue: "> 10,000")
        case "resting_hr":
            return ZoneConfig(rangeMin: 35, optimalMin: 50, optimalMax: 75, rangeMax: 100,
                              leftLabel: "Athletic", leftValue: "< 50 bpm",
                              midLabel: "Optimal",   midValue: "50 – 75 bpm",
                              rightLabel: "Elevated", rightValue: "> 75 bpm")
        default:
            return ZoneConfig(rangeMin: 0, optimalMin: 33, optimalMax: 66, rangeMax: 100,
                              leftLabel: "Low",     leftValue: "",
                              midLabel: "Typical",  midValue: "",
                              rightLabel: "High",   rightValue: "")
        }
    }

    private func frac(_ value: Double) -> CGFloat {
        let range = cfg.rangeMax - cfg.rangeMin
        guard range > 0 else { return 0 }
        let raw = CGFloat((value - cfg.rangeMin) / range)
        return min(max(raw, 0), 1)
    }

    private var formattedBaseline: String? {
        context.baselineValue.map {
            ChronosMetricHelpers.formatValue(metricRaw: metric, value: $0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            intelSectionLabel("YOUR RANGE")
                .padding(.bottom, 16)

            // Zone labels above track (equal thirds)
            HStack(spacing: 0) {
                zoneLabel(cfg.leftLabel, cfg.leftValue, .leading)
                zoneLabel(cfg.midLabel, cfg.midValue, .center)
                zoneLabel(cfg.rightLabel, cfg.rightValue, .trailing)
            }
            .padding(.bottom, 12)

            // Bar + callout bubble area
            GeometryReader { geo in
                let w = geo.size.width
                let barH: CGFloat = 6
                let dotD: CGFloat = 12
                // Vertical layout within this GeometryReader:
                //   y=0..36   → callout bubble (approx 36pt tall)
                //   y=36..46  → connector line (10pt)
                //   y=46..58  → dot (12pt); bar center at y=52
                let connectorTopY: CGFloat = 36
                let connectorH: CGFloat = 10
                let dotTopY: CGFloat = connectorTopY + connectorH
                let barOffsetY: CGFloat = dotTopY + (dotD - barH) / 2

                let todayF: CGFloat = context.todayValue.map { frac($0) } ?? 0.5
                let optMinF = frac(cfg.optimalMin)
                let optMaxF = frac(cfg.optimalMax)
                let dotX = todayF * w - dotD / 2

                // Bubble width (sized for text content)
                let bubbleW: CGFloat = 76
                let bubbleRawX = todayF * w - bubbleW / 2
                let bubbleX = min(max(bubbleRawX, 0), w - bubbleW)

                ZStack(alignment: .topLeading) {
                    // Background bar (full width, dark grey)
                    RoundedRectangle(cornerRadius: barH / 2)
                        .fill(Color(red: 0.165, green: 0.165, blue: 0.165))
                        .frame(width: w, height: barH)
                        .offset(y: barOffsetY)

                    // Optimal zone overlay (Chronos Gold 50%)
                    let optSegW = max((optMaxF - optMinF) * w, 4)
                    Rectangle()
                        .fill(ChronosTheme.gold.opacity(0.50))
                        .frame(width: optSegW, height: barH)
                        .offset(x: optMinF * w, y: barOffsetY)

                    // Connector line: from bottom of bubble to top of dot
                    Rectangle()
                        .fill(Color.white.opacity(0.30))
                        .frame(width: 1, height: connectorH)
                        .offset(x: todayF * w - 0.5, y: connectorTopY)

                    // Today dot (Chronos Gold 100%)
                    Circle()
                        .fill(ChronosTheme.gold)
                        .frame(width: dotD, height: dotD)
                        .shadow(color: ChronosTheme.gold.opacity(0.55), radius: 4)
                        .offset(x: dotX, y: dotTopY)

                    // Callout bubble
                    VStack(spacing: 2) {
                        Text("Today")
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(.white.opacity(0.80))
                        if let v = context.formattedTodayValue {
                            Text(v)
                                .font(.jost(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.20, green: 0.18, blue: 0.14))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(ChronosTheme.gold.opacity(0.45), lineWidth: 1))
                    )
                    .frame(width: bubbleW)
                    .offset(x: bubbleX, y: 0)
                }
            }
            .frame(height: 70)

            // Baseline average label
            if let bl = formattedBaseline {
                Text("Baseline average: \(bl)")
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(.white.opacity(0.60))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(ChronosTheme.border, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func zoneLabel(_ label: String, _ value: String, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 3) {
            Text(label)
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(.white.opacity(0.60))
            if !value.isEmpty {
                Text(value)
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(.white.opacity(0.80))
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: align, vertical: .center))
    }
}

// ─────────────────────────────────────────
// SECTION 3 — WHY THIS IS YOUR DRIVER TODAY
// C5: Updated prompt rules reflected in parent IntelligenceCard.fetchIntelligence()
// ─────────────────────────────────────────

struct WhyDriverSection: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                intelSectionLabel("WHY THIS IS YOUR DRIVER TODAY")

                Rectangle()
                    .fill(ChronosTheme.gold.opacity(0.15))
                    .frame(height: 1)

                Text(text)
                    .font(.jost(size: 15, weight: .light))
                    .foregroundColor(.white.opacity(0.80))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.13, green: 0.11, blue: 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(ChronosTheme.gold.opacity(0.18), lineWidth: 1)
                )
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ChronosTheme.gold.opacity(0.70))
                        .frame(width: 4)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
        )
    }
}

// ─────────────────────────────────────────
// SECTION 4 — WHAT IT MEASURES
// C6: Label is text only, no icons. Bullets are plain text with small dot — unchanged.
// ─────────────────────────────────────────

struct WhatItMeasuresSection: View {
    let metric: String
    let metricName: String

    private var bullets: [String] {
        switch metric {
        case "hrv":
            return [
                "Reflects the variability between consecutive heartbeats. Higher variability means your nervous system is balanced and responsive.",
                "A key window into your autonomic nervous system's ability to shift between stress response and recovery mode.",
                "Influenced by sleep quality, stress load, alcohol, and training intensity. Often the first metric to respond to lifestyle changes."
            ]
        case "resting_hr":
            return [
                "The number of times your heart beats per minute when fully at rest. Lower values reflect greater cardiovascular efficiency.",
                "A well-conditioned heart pumps more blood per beat, requiring fewer beats to meet the body's baseline demands.",
                "Rises with fatigue, dehydration, illness, or accumulated stress. A reliable early signal that your body is working harder than usual."
            ]
        case "respiratory_rate":
            return [
                "The number of breaths taken per minute at rest, typically 12-18 for healthy adults.",
                "Elevated rates during sleep often reflect airway restriction, increased metabolic demand, or autonomic stress.",
                "One of the most sensitive early indicators of physiological stress, often rising 12-24 hours before other symptoms appear."
            ]
        case "sleep_duration":
            return [
                "Total time asleep across all sleep stages, and the foundation of physical and cognitive restoration.",
                "Most adults need 7-9 hours to complete full recovery cycles, including deep and REM sleep stages.",
                "Even minor chronic deficits accumulate into measurable performance and recovery debt over multiple days."
            ]
        case "sleep_continuity":
            return [
                "How uninterrupted your sleep was across the night. Frequent micro-arousals reduce the depth of restorative sleep.",
                "High continuity means your body was able to cycle through deep and REM sleep without disruption.",
                "Fragmented sleep at the same total duration delivers significantly less restoration than consolidated sleep."
            ]
        case "steps":
            return [
                "Your total daily step count, a proxy for low-intensity movement and general activity level throughout the day.",
                "Regular movement supports circulation, metabolic health, and mood independently of structured exercise.",
                "Research consistently links 7,000-10,000 daily steps with improved cardiovascular and metabolic outcomes."
            ]
        case "active_minutes":
            return [
                "Time spent in moderate-to-vigorous physical activity, the kind that elevates your heart rate above a conversational pace.",
                "Active minutes support cardiovascular fitness, insulin sensitivity, and stress regulation more than step count alone.",
                "Even 20-30 minutes of daily activity meaningfully reduces stress response and improves sleep quality."
            ]
        default:
            return [
                "\(metricName) is a physiological signal your body generates continuously.",
                "Shifts in this metric reflect changes in how your body is managing its current demands.",
                "Consistent monitoring reveals patterns that connect to sleep, stress, and recovery habits."
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // C6: label only, no icon
            intelSectionLabel("WHAT IT MEASURES")

            Rectangle()
                .fill(ChronosTheme.gold.opacity(0.15))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(ChronosTheme.gold.opacity(0.5))
                            .frame(width: 4, height: 4)
                            .padding(.top, 8)

                        Text(bullet)
                            .font(.jost(size: 15, weight: .light))
                            .foregroundColor(.white.opacity(0.80))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// SECTION 5 — KEY TAKEAWAY
// C7: Body text color changed to white. Label + icon remain gold.
// ─────────────────────────────────────────

struct KeyTakeawaySection: View {
    let text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.goldDim)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(ChronosTheme.gold.opacity(0.22), lineWidth: 1))

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    Text("KEY TAKEAWAY")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(ChronosTheme.gold.opacity(0.70))
                        .tracking(2.0)
                    // C7: white body text
                    Text(text)
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }
}

// ─────────────────────────────────────────
// SHARED HELPERS
// ─────────────────────────────────────────

private func intelSectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.jost(size: 11, weight: .medium))
        .foregroundColor(ChronosTheme.gold.opacity(0.65))
        .tracking(2.0)
}
