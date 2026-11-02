import Foundation

public struct WorkHours: Equatable, Sendable {
    public let startMinute: Int
    public let endMinute: Int

    public static let standard = WorkHours(startMinute: 9 * 60, endMinute: 18 * 60)!

    public init?(startMinute: Int, endMinute: Int) {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute),
              endMinute > startMinute else { return nil }
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public func window(on date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let day = calendar.startOfDay(for: date)
        guard let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60,
                                        second: 0, of: day),
              let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60,
                                      second: 0, of: day), end > start else { return nil }
        return (start, end)
    }
}

public enum DailySpendForecast: Equatable, Sendable {
    case unavailable
    case waiting(until: Date)
    case projected(total: Double, workdayEnded: Bool)

    public static func estimate(
        cost: Double, observedAt: Date, calendar: Calendar, workHours: WorkHours = .standard
    ) -> DailySpendForecast {
        guard cost.isFinite, cost >= 0, let window = workHours.window(on: observedAt, calendar: calendar) else {
            return .unavailable
        }
        if observedAt >= window.end { return .projected(total: cost, workdayEnded: true) }
        let readyAt = min(window.start.addingTimeInterval(30 * 60), window.end)
        guard observedAt >= readyAt else { return .waiting(until: readyAt) }
        let fraction = window.end.timeIntervalSince(window.start) / observedAt.timeIntervalSince(window.start)
        let projected = cost * fraction
        guard projected.isFinite else { return .unavailable }
        return .projected(total: max(cost, projected), workdayEnded: false)
    }
}

public struct UsageDayContext: Equatable, Sendable {
    public let period: String
    public let timeZoneIdentifier: String

    public init(date: Date, timeZone: TimeZone) {
        let calendar = Self.calendar(in: timeZone)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        period = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        timeZoneIdentifier = timeZone.identifier
    }

    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public var dailyArguments: [String] {
        ["daily", "--since", period, "--until", period, "--timezone", timeZoneIdentifier, "--json", "--by-agent"]
    }
}

/// Capture the clock and timezone together, and allow deterministic boundary tests.
public struct UsageObservation: Sendable {
    public let date: Date
    public let timeZone: TimeZone

    public init(date: Date, timeZone: TimeZone) {
        self.date = date
        self.timeZone = timeZone
    }

    public static func localNow() -> UsageObservation {
        // Freeze the currently auto-updating zone in this observation.
        UsageObservation(date: Date(), timeZone: TimeZone(identifier: TimeZone.autoupdatingCurrent.identifier)!)
    }

    public var context: UsageDayContext { UsageDayContext(date: date, timeZone: timeZone) }
}
