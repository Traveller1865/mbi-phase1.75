// ios/MBI/MBI/Views/NotificationPreferencesView.swift
// MBI Phase 2 — Sprint 4: Notification Preferences
//
// Inline preferences card used inside AccountPreferencesTab.
// Replaces the single Morning Brief toggle with a per-type control surface.
//
// Notification types:
//   Morning Brief   — daily local at user-set time (default 7:00 AM)
//   Horizon Alert   — triggered when elevated pattern detected
//   Streak Reminder — daily 6:00 PM opt-in nudge
//
// AppStorage keys (shared with NotificationService):
//   notif_morning_brief_enabled    Bool  default true
//   notif_horizon_alert_enabled    Bool  default true
//   notif_streak_reminder_enabled  Bool  default false
//   notif_brief_delivery_hour      Int   default 7
//   notif_brief_delivery_minute    Int   default 0
//
// Permission card: shown automatically when notifications are blocked.
// Tapping "Open Settings" routes to iOS Settings for this app.

import SwiftUI
import UIKit

// MARK: - NotificationPreferencesView

struct NotificationPreferencesView: View {

    // ── AppStorage — source of truth for all notification prefs ──
    @AppStorage("notif_morning_brief_enabled")   private var morningBriefEnabled:   Bool = true
    @AppStorage("notif_horizon_alert_enabled")   private var horizonAlertEnabled:   Bool = true
    @AppStorage("notif_streak_reminder_enabled") private var streakReminderEnabled: Bool = false
    @AppStorage("notif_brief_delivery_hour")     private var briefHour:             Int  = 7
    @AppStorage("notif_brief_delivery_minute")   private var briefMinute:           Int  = 0

    @State private var showTimePicker   = false
    @State private var briefTime: Date  = Self.makeTime(hour: 7, minute: 0)
    @State private var showPermCard     = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Permission card (visible when notifications are blocked) ──
            if showPermCard {
                NotifPermissionCard()
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            }

            // ── Morning Brief ──
            morningBriefRow

            divider

            // ── Horizon Alert ──
            horizonAlertRow

            divider

            // ── Streak Reminder ──
            streakReminderRow
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ChronosTheme.border, lineWidth: 1))
        )
        .onAppear {
            briefTime = Self.makeTime(hour: briefHour, minute: briefMinute)
            Task { await syncPermissionState() }
        }
    }

    // MARK: - Morning Brief Row

    @ViewBuilder
    private var morningBriefRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "bell")
                    .font(.system(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.gold).frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning Brief")
                        .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                    Text("Daily score delivery")
                        .font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint)
                }

                Spacer()

                Toggle("", isOn: $morningBriefEnabled)
                    .tint(ChronosTheme.gold).labelsHidden()
                    .onChange(of: morningBriefEnabled) { _, enabled in
                        applyMorningBrief(enabled: enabled)
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            // ── Delivery Time sub-row ──
            if morningBriefEnabled {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(ChronosTheme.border.opacity(0.5)).frame(height: 1)

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { showTimePicker.toggle() }
                    }) {
                        HStack(spacing: 14) {
                            Image(systemName: "clock")
                                .font(.system(size: 12, weight: .light))
                                .foregroundColor(ChronosTheme.faint).frame(width: 20)
                            Text("Delivery Time")
                                .font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.muted)
                            Spacer()
                            Text(displayTime)
                                .font(.jost(size: 12, weight: .light)).foregroundColor(ChronosTheme.goldLight)
                            Image(systemName: showTimePicker ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .light)).foregroundColor(ChronosTheme.faint)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    if showTimePicker {
                        DatePicker("", selection: $briefTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel).labelsHidden()
                            .colorScheme(.dark).tint(ChronosTheme.gold)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 8)
                            .onChange(of: briefTime) { _, time in
                                let cal     = Calendar.current
                                briefHour   = cal.component(.hour,   from: time)
                                briefMinute = cal.component(.minute, from: time)
                                applyMorningBrief(enabled: true)
                            }
                        }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Horizon Alert Row

    private var horizonAlertRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.gold).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Horizon Alert")
                    .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                Text("Elevated pattern detected")
                    .font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint)
            }

            Spacer()

            Toggle("", isOn: $horizonAlertEnabled)
                .tint(ChronosTheme.gold).labelsHidden()
            // AppStorage write is automatic — no active scheduling needed.
            // HorizonModuleView reads this key before calling scheduleHorizonAlert.
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // MARK: - Streak Reminder Row

    private var streakReminderRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame")
                .font(.system(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.gold).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Streak Reminder")
                    .font(.jost(size: 13, weight: .light)).foregroundColor(ChronosTheme.text)
                Text("6:00 PM check-in nudge")
                    .font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint)
            }

            Spacer()

            Toggle("", isOn: $streakReminderEnabled)
                .tint(ChronosTheme.gold).labelsHidden()
                .onChange(of: streakReminderEnabled) { _, enabled in
                    Task { NotificationService.shared.scheduleStreakReminder(enabled: enabled) }
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // MARK: - Helpers

    private var divider: some View {
        Rectangle()
            .fill(ChronosTheme.border)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    private var displayTime: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: briefTime)
    }

    private func applyMorningBrief(enabled: Bool) {
        Task {
            NotificationService.shared.scheduleMorningBrief(
                hour:    briefHour,
                minute:  briefMinute,
                enabled: enabled
            )
        }
    }

    private func syncPermissionState() async {
        await NotificationService.shared.checkPermissionStatus()
        showPermCard = NotificationService.shared.permissionDetermined &&
                       !NotificationService.shared.permissionGranted
    }

    static func makeTime(hour: Int, minute: Int) -> Date {
        var c       = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour      = hour
        c.minute    = minute
        return Calendar.current.date(from: c) ?? Date()
    }
}

// MARK: - Permission Prompt Card

private struct NotifPermissionCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 13, weight: .light))
                .foregroundColor(ChronosTheme.faint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications are off")
                    .font(.jost(size: 12, weight: .medium)).foregroundColor(ChronosTheme.muted)
                Text("Enable in Settings → Chronos → Notifications.")
                    .font(.jost(size: 11, weight: .light)).foregroundColor(ChronosTheme.faint)
                    .lineSpacing(3)

                Button(action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Text("Open Settings")
                        .font(.jost(size: 11, weight: .medium))
                        .foregroundColor(ChronosTheme.gold)
                        .underline()
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ChronosTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ChronosTheme.faint.opacity(0.5), lineWidth: 1))
        )
    }
}
