// ios/MBI/MBI/Views/PolicyView.swift
// In-app policy viewer — renders Privacy Policy, Terms of Service,
// Beta Tester Agreement, and Health Data Processing Notice natively.
// No external URL required during beta.
//
// Usage:
//   .sheet(isPresented: $showPrivacy) { PolicyView(document: .privacyPolicy) }

import SwiftUI

// ─────────────────────────────────────────
// MARK: - Document Model
// ─────────────────────────────────────────

struct PolicySection: Identifiable {
    let id   = UUID()
    let heading: String?   // nil = body-only (no header rendered)
    let body:    String
}

enum PolicyDocument {
    case privacyPolicy
    case termsOfService
    case betaAgreement
    case healthDataNotice

    var title: String {
        switch self {
        case .privacyPolicy:    return "Privacy Policy"
        case .termsOfService:   return "Terms of Service"
        case .betaAgreement:    return "Beta Tester Agreement"
        case .healthDataNotice: return "Health Data Notice"
        }
    }

    var version: String { "Version 1.0  ·  Effective May 11, 2026" }

    var sections: [PolicySection] { PolicyContent.sections(for: self) }
}

// ─────────────────────────────────────────
// MARK: - Policy View
// ─────────────────────────────────────────

struct PolicyView: View {
    let document: PolicyDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ChronosTheme.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header bar ──
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.title)
                            .font(.jost(size: 15, weight: .medium))
                            .foregroundColor(ChronosTheme.text)
                        Text(document.version)
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(ChronosTheme.border)
                    .frame(height: 1)

                // ── Scrollable content ──
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(document.sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                if let heading = section.heading {
                                    Text(heading)
                                        .font(.jost(size: 12, weight: .medium))
                                        .foregroundColor(ChronosTheme.gold)
                                        .padding(.top, 4)
                                }
                                Text(section.body)
                                    .font(.jost(size: 12, weight: .light))
                                    .foregroundColor(ChronosTheme.muted)
                                    .lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        // Footer
                        Rectangle()
                            .fill(ChronosTheme.border)
                            .frame(height: 1)
                            .padding(.top, 8)

                        Text("Mynd & Bodi Institute · MyndBodiInstitute@gmail.com")
                            .font(.jost(size: 10, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                            .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// MARK: - Policy Content
// ─────────────────────────────────────────

enum PolicyContent {

    static func sections(for document: PolicyDocument) -> [PolicySection] {
        switch document {
        case .privacyPolicy:    return privacyPolicy
        case .termsOfService:   return termsOfService
        case .betaAgreement:    return betaAgreement
        case .healthDataNotice: return healthDataNotice
        }
    }

    // ── Privacy Policy ──────────────────────────────────────────────────────

    static let privacyPolicy: [PolicySection] = [
        .init(heading: nil, body: "Chronos by Mynd & Bodi Institute respects your privacy. This policy explains what information we collect, how we use it, and the rights you have regarding your data. Our philosophy: your health data belongs to you."),
        .init(heading: "What We Collect", body: "Health & Wellness Data (read-only from Apple Health): Heart Rate Variability (HRV), Resting Heart Rate, Respiratory Rate, Sleep Duration and Quality, Step Count, Active Energy Burned, and Exercise Minutes. We never write data back to Apple Health.\n\nUser-Provided Information: name, email, date of birth, height, mood inputs, wellness goals, and feedback submissions.\n\nUsage & Device Data: app opens, session duration, feature interactions, device type, OS version, app version, error logs. We do not collect GPS location."),
        .init(heading: "How We Use Your Data", body: "We use your data to calculate your daily Chronos Resilience Score, generate personalized wellness insights, deliver adaptive recommendations, improve platform reliability, and provide support.\n\nWe do NOT use your health data to serve advertising, build advertising profiles, sell to data brokers, or make automated decisions about your insurance, employment, or creditworthiness."),
        .init(heading: "The Horizon Monitoring Feature", body: "If your Chronos Resilience Score falls below a wellness threshold for three or more consecutive days, a member of the MBI team may personally reach out to check in. This is a human wellness check — not automated clinical triage or diagnosis.\n\nYou can disable Horizon check-ins at any time: Account → Privacy → Horizon Check-ins.\n\nWhen Horizon triggers, only your anonymized user identifier, score values, and date pattern may be visible to MBI. No raw health data is transmitted."),
        .init(heading: "AI & Automated Processing", body: "Chronos uses machine learning models and AI-generated narrative explanations to interpret wellness trends and personalize your experience. These systems support wellness awareness only. Chronos does not provide medical diagnoses, treatment plans, or emergency monitoring. Always consult a qualified healthcare professional for medical concerns."),
        .init(heading: "HealthKit Commitments", body: "HealthKit data is never sold, never used for advertising, never shared with data brokers, and never used to build commercial profiles unrelated to your wellness experience. We comply with Apple's HealthKit developer policies in full."),
        .init(heading: "Data Storage", body: "Data is stored using Supabase-managed cloud infrastructure, hosted primarily in the United States. Data is encrypted at rest and in transit, protected by row-level security controls."),
        .init(heading: "Who Has Access", body: "Access to your data is limited to you, authorized MBI operational personnel for support and security purposes, and Supabase as a data processor. We do not sell personal data or share identifiable health data with employers or insurers without your explicit authorization."),
        .init(heading: "Data Retention & Deletion", body: "We retain your data while your account is active. If you request deletion, identifiable personal and wellness data will be deleted or anonymized within approximately 30 days, except where retention is legally required.\n\nTo delete your account: Account → Delete Account, or contact MyndBodiInstitute@gmail.com."),
        .init(heading: "Your Rights", body: "You may access, correct, request deletion of, or export your personal data. You may revoke Apple Health permissions at any time via Apple Health → Sharing → Apps → Chronos. You may disable Horizon check-ins via Account → Privacy."),
        .init(heading: "Security", body: "We implement encrypted network communication (TLS), authenticated database access, row-level security controls, and restricted administrative access. No platform can guarantee absolute security."),
        .init(heading: "FTC Compliance", body: "Although Chronos is a direct-to-consumer wellness app and is not subject to HIPAA as a covered entity, the FTC Act and FTC Health Breach Notification Rule may apply. We are committed to honoring our privacy representations and will notify affected users of any unauthorized disclosure of health information as required by applicable law."),
        .init(heading: "Children's Privacy", body: "Chronos is not intended for individuals under 18. We do not knowingly collect personal information from minors."),
        .init(heading: "Changes", body: "We may update this policy periodically. Material changes will be communicated through the app. Continued use after updates constitutes acceptance."),
    ]

    // ── Terms of Service ────────────────────────────────────────────────────

    static let termsOfService: [PolicySection] = [
        .init(heading: nil, body: "By accessing or using Chronos, you agree to these Terms of Service. If you do not agree, do not use the Services."),
        .init(heading: "Eligibility", body: "You must be at least 18 years old to use Chronos. By using the Services, you represent that you meet this requirement and that all information you provide is accurate."),
        .init(heading: "Description of Services", body: "Chronos is a preventative wellness and health intelligence platform. It interprets wearable and behavioral wellness data, provides educational insights, supports habit formation, and helps you understand long-term wellness trends. Features may evolve over time."),
        .init(heading: "Not a Medical Device", body: "Chronos is NOT a medical device. It has not been evaluated, cleared, or approved by the FDA. The Services are intended solely for general wellness, educational, behavioral, and informational purposes.\n\nChronos does not diagnose diseases, prescribe treatment, monitor medical emergencies, provide clinical decision support, or replace licensed healthcare professionals."),
        .init(heading: "Not Medical Advice", body: "Scores, insights, AI-generated summaries, behavioral observations, wellness trends, and notifications do not constitute medical advice. They are not a substitute for professional medical advice, diagnosis, treatment, or mental health care.\n\nAlways consult a qualified healthcare professional regarding medical concerns.\n\nIf you believe you are experiencing a medical emergency, contact your local emergency services immediately. Do not use Chronos as an emergency monitoring tool."),
        .init(heading: "The Horizon Monitoring Feature", body: "If your Chronos Resilience Score remains below a wellness threshold for three or more consecutive days, a member of the MBI team may personally reach out. This is a human wellness check-in — not an automated clinical service, diagnosis, or treatment recommendation.\n\nYou may disable this feature at any time: Account → Privacy → Horizon Check-ins."),
        .init(heading: "AI-Generated Content", body: "Chronos may use AI and automated analysis to generate wellness summaries, trend observations, and behavioral suggestions. These outputs are probabilistic, informational, and experimental. They may be incomplete or contain inaccuracies. You use such outputs at your own discretion and risk."),
        .init(heading: "Acceptable Use", body: "You agree not to misuse the Services, attempt unauthorized access, interfere with platform operations, reverse engineer the software, upload malicious code, impersonate another person, use Chronos for clinical decision-making, or use Chronos in emergency medical situations."),
        .init(heading: "Wellness Tracking Summaries", body: "Any data export or summary produced by Chronos is a consumer-generated wellness tracking summary. It is not a medical record, not validated clinical testing, and not intended as a clinical document. A licensed healthcare professional should independently evaluate any summary using their own clinical judgment."),
        .init(heading: "Disclaimer of Warranties", body: "THE SERVICES ARE PROVIDED \"AS IS\" AND \"AS AVAILABLE.\" TO THE MAXIMUM EXTENT PERMITTED BY LAW, MBI DISCLAIMS ALL WARRANTIES, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND ACCURACY. WE DO NOT GUARANTEE UNINTERRUPTED SERVICE OR ERROR-FREE OPERATION."),
        .init(heading: "Limitation of Liability", body: "TO THE MAXIMUM EXTENT PERMITTED BY LAW, MBI SHALL NOT BE LIABLE FOR INDIRECT, INCIDENTAL, SPECIAL, OR CONSEQUENTIAL DAMAGES, INCLUDING LOSS OF DATA, PERSONAL INJURY, OR HEALTH-RELATED OUTCOMES ARISING FROM USE OF THE SERVICES OR RELIANCE ON AI-GENERATED OUTPUTS. YOUR USE IS AT YOUR OWN RISK."),
        .init(heading: "Governing Law", body: "These Terms are governed by the laws of the State of Louisiana. Disputes shall be resolved in appropriate courts located within Louisiana, unless otherwise required by applicable law. Before filing any formal legal claim, contact MyndBodiInstitute@gmail.com for informal resolution."),
        .init(heading: "Changes", body: "We may update these Terms periodically. Continued use of Chronos after updates constitutes acceptance of the revised Terms."),
    ]

    // ── Beta Tester Agreement ────────────────────────────────────────────────

    static let betaAgreement: [PolicySection] = [
        .init(heading: nil, body: "Thank you for participating in the Chronos beta program. By installing or using this TestFlight build, you agree to the terms below."),
        .init(heading: "Purpose", body: "The Beta Program exists to evaluate platform functionality, identify bugs and usability issues, test wellness insights, and gather feedback before broader public release. This software is pre-release and may not perform as intended."),
        .init(heading: "Confidentiality", body: "All non-public aspects of the Beta Program are confidential, including app interfaces, features, workflows, scoring methodology, AI outputs, screenshots, screen recordings, build version numbers, TestFlight identifiers, and unreleased features.\n\nWithout prior written permission from MBI, do not publicly share screenshots, post or livestream the app, distribute builds, or discuss confidential product details publicly.\n\nThis obligation remains until MBI publicly releases the relevant information."),
        .init(heading: "Beta Software Acknowledgment", body: "The software is experimental. Features may change or disappear. Data may be modified or reset. Services may become unavailable. Builds are provided \"as is\" without guarantees of reliability, uptime, or accuracy.\n\nDo not rely on the Beta Program for medical decisions, emergency monitoring, healthcare treatment, or any critical personal needs."),
        .init(heading: "Health & Wellness Disclaimer", body: "Chronos is a wellness platform for informational and behavioral wellness purposes only. It is not a medical device, not a diagnostic tool, and not a substitute for professional medical advice. AI-generated insights may be inaccurate. Always consult a qualified healthcare professional regarding medical concerns.\n\nIf you are experiencing a medical emergency, contact emergency services immediately."),
        .init(heading: "The Horizon Feature", body: "During this beta, if your Chronos Resilience Score remains below a defined wellness threshold for three or more consecutive days, an MBI team member may personally reach out. This is a voluntary human wellness check-in, not a clinical service. You may disable it: Account → Privacy → Horizon Check-ins."),
        .init(heading: "Feedback", body: "By submitting feedback, bug reports, or suggestions, you agree that MBI may use, modify, incorporate, commercialize, and distribute such Feedback without restriction. All Feedback becomes the sole property of MBI. No compensation, royalties, or ownership rights are owed in connection with Feedback."),
        .init(heading: "No Compensation", body: "Participation is voluntary and unpaid. Unless explicitly agreed in a separate signed written agreement, you will not receive financial compensation, equity, royalties, or any product entitlements in exchange for participation or Feedback."),
        .init(heading: "Data Rights", body: "Your data is handled per the Chronos Privacy Policy. You may request account deletion at any time. Identifiable data will be deleted or anonymized within approximately 30 days of a verified deletion request. MBI may retain de-identified, aggregated analytics from beta usage."),
        .init(heading: "Account Removal", body: "MBI reserves the right to suspend or terminate beta access at any time for misuse, violation of this Agreement, confidentiality breaches, or security concerns. MBI may also discontinue the Beta Program entirely without notice."),
        .init(heading: "Intellectual Property", body: "All Chronos software, branding, systems, and methodologies remain the exclusive property of Mynd & Bodi Institute. Participation grants no ownership rights, licenses, or commercialization rights."),
        .init(heading: "Limitation of Liability", body: "TO THE MAXIMUM EXTENT PERMITTED BY LAW, MBI SHALL NOT BE LIABLE FOR DATA LOSS, SERVICE INTERRUPTIONS, SOFTWARE BUGS, OR ANY INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES RELATED TO THE BETA PROGRAM. YOUR USE IS AT YOUR OWN RISK."),
        .init(heading: "Governing Law", body: "This Agreement is governed by the laws of the State of Louisiana. Disputes shall be resolved in appropriate courts within Louisiana unless otherwise required by applicable law."),
    ]

    // ── Health Data Processing Notice ───────────────────────────────────────

    static let healthDataNotice: [PolicySection] = [
        .init(heading: "Your Health Data, Explained Clearly", body: "Chronos uses Apple Health and wearable data to help you better understand your personal recovery, stress, sleep, and wellness patterns over time. We only read the health categories you explicitly allow through Apple Health permissions. We never write data back to Apple Health."),
        .init(heading: "What We Read", body: "Depending on your device and permissions, Chronos may access:\n\n• Heart Rate Variability (HRV) — autonomic nervous system recovery\n• Resting Heart Rate — cardiovascular baseline trends\n• Respiratory Rate — breathing patterns during rest\n• Sleep Duration and Quality — recovery cycles\n• Step Count and Activity — daily movement patterns\n• Active Energy Burned — exertion over time\n• Exercise Minutes — structured activity\n\nChronos compares you only to your own historical baseline — not to other users."),
        .init(heading: "How Your Data Is Used", body: "Your health data is used exclusively to calculate your daily Chronos Resilience Score, generate personalized wellness insights, and deliver adaptive recommendations based on your patterns.\n\nYour health data is NEVER sold, used for advertising, shared with data brokers, shared with employers or insurers without your explicit permission, or used to build commercial profiles unrelated to your wellness experience."),
        .init(heading: "Where Your Data Goes", body: "Your data may be processed locally on your device and securely in your private Chronos account via Supabase cloud infrastructure hosted in the United States. Data is encrypted at rest and in transit. Access is limited to you, secure system infrastructure, and authorized MBI operational personnel when necessary for platform support."),
        .init(heading: "The Horizon Monitoring Feature", body: "Chronos includes a feature called Horizon. If your Chronos Resilience Score falls below a defined wellness threshold for three or more consecutive days, a member of the MBI team may personally reach out to check in.\n\nThis is a human wellness check-in — not automated clinical monitoring. It is based solely on the duration and pattern of your score trend, not a clinical assessment. Any outreach is supportive in nature and carries no clinical authority.\n\nYou can turn this off at any time: Account → Privacy → Horizon Check-ins."),
        .init(heading: "Your Control", body: "You can:\n• Revoke Apple Health permissions at any time\n  (Apple Health → Sharing → Apps → Chronos)\n• Disable Horizon check-ins via Account → Privacy\n• Request account deletion via Account → Delete Account\n• Stop using Chronos whenever you choose\n\nDeleted accounts and identifiable health data are scheduled for removal within approximately 30 days of a verified request."),
        .init(heading: "Important Reminder", body: "Chronos is a wellness and health intelligence platform. It is not a medical device, not a diagnostic tool, and not a substitute for professional medical advice. If you have medical concerns, consult a qualified healthcare professional. If you are experiencing a medical emergency, contact your local emergency services immediately."),
    ]
}
