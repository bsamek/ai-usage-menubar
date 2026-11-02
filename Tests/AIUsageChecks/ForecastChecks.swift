import AIUsageCore
import Foundation

let checkZone = TimeZone(identifier: "America/New_York")!
func checkDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private final class ObservationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [UsageObservation]
    init(_ observations: [UsageObservation]) { remaining = observations }
    func next() -> UsageObservation {
        lock.withLock {
            let value = remaining[0]
            if remaining.count > 1 { remaining.removeFirst() }
            return value
        }
    }
}

enum ForecastChecks {
    static let checks: [(String, @Sendable () async throws -> Void)] = [
        ("9–6 workday projection", standardProjection),
        ("warm-up and end-of-workday boundaries", boundaries),
        ("zero and invalid forecast inputs", invalidInputs),
        ("custom hours and short windows", customHours),
        ("work-hours persistence and corrupt settings", persistence),
        ("local calendar, midnight, and timezone", localContext),
        ("daylight-saving working windows", daylightSaving),
        ("cached forecast stays frozen and stale", cachedSnapshot),
        ("explicit local-day ccusage arguments", dailyArguments),
        ("ccusage rejects an unexpected report date", wrongReportDate),
        ("ccusage rejects midnight during a fetch", fetchMidnight),
        ("ccusage rejects a timezone change during a fetch", fetchTimeZone),
        ("empty report is zero for the requested day", emptyReport),
    ]

    private static func forecast(_ date: String, cost: Double = 6,
                                 hours: WorkHours = .standard) -> DailySpendForecast {
        .estimate(cost: cost, observedAt: checkDate(date),
                  calendar: UsageDayContext.calendar(in: checkZone), workHours: hours)
    }

    private static func standardProjection() throws {
        try expect(WorkHours.standard.startMinute == 540 && WorkHours.standard.endMinute == 1080, "Default must be 9–6")
        try expect(forecast("2026-11-02T12:00:00-05:00") == .projected(total: 18, workdayEnded: false), "$6 at noon must project $18")
        try expect(forecast("2026-11-02T15:00:00-05:00") == .projected(total: 9, workdayEnded: false), "Afternoon pace")
    }

    private static func boundaries() throws {
        let waiting = DailySpendForecast.waiting(until: checkDate("2026-11-02T09:30:00-05:00"))
        for time in ["00:00:00", "08:59:59", "09:00:00", "09:29:59"] {
            try expect(forecast("2026-11-02T\(time)-05:00") == waiting, "Early forecast at \(time)")
        }
        try expect(forecast("2026-11-02T09:30:00-05:00") == .projected(total: 108, workdayEnded: false), "30-minute boundary")
        for time in ["18:00:00", "23:59:59"] {
            try expect(forecast("2026-11-02T\(time)-05:00") == .projected(total: 6, workdayEnded: true), "End boundary")
        }
    }

    private static func invalidInputs() throws {
        try expect(forecast("2026-11-02T12:00:00-05:00", cost: 0) == .projected(total: 0, workdayEnded: false), "Zero forecast")
        for cost in [-1, .nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
            try expect(forecast("2026-11-02T12:00:00-05:00", cost: cost) == .unavailable, "Invalid/overflow cost")
        }
    }

    private static func customHours() throws {
        for (start, end) in [(-1, 1080), (540, 1440), (540, 540), (1080, 540), (1440, 1500)] {
            try expect(WorkHours(startMinute: start, endMinute: end) == nil, "Invalid work window accepted")
        }
        let hours = WorkHours(startMinute: 600, endMinute: 960)!
        try expect(forecast("2026-11-02T12:00:00-05:00", hours: hours) == .projected(total: 18, workdayEnded: false), "Custom 10–4")
        let short = WorkHours(startMinute: 540, endMinute: 555)!
        try expect(forecast("2026-11-02T09:10:00-05:00", hours: short) == .waiting(until: checkDate("2026-11-02T09:15:00-05:00")), "Short warm-up capped at end")
        try expect(forecast("2026-11-02T09:15:00-05:00", hours: short) == .projected(total: 6, workdayEnded: true), "Short day ended")
    }

    private static func persistence() throws {
        let suite = "AIUsageForecastChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(WorkHours.load(from: defaults) == .standard, "Missing settings default")
        let hours = WorkHours(startMinute: 615, endMinute: 1095)!
        hours.save(to: defaults)
        try expect(WorkHours.load(from: UserDefaults(suiteName: suite)!) == hours, "Settings reload")
        for data in ["not JSON", #"{"startMinute":540,"endMinute":400}"#, #"{"startMinute":-1,"endMinute":1080}"#] {
            defaults.set(Data(data.utf8), forKey: "forecast.workHours")
            try expect(WorkHours.load(from: defaults) == .standard, "Corrupt settings fallback")
        }
    }

    private static func localContext() throws {
        let instant = checkDate("2026-11-03T01:00:00Z")
        let ny = UsageDayContext(date: instant, timeZone: checkZone)
        let utc = UsageDayContext(date: instant, timeZone: TimeZone(secondsFromGMT: 0)!)
        try expect(ny.period == "2026-11-02" && utc.period == "2026-11-03", "UTC is not the local day")
        let noon = checkDate("2026-11-02T17:00:00Z")
        let la = UsageDayContext.calendar(in: TimeZone(identifier: "America/Los_Angeles")!)
        try expect(DailySpendForecast.estimate(cost: 6, observedAt: noon, calendar: la) == .waiting(until: checkDate("2026-11-02T09:30:00-08:00")), "Local working hours")
        try expect(UsageDayContext(date: checkDate("2026-11-03T00:00:00-05:00"), timeZone: checkZone).period == "2026-11-03", "Local midnight")
    }

    private static func daylightSaving() throws {
        for noon in ["2026-03-08T12:00:00-04:00", "2026-11-01T12:00:00-05:00"] {
            try expect(forecast(noon) == .projected(total: 18, workdayEnded: false), "DST default workday")
        }
        let hours = WorkHours(startMinute: 0, endMinute: 240)!
        try expect(forecast("2026-03-08T03:00:00-04:00", hours: hours) == .projected(total: 9, workdayEnded: false), "Spring elapsed duration")
        try expect(forecast("2026-11-01T03:00:00-05:00", hours: hours) == .projected(total: 7.5, workdayEnded: false), "Fall elapsed duration")
    }

    private static func cachedSnapshot() throws {
        let date = checkDate("2026-11-02T12:00:00-05:00")
        let observation = UsageObservation(date: date, timeZone: checkZone)
        let snapshot = UsageSnapshot(report: try report(period: observation.context.period), fetchedAt: date,
                                     warnings: nil, context: observation.context)
        let cached = UsageObservation(date: date.addingTimeInterval(3600), timeZone: checkZone)
        try expect(snapshot.forecast(workHours: .standard, at: cached) == .projected(total: 18, workdayEnded: false), "Cache must not decay with elapsed time")
        try expect(!snapshot.isStale(at: observation), "Fresh snapshot")
        try expect(!snapshot.isStale(at: UsageObservation(date: date.addingTimeInterval(90), timeZone: checkZone)), "90-second boundary")
        try expect(snapshot.isStale(at: cached), "Old snapshot")
        for invalid in [UsageObservation(date: date.addingTimeInterval(86400), timeZone: checkZone),
                        UsageObservation(date: date, timeZone: TimeZone(identifier: "America/Los_Angeles")!),
                        UsageObservation(date: date.addingTimeInterval(-1), timeZone: checkZone)] {
            try expect(snapshot.forecast(workHours: .standard, at: invalid) == .unavailable, "Invalid cache forecast")
            try expect(snapshot.isStale(at: invalid), "Invalid cache staleness")
        }
        let evening = UsageObservation(date: checkDate("2026-11-02T19:00:00-05:00"), timeZone: checkZone)
        try expect(snapshot.forecast(workHours: .standard, at: evening) == .projected(total: 18, workdayEnded: false), "Failed fetch after end keeps cached estimate")
    }

    private static func report(period: String) throws -> UsageReport {
        try UsageReport.decode(Data(json(period: period).utf8))
    }
    private static func json(period: String) -> String {
        #"{"daily":[{"period":"\#(period)","agents":[{"agent":"pi","totalCost":6,"totalTokens":10,"modelBreakdowns":[{"modelName":"example","cost":6,"inputTokens":10,"outputTokens":0,"cacheReadTokens":0,"cacheCreationTokens":0}]}]}],"totals":{"totalCost":6,"totalTokens":10}}"#
    }

    private static func withClient<T>(json: String, observe: @escaping @Sendable () -> UsageObservation,
                                      verifyArguments: Bool = false,
                                      body: (CCUsageClient) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ccusage-fixture")
        let check = verifyArguments ? "[ \"$*\" = 'daily --since 2026-11-02 --until 2026-11-02 --timezone America/New_York --json --by-agent' ] || exit 12\n" : ""
        try Data("#!/bin/sh\n\(check)cat <<'REPORT'\n\(json)\nREPORT\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return try await body(CCUsageClient(executable: executable, directory: directory, observe: observe))
    }
    private static var observation: UsageObservation {
        UsageObservation(date: checkDate("2026-11-02T12:00:00-05:00"), timeZone: checkZone)
    }
    private static func dailyArguments() async throws {
        try expect(observation.context.dailyArguments == ["daily", "--since", "2026-11-02", "--until", "2026-11-02", "--timezone", "America/New_York", "--json", "--by-agent"], "Date/zone arguments")
        try await withClient(json: json(period: "2026-11-02"), observe: { observation }, verifyArguments: true) { client in
            let snapshot = try await client.fetch()
            try expect(snapshot.context == observation.context && snapshot.fetchedAt == observation.date, "Capture context")
        }
    }
    private static func wrongReportDate() async throws {
        try await withClient(json: json(period: "2026-11-01"), observe: { observation }) { client in
            do { _ = try await client.fetch() } catch UsageError.invalidReport { return }
            throw CheckFailure(description: "Wrong-day report accepted")
        }
    }
    private static func expectContextChange(_ finish: UsageObservation) async throws {
        let sequence = ObservationSequence([observation, finish])
        try await withClient(json: json(period: "2026-11-02"), observe: { sequence.next() }) { client in
            do { _ = try await client.fetch() } catch UsageError.contextChanged { return }
            throw CheckFailure(description: "Changed context accepted")
        }
    }
    private static func fetchMidnight() async throws {
        try await expectContextChange(UsageObservation(date: checkDate("2026-11-03T00:00:01-05:00"), timeZone: checkZone))
    }
    private static func fetchTimeZone() async throws {
        try await expectContextChange(UsageObservation(date: observation.date, timeZone: TimeZone(identifier: "America/Los_Angeles")!))
    }
    private static func emptyReport() async throws {
        try await withClient(json: #"{"daily":[],"totals":{"totalCost":0,"totalTokens":0}}"#, observe: { observation }) { client in
            let snapshot = try await client.fetch()
            try expect(snapshot.forecast(workHours: .standard, at: observation) == .projected(total: 0, workdayEnded: false), "Empty local-day forecast")
        }
    }
}
