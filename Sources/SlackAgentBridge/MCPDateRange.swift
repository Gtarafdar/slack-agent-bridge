import Foundation

/// Parses optional `since`, `until`, and `days` parameters for MCP history/search tools.
struct MCPDateRange {
    var since: Date?
    var until: Date?

    static func parse(_ arguments: [String: Any]) -> MCPDateRange? {
        var since: Date?
        var until: Date?

        if let days = arguments["days"] as? Int, days > 0 {
            since = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        if let s = arguments["since"] as? String, !s.isEmpty {
            since = parseDateString(s, endOfDay: false) ?? since
        }
        if let u = arguments["until"] as? String, !u.isEmpty {
            until = parseDateString(u, endOfDay: true)
        }

        guard since != nil || until != nil else { return nil }
        return MCPDateRange(since: since, until: until)
    }

    func contains(_ date: Date) -> Bool {
        if let since, date < since { return false }
        if let until, date > until { return false }
        return true
    }

    private static func parseDateString(_ raw: String, endOfDay: Bool) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ts = Double(trimmed), ts > 1_000_000_000 {
            return Date(timeIntervalSince1970: ts)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone.current
        day.dateFormat = "yyyy-MM-dd"
        guard let d = day.date(from: trimmed) else { return nil }
        if endOfDay {
            return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d)
        }
        return d
    }
}
