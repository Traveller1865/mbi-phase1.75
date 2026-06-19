// ios/MBI/MBI/Views/DashboardView.swift
// MBI Phase 1.5 — Dashboard · Morning Brief
// Epic 1 Sprint 1 — Dashboard Redesign Build
// Changes:
//   §3.1  Header: time-aware greeting (sentence case, Large Title), date line added, first name only
//   §3.2  Score card: date removed, sparkline redesigned (state-colored, high/low labels, dashed baseline)
//   §3.3  Driver chips: value and signal word on separate lines, direction-aware signal color
//   §3.4  Driver detail: deviation data passed as navigation params (consumed in IntelligenceCardView)

import SwiftUI

// ─────────────────────────────────────────
// TIME OF DAY  — single source of truth
// Handoff §3.1: 12AM–11:59AM morning, 12PM–4:30PM afternoon, 4:31PM+ evening
// ─────────────────────────────────────────

enum TimeOfDay: String {
    case morning  = "morning"
    case daytime  = "daytime"
    case evening  = "evening"

    static var current: TimeOfDay {
        let hour = Calendar.current.component(.hour, from: Date())
        let minute = Calendar.current.component(.minute, from: Date())
        if hour < 12 { return .morning }
        // 4:31 PM cutoff = hour 16 minute 31+, or hour 17+
        if hour < 16 { return .daytime }
        if hour == 16 && minute <= 30 { return .daytime }
        return .evening
    }

    // §3.1: Sentence case — "Good morning", not "GOOD MORNING"
    var greeting: String {
        switch self {
        case .morning:  return "Good morning"
        case .daytime:  return "Good afternoon"
        case .evening:  return "Good evening"
        }
    }

    var label: String { rawValue }
}

// ─────────────────────────────────────────
// MAIN TAB
// ─────────────────────────────────────────

struct MainTabView: View {
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(selectedTab: $selectedTab)
                .tabItem { Label("Today", systemImage: "sun.horizon") }
                .tag(0)

            TrendView()
                .tabItem { Label("Trend", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(1)

            DomainBreakdownView()
                .tabItem { Label("Domains", systemImage: "hexagon") }
                .tag(2)

            HorizonModuleView()
                .environmentObject(sync)
                .environmentObject(supabase)
                .tabItem { Label("Horizon", systemImage: "scope") }
                .tag(3)
        }
        .accentColor(ChronosTheme.gold)
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1)

            let mutedColor = UIColor(red: 0.965, green: 0.953, blue: 0.933, alpha: 0.35)
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: mutedColor]
            appearance.stackedLayoutAppearance.normal.iconColor = mutedColor

            let goldColor = UIColor(red: 0.722, green: 0.580, blue: 0.416, alpha: 1)
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: goldColor]
            appearance.stackedLayoutAppearance.selected.iconColor = goldColor

            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// ─────────────────────────────────────────
// DASHBOARD VIEW
// ─────────────────────────────────────────

struct DashboardView: View {
    @Binding var selectedTab: Int

    @EnvironmentObject var sync: SyncCoordinator
    @EnvironmentObject var supabase: SupabaseService
    @State private var showFeedback = false
    @State private var showAccount = false

    // Intelligence cache — keyed by metric raw string.
    // Persists across sheet opens for the same driver.
    // Cleared when drivers change (new day brings new score).
    @State private var intelligenceCache: [String: IntelligenceContent] = [:]
    @State private var activeDriverTap: DriverTapContext? = nil

    // Peak Window cache — cleared with driver cache on day change
    @State private var peakWindowContent: PeakWindowContent? = nil

    // Track last known drivers to detect day change and clear cache
    @State private var lastKnownDriver1: String = ""
    @State private var lastKnownDriver2: String = ""

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [ChronosTheme.gold.opacity(0.05), .clear],
                center: .top, startRadius: 0, endRadius: 360
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // §3.1: Header now owns the greeting + date
                    MorningBriefHeader(
                        displayName: supabase.currentUser?.displayName ?? "",
                        syncState: sync.syncState,
                        onAccountTap: { showAccount = true }
                    )

                    if let data = sync.dashboard {

                        let failState = data.score.failState
                        // Sprint 1.5: Use computedBand for Yellowline detection.
                        // computedBand resolves client-side until backend emits "Yellowline" natively.
                        let band = data.computedBand

                        // Step 8: Correction banner — first card in the stack when flags are active
                        if !sync.correctionFlags.isEmpty {
                            CorrectionBannerCard(flags: sync.correctionFlags, score: data.score)
                                .environmentObject(supabase)
                                .environmentObject(sync)
                                .padding(.horizontal, 20).padding(.bottom, 16)
                        }

                        if failState == "Ghost-AtRisk" {
                            GhostAtRiskView(score: data.score, recentScores: data.recentScores) { }

                        } else if data.score.scoreBand == .redline {
                            RedlineDashboardView(
                                score: data.score,
                                explanation: data.explanation,
                                recentScores: data.recentScores
                            )
                            .environmentObject(supabase)

                        } else if band == .yellowline {
                            // Yellowline: normal layout, amber color theming via scoreBand override
                            // We pass a modified score view — same components, Yellowline tokens fire
                            // inside MorningScoreCard via scoreBand on the data model.
                            MorningScoreCard(
                                score: data.score,
                                recentScores: data.recentScores,
                                bandOverride: .yellowline
                            )
                            .padding(.horizontal, 20).padding(.bottom, 16)

                            DriverChipRow(
                                score: data.score,
                                onChipTap: { context in activeDriverTap = context }
                            )
                            .environmentObject(supabase)
                            .padding(.horizontal, 20).padding(.bottom, 16)

                            PeakWindowCard(
                                score: data.score,
                                cachedContent: $peakWindowContent,
                                onHorizonTap: { selectedTab = 3 }
                            )
                            .environmentObject(supabase)
                            .padding(.horizontal, 20).padding(.bottom, 16)

                            if let explanation = data.explanation {
                                LetterCard(score: data.score, explanation: explanation)
                                    .padding(.horizontal, 20).padding(.bottom, 16)

                                YellowlineNudgeCard(nudge: explanation.displayNudgeText)
                                    .padding(.horizontal, 20).padding(.bottom, 16)
                            }

                            FeedbackPromptCard(score: data.score) { showFeedback = true }
                                .padding(.horizontal, 20).padding(.bottom, 48)

                        } else {
                            // §3.2: Score card — date removed, sparkline redesigned
                            MorningScoreCard(score: data.score, recentScores: data.recentScores)
                                .padding(.horizontal, 20).padding(.bottom, 16)

                            // §3.3: Driver chips — value + signal word, direction-aware color
                            // §3.4: Deviation context passed through DriverTapContext
                            DriverChipRow(
                                score: data.score,
                                onChipTap: { context in
                                    activeDriverTap = context
                                }
                            )
                            .environmentObject(supabase)
                            .padding(.horizontal, 20).padding(.bottom, 16)

                            PeakWindowCard(
                                score: data.score,
                                cachedContent: $peakWindowContent,
                                onHorizonTap: { selectedTab = 3 }
                            )
                            .environmentObject(supabase)
                            .padding(.horizontal, 20).padding(.bottom, 16)

                            if let explanation = data.explanation {
                                LetterCard(score: data.score, explanation: explanation)
                                    .padding(.horizontal, 20).padding(.bottom, 16)

                                if failState == "Drift" {
                                    DriftNudgeCard(nudge: explanation.displayNudgeText)
                                        .padding(.horizontal, 20).padding(.bottom, 16)
                                } else {
                                    ChronosNudgeCard(nudge: explanation.displayNudgeText)
                                        .padding(.horizontal, 20).padding(.bottom, 16)
                                }
                            }

                            FeedbackPromptCard(score: data.score) { showFeedback = true }
                                .padding(.horizontal, 20).padding(.bottom, 48)
                        }

                    } else if case .syncing(let msg) = sync.syncState {
                        ChronosSyncingView(message: msg).padding(.top, 60)

                    } else if case .failed(let msg) = sync.syncState {
                        ChronosErrorView(message: msg) {
                            Task {
                                if let userId = supabase.session?.userId {
                                    if msg.contains("401") { await supabase.refreshSessionIfNeeded() }
                                    await sync.runDailySync(userId: userId)
                                }
                            }
                        }
                        .padding(.top, 60)

                    } else {
                        ChronosEmptyView().padding(.top, 60)
                    }
                }
            }
            .refreshable {
                if let userId = supabase.session?.userId {
                    await sync.forceSync(userId: userId)
                }
            }
        }
        .sheet(isPresented: $showFeedback) {
            if let data = sync.dashboard { FeedbackView(score: data.score, nudgeEventId: nil) }
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
                .environmentObject(supabase)
                .environmentObject(sync)
        }
        // §3.4: Intelligence sheet now receives full deviation context
        .sheet(item: $activeDriverTap) { context in
            if let data = sync.dashboard {
                IntelligenceSheet(
                    metric: context.metric,
                    score: data.score,
                    driverContext: context,
                    bandColor: ScoreDisplayBand.from(score: data.score.chronosScore).color,
                    cachedContent: $intelligenceCache
                )
            }
        }
        // iOS 17 two-parameter onChange — (oldValue, newValue)
        .onChange(of: sync.dashboard?.score.driver1) { _, newDriver in
            guard let driver = newDriver, driver != lastKnownDriver1 else { return }
            intelligenceCache.removeAll()
            peakWindowContent = nil
            lastKnownDriver1 = driver
            lastKnownDriver2 = sync.dashboard?.score.driver2 ?? ""
        }
        // ── Section 7: Gap validation prompt ─────────────────────────────────
        // Shown after sync when today's day had no wearable data (steps_only tier).
        // Three-button confirmation: worn device / didn't wear / check later.
        .alert("No wearable data today", isPresented: $sync.showGapValidationPrompt) {
            Button("Yes, I wore my \(sync.gapValidationDeviceName)") {
                if let userId = supabase.session?.userId {
                    Task { await sync.resolveGapValidation(userId: userId, response: .wornDevice) }
                }
            }
            Button("No, I didn't wear it") {
                if let userId = supabase.session?.userId {
                    Task { await sync.resolveGapValidation(userId: userId, response: .didNotWear) }
                }
            }
            Button("I'll check later", role: .cancel) {
                if let userId = supabase.session?.userId {
                    Task { await sync.resolveGapValidation(userId: userId, response: .checkLater) }
                }
            }
        } message: {
            Text("Chronos didn't detect \(sync.gapValidationDeviceName) data for \(sync.gapValidationDate). Did you wear your device?")
        }
    }
}

// ─────────────────────────────────────────
// HEADER  §3.1
// Changes from prior:
//   - Greeting: sentence case, Large Title weight (cormorant 28 light → larger presence)
//   - First name only (trim at first space)
//   - Date line added below greeting: "Friday · April 25" format, muted subheadline
//   - Avatar height scales to match combined two-line text block
//   - Greeting no longer uppercased
// ─────────────────────────────────────────

struct MorningBriefHeader: View {
    let displayName: String
    let syncState: SyncState
    let onAccountTap: () -> Void

    /// §3.1: Use first word only if display_name contains a space
    var firstName: String {
        let name = displayName.isEmpty ? "—" : displayName
        return String(name.split(separator: " ").first ?? Substring(name))
    }

    /// §3.1: "Friday · April 25" — no year
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE · MMMM d"
        return formatter.string(from: Date())
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                // §3.1: Sentence case, warm presence — reduced 25% from 30pt per founder feedback
                Text("\(TimeOfDay.current.greeting), \(firstName)")
                    .font(.cormorant(size: 22, weight: .light))
                    .foregroundColor(ChronosTheme.text)

                // §3.1: Date line — subheadline weight, muted, directly below greeting
                Text(formattedDate)
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
            }
            Spacer()
            HStack(spacing: 12) {
                SyncStatusBadge(state: syncState)
                // §3.1: Avatar scales to match combined two-line text block height.
                // The two lines are approx: 30pt cormorant + 2pt spacing + 13pt jost = ~45pt
                // Use a GeometryReader-free approach: fixed size that matches the block.
                Button(action: onAccountTap) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundColor(ChronosTheme.gold.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }
}

// ─────────────────────────────────────────
// SCORE DISPLAY BAND
// 6-tier system derived from raw score value.
// Independent of the model's ScoreBand — used for background image,
// arc color, band label, and score explanation display.
// ─────────────────────────────────────────

enum ScoreDisplayBand {
    case thriving, strong, recovering, yellowline, drifting, redline

    static func from(score: Double) -> ScoreDisplayBand {
        switch Int(score.rounded()) {
        case 90...:   return .thriving
        case 75...89: return .strong
        case 60...74: return .recovering
        case 45...59: return .yellowline
        case 30...44: return .drifting
        default:      return .redline
        }
    }

    static func from(scoreBand: ScoreBand) -> ScoreDisplayBand {
        switch scoreBand {
        case .thriving:   return .thriving
        case .recovering: return .recovering
        case .yellowline: return .yellowline
        case .drifting:   return .drifting
        case .redline:    return .redline
        }
    }

    // Spec color tokens (exact hex values per design)
    var color: Color {
        switch self {
        case .thriving:   return Color(red: 0.298, green: 0.686, blue: 0.510) // #4CAF82
        case .strong:     return Color(red: 0.482, green: 0.776, blue: 0.494) // #7BC67E
        case .recovering: return Color(red: 0.392, green: 0.710, blue: 0.965) // #64B5F6
        case .yellowline: return Color(red: 0.961, green: 0.651, blue: 0.137) // #F5A623
        case .drifting:   return Color(red: 0.878, green: 0.482, blue: 0.224) // #E07B39
        case .redline:    return Color(red: 0.839, green: 0.298, blue: 0.298) // #D64C4C
        }
    }

    var backgroundImageName: String {
        switch self {
        case .thriving:   return "bg_thriving"
        case .strong:     return "bg_strong"
        case .recovering: return "bg_recovering"
        case .yellowline: return "bg_yellowline"
        case .drifting:   return "bg_drifting"
        case .redline:    return "bg_redline"
        }
    }

    var label: String {
        switch self {
        case .thriving:   return "THRIVING"
        case .strong:     return "STRONG"
        case .recovering: return "RECOVERING"
        case .yellowline: return "YELLOW LINE"
        case .drifting:   return "DRIFTING"
        case .redline:    return "RED LINE"
        }
    }

    // Natural-case label for display as a Cormorant headline
    var titleLabel: String {
        switch self {
        case .thriving:   return "Thriving"
        case .strong:     return "Strong"
        case .recovering: return "Recovering"
        case .yellowline: return "Yellow Line"
        case .drifting:   return "Drifting"
        case .redline:    return "Red Line"
        }
    }

    var scoreRange: String {
        switch self {
        case .thriving:   return "90–100"
        case .strong:     return "75–89"
        case .recovering: return "60–74"
        case .yellowline: return "45–59"
        case .drifting:   return "30–44"
        case .redline:    return "0–29"
        }
    }

    var description: String {
        switch self {
        case .thriving:   return "Your body is recovering strongly and adapting well to daily demands. This is your system at its best."
        case .strong:     return "Solid recovery and physiological stability. You have good adaptive capacity today."
        case .recovering: return "Mild stress load, within manageable range. Your system is coping, but headroom is moderate."
        case .yellowline: return "Early signals of decline. Not urgent, but worth paying attention to today."
        case .drifting:   return "Risk is accumulating. Prioritise recovery — sleep, movement, and reducing stressors."
        case .redline:    return "Acute physiological stress. Rest is the most important thing you can do today."
        }
    }
}

// ─────────────────────────────────────────
// SCORE CARD — redesigned
// Step 1: Dynamic background image, open arc meter, double-tap sparkline.
//
// Layout:
//   - Background image fills edge to edge, scaledToFill + clipped
//   - Black→transparent gradient overlay (top 75% opacity, clear at 60% height)
//   - Upper portion: arc meter + score numeral (arc state) OR sparkline (sparkline state)
//   - Lower portion: band label · delta line · explanation button
//   - Double-tap anywhere toggles between states (fade 0.3s)
// ─────────────────────────────────────────

struct MorningScoreCard: View {
    let score: DailyScore
    let recentScores: [Double]
    // Yellowline routing: DashboardView passes .yellowline override when computedBand fires.
    // Nil = derive display band from raw chronosScore.
    var bandOverride: ScoreBand? = nil

    @State private var showSparkline = false
    @State private var showExplanation = false

    private var displayBand: ScoreDisplayBand {
        if let override = bandOverride {
            return ScoreDisplayBand.from(scoreBand: override)
        }
        return ScoreDisplayBand.from(score: score.chronosScore)
    }

    private var yesterdayScore: Double? {
        guard recentScores.count >= 2 else { return nil }
        return recentScores[recentScores.count - 2]
    }

    private var deltaText: String? {
        guard let yesterday = yesterdayScore else { return nil }
        let diff = Int(score.chronosScore.rounded()) - Int(yesterday.rounded())
        if diff == 0 { return "— No change from yesterday" }
        return diff > 0
            ? "↑ Up \(abs(diff)) from yesterday"
            : "↓ Down \(abs(diff)) from yesterday"
    }

    private var recentAvg: Double {
        recentScores.isEmpty ? 0.0 : recentScores.reduce(0, +) / Double(recentScores.count)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Uniform overlay — on top of background, below content
            Color.black.opacity(0.48)

            // Content — crossfades on toggle
            if showSparkline {
                sevenDayContent.transition(.opacity)
            } else {
                scoreContent.transition(.opacity)
            }

            // Toggle icon button — top-right corner
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { showSparkline.toggle() }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    Image(systemName: showSparkline ? "gauge.medium" : "chart.line.uptrend.xyaxis")
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(.white.opacity(0.90))
                }
                .frame(width: 34, height: 34)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 310)
        // Background as modifier — never participates in layout, clipped by clipShape below
        .background {
            if let uiImg = UIImage(named: displayBand.backgroundImageName) {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(red: 0.08, green: 0.08, blue: 0.13)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: $showExplanation) {
            ScoreExplanationView()
        }
    }

    // ── Score state: arc left, band info right, CTA full-width at bottom ──
    @ViewBuilder
    private var scoreContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left: arc meter
                ChronosArcMeter(score: score.chronosScore, bandColor: displayBand.color)
                    .frame(width: 158, height: 158)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 8)

                // Right: band label, delta, description
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayBand.titleLabel)
                        .font(.cormorant(size: 28, weight: .bold))
                        .foregroundColor(displayBand.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)
                        .padding(.bottom, 5)

                    if let delta = deltaText {
                        deltaBadge(delta).padding(.bottom, 8)
                    }

                    Text(displayBand.description)
                        .font(.jost(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.trailing, 16)
                .padding(.top, 52)  // clears the 34pt toggle button + 12pt padding
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            // CTA full-width at card bottom — matches 7-day view layout
            HStack {
                Spacer()
                ctaButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    // ── 7-day state: full-width sparkline ──
    @ViewBuilder
    private var sevenDayContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(displayBand.color)
                Text("LAST 7 DAYS")
                    .font(.jost(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(2)
            }
            .padding(.top, 18)
            .padding(.leading, 18)

            HStack(spacing: 4) {
                Text("Current")
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(.white.opacity(0.55))
                Text("\(Int(score.chronosScore.rounded()))")
                    .font(.jost(size: 12, weight: .medium))
                    .foregroundColor(displayBand.color)
                Text("·")
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(.white.opacity(0.35))
                Text("Avg")
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(.white.opacity(0.55))
                Text("\(Int(recentAvg.rounded()))")
                    .font(.jost(size: 12, weight: .medium))
                    .foregroundColor(displayBand.color)
            }
            .padding(.leading, 18)
            .padding(.top, 3)
            .padding(.bottom, 6)

            if recentScores.count > 1 {
                SevenDaySparkline(
                    scores: recentScores,
                    bandColor: displayBand.color,
                    currentScore: score.chronosScore
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
            } else {
                Spacer()
            }

            HStack {
                Spacer()
                ctaButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var ctaButton: some View {
        Button { showExplanation = true } label: {
            HStack(spacing: 4) {
                Text("What does this score mean?")
                    .font(.jost(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text("→")
                    .font(.jost(size: 13, weight: .medium))
                    .foregroundColor(displayBand.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.40))
                    .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 1))
            )
        }
        .frame(minHeight: 44)
    }

    private func deltaBadge(_ delta: String) -> some View {
        let isNeutral = delta.hasPrefix("—")
        let arrow = String(delta.prefix(1))
        let body  = String(delta.dropFirst(2))
        return HStack(spacing: 5) {
            Text(arrow)
                .foregroundColor(isNeutral ? .white.opacity(0.55) : displayBand.color)
            Text(body)
                .foregroundColor(.white)
        }
        .font(.jost(size: 13, weight: .bold))
    }
}

// ─────────────────────────────────────────
// ARC METER
// Open arc from 8 o'clock (150°) to 4 o'clock (390°=30°),
// gap at bottom. Track = full 240°, white 15%. Fill = score fraction.
// ─────────────────────────────────────────

struct ChronosArcMeter: View {
    let score: Double
    let bandColor: Color

    private let strokeWidth: CGFloat = 7
    private let startDeg: Double = 150.0
    private let totalSpan: Double = 240.0

    var body: some View {
        ZStack {
            // Track — full 240° arc
            ScoreArc(startDeg: startDeg, endDeg: startDeg + totalSpan)
                .stroke(
                    Color.white.opacity(0.15),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )

            // Filled arc — score fraction of 240°
            if score > 0 {
                ScoreArc(
                    startDeg: startDeg,
                    endDeg: startDeg + (min(score, 100) / 100.0) * totalSpan
                )
                .stroke(
                    bandColor,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
            }

            // Score numeral
            Text("\(Int(score.rounded()))")
                .font(.cormorant(size: 80, weight: .bold))
                .foregroundColor(bandColor)
        }
    }
}

// Arc shape — draws from startDeg to endDeg clockwise on screen.
// UIKit/SwiftUI inversion: clockwise: false → visually clockwise (Y-axis down).
private struct ScoreArc: Shape {
    let startDeg: Double
    let endDeg: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2 - 4, // inset so stroke stays in-bounds
            startAngle: .degrees(startDeg),
            endAngle: .degrees(endDeg),
            clockwise: false // false = clockwise visually in UIKit coordinate system
        )
        return p
    }
}

// ─────────────────────────────────────────
// SEVEN-DAY SPARKLINE
// Used in MorningScoreCard 7-day state.
// Fixed y-range 45–105, day-of-week x-axis, peak callout, today badge, avg dashed line.
// ─────────────────────────────────────────

struct SevenDaySparkline: View {
    let scores: [Double]
    let bandColor: Color
    let currentScore: Double

    private var avg: Double { scores.reduce(0, +) / Double(max(scores.count, 1)) }
    private var peakIndex: Int { scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0 }

    private var dayLabels: [String] {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        let count = scores.count
        return (0..<count).map { offset in
            let daysAgo = count - 1 - offset
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            return fmt.string(from: date)
        }
    }

    private let yMin: Double   = 45
    private let yMax: Double   = 105
    private let yLabelW: CGFloat   = 36
    private let chartTopPad: CGFloat = 28  // headroom above highest point for peak label
    private let xAxisH: CGFloat    = 18

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let chartH = h - chartTopPad - xAxisH
            let drawW  = w - yLabelW
            let count  = scores.count
            let step   = count > 1 ? drawW / CGFloat(count - 1) : drawW

            let yPos: (Double) -> CGFloat = { v in
                chartTopPad + chartH * (1 - CGFloat((v - yMin) / (yMax - yMin)))
            }
            let xPos: (Int) -> CGFloat = { i in yLabelW + CGFloat(i) * step }

            let pts = scores.indices.map { CGPoint(x: xPos($0), y: yPos(scores[$0])) }
            let avgY = yPos(avg)
            let pkPt = pts[peakIndex]
            let todayPt = pts.last ?? .zero
            let todayIsAlsoPeak = peakIndex == scores.count - 1
            let chartBottom = chartTopPad + chartH

            ZStack(alignment: .topLeading) {
                // Y-axis labels
                Text("100")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(.white.opacity(0.50))
                    .frame(width: yLabelW, alignment: .trailing)
                    .position(x: yLabelW / 2, y: yPos(100))

                Text("50")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(.white.opacity(0.50))
                    .frame(width: yLabelW, alignment: .trailing)
                    .position(x: yLabelW / 2, y: yPos(50))

                // Avg label — band color, sits just above the dashed line
                Text("\(Int(avg.rounded())) avg")
                    .font(.jost(size: 10, weight: .light))
                    .foregroundColor(bandColor.opacity(0.90))
                    .frame(width: yLabelW, alignment: .trailing)
                    .position(x: yLabelW / 2, y: avgY - 8)

                // Canvas: avg line + sparkline + vertical tick lines
                Canvas { ctx, _ in
                    // Avg dashed line
                    var dash = Path()
                    dash.move(to: CGPoint(x: yLabelW, y: avgY))
                    dash.addLine(to: CGPoint(x: w, y: avgY))
                    ctx.stroke(dash, with: .color(.white.opacity(0.40)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    guard pts.count > 1 else { return }

                    // Sparkline
                    var line = Path()
                    line.move(to: pts[0])
                    for pt in pts.dropFirst() { line.addLine(to: pt) }
                    ctx.stroke(line, with: .color(bandColor), lineWidth: 2.5)

                    // Peak vertical tick
                    if !todayIsAlsoPeak {
                        var vl = Path()
                        vl.move(to: CGPoint(x: pkPt.x, y: pkPt.y + 4))
                        vl.addLine(to: CGPoint(x: pkPt.x, y: chartBottom))
                        ctx.stroke(vl, with: .color(.white.opacity(0.25)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    }

                    // Today vertical tick
                    var tv = Path()
                    tv.move(to: CGPoint(x: todayPt.x, y: todayPt.y + 4))
                    tv.addLine(to: CGPoint(x: todayPt.x, y: chartBottom))
                    ctx.stroke(tv, with: .color(.white.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }

                // Data point dots
                ForEach(scores.indices, id: \.self) { i in
                    Circle()
                        .fill(bandColor)
                        .frame(width: 6, height: 6)
                        .position(pts[i])
                }

                // Peak callout: score value above, "Peak" label just above the dot
                if !todayIsAlsoPeak {
                    Text("\(Int(scores[peakIndex].rounded()))")
                        .font(.jost(size: 13, weight: .medium))
                        .foregroundColor(bandColor)
                        .position(x: pkPt.x, y: pkPt.y - 21)
                    Text("Peak")
                        .font(.jost(size: 10, weight: .light))
                        .foregroundColor(.white.opacity(0.65))
                        .position(x: pkPt.x, y: pkPt.y - 9)
                }

                // Today badge — above last data point, shifted left to stay in-bounds
                let badgeX = min(max(todayPt.x - 38, yLabelW + 42), w - 42)
                HStack(spacing: 3) {
                    Text("Today")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(.white.opacity(0.80))
                    Text("\(Int(currentScore.rounded()))")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(bandColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(bandColor.opacity(0.55), lineWidth: 1))
                )
                .fixedSize()
                .position(x: badgeX, y: todayPt.y - 22)

                // X-axis day labels
                ForEach(scores.indices, id: \.self) { i in
                    if i < dayLabels.count {
                        Text(dayLabels[i])
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(.white.opacity(0.50))
                            .position(x: xPos(i), y: chartBottom + xAxisH / 2)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// ─────────────────────────────────────────
// SCORE EXPLANATION VIEW
// Sheet: "What does this score mean?"
// Shows all 6 bands with color, range, and plain-language description.
// ─────────────────────────────────────────

struct ScoreExplanationView: View {
    @Environment(\.dismiss) private var dismiss

    private let bands: [ScoreDisplayBand] = [
        .thriving, .strong, .recovering, .yellowline, .drifting, .redline
    ]

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR CHRONOS SCORE")
                                .font(.jost(size: 10, weight: .medium))
                                .foregroundColor(ChronosTheme.gold)
                                .tracking(2.5)
                            Text("What does it mean?")
                                .font(.cormorant(size: 26, weight: .light))
                                .foregroundColor(ChronosTheme.text)
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .padding(10)
                                .background(Circle().fill(ChronosTheme.surface))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 36)
                    .padding(.bottom, 16)

                    Text("Your Chronos score (0–100) is a daily measure of physiological readiness — how well your body has recovered and adapted to recent demands. It draws on heart rate variability, sleep quality, resting heart rate, and activity patterns from your Apple Watch.")
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)

                    ForEach(bands.indices, id: \.self) { i in
                        let band = bands[i]
                        HStack(alignment: .top, spacing: 16) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(band.color)
                                .frame(width: 4)
                                .padding(.vertical, 2)

                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(band.label)
                                        .font(.jost(size: 11, weight: .medium))
                                        .foregroundColor(band.color)
                                        .tracking(2)
                                    Spacer()
                                    Text(band.scoreRange)
                                        .font(.jost(size: 11, weight: .light))
                                        .foregroundColor(ChronosTheme.faint)
                                }
                                Text(band.description)
                                    .font(.jost(size: 13, weight: .light))
                                    .foregroundColor(ChronosTheme.muted)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)
                    }

                    Spacer().frame(height: 48)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// CHRONOS SPARKLINE  §3.2
// Read-only 7-day signal used by RedlineScoreCard (StateView.swift).
// ─────────────────────────────────────────

struct ChronosSparkline: View {
    let scores: [Double]
    let lineColor: Color

    private var baseline: Double {
        scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }

    private var highIndex: Int {
        scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0
    }

    private var lowIndex: Int {
        scores.indices.min(by: { scores[$0] < scores[$1] }) ?? 0
    }

    private func layout(in size: CGSize) -> SparklineLayout {
        let w = size.width
        let h = size.height
        let labelPad: CGFloat = 24
        let drawW = w - labelPad * 2
        let count = scores.count

        let minS = (scores.min() ?? 0) - 8
        let maxS = (scores.max() ?? 100) + 8
        let range = max(maxS - minS, 1)
        let step = count > 1 ? drawW / CGFloat(count - 1) : drawW

        let points: [CGPoint] = scores.indices.map { i in
            CGPoint(
                x: labelPad + CGFloat(i) * step,
                y: h - CGFloat((scores[i] - minS) / range) * h
            )
        }
        let baselineY = h - CGFloat((baseline - minS) / range) * h

        return SparklineLayout(
            width: w, height: h,
            points: points,
            baselineY: baselineY,
            baselineAvg: baseline,
            highIndex: highIndex,
            lowIndex: lowIndex
        )
    }

    var body: some View {
        GeometryReader { geo in
            SparklineCanvas(
                layout: layout(in: geo.size),
                scores: scores,
                lineColor: lineColor
            )
        }
        .allowsHitTesting(false)
    }
}

private struct SparklineLayout {
    let width: CGFloat
    let height: CGFloat
    let points: [CGPoint]
    let baselineY: CGFloat
    let baselineAvg: Double
    let highIndex: Int
    let lowIndex: Int
}

private struct SparklineCanvas: View {
    let layout: SparklineLayout
    let scores: [Double]
    let lineColor: Color

    var body: some View {
        ZStack {
            Canvas { ctx, _ in
                var dash = Path()
                dash.move(to: CGPoint(x: 0, y: layout.baselineY))
                dash.addLine(to: CGPoint(x: layout.width, y: layout.baselineY))
                ctx.stroke(dash, with: .color(.white.opacity(0.20)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            Text("avg \(Int(layout.baselineAvg.rounded()))")
                .font(.jost(size: 9, weight: .light))
                .foregroundColor(.white.opacity(0.35))
                .position(x: 18, y: layout.baselineY - 8)

            Canvas { ctx, _ in
                guard layout.points.count > 1 else { return }
                var path = Path()
                path.move(to: layout.points[0])
                for pt in layout.points.dropFirst() { path.addLine(to: pt) }
                ctx.stroke(path, with: .color(lineColor.opacity(0.85)), lineWidth: 1.5)
            }

            if let last = layout.points.last {
                Circle()
                    .fill(lineColor)
                    .frame(width: 6, height: 6)
                    .position(last)
            }

            if !scores.isEmpty {
                Text("\(Int(scores[layout.highIndex].rounded()))")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .position(x: layout.points[layout.highIndex].x,
                              y: layout.points[layout.highIndex].y - 10)

                Text("\(Int(scores[layout.lowIndex].rounded()))")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .position(x: layout.points[layout.lowIndex].x,
                              y: layout.points[layout.lowIndex].y + 10)
            }
        }
    }
}

// ─────────────────────────────────────────
// LETTER CARD
// ─────────────────────────────────────────

struct LetterCard: View {
    let score: DailyScore
    let explanation: Explanation
    @State private var showBriefPlaceholder = false

    // "{DAY} {SESSION} BRIEF"
    // Day derived from explanation.date, not device clock.
    // Session determined by which field is displayed: evening_explanation_text after 5pm = Evening, else Morning.
    var briefLabel: String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEEE"
        let dateObj = dateFmt.date(from: explanation.date) ?? Date()
        let day = dayFmt.string(from: dateObj)
        let hour = Calendar.current.component(.hour, from: Date())
        let isEvening = hour >= 17 && explanation.eveningExplanationText != nil
        return "\(day) \(isEvening ? "Evening" : "Morning") Brief"
    }

    var body: some View {
        Button(action: { showBriefPlaceholder = true }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(briefLabel)
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.gold).tracking(2.5).textCase(.uppercase)

                Rectangle().fill(ChronosTheme.gold.opacity(0.25)).frame(height: 1)

                Text(explanation.displayExplanationText)
                    .font(.jost(size: 15, weight: .light))
                    .foregroundColor(.white)
                    .lineSpacing(7).fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Text("›")
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold.opacity(0.50))
                }
                .padding(.top, 4)
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
        .sheet(isPresented: $showBriefPlaceholder) {
            BriefDetailSheet(explanation: explanation)
        }
    }
}

// ─────────────────────────────────────────
// NUDGE CARD
// ─────────────────────────────────────────

struct ChronosNudgeCard: View {
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
                    colors: [Color(red: 0.13, green: 0.11, blue: 0.08),
                             Color(red: 0.09, green: 0.08, blue: 0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(ChronosTheme.gold.opacity(0.18), lineWidth: 1))

            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [ChronosTheme.gold.opacity(0.4), ChronosTheme.goldLight],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 3).padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Today's focus")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold).tracking(2.5).textCase(.uppercase)

                    Text(nudge)
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)

                    Text(timeContextLabel)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                }
            }
            .padding(20)
        }
    }
}

// ─────────────────────────────────────────
// YELLOWLINE NUDGE CARD  Sprint 1.5
// Amber treatment — warmer than Drift, not as urgent as Redline.
// Same single-sentence nudge constraint as all other states.
// ─────────────────────────────────────────

struct YellowlineNudgeCard: View {
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
                        Color(red: 0.20, green: 0.15, blue: 0.04),
                        Color(red: 0.14, green: 0.11, blue: 0.03)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(red: 1.0, green: 0.72, blue: 0.20).opacity(0.25), lineWidth: 1))

            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.72, blue: 0.20).opacity(0.6),
                            Color(red: 1.0, green: 0.85, blue: 0.40)
                        ],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 3).padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Worth noting today")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.20))
                        .tracking(2.5).textCase(.uppercase)

                    Text(nudge)
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)

                    Text(timeContextLabel)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.20))
                }
            }
            .padding(20)
        }
    }
}

// ─────────────────────────────────────────
// FEEDBACK PROMPT
// ─────────────────────────────────────────

struct FeedbackPromptCard: View {
    let score: DailyScore
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Did this feel right?")
                        .font(.jost(size: 14, weight: .light)).foregroundColor(ChronosTheme.text)
                    Text("Your feedback sharpens your score over time.")
                        .font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light)).foregroundColor(ChronosTheme.faint)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1))
            )
        }
    }
}

// ─────────────────────────────────────────
// SYNC STATUS BADGE
// ─────────────────────────────────────────

struct SyncStatusBadge: View {
    let state: SyncState

    var body: some View {
        switch state {
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.65).tint(ChronosTheme.gold.opacity(0.5))
                Text("Syncing").font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.muted)
            }
        case .stale:
            Text("Cached").font(.jost(size: 11, weight: .light)).foregroundColor(.orange.opacity(0.6))
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .light)).foregroundColor(.orange.opacity(0.6))
        default:
            EmptyView()
        }
    }
}

// ─────────────────────────────────────────
// STATE VIEWS
// ─────────────────────────────────────────

struct ChronosSyncingView: View {
    let message: String
    var body: some View {
        VStack(spacing: 20) {
            ChronosLogoMark().frame(width: 52, height: 52).opacity(0.5)
            Text(message).font(.jost(size: 14, weight: .light)).foregroundColor(ChronosTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

struct ChronosErrorView: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .thin)).foregroundColor(ChronosTheme.gold.opacity(0.5))
            Text(message).font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.muted)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button(action: onRetry) {
                Text("Try Again").font(.jost(size: 13, weight: .medium)).foregroundColor(ChronosTheme.gold)
                    .tracking(1.5).textCase(.uppercase)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChronosTheme.gold.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

struct ChronosEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            ChronosLogoMark().frame(width: 52, height: 52).opacity(0.3)
            Text("No brief yet").font(.cormorant(size: 24)).foregroundColor(ChronosTheme.muted)
            Text("Your morning brief will appear after your\nfirst full night of Apple Watch data is synced.")
                .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.faint)
                .multilineTextAlignment(.center).lineSpacing(5).padding(.horizontal, 48)
        }
    }
}

// ─────────────────────────────────────────
// DRIVER CHIP ROW  §3.3 + §3.4
//
// §3.3 changes:
//   - Value and signal word are now on separate lines
//   - Signal word color is direction-aware: green tint (positive), amber/red (negative)
//   - Value line: metric value with unit (e.g. "23ms", "6h 45m", "12,400 steps")
//   - Signal word: "above baseline" / "below baseline" / "above goal" / etc.
//
// §3.4 changes:
//   - Deviation data (today value, baseline, direction, magnitude %)
//     computed here and passed as DriverTapContext — no new Supabase call from detail screen
// ─────────────────────────────────────────

struct DriverChipRow: View {
    let score: DailyScore
    let onChipTap: (DriverTapContext) -> Void

    @EnvironmentObject var supabase: SupabaseService
    @State private var inputs: [String: Double?] = [:]
    @State private var baselines: [String: Double] = [:]

    var body: some View {
        HStack(spacing: 12) {
            DriverChip(
                label: "PRIMARY DRIVER",
                metricRaw: score.driver1,
                chipData: chipData(for: score.driver1, isDriver1: true),
                onTap: {
                    onChipTap(buildContext(for: score.driver1, isDriver1: true))
                }
            )
            DriverChip(
                label: "SECONDARY DRIVER",
                metricRaw: score.driver2,
                chipData: chipData(for: score.driver2, isDriver1: false),
                onTap: {
                    onChipTap(buildContext(for: score.driver2, isDriver1: false))
                }
            )
        }
        .task {
            guard let userId = supabase.session?.userId else { return }
            async let i = supabase.fetchInputs(userId: userId, date: score.date)
            async let b = supabase.fetchLatestBaselines(userId: userId)
            inputs = (try? await i) ?? [:]
            baselines = (try? await b) ?? [:]
        }
    }

    // ── §3.3: Chip display data — value + signal word split ──

    struct ChipData {
        let formattedValue: String?       // e.g. "23ms" or "6h 45m"
        let signalWord: String?           // e.g. "below baseline"
        let signalIsPositive: Bool        // drives color
        let isBuilding: Bool             // true = baseline not yet established
    }

    private func chipData(for metricRaw: String, isDriver1: Bool) -> ChipData {
        let key = ChronosMetricHelpers.inputKey(for: metricRaw)
        guard let valueOpt = inputs[key], let value = valueOpt else {
            return ChipData(formattedValue: nil, signalWord: nil, signalIsPositive: true, isBuilding: false)
        }
        let formatted = ChronosMetricHelpers.formatValue(metricRaw: metricRaw, value: value)
        let baseline = baselines[ChronosMetricHelpers.baselineColumnKey(for: metricRaw)]
        if let baseline, baseline > 0 {
            let (signal, isPositive) = ChronosMetricHelpers.signalWord(metricRaw: metricRaw, value: value, baseline: baseline)
            return ChipData(formattedValue: formatted, signalWord: signal, signalIsPositive: isPositive, isBuilding: false)
        } else {
            return ChipData(formattedValue: formatted, signalWord: "building", signalIsPositive: true, isBuilding: true)
        }
    }

    private func buildContext(for metricRaw: String, isDriver1: Bool) -> DriverTapContext {
        ChronosMetricHelpers.buildContext(
            metric: metricRaw,
            isDriver1: isDriver1,
            inputs: inputs,
            baselines: baselines
        )
    }
}

// ─────────────────────────────────────────
// DRIVER CHIP  §3.3
//
// Layout per handoff:
//   DRIVER 1 / DRIVER 2   (small caps, muted — unchanged)
//   Metric name           (large, white — unchanged)
//   Value                 (own line, slightly smaller, unit included)
//   Signal word           (own line, direction-aware color)
//   ↓ Learn more          (unchanged)
// ─────────────────────────────────────────

struct DriverChip: View {
    let label: String
    let metricRaw: String
    let chipData: DriverChipRow.ChipData
    let onTap: () -> Void

    var metricName: String {
        Metric(rawValue: metricRaw)?.shortName
            ?? metricRaw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // §3.3: Green tint for positive, amber/red for negative
    var signalColor: Color {
        if chipData.isBuilding {
            return ChronosTheme.gold.opacity(0.6)  // neutral — still establishing baseline
        }
        return chipData.signalIsPositive
            ? Color(red: 0.50, green: 0.90, blue: 0.55)   // green tint
            : Color(red: 1.0, green: 0.65, blue: 0.35)    // amber
    }

    // Pill color: gold for negative signal, green for positive, muted while building
    var pillBg: Color {
        if chipData.isBuilding { return ChronosTheme.faint.opacity(0.25) }
        return chipData.signalIsPositive
            ? Color(red: 0.13, green: 0.45, blue: 0.20)
            : Color(red: 0.55, green: 0.38, blue: 0.08)
    }
    var pillFg: Color {
        if chipData.isBuilding { return ChronosTheme.muted }
        return chipData.signalIsPositive
            ? Color(red: 0.50, green: 0.90, blue: 0.55)
            : ChronosTheme.gold
    }

    private var dragLabel: String {
        label == "PRIMARY DRIVER"
            ? "Largest drag on\ntoday's score"
            : "Secondary drag on\ntoday's score"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // 1. Driver label — branded gold
                Text(label)
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                    .tracking(1.8)

                // 2. Status pill — reduced size
                if let signal = chipData.signalWord {
                    Text(signal)
                        .font(.jost(size: 10, weight: .medium))
                        .foregroundColor(pillFg)
                        .tracking(0.3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(pillBg))
                } else {
                    Capsule()
                        .fill(ChronosTheme.faint.opacity(0.15))
                        .frame(width: 80, height: 20)
                }

                // 3. Metric name + value on the same line
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metricName)
                        .font(.cormorant(size: 24, weight: .medium))
                        .foregroundColor(ChronosTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)

                    Spacer()

                    if let value = chipData.formattedValue {
                        Text(value)
                            .font(.jost(size: 18, weight: .medium))
                            .foregroundColor(ChronosTheme.gold)
                            .lineLimit(1)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ChronosTheme.faint.opacity(0.2))
                            .frame(width: 50, height: 10)
                    }
                }

                // 5. Gold divider
                Rectangle()
                    .fill(ChronosTheme.gold.opacity(0.25))
                    .frame(height: 1)
                    .padding(.top, 2)

                // 6. Bottom row: drag label + chevron
                HStack(alignment: .bottom) {
                    Text(dragLabel)
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Text("›")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(ChronosTheme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(ChronosTheme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// ─────────────────────────────────────────
// COLOR BLEND HELPER
// ─────────────────────────────────────────

private extension Color {
    func blended(with other: Color, fraction: CGFloat) -> Color {
        let f = min(max(fraction, 0), 1)
        return Color(UIColor.blend(color1: UIColor(self), color2: UIColor(other), fraction: f))
    }
}

private extension UIColor {
    static func blend(color1: UIColor, color2: UIColor, fraction: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * fraction, green: g1 + (g2 - g1) * fraction,
                       blue: b1 + (b2 - b1) * fraction, alpha: a1 + (a2 - a1) * fraction)
    }
}

// ─────────────────────────────────────────
// CORRECTION BANNER CARD  (Step 8 Part C)
// First card in the Today tab stack when flags are active.
// Non-dismissible except via its two action buttons.
// ─────────────────────────────────────────

struct CorrectionBannerCard: View {
    let flags: [CorrectionFlag]
    let score: DailyScore

    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator

    @State private var showInputSheet  = false
    @State private var showInfoSheet   = false
    @State private var currentFlagIndex = 0

    private var primaryFlag: CorrectionFlag? { flags.first }
    private var isMultiple: Bool { flags.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                Text(bannerHeadline)
                    .font(.jost(size: 15, weight: .medium))
                    .foregroundColor(ChronosTheme.text)
                Spacer()
            }

            Text(bannerBody)
                .font(.jost(size: 14, weight: .light))
                .foregroundColor(.white.opacity(0.75))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)

            HStack(spacing: 12) {
                Button { handlePrimaryAction() } label: {
                    Text(primaryButtonLabel)
                        .font(.jost(size: 13, weight: .medium))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(0.5)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(ChronosTheme.gold.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(ChronosTheme.gold.opacity(0.30), lineWidth: 1))
                        )
                }
                Button { handleSecondaryAction() } label: {
                    Text(secondaryButtonLabel)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(.white.opacity(0.55))
                        .tracking(0.5)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1))
                        )
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.14, green: 0.11, blue: 0.06))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(ChronosTheme.gold.opacity(0.25), lineWidth: 1))
        )
        .sheet(isPresented: $showInputSheet, onDismiss: {
            Task { await advanceOrReload() }
        }) {
            if let flag = flags[safe: currentFlagIndex] {
                CorrectionInputSheet(flag: flag, score: score)
                    .environmentObject(supabase)
                    .environmentObject(sync)
            }
        }
        .sheet(isPresented: $showInfoSheet) {
            if let flag = primaryFlag { CorrectionInfoSheet(flag: flag) }
        }
    }

    private var bannerHeadline: String {
        if isMultiple { return "Several readings are missing" }
        guard let flag = primaryFlag else { return "Reading needs review" }
        switch flag.reason {
        case .missing, .provisional: return "Missing \(flag.displayName)"
        case .implausible:           return "One of your readings looks off"
        }
    }

    private var bannerBody: String {
        if isMultiple {
            return "Multiple signals didn't come through last night. Your score may be incomplete. Make sure your device is worn and synced before your first morning open."
        }
        guard let flag = primaryFlag else { return "" }
        switch flag.reason {
        case .missing, .provisional: return flag.missingMessage
        case .implausible:           return "\(flag.displayName) came in outside your normal range. Want to correct it?"
        }
    }

    private var primaryButtonLabel: String {
        if isMultiple { return "Fix individually" }
        guard let flag = primaryFlag else { return "Fix it" }
        return flag.reason == .implausible ? "Yes, fix it" : "Tell me more"
    }

    private var secondaryButtonLabel: String {
        if isMultiple { return "Got it" }
        guard let flag = primaryFlag else { return "Got it" }
        return flag.reason == .implausible ? "Looks right to me" : "Got it"
    }

    private func handlePrimaryAction() {
        if isMultiple {
            currentFlagIndex = 0
            showInputSheet = true
        } else if let flag = primaryFlag {
            flag.reason == .implausible ? { currentFlagIndex = 0; showInputSheet = true }() : { showInfoSheet = true }()
        }
    }

    private func handleSecondaryAction() {
        guard let userId = supabase.session?.userId else { return }
        Task {
            for flag in flags {
                let type = flag.reason == .implausible ? "user_edit" : "missing_acknowledged"
                _ = try? await supabase.insertCorrection(
                    userId: userId, date: score.date, signalName: flag.signalKey,
                    originalValue: flag.value, correctedValue: flag.value ?? 0,
                    correctionType: type, windowExpiresAt: flag.windowExpiresAt,
                    isApplied: false, dismissed: true
                )
            }
            await sync.checkCorrectionFlags(userId: userId)
        }
    }

    private func advanceOrReload() async {
        guard let userId = supabase.session?.userId else { return }
        let next = currentFlagIndex + 1
        if next < flags.count {
            currentFlagIndex = next
            try? await Task.sleep(nanoseconds: 300_000_000)
            showInputSheet = true
        } else {
            await sync.checkCorrectionFlags(userId: userId)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// ─────────────────────────────────────────
// CORRECTION INFO SHEET  ("Tell me more")
// ─────────────────────────────────────────

struct CorrectionInfoSheet: View {
    let flag: CorrectionFlag
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ChronosTheme.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(ChronosTheme.border).frame(width: 36, height: 4).padding(.top, 12)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("MISSING SIGNAL")
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(ChronosTheme.gold).tracking(1.8).padding(.top, 28)
                        Text(flag.displayName)
                            .font(.cormorant(size: 28, weight: .light))
                            .foregroundColor(ChronosTheme.text).padding(.top, 8).padding(.bottom, 20)
                        Text(flag.missingMessage)
                            .font(.jost(size: 15, weight: .light))
                            .foregroundColor(.white.opacity(0.80)).lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
                Button { dismiss() } label: {
                    Text("GOT IT")
                        .font(.jost(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 0.10, green: 0.10, blue: 0.08))
                        .tracking(1.5).frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.gold))
                }
                .padding(.horizontal, 24).padding(.bottom, 36)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

// ─────────────────────────────────────────
// CORRECTION INPUT SHEET  (Step 8 Part D)
// ─────────────────────────────────────────

struct CorrectionInputSheet: View {
    let flag: CorrectionFlag
    let score: DailyScore

    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var inputText      = ""
    @State private var isSubmitting   = false
    @State private var showConfirmation = false
    @State private var submitError: String?
    @FocusState private var inputFocused: Bool

    private var parsedValue: Double? { Double(inputText.trimmingCharacters(in: .whitespaces)) }
    private var canSubmit: Bool { parsedValue != nil && !isSubmitting }

    var body: some View {
        ZStack {
            ChronosTheme.surface.ignoresSafeArea()
            if showConfirmation { correctionConfirmationView } else { correctionFormView }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { inputFocused = true }
    }

    private var correctionFormView: some View {
        VStack(spacing: 0) {
            Capsule().fill(ChronosTheme.border).frame(width: 36, height: 4).padding(.top, 12)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CORRECT READING")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.gold).tracking(1.8).padding(.top, 28)
                    Text(flag.displayName)
                        .font(.cormorant(size: 28, weight: .light))
                        .foregroundColor(ChronosTheme.text).padding(.top, 8).padding(.bottom, 20)

                    if let v = flag.value {
                        Text("We recorded: \(correctionFormattedOriginal(v))")
                            .font(.jost(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.55)).padding(.bottom, 24)
                    }

                    Rectangle().fill(.white.opacity(0.10)).frame(height: 1).padding(.bottom, 24)

                    Text("Enter the correct value")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(.white.opacity(0.50)).tracking(1.5).padding(.bottom, 10)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(ChronosTheme.ink)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(inputFocused
                                        ? ChronosTheme.gold.opacity(0.50)
                                        : ChronosTheme.border, lineWidth: 1))
                        if inputText.isEmpty {
                            Text("0")
                                .font(.jost(size: 24, weight: .light))
                                .foregroundColor(ChronosTheme.muted.opacity(0.4))
                                .padding(.horizontal, 16)
                        }
                        TextField("", text: $inputText)
                            .keyboardType(.decimalPad)
                            .font(.jost(size: 24, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                            .padding(.horizontal, 16)
                            .focused($inputFocused)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") { inputFocused = false }
                                        .font(.jost(size: 14, weight: .medium))
                                        .foregroundColor(ChronosTheme.gold)
                                }
                            }
                    }
                    .frame(height: 56).padding(.bottom, 8)

                    Text(flag.signalUnit)
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(.white.opacity(0.40)).padding(.bottom, 4)

                    if let err = submitError {
                        Text(err)
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })

            VStack(spacing: 8) {
                correctionSubmitButton
                Text("Your correction is private and used to improve your score.")
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24).padding(.bottom, 36)
        }
    }

    private var correctionSubmitButton: some View {
        Button {
            guard let value = parsedValue, !isSubmitting else { return }
            inputFocused = false
            isSubmitting = true
            Task { await submitCorrection(correctedValue: value) }
        } label: {
            ZStack {
                if isSubmitting {
                    ProgressView().tint(canSubmit ? Color(red: 0.10, green: 0.10, blue: 0.08) : .white.opacity(0.4))
                } else {
                    Text("SUBMIT CORRECTION")
                        .font(.jost(size: 13, weight: canSubmit ? .bold : .light))
                        .foregroundColor(canSubmit ? Color(red: 0.10, green: 0.10, blue: 0.08) : .white.opacity(0.40))
                        .tracking(1.5)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(canSubmit ? ChronosTheme.gold : Color(red: 0.165, green: 0.165, blue: 0.165))
            )
            .animation(.easeInOut(duration: 0.2), value: canSubmit)
        }
        .disabled(!canSubmit)
    }

    private func submitCorrection(correctedValue: Double) async {
        guard let userId = supabase.session?.userId else { isSubmitting = false; return }
        do {
            let correctionId = try await supabase.insertCorrection(
                userId: userId, date: score.date, signalName: flag.signalKey,
                originalValue: flag.value, correctedValue: correctedValue,
                correctionType: "user_edit", windowExpiresAt: flag.windowExpiresAt,
                isApplied: true, dismissed: false
            )
            try? await supabase.triggerScoreWithOverride(
                userId: userId, date: score.date,
                signalName: flag.signalKey, correctedValue: correctedValue
            )
            showConfirmation = true
            Task {
                do {
                    let recent = try await supabase.fetchRecentAppliedCorrections(userId: userId, signalName: flag.signalKey)
                    if recent.count >= 3 {
                        supabase.sendEscalationAlert(userId: userId, signalName: flag.signalKey, corrections: recent)
                        await supabase.markEscalationSent(correctionId: correctionId)
                    }
                } catch { print("[escalation] \(error)") }
            }
        } catch { submitError = error.localizedDescription }
        isSubmitting = false
    }

    // ── Part E — Confirmation modal ──

    private var correctionConfirmationView: some View {
        ZStack(alignment: .topTrailing) {
            ChronosTheme.surface.ignoresSafeArea()

            Button {
                dismiss()
                Task { if let uid = supabase.session?.userId { await sync.loadDashboard(userId: uid) } }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .padding(10)
                    .background(Circle().fill(ChronosTheme.ink))
            }
            .padding(.top, 20).padding(.trailing, 20)

            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(ChronosTheme.gold).padding(.bottom, 16)
                Text("Correction saved")
                    .font(.cormorant(size: 28, weight: .light))
                    .foregroundColor(.white).multilineTextAlignment(.center)
                Text("Your score has been recalculated. If this keeps happening, make sure your Watch is snug above the wrist bone and charged before sleep.")
                    .font(.jost(size: 14, weight: .light))
                    .foregroundColor(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48).padding(.top, 8).lineSpacing(4)
                Spacer()
                Button {
                    dismiss()
                    Task { if let uid = supabase.session?.userId { await sync.loadDashboard(userId: uid) } }
                } label: {
                    Text("DONE")
                        .font(.jost(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 0.10, green: 0.10, blue: 0.08))
                        .tracking(1.5).frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 14).fill(ChronosTheme.gold))
                }
                .padding(.horizontal, 24).padding(.bottom, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func correctionFormattedOriginal(_ v: Double) -> String {
        switch flag.signalKey {
        case "d1_autonomic":  return "\(Int(v))ms"
        case "d2_sleep":      return String(format: "%.1f hours", v)
        case "d3_activity":   return "\(Int(v)) (0–100)"
        case "d4_stress":     return "\(Int(v)) (0–100)"
        case "d5_allostatic": return "\(Int(v)) (0–100)"
        default:              return "\(v)"
        }
    }
}

// ─────────────────────────────────────────
// BRIEF DETAIL SHEET  (Step 9c)
// Full 7-day system narrative. Slides up from the morning brief card chevron.
// Reads detail_explanation_text from the local Explanation model — no new network call.
// ─────────────────────────────────────────

struct BriefDetailSheet: View {
    let explanation: Explanation
    @Environment(\.dismiss) private var dismiss

    private var briefLabel: String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEEE"
        let dateObj = dateFmt.date(from: explanation.date) ?? Date()
        let day = dayFmt.string(from: dateObj).uppercased()
        let hour = Calendar.current.component(.hour, from: Date())
        let isEvening = hour >= 17 && explanation.eveningExplanationText != nil
        return "\(day) \(isEvening ? "EVENING" : "MORNING") BRIEF"
    }

    private var timeContextLabel: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 5 && hour < 12 { return "This morning" }
        if hour >= 12 && hour < 17 { return "This afternoon" }
        return "Tonight"
    }

    private var sections: [(label: String, body: String)] {
        guard let text = explanation.detailExplanationText else { return [] }
        return parseBriefDetailSections(text)
    }

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header row ──
                HStack(alignment: .center) {
                    Text(briefLabel)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(2.5)
                        .textCase(.uppercase)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .padding(10)
                            .background(Circle().fill(ChronosTheme.surface))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 16)

                // ── Divider ──
                Rectangle()
                    .fill(ChronosTheme.gold.opacity(0.25))
                    .frame(height: 1)
                    .padding(.horizontal, 24)

                // ── Content ──
                if explanation.detailExplanationText == nil {
                    loadingView
                } else if sections.isEmpty {
                    loadingView
                } else {
                    narrativeScrollView
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(ChronosTheme.gold.opacity(0.6))
                .scaleEffect(1.2)
            Text("Your full brief is being prepared...")
                .font(.jost(size: 14, weight: .light))
                .foregroundColor(ChronosTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var narrativeScrollView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Five narrative sections ──
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.label)
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(ChronosTheme.gold)
                            .tracking(2.5)
                            .textCase(.uppercase)

                        Text(section.body)
                            .font(.jost(size: 15, weight: .light))
                            .foregroundColor(.white)
                            .lineSpacing(7)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 24)
                }

                // ── Nudge separator ──
                Rectangle()
                    .fill(ChronosTheme.gold.opacity(0.15))
                    .frame(height: 1)
                    .padding(.bottom, 24)

                // ── TODAY'S FOCUS nudge ──
                VStack(alignment: .leading, spacing: 10) {
                    Text("TODAY'S FOCUS")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(2.5)
                        .textCase(.uppercase)

                    Text(explanation.displayNudgeText)
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white)
                        .lineSpacing(7)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(timeContextLabel)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                        .padding(.top, 2)
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
    }
}

/// Parses `**Label**\n\nBody` sections from detail_explanation_text.
/// Splits on "**" delimiters — odd indices are labels, even indices (after first) are bodies.
/// Handles missing sections gracefully; never crashes on malformed input.
private func parseBriefDetailSections(_ text: String) -> [(label: String, body: String)] {
    let parts = text.components(separatedBy: "**")
    var sections: [(label: String, body: String)] = []
    var i = 1
    while i + 1 < parts.count {
        let label = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
        let body  = parts[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty && !body.isEmpty {
            sections.append((label: label, body: body))
        }
        i += 2
    }
    return sections
}
