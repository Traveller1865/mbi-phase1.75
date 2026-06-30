// ios/MBI/MBI/Views/OnboardingConsentView.swift
// MBI Beta Readiness — NA-010 / CC-024
//
// Affirmative beta consent gate. Inserted into the onboarding sequence
// immediately before the Profile step (Stage 4) — see OnboardingFlowView
// step 4. Account creation has already happened in AuthView by the time this
// renders, so this screen sits between account creation and profile setup.
//
// Blocks progression until the user explicitly agrees to the Beta Tester
// Agreement, Privacy Policy, and Terms of Service, then logs a
// `consent_accepted` event to app_events via AnalyticsService.
//
// Reuse: the agreement copy is rendered from PolicyContent.betaAgreement and
// the full Privacy Policy / Terms are opened via PolicyView — no policy text
// is duplicated in this file.

import SwiftUI

struct OnboardingConsentView: View {
    /// Called once the user has affirmatively consented (and the event logged).
    let onConsent: () -> Void

    @State private var agreed             = false
    @State private var showPrivacyPolicy  = false
    @State private var showTerms          = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 72)

                    // Seal icon — consistent with the disclosure screens
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundColor(ChronosTheme.gold)
                        .padding(.bottom, 28)

                    VStack(spacing: 8) {
                        Text("Before you begin.")
                            .font(.cormorant(size: 30, weight: .light))
                            .foregroundColor(ChronosTheme.text)
                            .lineSpacing(4)
                            .multilineTextAlignment(.center)

                        Text("Chronos is a pre-release beta. Please review and agree to the terms below before continuing.")
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.muted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 32)

                    // ── Beta Tester Agreement — embedded scrollable section ──
                    // Rendered from PolicyContent so the legal copy lives in one place.
                    VStack(alignment: .leading, spacing: 16) {
                        Text("BETA TESTER AGREEMENT")
                            .font(.jost(size: 11, weight: .medium))
                            .foregroundColor(ChronosTheme.gold)
                            .tracking(1.5)

                        ForEach(PolicyContent.betaAgreement) { section in
                            VStack(alignment: .leading, spacing: 5) {
                                if let heading = section.heading {
                                    Text(heading)
                                        .font(.jost(size: 12, weight: .medium))
                                        .foregroundColor(ChronosTheme.text)
                                }
                                Text(section.body)
                                    .font(.jost(size: 12, weight: .light))
                                    .foregroundColor(ChronosTheme.muted)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
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
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                    // ── Full-document links — reuse PolicyView ──
                    HStack(spacing: 20) {
                        Button(action: { showPrivacyPolicy = true }) {
                            policyLinkLabel("Privacy Policy")
                        }
                        Button(action: { showTerms = true }) {
                            policyLinkLabel("Terms of Service")
                        }
                    }
                    .padding(.bottom, 28)

                    // ── Affirmative consent toggle — default OFF ──
                    Button(action: { agreed.toggle() }) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: agreed ? "checkmark.square.fill" : "square")
                                .font(.system(size: 20, weight: .light))
                                .foregroundColor(agreed ? ChronosTheme.gold : ChronosTheme.faint)
                            Text("I have read and agree to the Beta Tester Agreement, Privacy Policy, and Terms of Service.")
                                .font(.jost(size: 12, weight: .light))
                                .foregroundColor(ChronosTheme.text)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }

            // Continue — disabled until the box is checked
            ChronosPrimaryButton(title: "Agree & Continue") {
                guard agreed else { return }
                AnalyticsService.shared.logConsentAccepted()
                onConsent()
            }
            .opacity(agreed ? 1 : 0.45)
            .disabled(!agreed)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .sheet(isPresented: $showPrivacyPolicy) { PolicyView(document: .privacyPolicy) }
        .sheet(isPresented: $showTerms)         { PolicyView(document: .termsOfService) }
    }

    private func policyLinkLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .ultraLight))
            Text(title)
                .font(.jost(size: 12, weight: .light))
        }
        .foregroundColor(ChronosTheme.gold.opacity(0.8))
    }
}
