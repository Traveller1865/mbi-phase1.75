// ios/MBI/MBI/MBIApp.swift
// MBI Phase 2 — Sprint 4: AppDelegate added for push token registration
// @UIApplicationDelegateAdaptor wires UIKit lifecycle into SwiftUI app.

import SwiftUI
import UserNotifications
import Sentry

@main
struct MBIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var supabase = SupabaseService.shared
    @StateObject private var sync     = SyncCoordinator.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(supabase)
                .environmentObject(sync)
                // S8: Force dark mode — Chronos is dark-UI by design.
                // Light mode renders incorrectly with the current colour palette.
                .preferredColorScheme(.dark)
        }
    }
}

// ─────────────────────────────────────────
// APP DELEGATE
// Handles:
//   - UNUserNotificationCenter delegate (foreground banner display)
//   - APNs device token registration → NotificationService → Supabase
// ─────────────────────────────────────────

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Sentry crash reporting — initialised before any user code runs
        // so first-launch crashes are captured.
        SentrySDK.start { options in
            options.dsn                  = Config.sentryDSN
            options.environment          = "beta"
            options.tracesSampleRate     = 0.2   // 20% of sessions get performance traces
            options.enableAppHangTracking    = true
            options.enableCrashHandler       = true
            options.attachScreenshot         = false  // never capture health-data screens
            options.attachViewHierarchy      = false
        }

        return true
    }

    /// APNs registration succeeded — store token for future remote push.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            if let userId = SupabaseService.shared.session?.userId {
                await NotificationService.shared.storePushToken(deviceToken, userId: userId)
            }
        }
    }

    /// APNs registration failed — local notifications continue to function normally.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Silent — local scheduling is unaffected
    }

    /// Show banner + play sound when a notification arrives while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

struct RootView: View {
    @EnvironmentObject var supabase: SupabaseService
    @EnvironmentObject var sync: SyncCoordinator
    @State private var isRestoringSession = true

    // S2: Biometric lock — shared instance, observed for lock/unlock state changes
    @ObservedObject private var biometric = BiometricAuthService.shared

    // S2: Scene phase — triggers biometric lock on foreground return
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if isRestoringSession {
                // Silent splash while we attempt token refresh
                ZStack {
                    ChronosTheme.surface.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Text("CHRONOS")
                            .font(.cormorant(size: 28, weight: .light))
                            .tracking(8)
                            .foregroundColor(ChronosTheme.text)
                        Text("by Mynd & Bodi Institute")
                            .font(.jost(size: 10, weight: .light))
                            .tracking(4)
                            .foregroundColor(ChronosTheme.muted)
                    }
                }
            } else if supabase.session == nil {
                AuthView()
            } else if supabase.currentUser?.onboardingComplete != true {
                OnboardingFlowView()
            } else {
                // S2: Wrap MainTabView in biometric lock overlay
                BiometricLockOverlay(biometric: biometric) {
                    MainTabView()
                }
                .task {
                    if let userId = supabase.session?.userId {
                        _ = try? await supabase.loadCurrentUser(userId: userId)
                        await sync.runDailySync(userId: userId)
                    }
                    // Catch returning users who completed onboarding on a prior build
                    // before push permission was wired. Re-request if still undetermined.
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    if settings.authorizationStatus == .notDetermined {
                        await NotificationService.shared.requestPermission()
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: supabase.session?.userId)
        .animation(.easeInOut(duration: 0.3), value: isRestoringSession)
        // S2: Track scene phase transitions for biometric lock gate
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background: biometric.appDidBackground()
            case .active:     biometric.appDidForeground()
            default:          break
            }
        }
        .task {
            // On every cold launch: attempt token refresh before showing any screen
            await supabase.refreshSessionIfNeeded()
            isRestoringSession = false
            // P3.2: Track app open after session is known
            AnalyticsService.shared.track(.appOpen)
            // Sentry: set anonymous user context for crash correlation.
            // Only the opaque userId is sent — no email, no health data.
            if let userId = supabase.session?.userId {
                let sentryUser = Sentry.User(userId: userId)
                SentrySDK.setUser(sentryUser)
            }
        }
    }
}
