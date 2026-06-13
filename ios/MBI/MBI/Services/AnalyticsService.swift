// ios/MBI/MBI/Services/AnalyticsService.swift
// MBI Beta Readiness — Phase 3, P3.2
// Custom privacy-first analytics. No third-party SDKs.
// All events land in the `app_events` Supabase table (owned by us, no data sharing).
//
// Usage:
//   AnalyticsService.shared.track("sync_complete", properties: ["days": 7])
//   AnalyticsService.shared.track("onboarding_complete")
//
// Design principles:
//   • Fire-and-forget — never blocks the calling thread
//   • Never crashes — all errors are swallowed silently
//   • Never logs PII — userId is the only identifier; no name, email, or health values
//   • No tracking before session is established (events are dropped, not queued)

import Foundation
import UIKit

final class AnalyticsService {
    static let shared = AnalyticsService()
    private init() {}

    // ─────────────────────────────────────────
    // TRACK
    // Fire-and-forget. Non-blocking.
    // ─────────────────────────────────────────

    func track(_ event: AnalyticsEvent, properties: [String: Any] = [:]) {
        track(event.rawValue, properties: properties)
    }

    func track(_ eventName: String, properties: [String: Any] = [:]) {
        Task {
            guard let userId = await SupabaseService.shared.session?.userId else {
                // Drop events before auth — no queue, no local buffer
                return
            }
            await SupabaseService.shared.insertAnalyticsEvent(
                userId: userId,
                name: eventName,
                properties: properties
            )
        }
    }
}

// ─────────────────────────────────────────
// EVENT CATALOGUE
// All event names centralised here — prevents string typos and
// gives a single document of what the app instruments.
// ─────────────────────────────────────────

enum AnalyticsEvent: String {
    // ── App lifecycle ──
    case appOpen                = "app_open"
    case appBackground          = "app_background"

    // ── Auth ──
    case signUpStarted          = "sign_up_started"
    case signUpComplete         = "sign_up_complete"
    case signInComplete         = "sign_in_complete"
    case signOut                = "sign_out"

    // ── Onboarding ──
    case onboardingStarted      = "onboarding_started"
    case onboardingComplete     = "onboarding_complete"
    case onboardingStepViewed   = "onboarding_step_viewed"

    // ── HealthKit ──
    case healthKitAuthorized    = "healthkit_authorized"
    case healthKitDenied        = "healthkit_denied"

    // ── Sync ──
    case syncTriggered          = "sync_triggered"
    case syncComplete           = "sync_complete"
    case syncFailed             = "sync_failed"
    case syncCacheServed        = "sync_cache_served"

    // ── Dashboard ──
    case dashboardViewed        = "dashboard_viewed"
    case scoreCardViewed        = "score_card_viewed"
    case driverChipTapped       = "driver_chip_tapped"
    case feedbackTapped         = "feedback_tapped"

    // ── Intelligence ──
    case intelligenceSheetViewed = "intelligence_sheet_viewed"

    // ── Horizon ──
    case horizonTabViewed       = "horizon_tab_viewed"
    case horizonCardViewed      = "horizon_card_viewed"
    case horizonEscalateViewed  = "horizon_escalate_viewed"

    // ── Account ──
    case accountTabOpened       = "account_tab_opened"
    case profileSaved           = "profile_saved"
    case resyncTriggered        = "resync_triggered"

    // ── Notifications ──
    case pushPermissionGranted  = "push_permission_granted"
    case pushPermissionDenied   = "push_permission_denied"

    // ── Feedback ──
    case feedbackSubmitted      = "feedback_submitted"

    // ── Check-in ──
    case checkInCompleted       = "checkin_completed"

    // ── Workout log ──
    case workoutLogged          = "workout_logged"
}
