import Foundation

public struct UsageReport: Decodable, Sendable {
    public let daily: [UsageDay]
    public let totals: UsageTotals

    public static func decode(_ data: Data) throws -> UsageReport {
        let report = try JSONDecoder().decode(UsageReport.self, from: data)
        guard report.totals.totalCost.isFinite, report.totals.totalCost >= 0,
              report.totals.totalTokens >= 0 else {
            throw UsageError.invalidReport("The report contains invalid totals.")
        }
        guard report.daily.count <= 1 else {
            throw UsageError.invalidReport("Expected only today's usage, but received several days.")
        }
        for day in report.daily {
            guard let agents = day.agents, !agents.isEmpty else {
                throw UsageError.invalidReport("The report is missing its per-harness breakdown.")
            }
            for agent in agents {
                guard agent.totalCost.isFinite, agent.totalCost >= 0,
                      agent.totalTokens >= 0,
                      agent.modelBreakdowns.allSatisfy({ $0.cost.isFinite && $0.cost >= 0 }) else {
                    throw UsageError.invalidReport("The report contains invalid model or harness costs.")
                }
            }
        }
        guard !report.daily.isEmpty || (report.totals.totalTokens == 0 && report.totals.totalCost == 0) else {
            throw UsageError.invalidReport("The report has totals but no daily breakdown.")
        }
        return report
    }

    public var agents: [AgentUsage] {
        (daily.first?.agents ?? []).sorted {
            $0.totalCost == $1.totalCost ? $0.agent < $1.agent : $0.totalCost > $1.totalCost
        }
    }
}

public struct UsageDay: Decodable, Sendable {
    public let period: String
    public let agents: [AgentUsage]?
}

public struct UsageTotals: Decodable, Sendable {
    public let totalCost: Double
    public let totalTokens: Int
}

public struct AgentUsage: Decodable, Identifiable, Sendable {
    public let agent: String
    public let totalCost: Double
    public let totalTokens: Int
    public let modelBreakdowns: [ModelUsage]

    public var id: String { agent }
    public var displayName: String {
        ["claude": "Claude Code", "pi": "Pi", "opencode": "OpenCode", "codex": "Codex"][agent]
            ?? agent.capitalized
    }
    public var models: [ModelUsage] {
        modelBreakdowns.sorted {
            $0.cost == $1.cost ? $0.modelName < $1.modelName : $0.cost > $1.cost
        }
    }
}

public struct ModelUsage: Decodable, Identifiable, Sendable {
    public let modelName: String
    public let cost: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public var id: String { modelName }
    public var displayName: String {
        // Remove the Pi adapter prefix and long provider paths only for display.
        let name = modelName.hasPrefix("[pi] ") ? String(modelName.dropFirst(5)) : modelName
        return name.split(separator: "/").last.map(String.init) ?? name
    }
}

public enum UsageError: LocalizedError {
    case missingExecutable(String)
    case failed(Int32, String)
    case timedOut
    case invalidReport(String)
    case contextChanged

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            "The bundled ccusage executable is missing: \(path). Rebuild the app."
        case .failed(let status, let message):
            "ccusage exited with status \(status). \(message)"
        case .timedOut:
            "ccusage did not finish within 45 seconds. The next refresh will retry."
        case .contextChanged:
            "The local date or timezone changed during refresh. The next refresh will retry."
        case .invalidReport(let message):
            "Could not read ccusage's report. \(message)"
        }
    }
}

public enum UsageFormat {
    public static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    public static func time(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
