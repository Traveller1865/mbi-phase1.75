// ios/MBI/Views/FeedbackView.swift
// MBI Phase 1.5 — Feedback Sheet: Step 7 of 10 · Corrections Pass 1
// Three-dimension flag system. Corrections:
//   - Updated pill labels and DB values across all dimensions
//   - Nudge relevance wraps to two rows for 4-option layout
//   - Keyboard dismissal: tap outside, Done toolbar button, drag-to-dismiss
//   - Privacy footnote below submit
//   - Confirmation: checkmark icon, "Thank you." headline, supporting copy

import SwiftUI

struct FeedbackView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) var dismiss

    let score: DailyScore
    let nudgeEventId: String?

    @State private var scoreAccuracy: String?  = nil  // "accurate" | "somewhat" | "off"
    @State private var briefQuality: String?   = nil  // "aligned" | "somewhat" | "missed"
    @State private var nudgeRelevance: String? = nil  // "helpful" | "somewhat" | "not_relevant" | "not_applicable"
    @State private var note                    = ""
    @State private var isSubmitting            = false
    @State private var submitted               = false
    @State private var error: String?

    @FocusState private var noteFocused: Bool

    private let maxNoteLength = 350

    private var hasAnySelection: Bool {
        scoreAccuracy != nil || briefQuality != nil || nudgeRelevance != nil
    }

    var body: some View {
        ZStack {
            ChronosTheme.surface.ignoresSafeArea()

            if submitted {
                confirmationView
            } else {
                formView
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        // Drag-to-dismiss is enabled by default — interactiveDismissDisabled is not set
    }

    // ─────────────────────────────────────────
    // CONFIRMATION
    // Checkmark icon, "Thank you." headline, supporting copy.
    // Auto-dismisses after 3 seconds. X button dismisses immediately.
    // Both paths close the full sheet (dismiss() on EnvironmentObject).
    // ─────────────────────────────────────────

    private var confirmationView: some View {
        ZStack(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.muted)
                    .padding(10)
                    .background(Circle().fill(ChronosTheme.ink))
            }
            .padding(.top, 20)
            .padding(.trailing, 20)

            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(ChronosTheme.gold)
                    .padding(.bottom, 16)
                Text("Thank you.")
                    .font(.cormorant(size: 28, weight: .light))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text("Your feedback helps Chronos learn how your signals feel in real life.")
                    .font(.jost(size: 14, weight: .light))
                    .foregroundColor(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                    .padding(.top, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dismiss() }
        }
    }

    // ─────────────────────────────────────────
    // FORM
    // ─────────────────────────────────────────

    private var formView: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(ChronosTheme.border)
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Header — unchanged per spec
                    Text("Did this feel right?")
                        .font(.cormorant(size: 28, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .padding(.top, 28)

                    Text("Your Chronos score was \(Int(score.chronosScore)) — \(score.scoreBand.rawValue)")
                        .font(.jost(size: 15, weight: .light))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.top, 6)
                        .padding(.bottom, 32)

                    // DIMENSION 1 — SCORE ACCURACY
                    FeedbackDimension(
                        label: "SCORE ACCURACY",
                        question: "Did your Chronos score feel accurate today?",
                        options: ["Accurate", "Somewhat", "Off"],
                        values: ["accurate", "somewhat", "off"],
                        selection: $scoreAccuracy
                    )

                    sectionDivider.padding(.vertical, 24)

                    // DIMENSION 2 — BRIEF QUALITY
                    FeedbackDimension(
                        label: "BRIEF QUALITY",
                        question: "Did the brief reflect how you felt?",
                        options: ["Aligned", "Somewhat", "Missed"],
                        values: ["aligned", "somewhat", "missed"],
                        selection: $briefQuality
                    )

                    sectionDivider.padding(.vertical, 24)

                    // DIMENSION 3 — NUDGE RELEVANCE (4 options — wraps to two rows)
                    FeedbackDimension(
                        label: "NUDGE RELEVANCE",
                        question: "Was today's focus relevant and actionable?",
                        options: ["Helpful", "Somewhat", "Not relevant", "Not applicable"],
                        values: ["helpful", "somewhat", "not_relevant", "not_applicable"],
                        selection: $nudgeRelevance
                    )

                    sectionDivider.padding(.vertical, 24)

                    // NOTE FIELD
                    noteField

                    if let error {
                        Text(error)
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            // Method 1 — keyboard dismissal: tap outside text field
            // simultaneousGesture preserves pill and button taps
            .simultaneousGesture(TapGesture().onEnded { noteFocused = false })

            // SUBMIT BUTTON + PRIVACY FOOTNOTE
            VStack(spacing: 8) {
                submitButton

                Text("Your feedback is private and used to improve Chronos.")
                    .font(.jost(size: 12, weight: .light))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
        }
    }

    // ─────────────────────────────────────────
    // NOTE FIELD
    // ─────────────────────────────────────────

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD A NOTE (OPTIONAL)")
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(.white.opacity(0.50))
                .tracking(1.5)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(ChronosTheme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(ChronosTheme.border, lineWidth: 1))

                if note.isEmpty {
                    Text("Anything else worth noting?")
                        .foregroundColor(ChronosTheme.muted.opacity(0.6))
                        .font(.jost(size: 14, weight: .light))
                        .padding(14)
                }

                TextEditor(text: $note)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .foregroundColor(ChronosTheme.text)
                    .font(.jost(size: 14, weight: .light))
                    .frame(minHeight: 80)
                    .padding(10)
                    .focused($noteFocused)
                    // Method 2 — keyboard dismissal: Done toolbar button
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { noteFocused = false }
                                .font(.jost(size: 14, weight: .medium))
                                .foregroundColor(ChronosTheme.gold)
                        }
                    }
                    .onChange(of: note) {
                        if note.count > maxNoteLength {
                            note = String(note.prefix(maxNoteLength))
                        }
                    }
            }
            .frame(minHeight: 80)

            HStack {
                Spacer()
                Text("\(note.count)/\(maxNoteLength)")
                    .font(.jost(size: 11, weight: .light))
                    .foregroundColor(.white.opacity(0.40))
            }
        }
    }

    // ─────────────────────────────────────────
    // SUBMIT BUTTON
    // Inactive (dark, muted) → active (gold, bold) on 0.2s fade.
    // ─────────────────────────────────────────

    private var submitButton: some View {
        Button {
            guard hasAnySelection, !isSubmitting else { return }
            noteFocused = false
            isSubmitting = true
            Task {
                do {
                    guard let userId = supabase.session?.userId else { return }
                    try await supabase.submitDimensionedFeedback(
                        scoreId:        score.id,
                        userId:         userId,
                        date:           score.date,
                        scoreAccuracy:  scoreAccuracy,
                        briefQuality:   briefQuality,
                        nudgeRelevance: nudgeRelevance,
                        noteText:       note.isEmpty ? nil : note
                    )
                    submitted = true
                } catch {
                    self.error = error.localizedDescription
                }
                isSubmitting = false
            }
        } label: {
            ZStack {
                if isSubmitting {
                    ProgressView()
                        .tint(hasAnySelection
                              ? Color(red: 0.10, green: 0.10, blue: 0.08)
                              : .white.opacity(0.4))
                } else {
                    Text("SUBMIT FEEDBACK")
                        .font(.jost(size: 13, weight: hasAnySelection ? .bold : .light))
                        .foregroundColor(
                            hasAnySelection
                                ? Color(red: 0.10, green: 0.10, blue: 0.08)
                                : .white.opacity(0.40)
                        )
                        .tracking(1.5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(hasAnySelection
                          ? ChronosTheme.gold
                          : Color(red: 0.165, green: 0.165, blue: 0.165))
            )
            .animation(.easeInOut(duration: 0.2), value: hasAnySelection)
        }
        .disabled(!hasAnySelection || isSubmitting)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(height: 1)
    }
}

// ─────────────────────────────────────────
// FEEDBACK DIMENSION
// ≤ 3 options: single scrollable row.
// 4 options: wraps into two rows of 2 — pills are never compressed.
// ─────────────────────────────────────────

struct FeedbackDimension: View {
    let label: String
    let question: String
    let options: [String]
    let values: [String]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.jost(size: 11, weight: .light))
                .foregroundColor(ChronosTheme.gold)
                .tracking(1.8)

            Text(question)
                .font(.jost(size: 15, weight: .light))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            if options.count <= 3 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        pillRow(from: 0, to: options.count)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                // Wrap into rows of 2
                let rowCount = Int(ceil(Double(options.count) / 2.0))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HStack(spacing: 8) {
                            pillRow(from: row * 2, to: min(row * 2 + 2, options.count))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pillRow(from start: Int, to end: Int) -> some View {
        ForEach(start..<end, id: \.self) { i in
            FeedbackPill(
                label: options[i],
                isSelected: selection == values[i]
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selection = selection == values[i] ? nil : values[i]
                }
            }
        }
    }
}

// ─────────────────────────────────────────
// FEEDBACK PILL
// Default: clear fill, white border 30%, white text Jost Light.
// Selected: Chronos Gold fill, dark text Jost Bold.
// ─────────────────────────────────────────

struct FeedbackPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.jost(size: 14, weight: isSelected ? .bold : .light))
                .foregroundColor(
                    isSelected ? Color(red: 0.10, green: 0.10, blue: 0.08) : .white
                )
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .background(
                    Capsule()
                        .fill(isSelected ? ChronosTheme.gold : Color.clear)
                        .overlay(Capsule().stroke(.white.opacity(0.30), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }
}
