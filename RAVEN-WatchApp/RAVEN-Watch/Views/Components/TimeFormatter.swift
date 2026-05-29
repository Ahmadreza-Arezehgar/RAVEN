// TimeFormatter.swift
//
// Watch-friendly relative timestamps. We want "2m", "3h", "Mon", "12 Jun"
// — RelativeDateTimeFormatter is too verbose for a 41mm screen.

import Foundation

enum TimeFormatter {
    static func shortRelative(_ ts: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let now = Date()
        let delta = now.timeIntervalSince(date)

        switch delta {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(delta / 60))m"
        case ..<86_400: return "\(Int(delta / 3_600))h"
        case ..<604_800:
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: date)
        default:
            let f = DateFormatter()
            f.dateFormat = "d MMM"
            return f.string(from: date)
        }
    }
}
