// ios/MBI/Config.swift
import Foundation

enum Config {
    static let supabaseURL = "https://sjhysadnpswrcpmezmoc.supabase.co"
    // Secret values live only in Secrets.swift (gitignored). Update once there.
    static let supabaseAnonKey = Secrets.supabasePublishableKey
    static let anthropicAPIKey = Secrets.anthropicAPIKey

    static var ingestURL: URL { URL(string: "\(supabaseURL)/functions/v1/ingest")! }
    static var scoreURL: URL { URL(string: "\(supabaseURL)/functions/v1/score")! }
    static var narrateURL: URL { URL(string: "\(supabaseURL)/functions/v1/narrate")! }
    static var adminURL: URL { URL(string: "\(supabaseURL)/functions/v1/admin")! }
    static var narrateTrendURL: URL { URL(string: "\(supabaseURL)/functions/v1/narrate-trend")! }
    static let narrateDomainsPatternURL  = URL(string: "\(supabaseURL)/functions/v1/narrate-domains-pattern")!
    static let narrateDomainExpandedURL  = URL(string: "\(supabaseURL)/functions/v1/narrate-domain-expanded")!
    static let narrateDomains30DayURL    = URL(string: "\(supabaseURL)/functions/v1/narrate-domains-30day")!
    static let horizonURL                = URL(string: "\(supabaseURL)/functions/v1/horizon")!
    static let narrateHorizonURL         = URL(string: "\(supabaseURL)/functions/v1/narrate-horizon")!
    static let horizonClassifyURL        = URL(string: "\(supabaseURL)/functions/v1/horizon-classify")!
    // Sprint 9 — Phase 3: deploy `horizon-assist` Edge Function, then uncomment below.
    // static let horizonAssistURL       = URL(string: "\(supabaseURL)/functions/v1/horizon-assist")!
    static let escalationAlertURL     = URL(string: "\(supabaseURL)/functions/v1/escalation-alert")!
    // Pipeline Performance Architecture (June 2026)
    static let orchestratorURL        = URL(string: "\(supabaseURL)/functions/v1/score-orchestrator")!
    static let narrateDetailURL       = URL(string: "\(supabaseURL)/functions/v1/narrate-detail")!

    static let defaultStepGoal = 8000
    static let minHistoryDaysForScore = 3
    static let appVersion = "1.0.0"

    // Sentry crash reporting DSN — beta environment.
    // Swap for production DSN when moving to App Store release.
    static let sentryDSN = "https://15bfde2da31309219aab24c15f4e0620@o4511374447673344.ingest.us.sentry.io/4511374449115136"
}
