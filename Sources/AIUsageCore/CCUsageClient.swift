import Darwin
import Foundation

public struct UsageSnapshot: Sendable {
    public let report: UsageReport
    public let fetchedAt: Date
    public let warnings: String?
    public let context: UsageDayContext

    public init(report: UsageReport, fetchedAt: Date, warnings: String?, context: UsageDayContext) {
        self.report = report
        self.fetchedAt = fetchedAt
        self.warnings = warnings
        self.context = context
    }

    public func isStale(at observation: UsageObservation) -> Bool {
        context != observation.context || observation.date < fetchedAt
            || observation.date.timeIntervalSince(fetchedAt) > 90
    }

    public func forecast(workHours: WorkHours, at observation: UsageObservation) -> DailySpendForecast {
        guard context == observation.context, observation.date >= fetchedAt else { return .unavailable }
        // Cached reports keep the rate from their last observation, rather than
        // pretending that a failed refresh observed a period of inactivity.
        return .estimate(cost: report.totals.totalCost, observedAt: fetchedAt,
                         calendar: UsageDayContext.calendar(in: observation.timeZone), workHours: workHours)
    }
}

public struct CCUsageClient: Sendable {
    public let executable: URL
    public let arguments: [String]?
    public let directory: URL
    public let timeout: TimeInterval
    private let observe: @Sendable () -> UsageObservation

    public init(
        executable: URL,
        arguments: [String]? = nil,
        directory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: TimeInterval = 45,
        observe: @escaping @Sendable () -> UsageObservation = { .localNow() }
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.timeout = timeout
        self.observe = observe
    }

    public func fetch() async throws -> UsageSnapshot {
        // Waiting for a subprocess and reading its output must not block the menu bar.
        try await Task.detached(priority: .utility) { try fetchSynchronously() }.value
    }

    private func fetchSynchronously() throws -> UsageSnapshot {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UsageError.missingExecutable(executable.path)
        }

        let context = observe().context

        // Files avoid pipe-buffer deadlocks, including when ccusage emits many warnings.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout")
        let errorURL = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? errors.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments ?? context.dailyArguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let deadline = ProcessDeadline(process)
        let watchdog = DispatchWorkItem { deadline.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        if deadline.didExpire { throw UsageError.timedOut }

        let errorData = try read(errorURL, limit: 8_192)
        let errorText = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw UsageError.failed(process.terminationStatus, errorText)
        }
        let data = try read(outputURL, limit: 8_000_001)
        guard data.count <= 8_000_000 else {
            throw UsageError.invalidReport("The JSON report was unexpectedly large.")
        }
        let finished = observe()
        guard finished.context == context else { throw UsageError.contextChanged }
        let report = try UsageReport.decode(data)
        guard report.daily.allSatisfy({ $0.period == context.period }) else {
            throw UsageError.invalidReport("The report does not match the requested local date.")
        }
        return UsageSnapshot(report: report, fetchedAt: finished.date,
                             warnings: errorText.isEmpty ? nil : errorText, context: context)
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }
}

private final class ProcessDeadline: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var expired = false

    init(_ process: Process) { self.process = process }

    var didExpire: Bool { lock.withLock { expired } }

    func expire() {
        lock.withLock {
            guard process.isRunning else { return }
            expired = true
            process.terminate()
        }
        // A stuck process must not prevent all future refreshes.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
