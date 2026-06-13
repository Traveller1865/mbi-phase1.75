// ios/MBI/MBI/Services/BiometricAuthService.swift
// S2 — Biometric App Lock (Face ID / Touch ID)
//
// Behaviour:
//   - Off by default. User enables in Account → Privacy.
//   - When enabled, the app prompts for Face ID / Touch ID on every foreground
//     return (scene phase .active) after the app has been backgrounded.
//   - 15-second grace period: if the app has only been in the background briefly,
//     no prompt is shown (prevents constant prompts for e.g. Control Center swipes).
//   - If biometrics are unavailable or the user's device has no enrolled biometrics,
//     the setting is hidden in AccountView.
//   - On evaluation failure (3 failed attempts / too many attempts),
//     the app shows a locked screen until the next successful evaluation.
//
// Integration:
//   1. Wrap MainTabView in BiometricLockOverlay in RootView.
//   2. Expose the toggle in AccountView → Privacy section.
//   3. Call BiometricAuthService.shared.appDidBackground() in ScenePhase.background.
//
// Requires: LocalAuthentication framework (no additional Xcode entitlements)
// Info.plist key: NSFaceIDUsageDescription — add to Info.plist before shipping.

import LocalAuthentication
import SwiftUI
import Combine

@MainActor
final class BiometricAuthService: ObservableObject {

    static let shared = BiometricAuthService()

    // ── Persistent preference ─────────────────────────────────────────────────
    // S2: UserDefaults key — mirrors the toggle in AccountView → Privacy.
    private static let enabledKey = "biometric_lock_enabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    // ── Runtime lock state ────────────────────────────────────────────────────
    /// True when the app is locked and the biometric prompt must be shown.
    @Published var isLocked: Bool = false

    /// Whether Face ID / Touch ID is available on this device.
    let isBiometricAvailable: Bool

    /// Human-readable name of the available biometric type.
    let biometricName: String

    // ── Grace period ──────────────────────────────────────────────────────────
    /// Timestamp when the app last went to background.
    private var backgroundedAt: Date?
    /// Don't prompt if the app was only backgrounded for this many seconds or less.
    private static let gracePeriodSeconds: TimeInterval = 15

    // ── Init ──────────────────────────────────────────────────────────────────
    private init() {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        isBiometricAvailable = canEvaluate

        switch context.biometryType {
        case .faceID:   biometricName = "Face ID"
        case .touchID:  biometricName = "Touch ID"
        case .opticID:  biometricName = "Optic ID"
        default:        biometricName = "Biometrics"
        }

        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // ── Lifecycle hooks ───────────────────────────────────────────────────────

    /// Call this when scenePhase transitions to .background.
    func appDidBackground() {
        backgroundedAt = Date()
    }

    /// Call this when scenePhase transitions to .active.
    /// Locks the app (if biometric lock is enabled and the grace period has elapsed).
    func appDidForeground() {
        guard isEnabled, isBiometricAvailable else { return }

        let elapsed = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard elapsed > Self.gracePeriodSeconds else { return }

        isLocked = true
    }

    // ── Evaluation ────────────────────────────────────────────────────────────

    /// Prompt for biometric authentication. Unlocks the app on success.
    func evaluate() {
        let context = LAContext()
        let reason = "Unlock Chronos to view your health data."

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
                if success {
                    await MainActor.run { self.isLocked = false }
                }
            } catch {
                // Failures (3 tries, not enrolled, etc.) leave the app locked.
                // LAError.userCancel: user dismissed — remain locked, keep prompting on next tap.
                // Do not surface raw error to the user.
            }
        }
    }
}

// ─────────────────────────────────────────
// BIOMETRIC LOCK OVERLAY
// Wrap MainTabView with this in RootView.
// ─────────────────────────────────────────

struct BiometricLockOverlay<Content: View>: View {
    @ObservedObject var biometric: BiometricAuthService
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()

            if biometric.isLocked {
                ZStack {
                    ChronosTheme.ink.ignoresSafeArea()

                    RadialGradient(
                        colors: [ChronosTheme.gold.opacity(0.06), .clear],
                        center: .center, startRadius: 0, endRadius: 300
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 24) {
                        Image(systemName: biometric.biometricName == "Touch ID"
                              ? "touchid" : "faceid")
                            .font(.system(size: 52, weight: .ultraLight))
                            .foregroundColor(ChronosTheme.gold)

                        VStack(spacing: 8) {
                            Text("Chronos is locked.")
                                .font(.cormorant(size: 26, weight: .light))
                                .foregroundColor(ChronosTheme.text)

                            Text("Use \(biometric.biometricName) to continue.")
                                .font(.jost(size: 13, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                        }

                        Button(action: { biometric.evaluate() }) {
                            HStack(spacing: 8) {
                                Image(systemName: biometric.biometricName == "Touch ID"
                                      ? "touchid" : "faceid")
                                    .font(.system(size: 15, weight: .ultraLight))
                                Text("Unlock with \(biometric.biometricName)")
                                    .font(.jost(size: 13, weight: .medium))
                                    .tracking(0.5)
                            }
                            .foregroundColor(ChronosTheme.ink)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(ChronosTheme.text)
                            )
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 40)
                }
                .transition(.opacity)
                .onAppear { biometric.evaluate() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: biometric.isLocked)
    }
}
