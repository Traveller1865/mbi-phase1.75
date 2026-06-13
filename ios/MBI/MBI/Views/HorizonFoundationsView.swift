// ios/MBI/MBI/Views/HorizonFoundationsView.swift
// MBI Phase 2 — Horizon · Foundations Page
// Epic 3 Sprint 3 — Page 3 (always visible)
//
// System voice — first-person, plain language.
// Three sections: what Horizon watches / what triggers a shift / what you can do now.
// No data fetch. No LLM generation. All copy is static and deterministic.
// This is the transparency layer — answers "how does this work?"
// Hard constraints: no scores, no disease names, no backward language.

import SwiftUI

struct HorizonFoundationsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [Color.white.opacity(0.018), .clear],
                center: .top, startRadius: 0, endRadius: 280
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    FoundationsHeader(onDone: { dismiss() })

                    VStack(spacing: 16) {

                        FoundationsSection(
                            eyebrow: "WHAT HORIZON WATCHES",
                            title: "Three upstream pathways.",
                            items: [
                                FoundationItem(
                                    icon: "waveform.path.ecg",
                                    label: "Autonomic",
                                    detail: "Heart rate variability and resting heart rate. HRV reflects how much reserve your nervous system carries — not fitness level, but recovery capacity."
                                ),
                                FoundationItem(
                                    icon: "moon.stars",
                                    label: "Sleep",
                                    detail: "Duration and efficiency across your recent nights. Sleep is when systemic repair happens. Fragmentation here surfaces across all other pathways."
                                ),
                                FoundationItem(
                                    icon: "figure.walk",
                                    label: "Metabolic",
                                    detail: "Daily movement and active minutes. Sustained movement — not intensity — drives metabolic efficiency. The multi-day pattern matters more than any single day."
                                )
                            ]
                        )

                        FoundationsSection(
                            eyebrow: "WHAT TRIGGERS A SHIFT",
                            title: "Patterns, not data points.",
                            items: [
                                FoundationItem(
                                    icon: "chart.line.uptrend.xyaxis",
                                    label: "Duration gates",
                                    detail: "A single off day is noise. Horizon waits for a pattern to hold across multiple consecutive days before signaling. The longer a pattern holds, the more weight it carries."
                                ),
                                FoundationItem(
                                    icon: "person.crop.circle",
                                    label: "Your own baseline",
                                    detail: "All thresholds compare against your personal 90-day history — not population averages. What's notable is relative to you, not a reference group."
                                ),
                                FoundationItem(
                                    icon: "lock.shield",
                                    label: "Confidence gates",
                                    detail: "Each signal carries a confidence score. Horizon surfaces a pattern only when the signal is strong enough to be meaningful — not just detectable."
                                )
                            ]
                        )

                        FoundationsSection(
                            eyebrow: "WHAT YOU CAN DO NOW",
                            title: "Upstream, always.",
                            items: [
                                FoundationItem(
                                    icon: "moon.zzz",
                                    label: "Protect the sleep window",
                                    detail: "Consistent sleep onset is the highest-leverage behavior across all three pathways. It directly supports autonomic recovery, sleep architecture, and metabolic regulation."
                                ),
                                FoundationItem(
                                    icon: "lungs",
                                    label: "Manage the load",
                                    detail: "Slow breathing — even 5–10 minutes — measurably shifts autonomic balance. It is not a coping mechanism; it is a direct input into the HRV signal Horizon tracks."
                                ),
                                FoundationItem(
                                    icon: "figure.walk.circle",
                                    label: "Move continuously",
                                    detail: "20 minutes of uninterrupted movement clears metabolic load more effectively than higher-intensity fragmented effort. The mechanism is continuity, not exertion."
                                )
                            ]
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 64)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// DATA MODEL
// ─────────────────────────────────────────

private struct FoundationItem {
    let icon: String
    let label: String
    let detail: String
}

// ─────────────────────────────────────────
// FOUNDATIONS HEADER
// ─────────────────────────────────────────

private struct FoundationsHeader: View {
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Done button — shown when presented as sheet
            if let done = onDone {
                HStack {
                    Spacer()
                    Button("Done", action: done)
                        .font(.jost(size: 14, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                }
                .padding(.bottom, 4)
            }

            Text("FOUNDATIONS")
                .font(.jost(size: 11, weight: .medium))
                .foregroundColor(Color.white.opacity(0.30))
                .tracking(3)

            Text("How it works.")
                .font(.cormorant(size: 34, weight: .regular))
                .foregroundColor(ChronosTheme.text)

            Text("What Horizon watches, what it takes to shift it, and what you can do upstream — right now.")
                .font(.jost(size: 15, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }
}

// ─────────────────────────────────────────
// SECTION CONTAINER
// ─────────────────────────────────────────

private struct FoundationsSection: View {
    let eyebrow: String
    let title: String
    let items: [FoundationItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.jost(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.24))
                    .tracking(2)
                Text(title)
                    .font(.cormorant(size: 24, weight: .regular))
                    .foregroundColor(ChronosTheme.text.opacity(0.88))
            }

            VStack(spacing: 8) {
                ForEach(items, id: \.label) { item in
                    FoundationItemRow(item: item)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// ITEM ROW
// ─────────────────────────────────────────

private struct FoundationItemRow: View {
    let item: FoundationItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .ultraLight))
                .foregroundColor(Color.white.opacity(0.32))
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(.jost(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.78))
                Text(item.detail)
                    .font(.jost(size: 15, weight: .regular))
                    .foregroundColor(ChronosTheme.faint)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }
}
