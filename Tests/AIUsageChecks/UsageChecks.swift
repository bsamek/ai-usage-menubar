import AIUsageCore
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

private func expectFailure(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(description: "Expected invalid data to fail")
}

@main
enum UsageChecks {
    static func main() async {
        let checks: [(String, @Sendable () async throws -> Void)] = [
            ("real report shape, harness/model sorting, and short names", reportShape),
            ("empty day is zero", emptyDay),
            ("reject missing breakdown", {
                try reject(#"{"daily":[{"period":"2026-10-29"}],"totals":{"totalCost":3,"totalTokens":500}}"#)
            }),
            ("reject negative totals", {
                try reject(#"{"daily":[],"totals":{"totalCost":-1,"totalTokens":0}}"#)
            }),
            ("reject multiple days", {
                try reject(#"{"daily":[{"period":"2026-10-28"},{"period":"2026-10-29"}],"totals":{"totalCost":0,"totalTokens":0}}"#)
            }),
            ("reject totals without a day", {
                try reject(#"{"daily":[],"totals":{"totalCost":3,"totalTokens":500}}"#)
            }),
            ("reject malformed JSON", { try reject("not JSON") }),
            ("USD formatting", {
                try expect(UsageFormat.dollars(5.28) == "$5.28", "Currency rounding")
                try expect(UsageFormat.dollars(0) == "$0.00", "Zero cost")
            }),
            ("subprocess JSON and stderr warnings", processOutput),
            ("subprocess exit failures", processFailure),
            ("deadline and forced termination of a stuck process", processTimeout),
            ("missing executable", missingExecutable),
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }

    private static func reject(_ text: String) throws {
        try expectFailure { _ = try UsageReport.decode(Data(text.utf8)) }
    }

    private static func reportShape() throws {
        let report = try UsageReport.decode(Data(fixture.utf8))
        try expect(report.totals.totalCost == 3, "Wrong total")
        try expect(report.agents.map(\.displayName) == ["OpenCode", "Pi"], "Harness order")
        try expect(report.agents.first?.models.map(\.modelName) == ["gpt-6.1-sol", "cheaper-model"], "Model order")
        try expect(report.agents.last?.models.first?.displayName == "deepseek-flash-latest", "Pi path prefix")
        try expect(report.agents.last?.models.first?.cacheReadTokens == 120, "Cache tokens")
    }

    private static func emptyDay() throws {
        let data = Data(#"{"daily":[],"totals":{"totalCost":0,"totalTokens":0}}"#.utf8)
        let report = try UsageReport.decode(data)
        try expect(report.totals.totalCost == 0 && report.agents.isEmpty, "Empty day")
    }

    private static func processOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(fixture.utf8).write(to: directory.appendingPathComponent("report.json"))
        let client = CCUsageClient(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat report.json; printf 'Pricing warning' >&2"],
            directory: directory
        )
        let snapshot = try await client.fetch()
        try expect(snapshot.report.totals.totalCost == 3, "Subprocess JSON")
        try expect(snapshot.warnings == "Pricing warning", "Stderr warning")
    }

    private static func processFailure() async throws {
        let client = CCUsageClient(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'Test failure' >&2; exit 7"]
        )
        do {
            _ = try await client.fetch()
        } catch UsageError.failed(let status, let message) {
            try expect(status == 7 && message == "Test failure", "Lost exit status or stderr")
            return
        }
        throw CheckFailure(description: "Expected nonzero exit to fail")
    }

    private static func processTimeout() async throws {
        let client = CCUsageClient(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 10"],
            timeout: 0.1
        )
        let started = Date()
        do {
            _ = try await client.fetch()
        } catch UsageError.timedOut {
            try expect(Date().timeIntervalSince(started) < 5, "Stuck process was not killed")
            return
        }
        throw CheckFailure(description: "Expected deadline to fail")
    }

    private static func missingExecutable() async throws {
        let client = CCUsageClient(executable: URL(fileURLWithPath: "/does-not-exist/ccusage"))
        do {
            _ = try await client.fetch()
        } catch UsageError.missingExecutable {
            return
        }
        throw CheckFailure(description: "Expected missing executable to fail")
    }

    private static let fixture = #"""
    {
      "daily": [{
        "period": "2026-10-29",
        "agents": [
          {
            "agent": "pi", "totalCost": 1, "totalTokens": 200,
            "modelBreakdowns": [{
              "modelName": "[pi] accounts/fireworks/routers/deepseek-flash-latest",
              "cost": 1, "inputTokens": 50, "outputTokens": 20,
              "cacheCreationTokens": 10, "cacheReadTokens": 120
            }]
          },
          {
            "agent": "opencode", "totalCost": 2, "totalTokens": 300,
            "modelBreakdowns": [
              {
                "modelName": "cheaper-model", "cost": 0.5,
                "inputTokens": 40, "outputTokens": 10,
                "cacheCreationTokens": 0, "cacheReadTokens": 50
              },
              {
                "modelName": "gpt-6.1-sol", "cost": 1.5,
                "inputTokens": 50, "outputTokens": 20,
                "cacheCreationTokens": 10, "cacheReadTokens": 120
              }
            ]
          }
        ]
      }],
      "totals": {"totalCost": 3, "totalTokens": 500}
    }
    """#
}
