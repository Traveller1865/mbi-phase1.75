// ios/MBI/MBI/Views/AdminView.swift
// MBI Phase 1.5 — Admin View
// Pre-Beta Sprint: Design system compliance
//   All .font(.system(size:)) → .jost() / .cormorant()
//   All Color.black / .white / .white.opacity() → ChronosTheme tokens
//   bandColor switch → ScoreBand.themeColor canonical tokens
//   Card backgrounds → ChronosTheme.ink + ChronosTheme.border stroke

import SwiftUI

struct AdminUserSummary: Identifiable {
    let id = UUID()
    let displayName: String
    let scores: [AdminScoreRow]

    var latestScore: Double? { scores.first?.chronosScore }
    var latestBand: String? { scores.first?.scoreBand }
    var trend: [Double] { scores.prefix(7).map { $0.chronosScore }.reversed() }
}

struct AdminScoreRow: Identifiable {
    let id = UUID()
    let date: String
    let chronosScore: Double
    let scoreBand: String
    let driver1: String
    let driver2: String
    let failState: String?
    let isProvisional: Bool
}

struct AdminView: View {
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator
    @State private var users: [AdminUserSummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var isResyncing = false
    @State private var resyncProgress = 0
    @State private var resyncTotal = 0
    @State private var resyncDone = false

    var body: some View {
        ZStack {
            ChronosTheme.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──
                HStack {
                    Text("Admin")
                        .font(.cormorant(size: 24, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                    Spacer()
                    Button(action: load) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // ── Re-sync History Card ──
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Full History Sync")
                                .font(.jost(size: 14, weight: .medium))
                                .foregroundColor(ChronosTheme.text)
                            Text("Read all available HealthKit history and score each day.")
                                .font(.jost(size: 12, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .lineSpacing(3)
                        }
                        Spacer()
                        if resyncDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .light))
                                .foregroundColor(ScoreBand.thriving.themeColor.opacity(0.8))
                        }
                    }

                    if isResyncing {
                        VStack(spacing: 8) {
                            ProgressView(
                                value: resyncTotal > 0 ? Double(resyncProgress) : 0,
                                total: resyncTotal > 0 ? Double(resyncTotal) : 1
                            )
                            .tint(ChronosTheme.gold)

                            Text(resyncTotal == 0
                                 ? "Scanning history..."
                                 : "Processing day \(resyncProgress) of \(resyncTotal)...")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                        }
                    } else {
                        Button(action: runResync) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12, weight: .light))
                                Text(resyncDone ? "Sync Again" : "Start Full Sync")
                                    .font(.jost(size: 13, weight: .medium))
                            }
                            .foregroundColor(ChronosTheme.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(ChronosTheme.ink)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(ChronosTheme.border, lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(ChronosTheme.ink)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(ChronosTheme.border, lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                // ── Users ──
                if isLoading {
                    Spacer()
                    ProgressView().tint(ChronosTheme.muted)
                    Spacer()
                } else if let error = error {
                    Spacer()
                    Text(error)
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .padding(.horizontal, 40)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else if users.isEmpty {
                    Spacer()
                    Text("No users yet.")
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(users) { user in
                                AdminUserCard(user: user)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .task { load() }
    }

    private func load() {
        isLoading = true
        error = nil
        Task {
            do {
                let raw = try await supabase.fetchAdminData()
                users = raw.compactMap { parseUser($0) }
            } catch {
                self.error = "Admin data unavailable."
            }
            isLoading = false
        }
    }

    private func runResync() {
        guard let userId = supabase.session?.userId else { return }
        isResyncing = true
        resyncProgress = 0
        resyncTotal = 0
        resyncDone = false

        Task {
            do {
                try await SyncCoordinator.shared.runBaselineBootstrap(
                    userId: userId
                ) { done, total in
                    Task { @MainActor in
                        self.resyncProgress = done
                        self.resyncTotal = total
                    }
                }
                resyncDone = true
                load()
            } catch {
                self.error = "Sync failed: \(error.localizedDescription)"
            }
            isResyncing = false
        }
    }

    private func parseUser(_ dict: [String: Any]) -> AdminUserSummary? {
        guard let name = dict["display_name"] as? String,
              let rawScores = dict["scores"] as? [[String: Any]] else { return nil }

        let scores = rawScores.compactMap { s -> AdminScoreRow? in
            guard let date = s["date"] as? String,
                  let score = s["chronos_score"] as? Double,
                  let band = s["score_band"] as? String else { return nil }
            return AdminScoreRow(
                date: date,
                chronosScore: score,
                scoreBand: band,
                driver1: (s["driver_1"] as? String) ?? "—",
                driver2: (s["driver_2"] as? String) ?? "—",
                failState: s["fail_state"] as? String,
                isProvisional: (s["is_provisional"] as? Bool) ?? false
            )
        }

        return AdminUserSummary(displayName: name, scores: scores)
    }
}

// ─────────────────────────────────────────
// ADMIN USER CARD
// ─────────────────────────────────────────

struct AdminUserCard: View {
    let user: AdminUserSummary
    @State private var isExpanded = false

    // Uses canonical ScoreBand.themeColor — eliminates inline Color(red:...) switch.
    var bandColor: Color {
        guard let rawBand = user.latestBand,
              let band = ScoreBand(rawValue: rawBand) else { return ChronosTheme.muted }
        return band.themeColor
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.displayName)
                            .font(.jost(size: 15, weight: .medium))
                            .foregroundColor(ChronosTheme.text)
                        if let band = user.latestBand {
                            Text(band.uppercased())
                                .font(.jost(size: 10, weight: .medium))
                                .foregroundColor(bandColor)
                                .tracking(1.5)
                        }
                    }
                    Spacer()
                    if user.trend.count > 1 {
                        MiniSparkline(scores: user.trend)
                            .frame(width: 60, height: 24)
                    }
                    if let score = user.latestScore {
                        Text("\(Int(score))")
                            .font(.cormorant(size: 28, weight: .light))
                            .foregroundColor(bandColor)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                }
                .padding(16)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(ChronosTheme.border)
                        .frame(height: 1)
                    ForEach(user.scores.prefix(7)) { row in
                        AdminScoreRowView(row: row)
                        if row.id != user.scores.prefix(7).last?.id {
                            Rectangle()
                                .fill(ChronosTheme.border.opacity(0.5))
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )
        )
    }
}

// ─────────────────────────────────────────
// ADMIN SCORE ROW
// ─────────────────────────────────────────

struct AdminScoreRowView: View {
    let row: AdminScoreRow

    var body: some View {
        HStack {
            Text(row.date)
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(ChronosTheme.muted)
            Spacer()
            if let fail = row.failState {
                Text(fail)
                    .font(.jost(size: 10, weight: .medium))
                    .foregroundColor(ChronosTheme.gold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ChronosTheme.gold.opacity(0.12)))
            }
            if row.isProvisional {
                Text("provisional")
                    .font(.jost(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ChronosTheme.border))
            }
            Text("\(row.driver1) · \(row.driver2)")
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(ChronosTheme.muted)
            Text("\(Int(row.chronosScore))")
                .font(.jost(size: 14, weight: .medium))
                .foregroundColor(ChronosTheme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// ─────────────────────────────────────────
// MINI SPARKLINE
// Used in AdminUserCard for the 7-day trend preview.
// ─────────────────────────────────────────

struct MiniSparkline: View {
    let scores: [Double]

    var body: some View {
        Canvas { context, size in
            guard scores.count > 1 else { return }
            let min = (scores.min() ?? 0) - 5
            let max = (scores.max() ?? 100) + 5
            let range = max - min
            let step = size.width / CGFloat(scores.count - 1)
            var path = Path()
            for (i, score) in scores.enumerated() {
                let x = CGFloat(i) * step
                let y = size.height - CGFloat((score - min) / range) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(Color(red: 0.722, green: 0.580, blue: 0.416, opacity: 0.6)), lineWidth: 1.5)
        }
    }
}
