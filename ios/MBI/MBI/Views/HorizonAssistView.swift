// ios/MBI/MBI/Views/HorizonAssistView.swift
// MBI Phase 2 — Sprint 9 · Horizon Assist
//
// Lets the user ask questions about their Horizon patterns.
// Architecture:
//   - Presented as a sheet from HorizonEscalateView.
//   - Passes current HorizonAssessment as context to every request.
//   - Calls SupabaseService.callHorizonAssist (Edge Function in Phase 3, stub in Phase 2).
//   - Legal disclaimer displayed above every response — mandatory.
//
// ⚠️  LEGAL GATE — DO NOT SHIP TO EXTERNAL USERS WITHOUT ATTORNEY REVIEW ⚠️
//   This feature presents AI-generated text about the user's biometric patterns.
//   The disclaimer block is required on every response screen per Legal Framework §4.1.
//   Never frame responses as diagnoses, treatment plans, or clinical assessments.

import SwiftUI

// ─────────────────────────────────────────
// HORIZON ASSIST VIEW
// ─────────────────────────────────────────

struct HorizonAssistView: View {
    let assessment: HorizonAssessment

    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = ""
    @State private var isLoading       = false
    @State private var response: HorizonAssistResponse? = nil
    @State private var errorMessage: String? = nil
    @FocusState private var isInputFocused: Bool

    private let amber   = Color(red: 1.0, green: 0.75, blue: 0.35)
    private let surface = Color(red: 0.09, green: 0.09, blue: 0.13)

    private var userId: String { supabase.session?.userId ?? "" }
    private var canSubmit: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty && !isLoading }

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [amber.opacity(0.03), .clear],
                center: .topLeading, startRadius: 0, endRadius: 300
            ).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // ── Header ──────────────────────────────────────────
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HORIZON ASSIST")
                                .font(.jost(size: 9, weight: .medium))
                                .foregroundColor(amber.opacity(0.70))
                                .tracking(2.5)
                            Text("Ask about your patterns.")
                                .font(.cormorant(size: 26, weight: .light))
                                .foregroundColor(ChronosTheme.text)
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(ChronosTheme.surface))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 20)

                    // ── Mandatory Legal Disclaimer ───────────────────────
                    AssistDisclaimerBanner()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)

                    // ── Active Signal Context ────────────────────────────
                    AssistContextChips(assessment: assessment)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)

                    // ── Example Questions ────────────────────────────────
                    if response == nil && !isLoading {
                        AssistExampleQuestions { selected in
                            question = selected
                            isInputFocused = false
                            Task { await submit() }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }

                    // ── Response Area ────────────────────────────────────
                    if let res = response {
                        AssistResponseCard(response: res)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(Color(red: 0.85, green: 0.45, blue: 0.45))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }

                    if isLoading {
                        AssistLoadingCard()
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    }

                    // ── Input Field ──────────────────────────────────────
                    AssistInputField(
                        question: $question,
                        isFocused: $isInputFocused,
                        canSubmit: canSubmit,
                        isLoading: isLoading
                    ) {
                        Task { await submit() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 48)
                }
            }
        }
        .onTapGesture { isInputFocused = false }
    }

    // ── Submit ────────────────────────────────────────────────────────────

    private func submit() async {
        guard canSubmit else { return }
        let trimmed = question.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isLoading    = true
        errorMessage = nil
        response     = nil

        do {
            let result = try await supabase.callHorizonAssist(
                userId: userId,
                question: trimmed,
                assessment: assessment
            )
            response = result
        } catch {
            errorMessage = "Unable to reach Horizon Assist. Please try again."
        }
        isLoading = false
    }
}

// ─────────────────────────────────────────
// DISCLAIMER BANNER
// Required above every response — Legal Framework §4.1.
// ─────────────────────────────────────────

private struct AssistDisclaimerBanner: View {
    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .light))
                .foregroundColor(amber.opacity(0.65))
                .padding(.top, 2)
            Text("Horizon Assist summarises your wellness tracking patterns. It is not a diagnosis, clinical assessment, or medical recommendation. Discuss any health concerns with a licensed healthcare professional.")
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(ChronosTheme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(amber.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(amber.opacity(0.20), lineWidth: 1))
        )
    }
}

// ─────────────────────────────────────────
// CONTEXT CHIPS — active Horizon pathways
// ─────────────────────────────────────────

private struct AssistContextChips: View {
    let assessment: HorizonAssessment

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)
    private let green = Color(red: 0.40, green: 0.82, blue: 0.50)

    private var signals: [(String, String, Bool)] {
        [
            ("Autonomic", "A1", assessment.autonomic?.isActive ?? false),
            ("Sleep",     "A2", assessment.sleep?.isActive     ?? false),
            ("Metabolic", "A3", assessment.metabolic?.isActive ?? false),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HORIZON CONTEXT")
                .font(.jost(size: 9, weight: .medium))
                .foregroundColor(ChronosTheme.faint)
                .tracking(2)

            HStack(spacing: 8) {
                ForEach(signals, id: \.0) { name, _, isActive in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isActive ? amber : green)
                            .frame(width: 5, height: 5)
                        Text(name)
                            .font(.jost(size: 11, weight: isActive ? .medium : .light))
                            .foregroundColor(isActive ? amber.opacity(0.85) : ChronosTheme.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isActive ? amber.opacity(0.08) : Color.white.opacity(0.04))
                            .overlay(Capsule().stroke(isActive ? amber.opacity(0.25) : Color.white.opacity(0.08), lineWidth: 1))
                    )
                }
                Spacer()
            }
        }
    }
}

// ─────────────────────────────────────────
// EXAMPLE QUESTIONS
// ─────────────────────────────────────────

private struct AssistExampleQuestions: View {
    let onSelect: (String) -> Void

    private let questions = [
        "What is my autonomic pathway tracking?",
        "Why has my sleep pattern been flagged?",
        "What contributes to my Chronos score?",
        "What does 'days in pattern' mean?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXAMPLE QUESTIONS")
                .font(.jost(size: 9, weight: .medium))
                .foregroundColor(ChronosTheme.faint)
                .tracking(2)

            VStack(spacing: 6) {
                ForEach(questions, id: \.self) { q in
                    Button { onSelect(q) } label: {
                        HStack {
                            Text(q)
                                .font(.jost(size: 12, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(ChronosTheme.surface)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(ChronosTheme.border, lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// RESPONSE CARD
// Legal disclaimer header required per §4.1.
// ─────────────────────────────────────────

private struct AssistResponseCard: View {
    let response: HorizonAssistResponse

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Response header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(amber.opacity(0.55))
                Text("HORIZON ASSIST")
                    .font(.jost(size: 9, weight: .medium))
                    .foregroundColor(amber.opacity(0.55))
                    .tracking(1.5)
                if response.isStub {
                    Text("PREVIEW")
                        .font(.jost(size: 7, weight: .medium))
                        .foregroundColor(ChronosTheme.faint)
                        .tracking(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                Spacer()
            }

            Rectangle()
                .fill(amber.opacity(0.10))
                .frame(height: 1)

            // Response text
            Text(response.answer)
                .font(.jost(size: 13, weight: .light))
                .foregroundColor(Color(red: 0.965, green: 0.953, blue: 0.920).opacity(0.85))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            // Mandatory per-response disclaimer
            Text("Not a medical assessment. For wellness pattern context only.")
                .font(.jost(size: 10, weight: .light))
                .foregroundColor(ChronosTheme.faint.opacity(0.60))
                .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.11, green: 0.10, blue: 0.08))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(amber.opacity(0.25), lineWidth: 1.5))
        )
    }
}

// ─────────────────────────────────────────
// LOADING CARD
// ─────────────────────────────────────────

private struct AssistLoadingCard: View {
    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .scaleEffect(0.75)
                .tint(amber.opacity(0.60))
            Text("Horizon is reading your patterns…")
                .font(.jost(size: 12, weight: .light))
                .foregroundColor(ChronosTheme.muted)
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChronosTheme.border, lineWidth: 1))
        )
    }
}

// ─────────────────────────────────────────
// INPUT FIELD
// ─────────────────────────────────────────

private struct AssistInputField: View {
    @Binding var question: String
    var isFocused: FocusState<Bool>.Binding
    let canSubmit: Bool
    let isLoading: Bool
    let onSubmit: () -> Void

    private let amber = Color(red: 1.0, green: 0.75, blue: 0.35)

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if question.isEmpty {
                    Text("Ask about your patterns…")
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.faint.opacity(0.50))
                        .padding(.top, 10)
                        .padding(.leading, 4)
                }
                TextEditor(text: $question)
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 42, maxHeight: 120)
                    .focused(isFocused)
            }

            Button(action: onSubmit) {
                Image(systemName: isLoading ? "ellipsis" : "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(canSubmit ? amber : ChronosTheme.faint.opacity(0.35))
                    .animation(.easeInOut(duration: 0.15), value: canSubmit)
            }
            .disabled(!canSubmit)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isFocused.wrappedValue ? amber.opacity(0.35) : ChronosTheme.border, lineWidth: 1)
                )
        )
    }
}
