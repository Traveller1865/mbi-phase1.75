// ios/MBI/MBI/Services/TerraService.swift
// MBI Phase 2 — Sprint 8 · Terra API Integration
//
// Manages Terra multi-device connection state.
// Architecture: UI shell + connection state. Full TerraSwift SDK wiring deferred to
// when the Terra API key and SPM package are configured.
//
// HOW IT WORKS (Phase 2):
//   1. Connection state stored in Supabase users.terra_providers (JSON array).
//   2. TerraService reads/writes this column via the REST API.
//   3. When TerraSwift SDK is added: replace initializeTerra() and connect(provider:) TODOs
//      with Terra.instance.initTerra(...) and Terra.instance.getUserid(...) calls.
//   4. Terra webhooks receive device data → normalization Edge Function maps to daily_inputs.
//
// Supported providers (Phase 2 activation targets):
//   Oura Ring, Garmin Connect, Whoop, Google Fit / Fitbit
//
// Source priority rule:
//   Apple Health (HealthKit) = primary. Terra data supplements for non-Apple devices.
//   When both sources report the same metric, Apple Watch value takes precedence.

import Foundation

// ─────────────────────────────────────────
// TERRA PROVIDER
// ─────────────────────────────────────────

struct TerraProvider: Identifiable, Hashable {
    let id:          String  // "oura" | "garmin" | "whoop" | "googlefit" | "fitbit"
    let displayName: String
    let sfSymbol:    String
    let description: String  // shown in connection row

    static let supported: [TerraProvider] = [
        TerraProvider(id: "oura",      displayName: "Oura Ring",    sfSymbol: "circle.hexagonpath",    description: "HRV · Sleep stages · Readiness"),
        TerraProvider(id: "garmin",    displayName: "Garmin",       sfSymbol: "location.circle",       description: "HRV · Activity · GPS workouts"),
        TerraProvider(id: "whoop",     displayName: "Whoop",        sfSymbol: "waveform.path.ecg.rectangle", description: "Recovery · Strain · HRV"),
        TerraProvider(id: "googlefit", displayName: "Google Fit",   sfSymbol: "figure.walk",           description: "Activity · Steps · Sleep"),
        TerraProvider(id: "fitbit",    displayName: "Fitbit",       sfSymbol: "heart.circle",          description: "Activity · Sleep · Heart rate"),
    ]
}

// ─────────────────────────────────────────
// TERRA SERVICE
// ─────────────────────────────────────────

@MainActor
final class TerraService: ObservableObject {
    static let shared = TerraService()

    @Published var connectedProviderIds: Set<String> = []
    @Published var isConnecting: String? = nil     // provider ID currently connecting, or nil
    @Published var connectionError: String? = nil

    // ── Load ─────────────────────────────────────────────────────────────────

    /// Loads connected provider IDs from Supabase users table.
    /// Falls back to UserDefaults cache if the column is unavailable (migration not yet applied).
    func load(userId: String) async {
        // UserDefaults cache key per user — used until Supabase column is available
        let cacheKey = "terra_connected_providers_\(userId)"
        if let cached = UserDefaults.standard.array(forKey: cacheKey) as? [String] {
            connectedProviderIds = Set(cached)
        }
    }

    private func saveToCache(userId: String) {
        let cacheKey = "terra_connected_providers_\(userId)"
        UserDefaults.standard.set(Array(connectedProviderIds), forKey: cacheKey)
    }

    // ── Connect ───────────────────────────────────────────────────────────────

    /// Initiates connection for a Terra provider.
    /// Phase 2: stores in UserDefaults. When TerraSwift is installed, replace with SDK call.
    func connect(provider: TerraProvider, userId: String) async {
        isConnecting   = provider.id
        connectionError = nil

        // TODO (TerraSwift): Replace this block with:
        //   Terra.instance.getUserid(userId: userId) { terraUserId, error in
        //       // Store terraUserId to Supabase users.terra_user_id
        //       // Trigger Terra's authorization flow for this provider
        //   }
        //   Terra.instance.initConnection(type: .OURA, token: terraDevToken, ...) { success, error in ... }
        //
        // Phase 2 stub: simulate connection success
        try? await Task.sleep(nanoseconds: 800_000_000)
        connectedProviderIds.insert(provider.id)
        saveToCache(userId: userId)
        isConnecting = nil
    }

    /// Disconnects a Terra provider.
    func disconnect(provider: TerraProvider, userId: String) async {
        connectedProviderIds.remove(provider.id)
        saveToCache(userId: userId)
    }

    func isConnected(_ provider: TerraProvider) -> Bool {
        connectedProviderIds.contains(provider.id)
    }
}
