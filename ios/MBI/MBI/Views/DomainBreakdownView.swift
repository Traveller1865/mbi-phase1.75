// ios/MBI/MBI/Views/DomainBreakdownView.swift
// MBI Phase 1.5 — Domain Breakdown · Sprint 3B
//
// Sprint 3B additions:
//   §3.2  System Pattern Block — deterministic detection + narrate-domains-pattern narrative
//   §3.3  Section Divider — "SYSTEM BREAKDOWN" between pattern block and cards
//   §3.4  Role tag system — DRIVER / BUFFER / ELEVATED / WATCH / STABLE / BUILDING
//   §3.4  Card border treatment — rose for DRIVER, green for BUFFER
//   §3.4  Score color system — 4-tier spec, no score below 60 renders green
//   §3.4  Semantic progress bar — score / 30d domain baseline avg, capped 1.0
//   §3.4  Conflict badge (collapsed) — cross-domain tension, single line
//   §3.4  Expanded card content — real metric values + baseline + observational line
//   §3.5  Building state copy — D4 "Day X of 7 · pattern building" / D5 variant
//   §3.6  Synthesis line — session-cached with pattern narrative, below D5
//   Tap affordance — chevron only; full-card tap NOT wired (Phase 2)

import SwiftUI

// ─────────────────────────────────────────
// PATTERN DETECTION — DETERMINISTIC LAYER
// All pattern logic computed here before any Claude call.
// Claude receives structured output and returns copy only.
// ─────────────────────────────────────────

enum DomainPattern: String {
    case loadOutpacingRecovery   = "load_outpacing_recovery"
    case hiddenStressSignal      = "hidden_stress_signal"
    case sleepProtectingRecovery = "sleep_protecting_recovery"
    case systemsInAlignment      = "systems_in_alignment"
    case recoveryUnderPressure   = "recovery_under_pressure"
    case defaultPattern          = "default"
}

enum DomainRole: String {
    case driver   = "DRIVER"
    case buffer   = "BUFFER"
    case elevated = "ELEVATED"
    case watch    = "WATCH"
    case stable   = "STABLE"
    case building = "BUILDING"
}

struct PatternResult {
    let pattern: DomainPattern
    let driverDomain: String        // e.g. "D1"
    let bufferDomain: String?
    let watchDomain: String?
    let roles: [String: DomainRole] // keyed by "D1"..."D5"
}

struct ConflictResult {
    let hasDomain: String           // e.g. "D2"
    let withDomain: String          // e.g. "D1"
    let conflictType: String        // e.g. "compensation"
    let badgeText: String           // one-line collapsed badge
}

struct PatternEngine {

    static func detect(
        d1: Double?, d2: Double?, d3: Double?,
        d4: Double?, d5: Double?,
        historyDayCount: Int
    ) -> PatternResult {

        // Use 0 for nil/building domains in pattern logic
        let v1 = d1 ?? 0
        let v2 = d2 ?? 0
        let v3 = d3 ?? 0
        let v4 = d4 ?? 0

        let d4Active = historyDayCount >= 7
        let d5Active = historyDayCount >= 30

        // Active domain scores only
        var activeDomains: [(label: String, score: Double)] = [
            ("D1", v1), ("D2", v2), ("D3", v3)
        ]
        if d4Active, let s = d4 { activeDomains.append(("D4", s)) }
        if d5Active, let s = d5 { activeDomains.append(("D5", s)) }

        // Determine pattern
        let pattern: DomainPattern
        var driverDomain = "D1"
        var bufferDomain: String? = nil
        var watchDomain: String? = nil

        if v3 >= 80 && v1 < 65 {
            pattern = .loadOutpacingRecovery
            driverDomain = "D3"
            bufferDomain = v2 >= 75 ? "D2" : nil
            watchDomain = "D1"

        } else if d4Active && v4 < 65 && v2 >= 75 && v1 < 70 {
            pattern = .hiddenStressSignal
            driverDomain = "D4"
            bufferDomain = "D2"
            watchDomain = "D1"

        } else if v2 >= 80 && v1 < 70 {
            pattern = .sleepProtectingRecovery
            driverDomain = "D2"
            bufferDomain = nil
            watchDomain = "D1"

        } else if activeDomains.count >= 3 &&
                  activeDomains.allSatisfy({ $0.score >= 65 }) {
            let scores = activeDomains.map { $0.score }
            let maxS = scores.max() ?? 0
            let minS = scores.min() ?? 0
            if maxS - minS <= 15 {
                pattern = .systemsInAlignment
                // Driver = highest active domain
                driverDomain = activeDomains.max(by: { $0.score < $1.score })?.label ?? "D1"
            } else {
                pattern = .defaultPattern
                driverDomain = activeDomains.max(by: { $0.score < $1.score })?.label ?? "D1"
            }

        } else if v1 < 60 && d4Active && v4 < 65 {
            pattern = .recoveryUnderPressure
            driverDomain = v1 <= v4 ? "D1" : "D4"
            watchDomain = driverDomain == "D1" ? "D4" : "D1"

        } else {
            pattern = .defaultPattern
            // Most deviated domain as primary driver
            let sorted = activeDomains.sorted { $0.score < $1.score }
            driverDomain = sorted.first?.label ?? "D1"
        }

        // Assign roles
        var roles: [String: DomainRole] = [:]

        // D4 building
        if !d4Active {
            roles["D4"] = .building
        }
        // D5 building
        if !d5Active {
            roles["D5"] = .building
        }

        // Active domain roles
        for item in activeDomains {
            if item.label == driverDomain {
                roles[item.label] = .driver
            } else if let buf = bufferDomain, item.label == buf {
                roles[item.label] = .buffer
            } else if let watch = watchDomain, item.label == watch {
                roles[item.label] = .watch
            } else if item.score >= 80 {
                roles[item.label] = .elevated
            } else {
                roles[item.label] = .stable
            }
        }

        return PatternResult(
            pattern: pattern,
            driverDomain: driverDomain,
            bufferDomain: bufferDomain,
            watchDomain: watchDomain,
            roles: roles
        )
    }

    // ── Fallback synthesis line — shown when narrate-domains-pattern is unavailable ──
    // Returns a deterministic one-sentence summary so the synthesis card always renders.

    static func fallbackSynthesisLine(for pattern: DomainPattern) -> String {
        switch pattern {
        case .loadOutpacingRecovery:
            return "Your body is working hard — but recovery hasn't caught up yet"
        case .hiddenStressSignal:
            return "Sleep is holding steady while stress builds quietly underneath"
        case .sleepProtectingRecovery:
            return "Sleep is doing the heavy lifting while your nervous system rebuilds"
        case .systemsInAlignment:
            return "All systems are moving in the same direction today"
        case .recoveryUnderPressure:
            return "Your body is managing load while recovery works to keep pace"
        case .defaultPattern:
            return "Recovery is holding while output lags — the system is uneven today"
        }
    }

    // ── System Read Card tag — deterministic, one of three values ───────────
    // LARGEST DEVIATION · Dx  (negative outlier driving score down)
    // ABOVE BASELINE · Dx     (strongest positive anchor)
    // CROSS-DOMAIN SIGNAL     (multi-system alignment)

    static func systemReadTag(from result: PatternResult) -> SystemReadTag {
        switch result.pattern {
        case .systemsInAlignment:
            return .crossDomainSignal
        default:
            if let driverKey = result.roles.first(where: { $0.value == .driver })?.key {
                return .largestDeviation(domain: driverKey)
            }
            if let bufferKey = result.roles.first(where: { $0.value == .buffer })?.key {
                return .aboveBaseline(domain: bufferKey)
            }
            return .crossDomainSignal
        }
    }

    // ── Conflict detection ───────────────────────────────────────────────────
    // Returns conflicts for cards that should show a collapsed badge.

    static func detectConflicts(
        d1: Double?, d2: Double?, d3: Double?, d4: Double?,
        historyDayCount: Int
    ) -> [ConflictResult] {
        var conflicts: [ConflictResult] = []

        let v1 = d1 ?? 0
        let v2 = d2 ?? 0
        let v3 = d3 ?? 0
        let d4Active = historyDayCount >= 7

        // Sleep strong but autonomic hasn't followed
        if let _ = d2, let _ = d1, v2 >= 75 && v1 < 65 {
            conflicts.append(ConflictResult(
                hasDomain: "D2",
                withDomain: "D1",
                conflictType: "compensation",
                badgeText: "Sleep strong — but autonomic recovery hasn't followed yet"
            ))
        }

        // Activity elevated but recovery hasn't kept pace
        if let _ = d3, let _ = d1, v3 >= 80 && v1 < 70 {
            conflicts.append(ConflictResult(
                hasDomain: "D3",
                withDomain: "D1",
                conflictType: "suppression",
                badgeText: "Activity elevated — recovery hasn't kept pace"
            ))
        }

        // Stress building while sleep holding
        if d4Active, let _ = d4, let _ = d2, (d4 ?? 0) < 65 && v2 >= 75 {
            conflicts.append(ConflictResult(
                hasDomain: "D4",
                withDomain: "D2",
                conflictType: "suppression",
                badgeText: "Stress pattern building despite good sleep"
            ))
        }

        return conflicts
    }
}

// ─────────────────────────────────────────
// SYSTEM READ TAG
// Deterministic — one tag shown on the System Read Card.
// ─────────────────────────────────────────

enum SystemReadTag {
    case largestDeviation(domain: String)
    case aboveBaseline(domain: String)
    case crossDomainSignal

    var label: String {
        switch self {
        case .largestDeviation(let d): return "LARGEST DEVIATION · \(d)"
        case .aboveBaseline(let d):    return "ABOVE BASELINE · \(d)"
        case .crossDomainSignal:       return "CROSS-DOMAIN SIGNAL"
        }
    }

    var tagColor: Color {
        switch self {
        case .largestDeviation: return Color(hex: "E07070")
        case .aboveBaseline:    return Color(hex: "4ADE80")
        case .crossDomainSignal: return Color(hex: "C9A84C")
        }
    }
}

// ─────────────────────────────────────────
// NARRATIVE MODELS
// Returned by narrate-domains-pattern and narrate-domain-expanded.
// ─────────────────────────────────────────

struct DomainPatternNarrative {
    let patternTitle: String       // max 6 words, no punctuation
    let patternBody: String        // max 80 tokens, 2-3 sentences
    let synthesisLine: String      // max 30 tokens, 1 sentence
}

struct DomainExpandedNarrative {
    let observationalLine: String  // max 40 tokens
    let conflictElaboration: String? // max 60 tokens or nil
}

struct ThirtyDayNarrative {
    let synthesisText: String  // 1-2 sentences, 60 token budget
}

// ─────────────────────────────────────────
// DOMAIN BREAKDOWN VIEW
// ─────────────────────────────────────────

// Identifies which domain should open the Detail sheet (Identifiable for .sheet(item:))
struct DomainDetailContext: Identifiable {
    let id:       String   // label is unique per view instance — serves as stable ID
    let label:    String
    let title:    String
    let subtitle: String
}

struct DomainBreakdownView: View {
    @EnvironmentObject var sync: SyncCoordinator
    @EnvironmentObject var supabase: SupabaseService

    @State private var historyDayCount: Int = 0
    @State private var rawMetrics: DomainRawMetrics = .empty
    @State private var domainBaselines: DomainBaselines = .empty
    @State private var perMetricBaselines: [String: Double] = [:]

    // Pattern narrative — session-cached on first load
    @State private var patternNarrative: DomainPatternNarrative? = nil
    @State private var patternNarrativeLoading: Bool = false

    // Expanded narratives — keyed by domain label, generated on expand
    @State private var expandedNarratives: [String: DomainExpandedNarrative] = [:]

    // 30-day mode narrative — session-cached on first mode toggle
    @State private var thirtyDayNarrative: ThirtyDayNarrative? = nil
    @State private var thirtyDayNarrativeLoading: Bool = false

    // Sprint 7: Domain Detail sheet
    @State private var domainDetailContext: DomainDetailContext? = nil

    // Phase 2: Pattern Detail drill-through
    @State private var showPatternDetail = false
    @State private var patternDetailSnapshot: PatternDetailSnapshot? = nil

    // Phase 2: Historical domain comparison
    @AppStorage("domains_show_history") private var showHistoryMode: Bool = false
    @State private var domainHistories: [String: [(date: String, value: Double)]] = [:]
    @State private var historiesLoading = false

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [ChronosTheme.gold.opacity(0.04), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 300
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    DomainsHeader(showHistory: showHistoryMode)

                    // Phase 2: Mode toggle — TODAY / 30 DAYS
                    HStack {
                        Spacer()
                        DomainModeToggle(showHistory: $showHistoryMode)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                    if showHistoryMode {
                        DomainHistoryPanel(
                            histories: domainHistories,
                            isLoading: historiesLoading,
                            historyDayCount: historyDayCount,
                            todayScore: sync.dashboard?.score,
                            thirtyDayNarrative: thirtyDayNarrative,
                            isNarrativeLoading: thirtyDayNarrativeLoading,
                            onPatternDetailTap: {
                                if let score = sync.dashboard?.score {
                                    let patternResult = PatternEngine.detect(
                                        d1: score.d1Autonomic, d2: score.d2Sleep, d3: score.d3Activity,
                                        d4: score.d4Stress, d5: score.d5Allostatic,
                                        historyDayCount: historyDayCount
                                    )
                                    let conflicts = PatternEngine.detectConflicts(
                                        d1: score.d1Autonomic, d2: score.d2Sleep,
                                        d3: score.d3Activity, d4: score.d4Stress,
                                        historyDayCount: historyDayCount
                                    )
                                    patternDetailSnapshot = PatternDetailSnapshot(
                                        patternResult: patternResult,
                                        narrative: patternNarrative,
                                        conflicts: conflicts,
                                        score: score,
                                        historyDayCount: historyDayCount,
                                        window: .thirtyDay
                                    )
                                    showPatternDetail = true
                                }
                            }
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 48)
                    } else if let score = sync.dashboard?.score {

                        let patternResult = PatternEngine.detect(
                            d1: score.d1Autonomic,
                            d2: score.d2Sleep,
                            d3: score.d3Activity,
                            d4: score.d4Stress,
                            d5: score.d5Allostatic,
                            historyDayCount: historyDayCount
                        )

                        let conflicts = PatternEngine.detectConflicts(
                            d1: score.d1Autonomic,
                            d2: score.d2Sleep,
                            d3: score.d3Activity,
                            d4: score.d4Stress,
                            historyDayCount: historyDayCount
                        )

                        VStack(spacing: 0) {

                            // §3.2 System Pattern Block — Phase 2: tappable drill-through
                            // S12: historyDayCount passed to enforce 14-day pattern visibility gate
                            SystemPatternBlock(
                                patternResult: patternResult,
                                narrative: patternNarrative,
                                isLoading: patternNarrativeLoading,
                                historyDayCount: historyDayCount
                            ) {
                                patternDetailSnapshot = PatternDetailSnapshot(
                                    patternResult: patternResult,
                                    narrative: patternNarrative,
                                    conflicts: conflicts,
                                    score: score,
                                    historyDayCount: historyDayCount
                                )
                                showPatternDetail = true
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)

                            // §3.3 Section Divider
                            SectionDividerLabel(text: "SYSTEM BREAKDOWN")
                                .padding(.horizontal, 20)
                                .padding(.bottom, 14)

                            // §3.4 Domain Cards
                            VStack(spacing: 10) {

                                ChronosDomainCard(
                                    label: "D1",
                                    title: "Autonomic Recovery",
                                    subtitle: "HRV · Resting HR",
                                    score: score.d1Autonomic,
                                    isActive: true,
                                    role: patternResult.roles["D1"] ?? .stable,
                                    conflict: conflicts.first(where: { $0.hasDomain == "D1" }),
                                    domainBaseline: domainBaselines.d1Autonomic,
                                    rawMetrics: rawMetrics,
                                    perMetricBaselines: perMetricBaselines,
                                    expandedNarrative: expandedNarratives["D1"],
                                    onExpandRequest: { fetchExpandedNarrative(domain: "D1", score: score.d1Autonomic) },
                                    onDetailTap: { domainDetailContext = DomainDetailContext(id: "D1", label: "D1", title: "Autonomic Recovery", subtitle: "HRV · Resting HR") }
                                )

                                ChronosDomainCard(
                                    label: "D2",
                                    title: "Sleep Recovery",
                                    subtitle: "Duration · Quality",
                                    score: score.d2Sleep,
                                    isActive: true,
                                    role: patternResult.roles["D2"] ?? .stable,
                                    conflict: conflicts.first(where: { $0.hasDomain == "D2" }),
                                    domainBaseline: domainBaselines.d2Sleep,
                                    rawMetrics: rawMetrics,
                                    perMetricBaselines: perMetricBaselines,
                                    expandedNarrative: expandedNarratives["D2"],
                                    onExpandRequest: { fetchExpandedNarrative(domain: "D2", score: score.d2Sleep) },
                                    onDetailTap: { domainDetailContext = DomainDetailContext(id: "D2", label: "D2", title: "Sleep Recovery", subtitle: "Duration · Quality") }
                                )

                                ChronosDomainCard(
                                    label: "D3",
                                    title: "Activity Load",
                                    subtitle: "Steps · Active min",
                                    score: score.d3Activity,
                                    isActive: true,
                                    role: patternResult.roles["D3"] ?? .stable,
                                    conflict: conflicts.first(where: { $0.hasDomain == "D3" }),
                                    domainBaseline: domainBaselines.d3Activity,
                                    rawMetrics: rawMetrics,
                                    perMetricBaselines: perMetricBaselines,
                                    expandedNarrative: expandedNarratives["D3"],
                                    onExpandRequest: { fetchExpandedNarrative(domain: "D3", score: score.d3Activity) },
                                    onDetailTap: { domainDetailContext = DomainDetailContext(id: "D3", label: "D3", title: "Activity Load", subtitle: "Steps · Active min") }
                                )

                                ChronosDomainCard(
                                    label: "D4",
                                    title: "Inferred Stress",
                                    subtitle: "7-day pattern",
                                    score: score.d4Stress,
                                    isActive: historyDayCount >= 7,
                                    role: patternResult.roles["D4"] ?? .building,
                                    conflict: conflicts.first(where: { $0.hasDomain == "D4" }),
                                    domainBaseline: domainBaselines.d4Stress,
                                    rawMetrics: rawMetrics,
                                    perMetricBaselines: perMetricBaselines,
                                    expandedNarrative: expandedNarratives["D4"],
                                    buildingMessage: historyDayCount < 7
                                        ? "Day \(historyDayCount) of 7 · pattern building"
                                        : nil,
                                    onExpandRequest: { fetchExpandedNarrative(domain: "D4", score: score.d4Stress) },
                                    onDetailTap: historyDayCount >= 7 ? { domainDetailContext = DomainDetailContext(id: "D4", label: "D4", title: "Inferred Stress", subtitle: "7-day pattern") } : { }
                                )

                                ChronosDomainCard(
                                    label: "D5",
                                    title: "Allostatic Trend",
                                    subtitle: "30-day composite",
                                    score: score.d5Allostatic,
                                    isActive: historyDayCount >= 30,
                                    role: patternResult.roles["D5"] ?? .building,
                                    conflict: nil,
                                    domainBaseline: domainBaselines.d5Allostatic,
                                    rawMetrics: rawMetrics,
                                    perMetricBaselines: perMetricBaselines,
                                    expandedNarrative: expandedNarratives["D5"],
                                    buildingMessage: historyDayCount < 30
                                        ? "Day \(historyDayCount) of 30 · building your long-arc baseline"
                                        : nil,
                                    onExpandRequest: { fetchExpandedNarrative(domain: "D5", score: score.d5Allostatic) },
                                    onDetailTap: historyDayCount >= 30 ? { domainDetailContext = DomainDetailContext(id: "D5", label: "D5", title: "Allostatic Trend", subtitle: "30-day composite") } : { }
                                )

                                // D4/D5 disclosure — these are snapshot-derived signals, not
                                // validated index scores. Beta users should understand their nature.
                                HStack(spacing: 6) {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 10, weight: .light))
                                        .foregroundColor(ChronosTheme.faint)
                                    Text("D4 and D5 are snapshot-derived signals, not validated index scores. They improve with more data.")
                                        .font(.jost(size: 10, weight: .light))
                                        .foregroundColor(ChronosTheme.faint)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 4)
                                .padding(.top, 2)

                                // §3.6 Synthesis Line — below D5, above Allostatic Portrait
                                // Shows narrative synthesis when available, fallback when Edge Fn 404
                                let synthesisText = patternNarrative?.synthesisLine
                                    ?? PatternEngine.fallbackSynthesisLine(for: patternResult.pattern)
                                SynthesisLineCard(text: synthesisText)
                                    .padding(.top, 4)

                                // ── Allostatic Portrait (E-11) — unchanged ──
                                if score.d5Allostatic != nil {
                                    AllostaticPortraitCard()
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 48)
                        }

                    } else {
                        DomainsEmptyView()
                            .padding(.top, 60)
                    }
                }
            }
        }
        .task {
            guard let userId = supabase.session?.userId else { return }

            async let dayCount  = supabase.fetchHistoryDayCount(userId: userId)
            async let inputs    = supabase.fetchLatestDailyInputs(userId: userId)
            async let bases     = supabase.fetchDomainBaselines(userId: userId)
            async let perMetric = supabase.fetchLatestBaselines(userId: userId)

            historyDayCount     = (try? await dayCount) ?? 0
            rawMetrics          = (try? await inputs) ?? .empty
            domainBaselines     = (try? await bases) ?? .empty
            perMetricBaselines  = (try? await perMetric) ?? [:]

            // Fetch pattern narrative after data loads — session-cached
            if let score = sync.dashboard?.score {
                await fetchPatternNarrative(score: score)
            }

            // Phase 2: pre-fetch domain histories if history mode is already on
            if showHistoryMode {
                await fetchDomainHistories(userId: userId)
            }
        }
        .onChange(of: showHistoryMode) { _, isOn in
            guard isOn else { return }
            guard let userId = supabase.session?.userId else { return }
            if domainHistories.isEmpty {
                Task { await fetchDomainHistories(userId: userId) }
            }
            // Fetch 30-day narrative on first toggle — session cached
            if thirtyDayNarrative == nil {
                Task { await fetchThirtyDayNarrative() }
            }
        }
        // Sprint 7: Domain Detail sheet
        .sheet(item: $domainDetailContext) { ctx in
            let score = sync.dashboard?.score
            let domainScore: Double? = {
                switch ctx.label {
                case "D1": return score?.d1Autonomic
                case "D2": return score?.d2Sleep
                case "D3": return score?.d3Activity
                case "D4": return score?.d4Stress
                case "D5": return score?.d5Allostatic
                default:   return nil
                }
            }()
            let domainBase: Double? = {
                switch ctx.label {
                case "D1": return domainBaselines.d1Autonomic
                case "D2": return domainBaselines.d2Sleep
                case "D3": return domainBaselines.d3Activity
                case "D4": return domainBaselines.d4Stress
                case "D5": return domainBaselines.d5Allostatic
                default:   return nil
                }
            }()
            let conflicts = score.map {
                PatternEngine.detectConflicts(
                    d1: $0.d1Autonomic, d2: $0.d2Sleep,
                    d3: $0.d3Activity, d4: $0.d4Stress,
                    historyDayCount: historyDayCount
                )
            } ?? []
            let patternResult = score.map {
                PatternEngine.detect(
                    d1: $0.d1Autonomic, d2: $0.d2Sleep, d3: $0.d3Activity,
                    d4: $0.d4Stress, d5: $0.d5Allostatic,
                    historyDayCount: historyDayCount
                )
            }

            DomainDetailView(
                label:             ctx.label,
                title:             ctx.title,
                subtitle:          ctx.subtitle,
                score:             domainScore,
                domainBaseline:    domainBase,
                role:              patternResult?.roles[ctx.label] ?? .stable,
                conflict:          conflicts.first(where: { $0.hasDomain == ctx.label }),
                rawMetrics:        rawMetrics,
                perMetricBaselines: perMetricBaselines,
                expandedNarrative: expandedNarratives[ctx.label],
                historyDayCount:   historyDayCount,
                allScores:         score,
                allRoles:          patternResult?.roles ?? [:],
                allBaselines:      domainBaselines
            )
            .environmentObject(supabase)
            .environmentObject(sync)
        }
        // Phase 2: Pattern Detail drill-through
        .sheet(isPresented: $showPatternDetail) {
            if let snap = patternDetailSnapshot {
                PatternDetailView(snapshot: snap)
            }
        }
    }

    // ── Narrative fetches ────────────────────────────────────────────────────

    private func fetchPatternNarrative(score: DailyScore) async {
        guard patternNarrative == nil else { return }  // session cache — don't re-fetch
        patternNarrativeLoading = true

        let pattern = PatternEngine.detect(
            d1: score.d1Autonomic, d2: score.d2Sleep, d3: score.d3Activity,
            d4: score.d4Stress, d5: score.d5Allostatic,
            historyDayCount: historyDayCount
        )

        let payload: [String: Any] = [
            "userId":          supabase.session?.userId ?? "",
            "pattern_type":    pattern.pattern.rawValue,
            "driver_domain":   pattern.driverDomain,
            "buffer_domain":   pattern.bufferDomain as Any,
            "watch_domain":    pattern.watchDomain as Any,
            "domain_scores":   [
                "d1": score.d1Autonomic as Any,
                "d2": score.d2Sleep as Any,
                "d3": score.d3Activity as Any,
                "d4": score.d4Stress as Any,
                "d5": score.d5Allostatic as Any
            ],
            "days_of_history": historyDayCount
        ]

        do {
            let result = try await supabase.callDomainEdgeFunction(
                url: Config.narrateDomainsPatternURL,
                body: payload
            )
            if let title = result["pattern_title"] as? String,
               let body  = result["pattern_body"] as? String,
               let synth = result["synthesis_line"] as? String {
                patternNarrative = DomainPatternNarrative(
                    patternTitle: title,
                    patternBody: body,
                    synthesisLine: synth
                )
            }
        } catch {
            print("[DomainBreakdownView] narrate-domains-pattern failed: \(error)")
        }
        patternNarrativeLoading = false
    }

    private func fetchExpandedNarrative(domain: String, score: Double?) {
        guard expandedNarratives[domain] == nil else { return }
        guard let score = score else { return }

        let conflicts = PatternEngine.detectConflicts(
            d1: sync.dashboard?.score.d1Autonomic,
            d2: sync.dashboard?.score.d2Sleep,
            d3: sync.dashboard?.score.d3Activity,
            d4: sync.dashboard?.score.d4Stress,
            historyDayCount: historyDayCount
        )
        let conflict = conflicts.first(where: { $0.hasDomain == domain })

        let metricValues   = rawMetricValues(for: domain)
        let baselineValues = rawBaselineValues(for: domain)

        var payload: [String: Any] = [
            "userId":          supabase.session?.userId ?? "",
            "domain":          domain,
            "score":           score,
            "metric_values":   metricValues,
            "baseline_values": baselineValues
        ]
        if let c = conflict {
            payload["conflict_domain"] = c.withDomain
            payload["conflict_type"]   = c.conflictType
        }

        Task {
            do {
                let result = try await supabase.callDomainEdgeFunction(
                    url: Config.narrateDomainExpandedURL,
                    body: payload
                )
                if let line = result["observational_line"] as? String {
                    let elab = result["conflict_elaboration"] as? String
                    expandedNarratives[domain] = DomainExpandedNarrative(
                        observationalLine: line,
                        conflictElaboration: elab
                    )
                }
            } catch {
                print("[DomainBreakdownView] narrate-domain-expanded \(domain) failed: \(error)")
            }
        }
    }

    // ── Fetch all 5 domain histories in parallel (Phase 2) ──────────────────

    private func fetchDomainHistories(userId: String) async {
        historiesLoading = true
        async let h1 = supabase.fetchDomainHistory(userId: userId, column: "d1_autonomic")
        async let h2 = supabase.fetchDomainHistory(userId: userId, column: "d2_sleep")
        async let h3 = supabase.fetchDomainHistory(userId: userId, column: "d3_activity")
        async let h4 = supabase.fetchDomainHistory(userId: userId, column: "d4_stress")
        async let h5 = supabase.fetchDomainHistory(userId: userId, column: "d5_allostatic")
        domainHistories["D1"] = (try? await h1) ?? []
        domainHistories["D2"] = (try? await h2) ?? []
        domainHistories["D3"] = (try? await h3) ?? []
        domainHistories["D4"] = (try? await h4) ?? []
        domainHistories["D5"] = (try? await h5) ?? []
        historiesLoading = false
    }

    // ── 30-day narrative fetch ───────────────────────────────────────────────

    private func fetchThirtyDayNarrative() async {
        guard thirtyDayNarrative == nil else { return }   // session cache
        guard let userId = supabase.session?.userId else { return }
        thirtyDayNarrativeLoading = true

        // Compute avg + std-dev (volatility) per domain from 30-day histories
        func stats(_ history: [(date: String, value: Double)]) -> (avg: Double?, vol: Double?) {
            let vals = history.map { $0.value }
            guard !vals.isEmpty else { return (nil, nil) }
            let avg = vals.reduce(0, +) / Double(vals.count)
            let vol = vals.count > 1
                ? sqrt(vals.reduce(0) { $0 + pow($1 - avg, 2) } / Double(vals.count))
                : nil
            return (avg, vol)
        }

        let s1 = stats(domainHistories["D1"] ?? [])
        let s2 = stats(domainHistories["D2"] ?? [])
        let s3 = stats(domainHistories["D3"] ?? [])
        let s4 = stats(domainHistories["D4"] ?? [])
        let s5 = stats(domainHistories["D5"] ?? [])

        let payload: [String: Any] = [
            "userId":          userId,
            "d1_avg":          s1.avg as Any,
            "d1_volatility":   s1.vol as Any,
            "d2_avg":          s2.avg as Any,
            "d2_volatility":   s2.vol as Any,
            "d3_avg":          s3.avg as Any,
            "d3_volatility":   s3.vol as Any,
            "d4_avg":          s4.avg as Any,
            "d4_volatility":   s4.vol as Any,
            "d5_avg":          s5.avg as Any,
            "d5_volatility":   s5.vol as Any,
            "days_of_history": historyDayCount
        ]

        do {
            let result = try await supabase.callDomainEdgeFunction(
                url: Config.narrateDomains30DayURL,
                body: payload
            )
            if let text = result["synthesis_text"] as? String {
                thirtyDayNarrative = ThirtyDayNarrative(synthesisText: text)
            }
        } catch {
            print("[DomainBreakdownView] narrate-domains-30day failed: \(error)")
        }
        thirtyDayNarrativeLoading = false
    }

    // ── Metric/baseline value maps for Edge Function payload ────────────────

    private func rawMetricValues(for domain: String) -> [String: Double?] {
        switch domain {
        case "D1": return ["hrv_ms": rawMetrics.hrv_ms, "resting_hr_bpm": rawMetrics.resting_hr_bpm]
        case "D2": return ["sleep_duration_hrs": rawMetrics.sleep_duration_hrs, "sleep_continuity_pct": rawMetrics.sleep_continuity_pct]
        case "D3": return ["steps": rawMetrics.steps, "active_minutes": rawMetrics.active_minutes]
        case "D4": return [:]  // D4 has no raw input metrics
        case "D5": return [:]  // D5 is composite only
        default:   return [:]
        }
    }

    private func rawBaselineValues(for domain: String) -> [String: Double?] {
        // Domain-level baseline — the same value used for the progress bar
        switch domain {
        case "D1": return ["d1_baseline": domainBaselines.d1Autonomic]
        case "D2": return ["d2_baseline": domainBaselines.d2Sleep]
        case "D3": return ["d3_baseline": domainBaselines.d3Activity]
        case "D4": return ["d4_baseline": domainBaselines.d4Stress]
        case "D5": return ["d5_baseline": domainBaselines.d5Allostatic]
        default:   return [:]
        }
    }
}

// ─────────────────────────────────────────
// HEADER — unchanged from prior implementation
// ─────────────────────────────────────────

struct DomainsHeader: View {
    var showHistory: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FIVE SYSTEMS")
                .font(.jost(size: 10, weight: .light))
                .foregroundColor(ChronosTheme.gold)
                .tracking(3)

            Text("One picture.")
                .font(.cormorant(size: 32, weight: .light))
                .foregroundColor(ChronosTheme.text)

            Text(showHistory
                 ? "How each system has trended over the last 30 days."
                 : "How each system performed today relative to your baseline.")
                .font(.jost(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.muted)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }
}

// ─────────────────────────────────────────
// SYSTEM PATTERN BLOCK  §3.2
// Leads the screen. Gold border treatment.
// Designed with expandable architecture — do not couple height to current content.
// ─────────────────────────────────────────

struct SystemPatternBlock: View {
    let patternResult: PatternResult
    let narrative: DomainPatternNarrative?
    let isLoading: Bool
    var historyDayCount: Int = 0               // S12: pattern visibility gate
    var onDetailTap: (() -> Void)? = nil       // Phase 2: drill-through

    // S12: Patterns require at least 14 days of history to be meaningful.
    // With fewer days the cross-domain comparison is unreliable.
    private static let minimumPatternDays = 14

    var body: some View {
        if historyDayCount < Self.minimumPatternDays {
            // S12: Under-threshold placeholder — never show misleading early patterns
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 16, weight: .ultraLight))
                    .foregroundColor(ChronosTheme.gold.opacity(0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("SYSTEM PATTERN")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.gold.opacity(0.5))
                        .tracking(2.5)
                    Text("Patterns unlock after \(Self.minimumPatternDays) days of data. Day \(historyDayCount) of \(Self.minimumPatternDays).")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .lineSpacing(3)
                }
                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(ChronosTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1))
            )
        } else {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.11, green: 0.10, blue: 0.17),
                        Color(red: 0.08, green: 0.07, blue: 0.13)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.gold.opacity(0.35), lineWidth: 1)
                )

            // Gold top border
            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, ChronosTheme.gold.opacity(0.6), .clear],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 1)
                    .clipShape(.rect(topLeadingRadius: 16, topTrailingRadius: 16))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {

                // Eyebrow + info button row
                HStack {
                    Text("TODAY'S SYSTEM READ")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(3)
                    Spacer()
                    if !isLoading, let onTap = onDetailTap {
                        Button(action: onTap) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 15, weight: .light))
                                .foregroundColor(ChronosTheme.gold.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isLoading {
                    // Loading state — skeleton
                    VStack(alignment: .leading, spacing: 8) {
                        skeletonLine(width: .infinity, height: 14)
                        skeletonLine(width: 240, height: 14)
                    }
                } else {
                    // Headline sentence — Claude synthesisLine or deterministic fallback
                    let headlineText = narrative?.synthesisLine
                        ?? PatternEngine.fallbackSynthesisLine(for: patternResult.pattern)
                    Text(headlineText)
                        .font(.cormorant(size: 20, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .fixedSize(horizontal: false, vertical: true)

                    // System read tag — one deterministic tag
                    let tag = PatternEngine.systemReadTag(from: patternResult)
                    SystemReadTagPill(tag: tag)
                }

                // "Why this pattern" link
                if !isLoading, let onTap = onDetailTap {
                    Rectangle()
                        .fill(ChronosTheme.gold.opacity(0.12))
                        .frame(height: 1)
                        .padding(.top, 2)

                    Button(action: onTap) {
                        HStack(spacing: 6) {
                            Text("Why this pattern")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.gold.opacity(0.70))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .light))
                                .foregroundColor(ChronosTheme.gold.opacity(0.55))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        } // end else (S12: historyDayCount >= minimumPatternDays)
    }

    private func rolePills(from result: PatternResult) -> [(String, String)] {
        var pills: [(String, String)] = []
        if let driverLabel = result.roles.first(where: { $0.value == .driver })?.key {
            pills.append(("PRIMARY DRIVER", driverLabel))
        }
        if let bufferLabel = result.roles.first(where: { $0.value == .buffer })?.key {
            pills.append(("PROTECTING", bufferLabel))
        }
        if let watchLabel = result.roles.first(where: { $0.value == .watch })?.key {
            pills.append(("WATCH", watchLabel))
        }
        return pills
    }

    private func patternFallbackTitle(_ pattern: DomainPattern) -> String {
        switch pattern {
        case .loadOutpacingRecovery:   return "Load outpacing recovery"
        case .hiddenStressSignal:      return "Hidden stress signal"
        case .sleepProtectingRecovery: return "Sleep protecting recovery"
        case .systemsInAlignment:      return "Systems in alignment"
        case .recoveryUnderPressure:   return "Recovery under pressure"
        case .defaultPattern:          return "System read"
        }
    }

    @ViewBuilder
    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        if width == .infinity {
            RoundedRectangle(cornerRadius: 3)
                .fill(ChronosTheme.faint.opacity(0.15))
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(ChronosTheme.faint.opacity(0.15))
                .frame(width: width, height: height)
        }
    }
}

struct RolePill: View {
    let label: String
    let domain: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.jost(size: 8, weight: .medium))
                .foregroundColor(ChronosTheme.gold.opacity(0.75))
                .tracking(1.5)
            Text("·")
                .font(.jost(size: 8, weight: .light))
                .foregroundColor(ChronosTheme.faint)
            Text(domain)
                .font(.jost(size: 8, weight: .medium))
                .foregroundColor(ChronosTheme.gold)
                .tracking(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(ChronosTheme.goldDim.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ChronosTheme.gold.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// ─────────────────────────────────────────
// SYSTEM READ TAG PILL
// One deterministic tag on the System Read Card.
// ─────────────────────────────────────────

struct SystemReadTagPill: View {
    let tag: SystemReadTag

    var body: some View {
        Text(tag.label)
            .font(.jost(size: 8, weight: .medium))
            .foregroundColor(tag.tagColor)
            .tracking(1.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tag.tagColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(tag.tagColor.opacity(0.25), lineWidth: 1)
                    )
            )
    }
}

// ─────────────────────────────────────────
// 30-DAY SYSTEM READ BLOCK  §3.8
// Shown at top of 30-day mode. Claude-generated synthesis, session-cached.
// ─────────────────────────────────────────

struct ThirtyDaySystemReadBlock: View {
    let narrative: ThirtyDayNarrative?
    let isLoading: Bool
    var onDetailTap: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [Color(red: 0.11, green: 0.10, blue: 0.17),
                             Color(red: 0.08, green: 0.07, blue: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.gold.opacity(0.35), lineWidth: 1)
                )

            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, ChronosTheme.gold.opacity(0.55), .clear],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 1)
                    .clipShape(.rect(topLeadingRadius: 16, topTrailingRadius: 16))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("30-DAY SYSTEM READ")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                    .tracking(3)

                if isLoading {
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ChronosTheme.faint.opacity(0.15))
                            .frame(maxWidth: .infinity).frame(height: 12)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ChronosTheme.faint.opacity(0.10))
                            .frame(width: 200, height: 12)
                    }
                } else {
                    let text = narrative?.synthesisText
                        ?? "Your domain scores show variation across the past 30 days. Check each system below for detail."
                    Text(text)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let onTap = onDetailTap {
                    Rectangle()
                        .fill(ChronosTheme.gold.opacity(0.12))
                        .frame(height: 1)
                    Button(action: onTap) {
                        HStack(spacing: 6) {
                            Text("View pattern details")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.gold.opacity(0.70))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .light))
                                .foregroundColor(ChronosTheme.gold.opacity(0.55))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
    }
}

// ─────────────────────────────────────────
// SECTION DIVIDER  §3.3
// ─────────────────────────────────────────

struct SectionDividerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(ChronosTheme.gold.opacity(0.15))
                .frame(height: 1)
            Text(text)
                .font(.jost(size: 9, weight: .light))
                .foregroundColor(ChronosTheme.gold.opacity(0.5))
                .tracking(3)
                .fixedSize()
            Rectangle()
                .fill(ChronosTheme.gold.opacity(0.15))
                .frame(height: 1)
        }
    }
}

// ─────────────────────────────────────────
// DOMAIN CARD  §3.4
// ─────────────────────────────────────────

struct ChronosDomainCard: View {
    let label: String
    let title: String
    let subtitle: String
    let score: Double?
    let isActive: Bool
    let role: DomainRole
    let conflict: ConflictResult?
    let domainBaseline: Double?
    let rawMetrics: DomainRawMetrics
    let perMetricBaselines: [String: Double]
    let expandedNarrative: DomainExpandedNarrative?
    var buildingMessage: String? = nil
    let onExpandRequest: () -> Void
    var onDetailTap: (() -> Void)? = nil   // Sprint 7: full-card tap → DomainDetailView

    @State private var isExpanded = false

    // ── Score color — 4-tier spec, no score below 60 renders green ──────────
    var scoreColor: Color {
        guard let s = score else { return Color(hex: "7A8FA6") }  // building blue-grey
        if s >= 80 { return Color(hex: "4ADE80") }               // Strong — green
        if s >= 60 { return Color(hex: "C9A84C") }               // Moderate — gold
        if s >= 40 { return Color(hex: "B0936A") }               // Below baseline — warm tan
        return Color(hex: "E07070")                               // Low — rose
    }

    // ── Card border — role-driven ─────────────────────────────────────────
    var cardBorderColor: Color {
        switch role {
        case .driver:   return Color(red: 0.878, green: 0.439, blue: 0.439).opacity(0.25) // rose
        case .buffer:   return Color(red: 0.290, green: 0.871, blue: 0.502).opacity(0.18) // green
        default:        return isActive ? ChronosTheme.gold.opacity(0.18) : ChronosTheme.border
        }
    }

    // ── Semantic progress bar fill ────────────────────────────────────────
    var progressFill: CGFloat {
        guard let s = score, let baseline = domainBaseline, baseline > 0 else {
            return score.map { CGFloat($0 / 100) } ?? 0
        }
        return min(CGFloat(s / baseline), 1.0)
    }

    // ── Progress bar gradient — follows score color tier ─────────────────
    var barGradient: LinearGradient {
        guard let s = score else {
            return LinearGradient(colors: [Color(hex: "7A8FA6").opacity(0.3)], startPoint: .leading, endPoint: .trailing)
        }
        if s >= 80 {
            return LinearGradient(colors: [Color(hex: "4ADE80").opacity(0.6), Color(hex: "4ADE80")], startPoint: .leading, endPoint: .trailing)
        }
        if s >= 60 {
            return LinearGradient(colors: [ChronosTheme.gold.opacity(0.6), ChronosTheme.goldLight], startPoint: .leading, endPoint: .trailing)
        }
        if s >= 40 {
            return LinearGradient(colors: [Color(hex: "B0936A").opacity(0.7), Color(hex: "B0936A")], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [Color(hex: "E07070").opacity(0.6), Color(hex: "E07070")], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.098, green: 0.098, blue: 0.157),
                        Color(red: 0.071, green: 0.071, blue: 0.118)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(cardBorderColor, lineWidth: 1)
                )

            if isActive {
                VStack {
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.clear, ChronosTheme.gold.opacity(0.5), .clear],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(height: 1)
                        .clipShape(.rect(topLeadingRadius: 16, topTrailingRadius: 16))
                    Spacer()
                }
            }

            VStack(spacing: 0) {

                // ── Header row — label, title, score, chevron ───────────────
                // Chevron is the tap target. Full-card tap NOT wired (Phase 2).
                HStack(spacing: 12) {
                    // Domain label badge
                    Text(label)
                        .font(.jost(size: 9, weight: isActive ? .medium : .light))
                        .foregroundColor(isActive ? ChronosTheme.gold : ChronosTheme.faint)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isActive ? ChronosTheme.goldDim : ChronosTheme.ink)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isActive ? ChronosTheme.gold.opacity(0.2) : ChronosTheme.border, lineWidth: 1)
                                )
                        )

                    // Title + subtitle
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.jost(size: 13, weight: .regular))
                            .foregroundColor(isActive ? ChronosTheme.text : ChronosTheme.muted)
                        Text(subtitle)
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }

                    Spacer()

                    // Score — right side
                    if let s = score {
                        Text("\(Int(s))")
                            .font(.cormorant(size: 22, weight: .light))
                            .foregroundColor(scoreColor)
                    } else if isActive {
                        // Score is nil but domain should be active — show dash in building color
                        Text("—")
                            .font(.cormorant(size: 22, weight: .light))
                            .foregroundColor(Color(hex: "7A8FA6"))
                    }

                    // Role tag — all active, non-building domains
                    if isActive && role != .building {
                        RoleTagView(role: role)
                    }

                    // Chevron — tap affordance (Phase 2: full-card tap reserved)
                    if isActive {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                                if isExpanded { onExpandRequest() }
                            }
                        }) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                                .frame(width: 28, height: 28)  // generous tap target
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isActive ? 10 : 14)

                // ── Semantic progress bar ────────────────────────────────────
                if isActive, score != nil {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ChronosTheme.faint.opacity(0.3))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barGradient)
                                .frame(width: geo.size.width * progressFill, height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, (isExpanded || conflict != nil) ? 0 : 12)
                }

                // ── Conflict badge — collapsed state ─────────────────────────
                if isActive, !isExpanded, let c = conflict {
                    ConflictBadge(text: c.badgeText)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }

                // ── Building state ──────────────────────────────────────────
                if !isActive, let msg = buildingMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .light))
                            .foregroundColor(Color(hex: "7A8FA6").opacity(0.7))
                        Text(msg.uppercased())
                            .font(.jost(size: 8, weight: .light))
                            .foregroundColor(Color(hex: "7A8FA6").opacity(0.7))
                            .tracking(1.5)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }

                // ── Expanded content ─────────────────────────────────────────
                if isExpanded && isActive {
                    ExpandedDomainContent(
                        label: label,
                        rawMetrics: rawMetrics,
                        perMetricBaselines: perMetricBaselines,
                        narrative: expandedNarrative,
                        conflict: conflict
                    )
                    .padding(.bottom, 4)
                }
            }
        }
        .opacity(label == "D5" && !isActive && buildingMessage == nil ? 0.35 : 1.0)
        .opacity(label == "D4" && !isActive && buildingMessage == nil ? 0.60 : 1.0)
        // Sprint 7: full-card tap → DomainDetailView (chevron button absorbs its own tap)
        .contentShape(Rectangle())
        .onTapGesture {
            if isActive, let handler = onDetailTap { handler() }
        }
    }
}

// ─────────────────────────────────────────
// ROLE TAG
// ─────────────────────────────────────────

struct RoleTagView: View {
    let role: DomainRole

    // Updated vocabulary per spec §3.3
    // ELEVATED → STRONG, DRIVER → DRAG, BUFFER → ABOVE BASELINE, WATCH → STABLE
    var displayLabel: String {
        switch role {
        case .driver:           return "DRAG"
        case .buffer:           return "ABOVE BASELINE"
        case .elevated:         return "STRONG"
        case .watch, .stable:   return "STABLE"
        case .building:         return "BUILDING"
        }
    }

    var tagColor: Color {
        switch role {
        case .driver:           return Color(hex: "E07070")
        case .buffer:           return Color(hex: "4ADE80")
        case .elevated:         return Color(hex: "4ADE80").opacity(0.7)
        case .watch, .stable:   return ChronosTheme.faint
        case .building:         return Color(hex: "7A8FA6")
        }
    }

    var body: some View {
        Text(displayLabel)
            .font(.jost(size: 7, weight: .medium))
            .foregroundColor(tagColor)
            .tracking(1.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(tagColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(tagColor.opacity(0.25), lineWidth: 1)
                    )
            )
    }
}

// ─────────────────────────────────────────
// CONFLICT BADGE — collapsed state
// ─────────────────────────────────────────

struct ConflictBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 8, weight: .light))
                .foregroundColor(Color(hex: "C9A84C").opacity(0.7))
            Text(text)
                .font(.jost(size: 10, weight: .light))
                .foregroundColor(ChronosTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "C9A84C").opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "C9A84C").opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// ─────────────────────────────────────────
// EXPANDED CARD CONTENT
// Today's metric values, baseline reference, observational line.
// Conflict elaboration if cross-domain tension exists.
// ─────────────────────────────────────────

struct ExpandedDomainContent: View {
    let label: String
    let rawMetrics: DomainRawMetrics
    let perMetricBaselines: [String: Double]
    let narrative: DomainExpandedNarrative?
    let conflict: ConflictResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(ChronosTheme.gold.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {

                // Metric values + baseline reference
                let rows = metricRows(for: label)
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rows, id: \.metric) { row in
                            MetricValueRow(
                                metric: row.metric,
                                value: row.value,
                                baseline: row.baseline,
                                unit: row.unit
                            )
                        }
                    }
                }

                // Observational line from narrative layer
                if let narrative = narrative {
                    Text(narrative.observationalLine)
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    // Conflict elaboration
                    if let elab = narrative.conflictElaboration {
                        VStack(alignment: .leading, spacing: 6) {
                            Rectangle()
                                .fill(Color(hex: "C9A84C").opacity(0.15))
                                .frame(height: 1)
                            Text(elab)
                                .font(.jost(size: 12, weight: .light))
                                .foregroundColor(ChronosTheme.muted.opacity(0.85))
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    // Loading state for narrative
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(ChronosTheme.gold.opacity(0.35))
                        Text("Reading signals...")
                            .font(.jost(size: 11, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    // ── Metric row data ──────────────────────────────────────────────────

    struct MetricRowData {
        let metric: String
        let value: Double?
        let baseline: Double?
        let unit: String
    }

    private func metricRows(for domain: String) -> [MetricRowData] {
        switch domain {
        case "D1":
            return [
                MetricRowData(metric: "HRV", value: rawMetrics.hrv_ms, baseline: perMetricBaselines["hrv_avg"], unit: "ms"),
                MetricRowData(metric: "Resting HR", value: rawMetrics.resting_hr_bpm, baseline: perMetricBaselines["resting_hr_avg"], unit: "bpm")
            ]
        case "D2":
            return [
                MetricRowData(metric: "Sleep", value: rawMetrics.sleep_duration_hrs, baseline: perMetricBaselines["sleep_duration_avg"], unit: "hrs"),
                MetricRowData(metric: "Continuity", value: rawMetrics.sleep_continuity_pct, baseline: perMetricBaselines["sleep_continuity_avg"], unit: "%")
            ]
        case "D3":
            return [
                MetricRowData(metric: "Steps", value: rawMetrics.steps, baseline: perMetricBaselines["steps_avg"], unit: "steps"),
                MetricRowData(metric: "Active min", value: rawMetrics.active_minutes, baseline: perMetricBaselines["active_minutes_avg"], unit: "min")
            ]
        case "D4":
            return []   // D4 has no raw input metrics to display
        case "D5":
            return []   // D5 is composite — no raw metric breakdown
        default:
            return []
        }
    }
}

struct MetricValueRow: View {
    let metric: String
    let value: Double?
    let baseline: Double?
    let unit: String

    var formattedValue: String {
        guard let v = value else { return "—" }
        switch unit {
        case "hrs":
            let hrs = Int(v)
            let mins = Int((v - Double(hrs)) * 60)
            return mins > 0 ? "\(hrs)h \(mins)m" : "\(hrs)h"
        case "steps":
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return (formatter.string(from: NSNumber(value: Int(v))) ?? "\(Int(v))") + " steps"
        case "%":
            return "\(Int(v))%"
        case "ms", "bpm", "min":
            return "\(Int(v)) \(unit)"
        default:
            return "\(String(format: "%.1f", v)) \(unit)"
        }
    }

    var formattedBaseline: String? {
        guard let b = baseline else { return nil }
        switch unit {
        case "hrs":
            let hrs = Int(b)
            let mins = Int((b - Double(hrs)) * 60)
            return mins > 0 ? "\(hrs)h \(mins)m" : "\(hrs)h"
        case "steps":
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return (formatter.string(from: NSNumber(value: Int(b))) ?? "\(Int(b))") + " steps"
        case "%":
            return "\(Int(b.rounded()))%"
        case "ms", "bpm", "min":
            return "\(Int(b.rounded())) \(unit)"
        default:
            return "\(String(format: "%.1f", b)) \(unit)"
        }
    }

    var body: some View {
        HStack {
            Text(metric)
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(ChronosTheme.faint)
            Spacer()
            if let avg = formattedBaseline {
                Text("avg \(avg)")
                    .font(.jost(size: 10, weight: .light))
                    .foregroundColor(ChronosTheme.faint.opacity(0.55))
            }
            Text(formattedValue)
                .font(.jost(size: 11, weight: .regular))
                .foregroundColor(ChronosTheme.text.opacity(0.85))
        }
    }
}

// ─────────────────────────────────────────
// SYNTHESIS LINE  §3.6
// Anchors the bottom of domain content.
// Italic serif, muted border, card surface.
// ─────────────────────────────────────────

struct SynthesisLineCard: View {
    let text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 10) {
                Text("TODAY IN ONE LINE")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.6))
                    .tracking(3)

                Text("\u{201C}\(text)\u{201D}")
                    .font(.cormorant(size: 17, weight: .light))
                    .italic()
                    .foregroundColor(ChronosTheme.muted)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}

// ─────────────────────────────────────────
// ALLOSTATIC PORTRAIT CARD  (E-11) — unchanged
// 90-day D5 load curve. Renders only when D5 active.
// ─────────────────────────────────────────

struct AllostaticPortraitCard: View {
    @EnvironmentObject var supabase: SupabaseService

    @State private var history: [(date: String, value: Double)] = []
    @State private var isLoading = true

    var trend: String {
        guard history.count >= 14 else { return "Building" }
        let recent = history.suffix(7).map { $0.value }
        let older  = history.prefix(7).map { $0.value }
        let recentAvg = recent.reduce(0, +) / Double(recent.count)
        let olderAvg  = older.reduce(0, +)  / Double(older.count)
        let delta = recentAvg - olderAvg
        if delta > 3  { return "Increasing" }
        if delta < -3 { return "Improving" }
        return "Stable"
    }

    var trendColor: Color {
        switch trend {
        case "Improving":  return Color(hex: "4ADE80")
        case "Increasing": return Color(red: 1.0, green: 0.55, blue: 0.45)
        default:           return ChronosTheme.goldLight
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [Color(red: 0.07, green: 0.07, blue: 0.13),
                             Color(red: 0.05, green: 0.05, blue: 0.09)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(ChronosTheme.border, lineWidth: 1))

            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, ChronosTheme.gold.opacity(0.30), .clear],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .clipShape(.rect(topLeadingRadius: 16, topTrailingRadius: 16))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ALLOSTATIC PORTRAIT")
                            .font(.jost(size: 9, weight: .light))
                            .foregroundColor(ChronosTheme.gold)
                            .tracking(2.5)
                        Text("90-day cumulative load")
                            .font(.cormorant(size: 18, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(trend.uppercased())
                            .font(.jost(size: 9, weight: .medium))
                            .foregroundColor(trendColor)
                            .tracking(2)
                        Text("load trend")
                            .font(.jost(size: 8, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                }

                Rectangle().fill(ChronosTheme.gold.opacity(0.15)).frame(height: 1)

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.6).tint(ChronosTheme.gold.opacity(0.4))
                        Text("Loading portrait...")
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    .frame(height: 80)
                } else if history.isEmpty {
                    Text("Not enough history yet — check back in a few days.")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .lineSpacing(4)
                        .frame(height: 80, alignment: .leading)
                } else {
                    AllostaticCurve(history: history).frame(height: 80)
                }

                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(ChronosTheme.gold.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text("Lower is better. A descending line means your body is carrying less cumulative stress over time.")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .task {
            guard let userId = supabase.session?.userId else { isLoading = false; return }
            do {
                history = try await supabase.fetchAllostaticHistory(userId: userId)
            } catch {
                print("[AllostaticPortrait] load failed: \(error)")
            }
            isLoading = false
        }
    }
}

// ─────────────────────────────────────────
// ALLOSTATIC CURVE — unchanged from E-11
// ─────────────────────────────────────────

struct AllostaticCurve: View {
    let history: [(date: String, value: Double)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let values = history.map { $0.value }
            let minV = (values.min() ?? 0) - 5
            let maxV = (values.max() ?? 100) + 5
            let range = maxV - minV
            let step = w / CGFloat(max(values.count - 1, 1))

            let points: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(
                    x: CGFloat(i) * step,
                    y: h - CGFloat((v - minV) / range) * h
                )
            }

            ZStack {
                Canvas { ctx, size in
                    guard points.count > 1 else { return }
                    var fill = Path()
                    fill.move(to: CGPoint(x: points[0].x, y: size.height))
                    fill.addLine(to: points[0])
                    for pt in points.dropFirst() { fill.addLine(to: pt) }
                    fill.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(
                        Gradient(colors: [ChronosTheme.gold.opacity(0.10), .clear]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                }

                Canvas { ctx, size in
                    guard points.count > 1 else { return }
                    var path = Path()
                    path.move(to: points[0])
                    for pt in points.dropFirst() { path.addLine(to: pt) }
                    ctx.stroke(path, with: .linearGradient(
                        Gradient(colors: [ChronosTheme.gold.opacity(0.35), ChronosTheme.goldLight]),
                        startPoint: CGPoint(x: 0, y: h / 2),
                        endPoint: CGPoint(x: w, y: h / 2)
                    ), lineWidth: 1.5)
                }

                if let last = points.last {
                    Circle()
                        .fill(ChronosTheme.goldLight)
                        .frame(width: 6, height: 6)
                        .position(last)
                }

                if let first = history.first, let last = history.last {
                    VStack {
                        Spacer()
                        HStack {
                            Text(shortDate(first.date))
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                            Spacer()
                            Text(shortDate(last.date))
                                .font(.jost(size: 8, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                        }
                    }
                }
            }
        }
    }

    // N7: Now uses Date.relativeLabel for "Today" / "Yesterday" / day names / "Jan 12"
    private func shortDate(_ dateString: String) -> String {
        Date.relativeLabel(from: dateString)
    }
}

// ─────────────────────────────────────────
// DOMAIN MODE TOGGLE  Phase 2
// TODAY | 30 DAYS pill segment control
// ─────────────────────────────────────────

struct DomainModeToggle: View {
    @Binding var showHistory: Bool

    var body: some View {
        HStack(spacing: 0) {
            toggleOption(label: "TODAY", isSelected: !showHistory) {
                withAnimation(.easeInOut(duration: 0.2)) { showHistory = false }
            }
            toggleOption(label: "30 DAYS", isSelected: showHistory) {
                withAnimation(.easeInOut(duration: 0.2)) { showHistory = true }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ChronosTheme.ink)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChronosTheme.border, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func toggleOption(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.jost(size: 9, weight: isSelected ? .medium : .light))
                .foregroundColor(isSelected ? ChronosTheme.gold : ChronosTheme.faint)
                .tracking(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? ChronosTheme.goldDim : .clear)
                )
        }
        .buttonStyle(.plain)
        .padding(2)
    }
}

// ─────────────────────────────────────────
// DOMAIN HISTORY PANEL  Phase 2
// 30-day multi-line chart + per-domain trend rows
// ─────────────────────────────────────────

struct DomainHistoryPanel: View {
    let histories: [String: [(date: String, value: Double)]]
    let isLoading: Bool
    let historyDayCount: Int
    let todayScore: DailyScore?
    // 30-day narrative
    var thirtyDayNarrative: ThirtyDayNarrative? = nil
    var isNarrativeLoading: Bool = false
    var onPatternDetailTap: (() -> Void)? = nil

    private let defs: [(label: String, name: String, color: Color)] = [
        ("D1", "Autonomic Recovery", Color(red: 0.878, green: 0.439, blue: 0.439)),
        ("D2", "Sleep Recovery",     Color(red: 0.494, green: 0.722, blue: 0.878)),
        ("D3", "Activity Load",      Color(red: 0.290, green: 0.871, blue: 0.502)),
        ("D4", "Inferred Stress",    Color(red: 0.788, green: 0.659, blue: 0.298)),
        ("D5", "Allostatic Trend",   Color(red: 0.690, green: 0.478, blue: 0.871)),
    ]

    var body: some View {
        VStack(spacing: 16) {

            // ── 30-DAY SYSTEM READ block ────────────────────────────────
            ThirtyDaySystemReadBlock(
                narrative: thirtyDayNarrative,
                isLoading: isNarrativeLoading,
                onDetailTap: onPatternDetailTap
            )

            SectionDividerLabel(text: "30-DAY SCORE TRENDS")

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.6).tint(ChronosTheme.gold.opacity(0.4))
                    Text("Loading domain history…")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
            } else {
                // ── Combined chart card ─────────────────────────────────
                DomainComparisonCard(histories: histories, defs: defs)

                // ── D4/D5 polarity legend ───────────────────────────────
                let d4Active = historyDayCount >= 7
                let d5Active = historyDayCount >= 30
                if d4Active || d5Active {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                        Text("for D4 and D5 means stress load is decreasing — that is good.")
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                            .lineSpacing(3)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, -4)
                }

                // ── Per-domain stat rows ────────────────────────────────
                VStack(spacing: 8) {
                    ForEach(defs, id: \.label) { def in
                        let hist = histories[def.label] ?? []
                        DomainTrendRow(
                            label: def.label,
                            name: def.name,
                            color: def.color,
                            history: hist,
                            isActive: domainIsActive(def.label),
                            latestScore: latestScore(for: def.label)
                        )
                    }
                }
            }
        }
    }

    private func domainIsActive(_ label: String) -> Bool {
        switch label {
        case "D4": return historyDayCount >= 7
        case "D5": return historyDayCount >= 30
        default:   return true
        }
    }

    private func latestScore(for label: String) -> Double? {
        switch label {
        case "D1": return todayScore?.d1Autonomic
        case "D2": return todayScore?.d2Sleep
        case "D3": return todayScore?.d3Activity
        case "D4": return todayScore?.d4Stress
        case "D5": return todayScore?.d5Allostatic
        default:   return nil
        }
    }
}

// ─────────────────────────────────────────
// DOMAIN COMPARISON CARD
// Combined multi-line chart with colour-coded legend
// ─────────────────────────────────────────

struct DomainComparisonCard: View {
    let histories: [String: [(date: String, value: Double)]]
    let defs: [(label: String, name: String, color: Color)]

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [Color(red: 0.09, green: 0.09, blue: 0.14),
                             Color(red: 0.07, green: 0.07, blue: 0.11)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 14) {
                Text("ALL DOMAINS · 30 DAYS")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.gold.opacity(0.7))
                    .tracking(2.5)

                DomainMultiLineChart(histories: histories, defs: defs)
                    .frame(height: 130)

                // Colour legend
                HStack(spacing: 14) {
                    ForEach(defs, id: \.label) { def in
                        if !(histories[def.label] ?? []).isEmpty {
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(def.color)
                                    .frame(width: 14, height: 2)
                                Text(def.label)
                                    .font(.jost(size: 8, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                            }
                        }
                    }
                    Spacer()
                }
            }
            .padding(18)
        }
    }
}

// ─────────────────────────────────────────
// DOMAIN MULTI-LINE CHART
// Canvas drawing — 0-100 fixed Y-axis, all domain lines
// ─────────────────────────────────────────

struct DomainMultiLineChart: View {
    let histories: [String: [(date: String, value: Double)]]
    let defs: [(label: String, name: String, color: Color)]

    var body: some View {
        Canvas { ctx, size in
            let leftPad: CGFloat = 26
            let chartW = size.width - leftPad
            let chartH = size.height - 12

            let yMin: Double = 0
            let yMax: Double = 100
            let yRange = yMax - yMin

            // Reference lines at 40 / 65 / 80
            for ref in [40.0, 65.0, 80.0] {
                let y = chartH - CGFloat((ref - yMin) / yRange) * chartH

                var refLine = Path()
                refLine.move(to: CGPoint(x: leftPad, y: y))
                refLine.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(refLine, with: .color(.white.opacity(0.05)), lineWidth: 1)

                ctx.draw(
                    Text("\(Int(ref))")
                        .font(.system(size: 7, weight: .light))
                        .foregroundStyle(Color(white: 0.35)),
                    at: CGPoint(x: leftPad - 4, y: y),
                    anchor: .trailing
                )
            }

            // Domain score lines
            for def in defs {
                guard let hist = histories[def.label], hist.count > 1 else { continue }
                let values = hist.map { $0.value }
                let xStep = chartW / CGFloat(max(values.count - 1, 1))

                let points: [CGPoint] = values.enumerated().map { i, v in
                    CGPoint(
                        x: leftPad + CGFloat(i) * xStep,
                        y: chartH - CGFloat((v - yMin) / yRange) * chartH
                    )
                }

                var path = Path()
                path.move(to: points[0])
                for pt in points.dropFirst() { path.addLine(to: pt) }
                ctx.stroke(path, with: .color(def.color.opacity(0.75)), lineWidth: 1.5)

                // End-point dot
                if let last = points.last {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)),
                        with: .color(def.color)
                    )
                }
            }

            // Date labels — first + last from longest history
            let longest = defs.compactMap { histories[$0.label] }.max(by: { $0.count < $1.count }) ?? []
            if let first = longest.first, let last = longest.last {
                let firstLabel = shortDate(first.date)
                let lastLabel  = shortDate(last.date)
                ctx.draw(
                    Text(firstLabel)
                        .font(.system(size: 7, weight: .light))
                        .foregroundStyle(Color(white: 0.30)),
                    at: CGPoint(x: leftPad, y: size.height),
                    anchor: .bottomLeading
                )
                ctx.draw(
                    Text(lastLabel)
                        .font(.system(size: 7, weight: .light))
                        .foregroundStyle(Color(white: 0.30)),
                    at: CGPoint(x: size.width, y: size.height),
                    anchor: .bottomTrailing
                )
            }
        }
    }

    private func shortDate(_ s: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return s }
        f.dateFormat = "MMM d"; return f.string(from: d)
    }
}

// ─────────────────────────────────────────
// DOMAIN TREND ROW
// Per-domain summary: today's score, 30d avg, trend arrow
// ─────────────────────────────────────────

struct DomainTrendRow: View {
    let label: String
    let name: String
    let color: Color
    let history: [(date: String, value: Double)]
    let isActive: Bool
    let latestScore: Double?

    // 7-day recent vs prior-7 trend
    private var trend: (symbol: String, delta: Double) {
        guard history.count >= 7 else { return ("→", 0) }
        let recent = Array(history.suffix(7)).map { $0.value }
        let prior  = Array(history.dropLast(7).suffix(7)).map { $0.value }
        guard !prior.isEmpty else { return ("→", 0) }
        let recentAvg = recent.reduce(0, +) / Double(recent.count)
        let priorAvg  = prior.reduce(0, +)  / Double(prior.count)
        let delta = recentAvg - priorAvg
        if delta > 2  { return ("↑", delta) }
        if delta < -2 { return ("↓", delta) }
        return ("→", delta)
    }

    // For D4 (stress) and D5 (allostatic load) lower scores = improving
    private var trendColor: Color {
        let sym = trend.symbol
        guard sym != "→" else { return ChronosTheme.faint }
        let higherIsBetter = label != "D4" && label != "D5"
        if higherIsBetter { return sym == "↑" ? Color(red: 0.290, green: 0.871, blue: 0.502) : Color(red: 0.878, green: 0.439, blue: 0.439) }
        else               { return sym == "↓" ? Color(red: 0.290, green: 0.871, blue: 0.502) : Color(red: 0.878, green: 0.439, blue: 0.439) }
    }

    private var avg30: Double? {
        guard !history.isEmpty else { return nil }
        return history.map { $0.value }.reduce(0, +) / Double(history.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Colour dot
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            // Label badge
            Text(label)
                .font(.jost(size: 9, weight: .medium))
                .foregroundColor(color.opacity(0.85))
                .frame(width: 22, alignment: .leading)

            // Domain name
            Text(name)
                .font(.jost(size: 12, weight: .light))
                .foregroundColor(isActive ? ChronosTheme.text : ChronosTheme.faint)

            Spacer()

            if !isActive {
                Text("BUILDING")
                    .font(.jost(size: 8, weight: .light))
                    .foregroundColor(Color(red: 0.478, green: 0.561, blue: 0.651).opacity(0.6))
                    .tracking(1.5)
            } else {
                // 30d avg
                if let avg = avg30 {
                    Text("avg \(Int(avg.rounded()))")
                        .font(.jost(size: 10, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                }

                // Today's score
                if let s = latestScore {
                    Text("\(Int(s))")
                        .font(.jost(size: 13, weight: .regular))
                        .foregroundColor(color)
                        .frame(width: 30, alignment: .trailing)
                }

                // Trend arrow
                Text(trend.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(trendColor)
                    .frame(width: 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )
        )
    }
}

// ─────────────────────────────────────────
// EMPTY STATE — unchanged
// ─────────────────────────────────────────

struct DomainsEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            ChronosLogoMark()
                .frame(width: 52, height: 52)
                .opacity(0.25)

            Text("No domain data yet")
                .font(.cormorant(size: 24))
                .foregroundColor(ChronosTheme.muted)

            Text("Sync your Apple Watch data to\nsee how each system is performing.")
                .font(.jost(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.faint)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.horizontal, 48)
        }
    }
}

// ─────────────────────────────────────────
// COLOR HELPER — hex initializer
// ─────────────────────────────────────────

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        _ = scanner.scanString("#")
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double(rgb         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
