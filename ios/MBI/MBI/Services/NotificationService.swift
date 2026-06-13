// ios/MBI/MBI/Services/NotificationService.swift
// MBI Phase 2 — Sprint 4: Notification Infrastructure
//
// Notification types:
//   Morning Brief   — local daily at user-set time (default 7:00 AM)
//   Horizon Alert   — one-shot when page6Active first detected
//   Streak Reminder — local daily at 6:00 PM (opt-in, default off)
//
// AppStorage keys (shared with NotificationPreferencesView):
//   notif_morning_brief_enabled    Bool  default true
//   notif_horizon_alert_enabled    Bool  default true
//   notif_streak_reminder_enabled  Bool  default false
//   notif_brief_delivery_hour      Int   default 7
//   notif_brief_delivery_minute    Int   default 0
//
// Device token: APNs token captured in AppDelegate and forwarded here.
// Stored to Supabase push_tokens table (hex-encoded) for future remote push.
// Remote push is not yet active — local scheduling handles all current types.

import Foundation
import UserNotifications
import UIKit

// MARK: - Notification Identifiers

enum NotificationID {
    static let morningBrief   = "com.mbi.notif.morning_brief"
    static let horizonAlert   = "com.mbi.notif.horizon_alert"
    static let streakReminder = "com.mbi.notif.streak_reminder"
}

// MARK: - NotificationService

@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    @Published var permissionGranted    = false
    @Published var permissionDetermined = false

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Permission

    /// Requests notification permission and shows the iOS system dialog.
    /// Also registers for remote notifications to capture APNs device token.
    /// Call once after onboarding completes — iOS only shows the dialog once.
    func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            permissionGranted    = granted
            permissionDetermined = true
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            permissionDetermined = true
        }
    }

    /// Reads current permission status without prompting.
    /// Call on app foreground to sync the permission badge in Preferences.
    func checkPermissionStatus() async {
        let settings = await center.notificationSettings()
        permissionDetermined = settings.authorizationStatus != .notDetermined
        permissionGranted    = settings.authorizationStatus == .authorized ||
                               settings.authorizationStatus == .provisional
    }

    // MARK: - Morning Brief

    /// Schedules (or reschedules) the daily Morning Brief local notification.
    /// Removes any existing Morning Brief trigger before setting the new one.
    /// Pass enabled: false to cancel without rescheduling.
    func scheduleMorningBrief(hour: Int, minute: Int, enabled: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.morningBrief])
        guard enabled else { return }

        let content       = UNMutableNotificationContent()
        content.title     = "Your Chronos score is ready."
        content.body      = "Open the app to see how your body recovered overnight."
        content.sound     = .default

        var components    = DateComponents()
        components.hour   = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: NotificationID.morningBrief,
            content:    content,
            trigger:    trigger
        )
        center.add(request)
    }

    func cancelMorningBrief() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.morningBrief])
    }

    // MARK: - Horizon Alert

    /// Fires a one-shot notification when an elevated wellness pattern is first detected.
    /// Caller is responsible for rate-limiting (once per detection cycle).
    /// Fires ~1 second after call so the app has time to background.
    func scheduleHorizonAlert(conditionLabel: String, enabled: Bool) {
        guard enabled else { return }

        let content   = UNMutableNotificationContent()
        content.title = "Chronos detected a change."
        content.body  = "\(conditionLabel) — open Chronos to see your full assessment."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: NotificationID.horizonAlert,
            content:    content,
            trigger:    trigger
        )
        center.add(request)
    }

    func cancelHorizonAlert() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.horizonAlert])
    }

    // MARK: - Streak Reminder

    /// Daily 6:00 PM nudge to open the app and maintain check-in streak.
    /// Off by default — user must opt in from Preferences.
    func scheduleStreakReminder(enabled: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.streakReminder])
        guard enabled else { return }

        let content       = UNMutableNotificationContent()
        content.title     = "Don't break your streak."
        content.body      = "Check in to keep your Chronos streak going."
        content.sound     = .default

        var components    = DateComponents()
        components.hour   = 18
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: NotificationID.streakReminder,
            content:    content,
            trigger:    trigger
        )
        center.add(request)
    }

    func cancelStreakReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.streakReminder])
    }

    // MARK: - Device Token Storage

    /// Stores the APNs device token to Supabase for future remote push delivery.
    /// Token is hex-encoded before storage. Device is identified by IDFV.
    /// Best-effort — swallows all errors.
    func storePushToken(_ tokenData: Data, userId: String) async {
        let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
        let deviceId    = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        await SupabaseService.shared.storePushToken(
            tokenString: tokenString,
            deviceId:    deviceId,
            userId:      userId
        )
    }
}
