// ios/MBI/MBI/Views/OnboardingFlowView.swift
// MBI Phase 1.5 — Onboarding Redesign · Epic 2 Sprint 1
// Phase 2 Sprint 4: Resume Checkpoint — step persisted via @AppStorage.
//   On cold launch mid-onboarding, flow resumes from last saved step.
//   Step is cleared (reset to 0) in OnboardingCompletionView.onAppear
//   so a fresh reinstall always starts from the beginning.
// Stages: Claim → How It Works (3) → Account → Personalization (2) → Disclosure → HealthKit (2) → Baseline → Completion
// PDR: MBI_Epic2_Sprint1_OnboardingRedesign_PDR_v1_0

import SwiftUI
import HealthKit

// ─────────────────────────────────────────
// FLOW COORDINATOR
// Steps:
//   0  — Stage 1: The Claim
//   1  — Stage 2a: Five Signals      (skippable → 4)
//   2  — Stage 2b: Your Baseline     (skippable → 4)
//   3  — Stage 2c: Prediction Promise(skippable → 4)
//        Note: Account creation (Stage 3) is handled by AuthView in sign-up mode,
//        routed externally by MBIApp root *before* this flow renders — it does
//        not consume an onboardingStep value. Onboarding begins here post-auth.
//   4  — Beta Consent Gate (NA-010 / CC-024) — blocks all later steps until
//        affirmative consent; every path into Stage 4 routes through here first.
//   5  — Stage 4a: Name & Step Goal
//   6  — Stage 4b: Health Goal
//   7  — Stage 5a: Health Data Processing Disclosure (P5.3 — required by Apple HealthKit guidelines)
//   8  — Stage 5b: Soft HealthKit Pre-Permission
//   9  — Stage 5c: HealthKit Signal Confirmation
//   10 — Stage 6a: Baseline Build
//   11 — Stage 6b: Completion & Handoff
// ─────────────────────────────────────────

struct OnboardingFlowView: View {
    @EnvironmentObject var supabase: SupabaseService

    // Resume checkpoint — persists across cold launches.
    // Cleared to 0 when onboarding completes (OnboardingCompletionView.onAppear).
    @AppStorage("onboardingStep") private var step: Int = 0

    // Shared profile state
    @State private var firstName = ""
    @State private var lastName  = ""
    @State private var birthday     = ""
    @State private var heightFt     = ""
    @State private var heightIn     = ""
    @State private var weightText   = ""
    @State private var biologicalSex = ""  // "male" | "female" | "prefer_not_to_say"
    @State private var healthGoal: String = ""   // no default — user must select

    // Wearable tier — set by OnboardingWearableCheckView, persisted for main app gating
    @AppStorage("wearableDataTier") private var wearableDataTierRaw: String = WearableDataTier.full.rawValue

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [ChronosTheme.gold.opacity(0.05), .clear],
                center: .top, startRadius: 0, endRadius: 360
            )
            .ignoresSafeArea()

            switch step {
            // Stage 1
            case 0:
                OnboardingClaimView(onNext: { step = 1 })

            // Stage 2 — How It Works (all skippable)
            // Every exit routes to the consent gate (step 4), never directly to Stage 4.
            case 1:
                OnboardingFiveSignalsView(
                    onNext: { step = 2 },
                    onSkip: { step = 4 }   // skip routes to consent gate
                )
            case 2:
                OnboardingYourBaselineView(
                    onNext: { step = 3 },
                    onSkip: { step = 4 }
                )
            case 3:
                OnboardingPredictionPromiseView(
                    onNext: { step = 4 },  // Stage 2 → consent gate (auth already done)
                    onSkip: { step = 4 }
                )

            // Beta Consent Gate — NA-010 / CC-024
            // The only path into Stage 4 and beyond. Blocks until affirmative consent.
            case 4:
                OnboardingConsentView(onConsent: { step = 5 })

            // Stage 4 — Personalization
            case 5:
                OnboardingProfileView(
                    firstName:    $firstName,
                    lastName:     $lastName,
                    birthday:     $birthday,
                    heightFt:     $heightFt,
                    heightIn:     $heightIn,
                    weightText:   $weightText,
                    biologicalSex: $biologicalSex,
                    onNext: { step = 6 }
                )
            case 6:
                OnboardingHealthGoalView(
                    healthGoal: $healthGoal,
                    onNext: { step = 7 }
                )

            // Stage 5 — Health Data Disclosure + Connect Your Data
            case 7:
                OnboardingHealthDisclosureView(onNext: { step = 8 })
            case 8:
                OnboardingSoftHealthKitView(onNext: { step = 9 })
            case 9:
                OnboardingHealthKitConfirmView(onNext: { step = 10 })

            // Stage 6 — Baseline Build & Handoff
            case 10:
                OnboardingBootstrapView(
                    firstName: firstName,
                    onComplete: { step = 12 }   // routes to wearable check, not directly to completion
                )
            case 11:
                OnboardingCompletionView(firstName: firstName)

            // Stage 6b — Wearable Data Quality Gate
            case 12:
                OnboardingWearableCheckView(
                    onNoWearable:  { wearableDataTierRaw = WearableDataTier.noWearable.rawValue; step = 13 },
                    onSevenDay:    { wearableDataTierRaw = WearableDataTier.sevenDay.rawValue;   step = 14 },
                    onSufficient:  { tier in wearableDataTierRaw = tier.rawValue;                step = 11 }
                )
            case 13:
                OnboardingNoWearableView(onNext: { step = 11 })
            case 14:
                OnboardingWearableGateView(onNext: { step = 11 })

            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: step)
    }
}

// ─────────────────────────────────────────
// PROGRESS INDICATOR — gold dash / muted dashes
// ─────────────────────────────────────────

struct OnboardingProgressDots: View {
    let current: Int   // 1-indexed
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i <= current ? ChronosTheme.gold : ChronosTheme.faint)
                    .frame(width: i == current ? 20 : 6, height: 2)
                    .animation(.easeInOut(duration: 0.3), value: current)
            }
        }
    }
}

// ─────────────────────────────────────────
// STAGE 1 — THE CLAIM
// PDR Screen 1.1
// ─────────────────────────────────────────

struct OnboardingClaimView: View {
    let onNext: () -> Void
    @State private var appeared = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Logo block
                VStack(spacing: 0) {
                    ChronosLogoMark()
                        .frame(width: 72, height: 72)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(.easeOut(duration: 0.8).delay(0.1), value: appeared)
                        .padding(.bottom, 24)

                    VStack(spacing: 8) {
                        Text("CHRONOS")
                            .font(.cormorant(size: 40))
                            .foregroundColor(ChronosTheme.text)
                            .tracking(10)

                        Text("BY MYND & BODI INSTITUTE")
                            .font(.jost(size: 9, weight: .light))
                            .foregroundColor(ChronosTheme.gold)
                            .tracking(4)

                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.clear, ChronosTheme.gold, .clear],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: 100, height: 1)
                            .padding(.top, 12)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .animation(.easeOut(duration: 0.8).delay(0.3), value: appeared)
                }
                .padding(.top, 60)

                // Headline block
                VStack(spacing: 24) {
                    Text("You are not average.\nYour wellness score shouldn't be either.")
                        .font(.cormorant(size: 28, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .padding(.horizontal, 32)
                        .padding(.top, 36)

                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.clear, ChronosTheme.gold.opacity(0.5), .clear],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: 60, height: 1)

                    VStack(spacing: 8) {
                        Text("Five signals. One score. Updated every morning.")
                            .font(.jost(size: 15, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                        Text("Compared only to you. Never a population.")
                            .font(.jost(size: 15, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                        Text("The more you connect, the smarter it gets.")
                            .font(.jost(size: 15, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                    }
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 40)
                }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.7).delay(0.45), value: appeared)

                // Proof point card
                VStack(alignment: .leading, spacing: 8) {
                    Text("FOR EXAMPLE")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(ChronosTheme.gold)
                        .tracking(3)

                    Text("\"Your Chronos score is 96. That's your strongest reading in two weeks. Keep the momentum going.\"")
                        .font(.cormorantItalic(size: 17))
                        .foregroundColor(ChronosTheme.text.opacity(0.85))
                        .lineSpacing(4)

                    Text("Same number. Completely different meaning.")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(ChronosTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(ChronosTheme.border, lineWidth: 1)
                        )
                        .overlay(
                            Rectangle()
                                .fill(ChronosTheme.gold)
                                .frame(width: 2)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 12)
                                ),
                            alignment: .leading
                        )
                )
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(0.65), value: appeared)

                // CTA block
                VStack(spacing: 12) {
                    ChronosPrimaryButton(title: "Get Started", fontSize: 15, action: onNext)

                    Text("Takes about 2 minutes.")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 52)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(0.8), value: appeared)
            }
        }
        .onAppear { appeared = true }
    }
}

// ─────────────────────────────────────────
// STAGE 2a — THE FIVE SIGNALS
// PDR Screen 2.1
// ─────────────────────────────────────────

struct OnboardingFiveSignalsView: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    let signals: [(String, String, String)] = [
        ("waveform.path.ecg",  "Heart Rate Variability",  "How well your nervous system recovered overnight."),
        ("heart",              "Resting Heart Rate",       "How hard your heart is working at rest. A stress signal."),
        ("lungs",              "Respiratory Rate",         "Your earliest warning signal for illness and overload."),
        ("moon.zzz",           "Sleep Duration & Quality", "The window where your body repairs itself."),
        ("figure.walk",        "Steps & Active Minutes",   "How much you moved and how your body responded."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(current: 1, total: 3)
                .padding(.top, 64)
                .padding(.bottom, 40)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("We read five signals\nyour body sends every night.")
                            .font(.cormorant(size: 30, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                            .lineSpacing(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)

                    VStack(spacing: 0) {
                        ForEach(signals, id: \.1) { icon, name, meaning in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: icon)
                                    .font(.system(size: 14, weight: .ultraLight))
                                    .foregroundColor(ChronosTheme.gold)
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(name)
                                        .font(.jost(size: 13, weight: .regular))
                                        .foregroundColor(ChronosTheme.text)
                                    Text(meaning)
                                        .font(.jost(size: 12, weight: .light))
                                        .foregroundColor(ChronosTheme.muted)
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)

                            if name != signals.last?.1 {
                                Rectangle()
                                    .fill(ChronosTheme.border)
                                    .frame(height: 1)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }

                    // Skip link
                    Button(action: onSkip) {
                        Text("Skip for now")
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 8)
                }
            }

            ChronosPrimaryButton(title: "Continue", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
    }
}

// ─────────────────────────────────────────
// STAGE 2b — YOUR BASELINE
// PDR Screen 2.2
// ─────────────────────────────────────────

struct OnboardingYourBaselineView: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(current: 2, total: 3)
                .padding(.top, 64)
                .padding(.bottom, 40)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Text("Your baseline\nis yours alone.")
                        .font(.cormorant(size: 30, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)

                    // Two-column comparison card
                    HStack(spacing: 0) {
                        // Left — Every Other App
                        VStack(spacing: 8) {
                            Text("EVERY OTHER APP")
                                .font(.jost(size: 9, weight: .medium))
                                .foregroundColor(ChronosTheme.faint)
                                .tracking(2)
                                .multilineTextAlignment(.center)
                            Text("HRV 42ms")
                                .font(.cormorant(size: 22, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                            Text("Is this good?\nDepends on the average.")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .padding(.horizontal, 12)

                        Rectangle()
                            .fill(ChronosTheme.border)
                            .frame(width: 1)
                            .padding(.vertical, 16)

                        // Right — Chronos
                        VStack(spacing: 8) {
                            Text("CHRONOS")
                                .font(.jost(size: 9, weight: .medium))
                                .foregroundColor(ChronosTheme.gold)
                                .tracking(2)
                            Text("HRV 42ms")
                                .font(.cormorant(size: 22, weight: .light))
                                .foregroundColor(ChronosTheme.text)
                            Text("Your strongest\nreading in 3 weeks.")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .padding(.horizontal, 12)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(ChronosTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(ChronosTheme.border, lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                    // Explanation
                    VStack(alignment: .leading, spacing: 10) {
                        Text("We don't compare you to anyone else. We track your patterns over time and tell you when something shifts relative to your own normal.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .lineSpacing(5)

                        Text("That's why your score on Monday means something different than it does for your partner.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .lineSpacing(5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)

                    // Skip link
                    Button(action: onSkip) {
                        Text("Skip for now")
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                }
            }

            ChronosPrimaryButton(title: "Continue", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
    }
}

// ─────────────────────────────────────────
// STAGE 2c — THE PREDICTION PROMISE
// PDR Screen 2.3
// ─────────────────────────────────────────

struct OnboardingPredictionPromiseView: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(current: 3, total: 3)
                .padding(.top, 64)
                .padding(.bottom, 40)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Text("The more you connect,\nthe more we can see.")
                        .font(.cormorant(size: 30, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 36)

                    // Three-tier device list
                    VStack(spacing: 0) {
                        DeviceTierRow(icon: "applewatch",        label: "Apple Watch",      badgeText: "Connected",   badgeActive: true)
                            Rectangle().fill(ChronosTheme.border).frame(height: 1).padding(.horizontal, 32)
                            DeviceTierRow(icon: "scalemass",         label: "Smart Scale",      badgeText: "Connected",   badgeActive: true)
                            Rectangle().fill(ChronosTheme.border).frame(height: 1).padding(.horizontal, 32)
                            DeviceTierRow(icon: "heart.text.square", label: "Blood Pressure",   badgeText: "Connected",   badgeActive: true)
                            Rectangle().fill(ChronosTheme.border).frame(height: 1).padding(.horizontal, 32)
                            DeviceTierRow(icon: "drop.circle",       label: "Blood Panel",      badgeText: "Coming Soon", badgeActive: false)
                            Rectangle().fill(ChronosTheme.border).frame(height: 1).padding(.horizontal, 32)
                            DeviceTierRow(icon: "target",            label: "Personal Targets", badgeText: "Coming Soon", badgeActive: false)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(ChronosTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(ChronosTheme.border, lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                    Text("Right now, we're reading your Apple Health data. As you connect more devices, your Chronos score becomes more precise — and we can start to see patterns before you feel them.")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)

                    // Skip link
                    Button(action: onSkip) {
                        Text("Skip for now")
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                }
            }

            ChronosPrimaryButton(title: "Continue", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
    }
}

private struct DeviceTierRow: View {
    let icon: String
    let label: String
    let badgeText: String
    let badgeActive: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .ultraLight))
                .foregroundColor(badgeActive ? ChronosTheme.gold : ChronosTheme.faint)
                .frame(width: 24)

            Text(label)
                .font(.jost(size: 13, weight: .regular))
                .foregroundColor(badgeActive ? ChronosTheme.text : ChronosTheme.muted)

            Spacer()

            Text(badgeText)
                .font(.jost(size: 10, weight: .medium))
                .foregroundColor(badgeActive ? ChronosTheme.gold : ChronosTheme.faint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(badgeActive ? ChronosTheme.goldDim : ChronosTheme.surface)
                        .overlay(
                            Capsule().stroke(
                                badgeActive ? ChronosTheme.gold.opacity(0.3) : ChronosTheme.border,
                                lineWidth: 1
                            )
                        )
                )
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
}

// ─────────────────────────────────────────
// STAGE 4a — NAME & STEP GOAL
// PDR Screen 4.1
// ─────────────────────────────────────────

struct OnboardingProfileView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Binding var firstName:    String
    @Binding var lastName:     String
    @Binding var birthday:     String
    @Binding var heightFt:     String
    @Binding var heightIn:     String
    @Binding var weightText:   String
    @Binding var biologicalSex: String
    let onNext: () -> Void

    @State private var selectedDate   = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var showDatePicker = false
    @State private var isLoading      = false
    @State private var error: String?

    private let storageFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private let displayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()
    private var maxBirthday: Date {
        Calendar.current.date(byAdding: .year, value: -13, to: Date()) ?? Date()
    }

    var canContinue: Bool { !firstName.trimmingCharacters(in: .whitespaces).isEmpty }
    var displayName: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(current: 1, total: 2)
                .padding(.top, 64).padding(.bottom, 40)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Who are we\npersonalizing this for?")
                            .font(.cormorant(size: 32, weight: .light))
                            .foregroundColor(ChronosTheme.text).lineSpacing(4)
                        Text("We use this to personalize your daily score and baseline calculations.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted).lineSpacing(4).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32).padding(.bottom, 36)

                    VStack(spacing: 14) {
                        ChronosTextField(placeholder: "First name", text: $firstName)
                        ChronosTextField(placeholder: "Last name",  text: $lastName)

                        // Birthday — inline wheel picker
                        VStack(alignment: .leading, spacing: 6) {
                            Button(action: {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                withAnimation(.easeInOut(duration: 0.25)) { showDatePicker.toggle() }
                            }) {
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(red: 0.06, green: 0.06, blue: 0.09))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ChronosTheme.border, lineWidth: 1))
                                        .frame(height: 52)
                                    HStack {
                                        Text(birthday.isEmpty ? "Birthday" : displayFmt.string(from: selectedDate))
                                            .font(.jost(size: 13, weight: .light))
                                            .foregroundColor(birthday.isEmpty ? ChronosTheme.faint : ChronosTheme.text)
                                            .padding(.horizontal, 16)
                                        Spacer()
                                        Image(systemName: "calendar")
                                            .font(.system(size: 13, weight: .ultraLight))
                                            .foregroundColor(ChronosTheme.faint).padding(.trailing, 16)
                                    }
                                }
                            }
                            if showDatePicker {
                                DatePicker("", selection: $selectedDate, in: ...maxBirthday, displayedComponents: .date)
                                    .datePickerStyle(.wheel).labelsHidden().colorScheme(.dark)
                                    .frame(maxWidth: .infinity)
                                    .onChange(of: selectedDate) { _, newDate in
                                        birthday = storageFmt.string(from: newDate)
                                    }
                                    .tint(ChronosTheme.gold)
                            }
                            Text("Used to calculate age-relative baselines.")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint).padding(.horizontal, 4)
                        }

                        // Height
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                ChronosTextField(placeholder: "Ft",        text: $heightFt, keyboardType: .numberPad)
                                ChronosTextField(placeholder: "In (0–11)", text: $heightIn, keyboardType: .numberPad)
                            }
                            Text("Height — feet and inches.")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint).padding(.horizontal, 4)
                        }

                        // Weight
                        VStack(alignment: .leading, spacing: 6) {
                            ChronosTextField(placeholder: "Current weight (lbs)", text: $weightText, keyboardType: .decimalPad)
                            Text("Used to personalize activity and metabolic signals.")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint).padding(.horizontal, 4)
                        }

                        // Biological sex
                        VStack(alignment: .leading, spacing: 6) {
                            Text("BIOLOGICAL SEX")
                                .font(.jost(size: 10, weight: .medium))
                                .foregroundColor(ChronosTheme.muted)
                                .tracking(1.5)

                            HStack(spacing: 10) {
                                ForEach([("Male", "male"), ("Female", "female"), ("Prefer not to say", "prefer_not_to_say")], id: \.1) { label, value in
                                    Button(action: { biologicalSex = value }) {
                                        Text(label)
                                            .font(.jost(size: 13, weight: biologicalSex == value ? .medium : .light))
                                            .foregroundColor(biologicalSex == value ? ChronosTheme.surface : ChronosTheme.text.opacity(0.7))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 11)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(biologicalSex == value ? ChronosTheme.gold : ChronosTheme.ink)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .stroke(biologicalSex == value ? Color.clear : ChronosTheme.border, lineWidth: 1)
                                                    )
                                            )
                                    }
                                }
                            }
                            Text("Used for age-relative physiological baselines. You can change this later.")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint).padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 32)

                    if let error = error {
                        Text(error).font(.jost(size: 12, weight: .light)).foregroundColor(.red.opacity(0.75))
                            .padding(.top, 12).padding(.horizontal, 32)
                    }
                    Spacer().frame(height: 40)
                }
            }
            // Fix 1: tap outside to dismiss keyboard
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }

            ChronosPrimaryButton(title: "Continue", isLoading: isLoading) {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                guard canContinue else { error = "Please enter your first name to continue."; return }
                isLoading = true
                Task {
                    do {
                        guard let userId = supabase.session?.userId else { return }
                        try await supabase.updateOnboardingProfile(
                            userId:        userId,
                            displayName:   displayName.isEmpty ? firstName : displayName,
                            birthday:      birthday.isEmpty ? nil : birthday,
                            heightFt:      Int(heightFt),
                            heightIn:      Int(heightIn),
                            weightLbs:     Double(weightText),
                            biologicalSex: biologicalSex.isEmpty ? nil : biologicalSex
                        )
                        onNext()
                    } catch { self.error = error.localizedDescription }
                    isLoading = false
                }
            }
            .opacity(canContinue ? 1 : 0.45)
            .padding(.horizontal, 32).padding(.bottom, 48)
        }
    }
}

// ─────────────────────────────────────────
// STAGE 4b — HEALTH GOAL
// PDR Screen 4.2 · Bug S1-001 fix: no default
// ─────────────────────────────────────────

struct OnboardingHealthGoalView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Binding var healthGoal: String
    let onNext: () -> Void

    @State private var isLoading = false
    @State private var error: String?

    // PDR options → Supabase raw values
    // "Improve sleep" removed per founder decision (maps to general_wellness,
    // duplicate of General health awareness)
    let goalOptions: [(label: String, value: String)] = [
        ("Optimize recovery",       "recovery"),
        ("Reduce stress",           "stress_management"),
        ("Build resilience",        "fitness"),
        ("General health awareness","general_wellness"),
    ]

    var canContinue: Bool { !healthGoal.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(current: 2, total: 2)
                .padding(.top, 64)
                .padding(.bottom, 40)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's your primary\nhealth goal?")
                            .font(.cormorant(size: 32, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                            .lineSpacing(4)

                        Text("This shapes how we explain your score each day.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)

                    VStack(spacing: 10) {
                        ForEach(goalOptions, id: \.value) { option in
                            let isSelected = healthGoal == option.value
                            Button(action: { healthGoal = option.value }) {
                                HStack {
                                    Text(option.label)
                                        .font(.jost(size: 13, weight: isSelected ? .medium : .light))
                                        .foregroundColor(isSelected ? ChronosTheme.gold : ChronosTheme.muted)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .light))
                                            .foregroundColor(ChronosTheme.gold)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(isSelected ? ChronosTheme.goldDim : ChronosTheme.surface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(
                                                    isSelected
                                                        ? ChronosTheme.gold.opacity(0.5)
                                                        : ChronosTheme.border,
                                                    lineWidth: isSelected ? 1.5 : 1
                                                )
                                        )
                                )
                            }
                            .padding(.horizontal, 32)
                        }
                    }

                    if let error = error {
                        Text(error)
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(.red.opacity(0.75))
                            .padding(.top, 12)
                            .padding(.horizontal, 32)
                    }

                    Spacer().frame(height: 40)
                }
            }

            ChronosPrimaryButton(title: "Continue", isLoading: isLoading) {
                guard canContinue else {
                    error = "Please select a health goal to continue."
                    return
                }
                isLoading = true
                Task {
                    do {
                        guard let userId = supabase.session?.userId else { return }
                        try await supabase.updateProfile(userId: userId, healthGoal: healthGoal)
                        onNext()
                    } catch {
                        self.error = error.localizedDescription
                    }
                    isLoading = false
                }
            }
            .opacity(canContinue ? 1 : 0.45)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
}

// ─────────────────────────────────────────
// STAGE 5a — HEALTH DATA PROCESSING DISCLOSURE
// P5.3 — Required by Apple HealthKit guidelines.
// Must immediately precede the HealthKit permission prompt.
// Discloses: what is collected, how it is used, where stored, how to delete.
// ─────────────────────────────────────────

struct OnboardingHealthDisclosureView: View {
    let onNext: () -> Void
    @State private var showPrivacyPolicy = false

    let disclosures: [(icon: String, title: String, detail: String)] = [
        (
            "list.bullet.clipboard",
            "What we collect",
            "Heart Rate Variability, Resting Heart Rate, Respiratory Rate, Sleep Duration & Quality, and Steps — read-only from Apple Health. We never write data back."
        ),
        (
            "lock.shield",
            "How it's used",
            "Exclusively to calculate your daily Chronos score. Your health data is never sold, shared with advertisers, or used for research without your explicit consent."
        ),
        (
            "server.rack",
            "Where it's stored",
            "Encrypted at rest on Supabase-managed servers (US/EU). Only your anonymous user ID is linked to your health data — never your name or email."
        ),
        (
            "trash",
            "How to delete it",
            "You can permanently delete all your data at any time via Account → Delete Account. Deletion is immediate and cannot be undone."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 72)

                    // Shield icon
                    Image(systemName: "lock.shield")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundColor(ChronosTheme.gold)
                        .padding(.bottom, 28)

                    VStack(spacing: 8) {
                        Text("Before we connect\nto Apple Health.")
                            .font(.cormorant(size: 30, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                            .lineSpacing(4)
                            .multilineTextAlignment(.center)

                        Text("Here's exactly what we read, how we use it, and how you stay in control.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 36)

                    // Four disclosure rows
                    VStack(spacing: 0) {
                        ForEach(disclosures, id: \.title) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .ultraLight))
                                    .foregroundColor(ChronosTheme.gold)
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title)
                                        .font(.jost(size: 13, weight: .medium))
                                        .foregroundColor(ChronosTheme.text)
                                    Text(item.detail)
                                        .font(.jost(size: 12, weight: .light))
                                        .foregroundColor(ChronosTheme.muted)
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)

                            if item.title != disclosures.last?.title {
                                Rectangle()
                                    .fill(ChronosTheme.border)
                                    .frame(height: 1)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
                    .padding(.bottom, 20)

                    // Privacy policy link — in-app native viewer
                    Button(action: { showPrivacyPolicy = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11, weight: .ultraLight))
                            Text("Read our full Privacy Policy")
                                .font(.jost(size: 12, weight: .light))
                        }
                        .foregroundColor(ChronosTheme.gold.opacity(0.8))
                    }
                    .padding(.bottom, 48)
                }
            }

            ChronosPrimaryButton(title: "I Understand, Continue", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
        .sheet(isPresented: $showPrivacyPolicy) { PolicyView(document: .privacyPolicy) }
    }
}

// ─────────────────────────────────────────
// STAGE 5b — SOFT HEALTHKIT PRE-PERMISSION
// PDR Screen 5.2 · (was 5.1) — shown after disclosure
// ─────────────────────────────────────────

struct OnboardingSoftHealthKitView: View {
    let onNext: () -> Void

    @State private var isLoading = false

    let signals: [(String, String)] = [
        ("waveform.path.ecg",  "Heart Rate Variability"),
        ("heart",              "Resting Heart Rate"),
        ("lungs",              "Respiratory Rate"),
        ("moon.zzz",           "Sleep Duration & Quality"),
        ("figure.walk",        "Steps & Active Minutes"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 72)

                    // Logo mark — smaller
                    ChronosLogoMark()
                        .frame(width: 56, height: 56)
                        .padding(.bottom, 32)

                    Text("Connect\nApple Health.")
                        .font(.cormorant(size: 32, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .lineSpacing(4)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 16)

                    // Two-sentence explanation
                    VStack(spacing: 8) {
                        Text("We read 5 signals to build your daily Chronos score.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .multilineTextAlignment(.center)
                        Text("Without this connection, we can't calculate your score.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .lineSpacing(4)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 36)

                    // Signal preview list
                    VStack(spacing: 0) {
                        ForEach(signals, id: \.1) { icon, name in
                            HStack(spacing: 14) {
                                Image(systemName: icon)
                                    .font(.system(size: 14, weight: .ultraLight))
                                    .foregroundColor(ChronosTheme.gold)
                                    .frame(width: 20)
                                Text(name)
                                    .font(.jost(size: 13, weight: .light))
                                    .foregroundColor(ChronosTheme.text)
                                Spacer()
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)

                            if name != signals.last?.1 {
                                Rectangle()
                                    .fill(ChronosTheme.border)
                                    .frame(height: 1)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
                    .padding(.bottom, 12)

                    Text("Nothing is stored on device.")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .padding(.bottom, 40)

                }
            }

            ChronosPrimaryButton(title: "Connect Apple Health", isLoading: isLoading) {
                isLoading = true
                Task {
                    try? await HealthKitManager.shared.requestAuthorization()
                    isLoading = false
                    onNext()
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
}

// ─────────────────────────────────────────
// STAGE 5c — HEALTHKIT SIGNAL CONFIRMATION
// PDR Screen 5.3 · Existing screen refined
// ─────────────────────────────────────────

struct OnboardingHealthKitConfirmView: View {
    let onNext: () -> Void

    let metrics: [(String, String, String)] = [
        ("waveform.path.ecg", "Heart Rate Variability", "Your primary recovery signal"),
        ("heart",             "Resting Heart Rate",      "Autonomic balance and stress load"),
        ("lungs",             "Respiratory Rate",        "Strongest early illness indicator"),
        ("moon.zzz",          "Sleep Duration & Quality","Cellular repair window"),
        ("figure.walk",       "Steps & Active Minutes",  "Movement and behavioral patterns"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 72)

                    Text("Connect\nApple Health.")
                        .font(.cormorant(size: 32, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)

                    Text("We read 5 signals to build your daily Chronos score. Nothing is stored on device.")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)

                    VStack(spacing: 0) {
                        ForEach(metrics, id: \.1) { icon, name, description in
                            HStack(alignment: .center, spacing: 14) {
                                Image(systemName: icon)
                                    .font(.system(size: 14, weight: .ultraLight))
                                    .foregroundColor(ChronosTheme.gold)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name)
                                        .font(.jost(size: 13, weight: .regular))
                                        .foregroundColor(ChronosTheme.text)
                                    Text(description)
                                        .font(.jost(size: 11, weight: .light))
                                        .foregroundColor(ChronosTheme.muted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)

                            if name != metrics.last?.1 {
                                Rectangle()
                                    .fill(ChronosTheme.border)
                                    .frame(height: 1)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
                    .padding(.bottom, 20)

                    // Connected confirmation line
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13, weight: .ultraLight))
                            .foregroundColor(ChronosTheme.gold)
                        Text("Apple Health connected. We'll start reading your data now.")
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .lineSpacing(3)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
                }
            }

            ChronosPrimaryButton(title: "Continue", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
    }
}

// ─────────────────────────────────────────
// STAGE 6a — BASELINE BUILD
// PDR Screen 6.1 · Auto-starts, sequential callouts
// ─────────────────────────────────────────

struct OnboardingBootstrapView: View {
    @EnvironmentObject var supabase: SupabaseService
    @ObservedObject private var sync = SyncCoordinator.shared
    let firstName: String
    let onComplete: () -> Void

    @State private var calloutIndex = 0
    @State private var error: String?
    @State private var isDone = false

    private var progress: Int { sync.backfillDone }
    private var total: Int    { sync.backfillTotal }

    // Sequential signal callouts — PDR Section 6.1
    let callouts = [
        "Reading your HRV history...",
        "Reading your heart rate patterns...",
        "Reading your sleep data...",
        "Reading your respiratory signals...",
        "Reading your movement data...",
    ]

    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(progress) / Double(total)
    }

    // Advance callout index in sync with processing progress
    var currentCallout: String {
        guard total > 0 else { return callouts[0] }
        let idx = min(
            Int((progressFraction * Double(callouts.count - 1)).rounded()),
            callouts.count - 1
        )
        return callouts[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Building your\nbaseline.")
                    .font(.cormorant(size: 32, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                    .lineSpacing(4)

                Text("We're reading your full Apple Health history to personalize your scoring from day one.")
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .lineSpacing(5)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)

            // Progress bar + sequential callout
            VStack(spacing: 14) {
                ProgressView(
                    value: progressFraction,
                    total: 1.0
                )
                .tint(ChronosTheme.gold)
                .padding(.horizontal, 32)

                Text(total == 0 ? "Scanning your health history..." : currentCallout)
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .animation(.easeInOut(duration: 0.4), value: progress)

                if total > 0 {
                    Text("Processing day \(progress) of \(total)...")
                        .font(.jost(size: 11, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .animation(.easeInOut, value: progress)
                }
            }

            if let error = error {
                Text(error)
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(.red.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            }

            Spacer()
        }
        .onAppear {
            // Auto-start — no "Start Sync" button per PDR
            Task {
                guard let userId = supabase.session?.userId else { return }
                await SyncCoordinator.shared.runHistoricalBackfill(userId: userId)
                isDone = true
                onComplete()
            }
        }
    }
}

// ─────────────────────────────────────────
// STAGE 6b — COMPLETION & HANDOFF
// PDR Screen 6.2
// onboarding_complete flips on screen LOAD, not button tap
// ─────────────────────────────────────────

struct OnboardingCompletionView: View {
    @EnvironmentObject var supabase: SupabaseService
    let firstName: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // Checkmark clock mark
                ZStack {
                    Circle()
                        .stroke(ChronosTheme.gold.opacity(0.2), lineWidth: 1)
                        .frame(width: 80, height: 80)
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundColor(ChronosTheme.gold)
                }

                VStack(spacing: 10) {
                    // Personalised headline
                    Text(firstName.isEmpty ? "You're all set." : "\(firstName), you're all set.")
                        .font(.cormorant(size: 32, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .multilineTextAlignment(.center)

                    Text("Your baseline is ready.")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)

                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.clear, ChronosTheme.gold.opacity(0.4), .clear],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: 80, height: 1)
                        .padding(.top, 8)

                    // Re-engagement hook — exact PDR copy
                    Text("Your score updates every morning.\nCome back tomorrow to see how you changed.")
                        .font(.cormorantItalic(size: 15))
                        .foregroundColor(ChronosTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .padding(.top, 4)
                        .padding(.horizontal, 40)
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            ChronosPrimaryButton(title: "Open My Dashboard") {
                Task {
                    // Reload user so app root picks up onboarding_complete = true
                    if let userId = supabase.session?.userId {
                        _ = try? await supabase.loadCurrentUser(userId: userId)
                    }
                    // Clear the resume checkpoint only AFTER the completion flag is
                    // refreshed — resetting step to 0 earlier would re-render step 0
                    // (Claim) under a still-onboarding root gate (the double-flow bug).
                    UserDefaults.standard.removeObject(forKey: "onboardingStep")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .onAppear {
            // onboarding_complete flips on SCREEN LOAD per PDR Section 6.2.
            // markOnboardingComplete sets the local currentUser flag once the
            // patch returns, so the root gate can route to the dashboard.
            Task {
                guard let userId = supabase.session?.userId else { return }
                try? await supabase.markOnboardingComplete(userId: userId)
            }
            // Request notification permission after onboarding completes
            Task { await NotificationService.shared.requestPermission() }
        }
    }
}

// ─────────────────────────────────────────
// STAGE 6b — WEARABLE DATA QUALITY GATE
// Runs after bootstrap. Counts HRV days in daily_inputs to classify data tier.
// HRV (SDNN) is Apple Watch-only — its presence is the wearable discriminator.
// Routes: noWearable → step 13, sevenDay → step 14, sufficient → step 11
// ─────────────────────────────────────────

struct OnboardingWearableCheckView: View {
    @EnvironmentObject var supabase: SupabaseService
    let onNoWearable: () -> Void
    let onSevenDay:   () -> Void
    let onSufficient: (WearableDataTier) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                ProgressView().tint(ChronosTheme.gold).scaleEffect(1.2)
                Text("Checking your data quality...")
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
            }
            Spacer()
        }
        .onAppear {
            Task {
                guard let userId = supabase.session?.userId else { onSufficient(.full); return }
                // Section 14: Use wearable tier count (data_tier = 'wearable') as the
                // primary discriminator post-migration. Falls back to HRV day count if the
                // wearable fetch returns 0 (pre-migration backfill may not have run yet).
                let wearableDays = (try? await supabase.fetchWearableDayCount(userId: userId)) ?? 0
                let tier: WearableDataTier
                if wearableDays > 0 {
                    tier = WearableDataTier.from(wearableDays: wearableDays)
                } else {
                    // Pre-migration fallback: count HRV days as proxy
                    let hrvDays = (try? await supabase.fetchHRVDayCount(userId: userId)) ?? 0
                    tier = WearableDataTier.from(hrvDays: hrvDays)
                }
                switch tier {
                case .noWearable: onNoWearable()
                case .sevenDay:   onSevenDay()
                default:          onSufficient(tier)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// STAGE 6c — NO WEARABLE DETECTED
// Shown when zero HRV days found after backfill.
// App loads but with canned template content only (no personalised scoring).
// Full-functionality messaging — not a hard block.
// ─────────────────────────────────────────

struct OnboardingNoWearableView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A wearable unlocks\nfull Chronos.")
                        .font(.cormorant(size: 32, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .lineSpacing(4)

                    Text("We didn't detect any Apple Watch data in your health history.")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                }

                VStack(alignment: .leading, spacing: 16) {
                    WearableFeatureRow(icon: "waveform.path.ecg", text: "HRV, resting heart rate, and respiratory rate — the core signals Chronos scores — require a wearable device.")
                    WearableFeatureRow(icon: "bed.double", text: "Sleep continuity tracking requires an Apple Watch or compatible wearable.")
                    WearableFeatureRow(icon: "chart.line.uptrend.xyaxis", text: "Without wearable data, your Chronos score and trend charts will not personalise.")
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("SUPPORTED DEVICES")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .tracking(2)
                    Text("Apple Watch Series 4 or later · Oura Ring · Garmin · Whoop")
                        .font(.jost(size: 12, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(4)
                }
                .padding(.top, 4)

                Text("You can explore Chronos now and return to connect a device at any time in Settings.")
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
                    .lineSpacing(5)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 32)

            Spacer()

            ChronosPrimaryButton(title: "Continue to Chronos", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
    }
}

private struct WearableFeatureRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .light))
                .foregroundColor(ChronosTheme.gold)
                .frame(width: 20, height: 20)
            Text(text)
                .font(.jost(size: 12, weight: .light))
                .foregroundColor(ChronosTheme.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// ─────────────────────────────────────────
// STAGE 6d — WEARABLE DETECTED, BUILDING (0–7 DAYS)
// Shown when wearable is present but < 8 days of HRV history.
// Placeholder — full content to be designed in a future sprint.
// ─────────────────────────────────────────

struct OnboardingWearableGateView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your baseline is\nstarting to form.")
                        .font(.cormorant(size: 32, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .lineSpacing(4)

                    Text("We detected your Apple Watch. Chronos needs 7 days of consistent wear to begin building your personal baseline.")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.muted)
                        .lineSpacing(5)
                }

                VStack(alignment: .leading, spacing: 12) {
                    DataTierRow(days: "7 days",   label: "First scores appear",            active: false)
                    DataTierRow(days: "30 days",  label: "Personalised baseline forms",    active: false)
                    DataTierRow(days: "90 days",  label: "Full Chronos intelligence",      active: false)
                }
                .padding(.top, 4)

                Text("Wear your Apple Watch to sleep each night to accelerate your baseline. Your data syncs automatically each morning.")
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(ChronosTheme.faint)
                    .lineSpacing(5)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 32)

            Spacer()

            ChronosPrimaryButton(title: "Start Building", action: onNext)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
        }
    }
}

private struct DataTierRow: View {
    let days: String
    let label: String
    let active: Bool
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(active ? ChronosTheme.gold : ChronosTheme.faint.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(days)
                .font(.jost(size: 12, weight: active ? .medium : .light))
                .foregroundColor(active ? ChronosTheme.gold : ChronosTheme.muted)
                .frame(width: 64, alignment: .leading)
            Text(label)
                .font(.jost(size: 12, weight: .light))
                .foregroundColor(active ? ChronosTheme.text : ChronosTheme.muted)
        }
    }
}

// ─────────────────────────────────────────
// CHRONOS PRIMARY BUTTON
// ─────────────────────────────────────────

struct ChronosPrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var fontSize: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(ChronosTheme.text)
                    .frame(height: 52)

                if isLoading {
                    ProgressView().tint(ChronosTheme.ink)
                } else {
                    Text(title)
                        .font(.jost(size: fontSize, weight: .medium))
                        .foregroundColor(ChronosTheme.ink)
                        .tracking(2)
                        .textCase(.uppercase)
                }
            }
        }
        .disabled(isLoading)
    }
}

// ─────────────────────────────────────────
// LEGACY — kept for FeedbackView + AdminView
// ─────────────────────────────────────────

struct MBIPrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        ChronosPrimaryButton(title: title, isLoading: isLoading, action: action)
    }
}
