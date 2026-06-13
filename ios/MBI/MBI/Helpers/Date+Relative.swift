// ios/MBI/MBI/Helpers/Date+Relative.swift
// N7 — Relative Date Formatting
//
// Converts yyyy-MM-dd strings to friendly relative language:
//   Today          →  "Today"
//   Yesterday      →  "Yesterday"
//   Within 7 days  →  "Monday", "Tuesday", etc.
//   Older          →  "Jan 12"
//
// Usage:
//   Date.relativeLabel(from: "2026-05-09")   // "Today"
//   Date.relativeLabel(from: "2026-05-08")   // "Yesterday"
//   Date.relativeLabel(from: "2026-05-03")   // "Saturday"
//   Date.relativeLabel(from: "2026-04-01")   // "Apr 1"

import Foundation

extension Date {

    /// Shared yyyy-MM-dd parser — reused across all call sites.
    private static let iso8601Parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dayNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Convert a `yyyy-MM-dd` string to a human-readable relative label.
    /// Falls back to "MMM d" for dates older than 7 days.
    /// Returns the raw string unchanged if parsing fails.
    static func relativeLabel(from dateString: String) -> String {
        guard let date = iso8601Parser.date(from: dateString) else {
            return dateString  // graceful fallback — never crash
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)

        let dayDiff = calendar.dateComponents([.day], from: target, to: today).day ?? Int.max

        switch dayDiff {
        case 0:   return "Today"
        case 1:   return "Yesterday"
        case 2...6: return dayNameFormatter.string(from: date)
        default:  return shortDateFormatter.string(from: date)
        }
    }

    /// Shorter variant for axis labels: "Today", "Yest.", "Mon", "Jan 12"
    static func shortRelativeLabel(from dateString: String) -> String {
        guard let date = iso8601Parser.date(from: dateString) else {
            return dateString
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: target, to: today).day ?? Int.max

        switch dayDiff {
        case 0:   return "Today"
        case 1:   return "Yest."
        case 2...6:
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: date)
        default:  return shortDateFormatter.string(from: date)
        }
    }
}
