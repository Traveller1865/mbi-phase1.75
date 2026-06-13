// ios/MBI/MBI/Views/HorizonEscalateView.swift
// MBI Phase 2 — Horizon · Escalate Page
// Epic 3 Sprint 3 — Page 6 (conditional)
//
// ⚠️  LEGAL GATE — DO NOT SHIP TO EXTERNAL USERS WITHOUT ATTORNEY REVIEW ⚠️
//
// Legal Framework §4.1 three-line copy structure implemented.
// All "physician" language replaced with "licensed healthcare professional" per §3.2.
// Frame disclosure sentence present above DoctorPromptCard per §4.2.
// Three-part legal qualifier present below DoctorPromptCard per §4.1.
//
// Sprint 9 activations:
//   • Doctor Report — PDF export via DoctorReportService. Presents UIActivityViewController.
//   • Horizon Assist — AI pattern Q&A via HorizonAssistView sheet. Stub in Phase 2.
// DPC scheduling remains Phase 3.

import SwiftUI
import UIKit

struct HorizonEscalateView: View {
    let assessment: HorizonAssessment
    /// True when the user flagged an exceptional circumstance in the context check modal.
    /// When set, display copy shifts from 'share with provider' to 'monitor and recalibrate'.
    var contextFlagActive: Bool = false

    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator

    @State private var showHorizonAssist = false
    @State private var isGeneratingReport = false

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [Color(red: 1.0, green: 0.75, blue: 0.35).opacity(0.03), .clear],
                center: .top, startRadius: 0, endRadius: 280
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    EscalateHeader()

                    // Context cards — one per escalation-level-3 signal
                    VStack(spacing: 12) {
                        ForEach(assessment.escalationSignals, id: \.pathway) { signal in
                            EscalateContextCard(signal: signal)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                    // Frame disclosure — required above doctor prompt per Legal §4.2
                    EscalateFrameDisclosure()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    // Doctor prompt — the key recommendation
                    DoctorPromptCard(signals: assessment.escalationSignals, contextFlagActive: contextFlagActive)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    // Three-part legal qualifier — required below doctor prompt per Legal §4.1
                    EscalateLegalQualifier()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)

                    // Protective counterweights
                    if !assessment.calmPathwayLabels.isEmpty {
                        EscalateCounterweightSection(labels: assessment.calmPathwayLabels)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }

                    // Deferred CTAs — Doctor Report + Horizon Assist activated in Sprint 9
                    EscalateActionSection(
                        assessment: assessment,
                        isGeneratingReport: $isGeneratingReport,
                        onDoctorReport: { generateDoctorReport() },
                        onHorizonAssist: { showHorizonAssist = true }
                    )
                    .environmentObject(supabase)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                    // Bottom legal note — always present on this page
                    EscalateLegalNote()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 64)
                }
            }
            .contentMargins(.top, 56, for: .scrollContent)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 32) }
        }
        .sheet(isPresented: $showHorizonAssist) {
            HorizonAssistView(assessment: assessment)
                .environmentObject(supabase)
        }
    }

    // ── Doctor Report Generation ──────────────────────────────────────────

    @MainActor
    private func generateDoctorReport() {
        guard let user = supabase.currentUser,
              let score = sync.dashboard?.score
        else { return }

        isGeneratingReport = true
        let pdfData = DoctorReportService.shared.generate(
            user: user,
            score: score,
            assessment: assessment
        )
        isGeneratingReport = false

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let fileName = "Chronos_Wellness_Summary_\(df.string(from: Date())).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? pdfData.write(to: tempURL)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }
}

// ─────────────────────────────────────────
// ESCALATE HEADER
// Calm and matter-of-fact. No urgency, no alarm.
// ─────────────────────────────────────────

private struct EscalateHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ESCALATE")
                .font(.jost(size: 11, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.35))
                .tracking(3)

            Text("Worth a conversation.")
                .font(.cormorant(size: 34, weight: .regular))
                .foregroundColor(ChronosTheme.text)

            Text("A pattern at this duration moves beyond what self-directed action alone is designed to resolve.")
                .font(.jost(size: 15, weight: .regular))
                .foregroundColor(ChronosTheme.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }
}

// ─────────────────────────────────────────
// ESCALATE CONTEXT CARD
// Shows which pathway triggered escalation and for how long.
// conditionClass labels updated per Design Session §2.3.
// ─────────────────────────────────────────

private struct EscalateContextCard: View {
    let signal: HorizonSignal

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    private var pathwayInfo: (label: String, subtitle: String) {
        switch signal.pathway {
        case "autonomic": return ("AUTONOMIC", "Nervous system · HRV · Heart rate")
        case "sleep":     return ("SLEEP",     "Recovery · Duration · Quality")
        default:          return ("METABOLIC", "Activity · Movement · Energy")
        }
    }

    private var wellnessLabel: String {
        switch signal.conditionClass ?? "" {
        // Current ontology values (Design Session §2.3)
        case "autonomic_stress_load":       return "Autonomic System Under Pressure"
        case "sleep_architecture_disruption": return "Sleep Architecture Under Pressure"
        case "metabolic_inactivity_load":   return "Metabolic Recovery Window"
        case "combined_autonomic_sleep":    return "Recovery Capacity Under Pressure"
        case "combined_metabolic_sleep":    return "Restorative Load Accumulating"
        case "full_system_load":            return "Systemic Resilience Under Pressure"
        // Legacy values — preserved for backward compat during pathway_classifications migration
        case "autonomic_dysfunction_early": return "Autonomic Load Accumulating"
        case "sleep_fragmentation_early":   return "Sleep Architecture Under Pressure"
        case "metabolic_risk_inferred":     return "Metabolic Stress Building"
        default: return signal.trajectoryLabel ?? "Pattern Detected"
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(amber.opacity(0.35), lineWidth: 1.5)
                )

            HStack(alignment: .top, spacing: 14) {

                RoundedRectangle(cornerRadius: 3)
                    .fill(amber)
                    .frame(width: 6)
                    .padding(.vertical, 6)
                    .shadow(color: amber.opacity(0.4), radius: 4, x: -2, y: 0)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pathwayInfo.label)
                                .font(.jost(size: 13, weight: .semibold))
                                .foregroundColor(ChronosTheme.text)
                                .tracking(1.5)
                            Text(pathwayInfo.subtitle)
                                .font(.jost(size: 12, weight: .regular))
                                .foregroundColor(ChronosTheme.faint)
                        }
                        Spacer()
                        Text("PATTERN DEEPENING")
                            .font(.jost(size: 11, weight: .semibold))
                            .foregroundColor(amber)
                            .tracking(1.2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(amber.opacity(0.15))
                                    .overlay(Capsule().stroke(amber.opacity(0.40), lineWidth: 1))
                            )
                    }

                    Text(wellnessLabel)
                        .font(.cormorant(size: 24, weight: .regular))
                        .foregroundColor(amber.opacity(0.85))

                    HStack(spacing: 14) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .light))
                                .foregroundColor(amber.opacity(0.55))
                            Text("\(signal.daysInPattern) days")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(amber.opacity(0.70))
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 9, weight: .light))
                                .foregroundColor(amber.opacity(0.55))
                            Text("\(Int(signal.confidenceGate * 100))% signal confidence")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(amber.opacity(0.70))
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
// FRAME DISCLOSURE
// Required above DoctorPromptCard per Legal Framework §4.2.
// Wellness-tracking framing. Fixed copy — do not modify without legal review.
// ─────────────────────────────────────────

private struct EscalateFrameDisclosure: View {
    var body: some View {
        Text("Chronos identifies changes in wellness measurements you choose to track. This screen does not diagnose, treat, or assess disease.")
            .font(.jost(size: 11, weight: .light))
            .foregroundColor(ChronosTheme.faint.opacity(0.65))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ─────────────────────────────────────────
// DOCTOR PROMPT CARD
// Legal Framework §4.1 three-line structure — Line 2.
// "a licensed healthcare professional" — never "physician" or "your doctor".
// ─────────────────────────────────────────

private struct DoctorPromptCard: View {
    let signals: [HorizonSignal]
    /// When true, user flagged an exception — show 'monitor and recalibrate' copy instead of 'share with provider'.
    var contextFlagActive: Bool = false

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    private var maxDays: Int {
        signals.map { $0.daysInPattern }.max() ?? 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: contextFlagActive ? "arrow.trianglehead.2.clockwise.rotate.90" : "person.and.background.dotted")
                    .font(.system(size: 15, weight: .ultraLight))
                    .foregroundColor(amber.opacity(0.60))
                Text(contextFlagActive ? "MONITORING ACTIVE" : "CARE CONVERSATION")
                    .font(.jost(size: 9, weight: .medium))
                    .foregroundColor(amber.opacity(0.65))
                    .tracking(2)
            }

            Rectangle()
                .fill(amber.opacity(0.12))
                .frame(height: 1)

            if contextFlagActive {
                // Context flag was raised — downgrade to monitor and recalibrate framing
                Text("Pattern noted alongside your context.")
                    .font(.cormorant(size: 22, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Chronos is monitoring this pattern alongside the context you shared. If the pattern recalibrates, you'll see it here. If it continues, we'll surface next steps.")
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.80))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Standard provider share copy — Legal §4.1 Line 2
                Text("This pattern has continued for \(maxDays) days.")
                    .font(.cormorant(size: 22, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Based on the duration of the wellness measurements you have been tracking, it may be helpful to discuss these measurements with a licensed healthcare professional.")
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.80))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.12, green: 0.10, blue: 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(amber.opacity(0.30), lineWidth: 1.5)
                )
        )
    }
}

// ─────────────────────────────────────────
// LEGAL QUALIFIER
// Legal Framework §4.1 Line 3 — required below DoctorPromptCard.
// Fixed copy — do not modify without legal review.
// ─────────────────────────────────────────

private struct EscalateLegalQualifier: View {
    var body: some View {
        Text("This prompt is based on duration and trend information only. It is not a diagnosis, treatment recommendation, emergency instruction, or determination that medical care is necessary.")
            .font(.jost(size: 11, weight: .light))
            .foregroundColor(ChronosTheme.faint.opacity(0.55))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ─────────────────────────────────────────
// ESCALATE COUNTERWEIGHT SECTION
// Same green treatment as TrajectoryCounterweightSection.
// ─────────────────────────────────────────

private struct EscalateCounterweightSection: View {
    let labels: [String]

    private let green = Color(red: 0.40, green: 0.82, blue: 0.50)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(green).frame(width: 5, height: 5)
                Text("WORKING IN YOUR FAVOR")
                    .font(.jost(size: 9, weight: .medium))
                    .foregroundColor(green)
                    .tracking(2)
            }

            VStack(spacing: 8) {
                ForEach(labels, id: \.self) { label in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .light))
                            .foregroundColor(green.opacity(0.70))
                        Text(label.capitalized)
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.75))
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.06, green: 0.12, blue: 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(green.opacity(0.18), lineWidth: 1))
            )
        }
    }
}

// ─────────────────────────────────────────
// ESCALATE ACTION SECTION
// Deferred CTAs with gold badge + alternative action + Notify me toggle.
// Toggle writes to user_feature_waitlist via SupabaseService.
// ─────────────────────────────────────────

private struct EscalateActionSection: View {
    let assessment: HorizonAssessment
    @Binding var isGeneratingReport: Bool
    let onDoctorReport: () -> Void
    let onHorizonAssist: () -> Void

    @EnvironmentObject var supabase: SupabaseService

    @AppStorage("waitlist_dpc_scheduling") private var enrolledDPC = false

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AVAILABLE ACTIONS")
                .font(.jost(size: 9, weight: .medium))
                .foregroundColor(ChronosTheme.faint)
                .tracking(2)
                .padding(.bottom, 2)

            // ── Doctor Report (Sprint 9: ACTIVE) ──────────────────────────
            ActiveCTARow(
                icon: "doc.text",
                title: "Doctor Report",
                subtitle: "Export a 30-day wellness summary formatted for a healthcare conversation.",
                actionLabel: isGeneratingReport ? "Generating…" : "Export PDF",
                isLoading: isGeneratingReport,
                onAction: onDoctorReport
            )

            // ── Direct Primary Care (Phase 3) ────────────────────────────
            DeferredCTARow(
                icon: "calendar.badge.plus",
                title: "Direct Primary Care",
                subtitle: "Schedule with an MBI-affiliated primary care provider.",
                alternative: "Search 'direct primary care' in your area",
                phase: "Phase 3",
                isEnrolled: enrolledDPC
            ) {
                enrolledDPC = true
                Task { await supabase.enrollFeatureWaitlist(
                    userId: supabase.session?.userId ?? "",
                    featureSlug: "dpc_scheduling",
                    sourcePage: "escalate"
                )}
            }

            // ── Horizon Assist (Sprint 9: ACTIVE) ────────────────────────
            ActiveCTARow(
                icon: "bubble.left.and.text.bubble.right",
                title: "Horizon Assist",
                subtitle: "Ask Horizon what it's tracking and why about your patterns.",
                actionLabel: "Ask Horizon",
                isLoading: false,
                onAction: onHorizonAssist
            )
        }
    }
}

// ─────────────────────────────────────────
// ACTIVE CTA ROW
// Sprint 9: Used for Doctor Report and Horizon Assist — both now functional.
// Shows a tappable action button instead of a "Notify me" waitlist toggle.
// ─────────────────────────────────────────

private struct ActiveCTARow: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionLabel: String
    let isLoading: Bool
    let onAction: () -> Void

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .ultraLight))
                    .foregroundColor(amber.opacity(0.65))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.text.opacity(0.90))
                    Text(subtitle)
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint.opacity(0.65))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            // Action row
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            HStack {
                Spacer()
                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.65).tint(amber.opacity(0.60))
                        Text(actionLabel)
                            .font(.jost(size: 11, weight: .medium))
                            .foregroundColor(amber.opacity(0.60))
                    }
                } else {
                    Button(action: onAction) {
                        Text(actionLabel)
                            .font(.jost(size: 11, weight: .medium))
                            .foregroundColor(amber)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(amber.opacity(0.12))
                                    .overlay(Capsule().stroke(amber.opacity(0.35), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(amber.opacity(0.18), lineWidth: 1))
        )
    }
}

private struct DeferredCTARow: View {
    let icon: String
    let title: String
    let subtitle: String
    let alternative: String
    let phase: String
    let isEnrolled: Bool
    let onEnroll: () -> Void

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .ultraLight))
                    .foregroundColor(ChronosTheme.faint.opacity(0.50))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                    Text(subtitle)
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint.opacity(0.60))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // Gold phase badge
                Text(phase.uppercased())
                    .font(.jost(size: 7, weight: .medium))
                    .foregroundColor(amber.opacity(0.70))
                    .tracking(1.0)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(amber.opacity(0.12))
                            .overlay(Capsule().stroke(amber.opacity(0.30), lineWidth: 1))
                    )
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Alternative action
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .light))
                    .foregroundColor(ChronosTheme.faint.opacity(0.40))
                Text("Now: \(alternative)")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(ChronosTheme.faint.opacity(0.55))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            // Notify me row
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            HStack {
                Text(isEnrolled ? "Enrolled — we'll notify you" : "Notify me when available")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(isEnrolled ? amber.opacity(0.70) : ChronosTheme.faint)

                Spacer()

                if isEnrolled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(amber.opacity(0.70))
                } else {
                    Button(action: onEnroll) {
                        Text("Notify me")
                            .font(.jost(size: 11, weight: .medium))
                            .foregroundColor(amber.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(amber.opacity(0.12))
                                    .overlay(Capsule().stroke(amber.opacity(0.28), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.13))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1))
        )
    }
}

// ─────────────────────────────────────────
// LEGAL NOTE
// Always visible on Page 6. Approved wellness-only framing.
// Fixed copy per Legal Framework §4.1 — do not modify without review.
// ─────────────────────────────────────────

private struct EscalateLegalNote: View {
    var body: some View {
        Text("Chronos tracks wellness patterns in measurements you choose to share. Nothing on this screen is a medical diagnosis, clinical assessment, or emergency instruction. The suggestion above is based on pattern duration only.")
            .font(.jost(size: 10, weight: .light))
            .foregroundColor(ChronosTheme.faint.opacity(0.45))
            .lineSpacing(4)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
