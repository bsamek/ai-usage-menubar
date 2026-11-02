import AIUsageCore
import AppKit
import SwiftUI

private func makeClient() -> CCUsageClient {
    let executable = ProcessInfo.processInfo.environment["AI_USAGE_CCUSAGE"].map {
        URL(fileURLWithPath: $0)
    } ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ccusage")
    return CCUsageClient(executable: executable)
}

@main
enum EntryPoint {
    @MainActor
    static func main() async {
        // Exercise the real bundled data path without creating UI or taking screenshots.
        let checkLayout = CommandLine.arguments.contains("--check-layout")
        if CommandLine.arguments.contains("--check") || checkLayout {
            do {
                let snapshot = try await makeClient().fetch()
                print("Today: \(UsageFormat.dollars(snapshot.report.totals.totalCost)) · \(snapshot.report.totals.totalTokens) tokens")
                for agent in snapshot.report.agents {
                    print("  \(agent.displayName): \(UsageFormat.dollars(agent.totalCost)) · \(agent.models.count) models")
                }
                if let warnings = snapshot.warnings { print("Warnings: \(warnings)") }
                let observation = UsageObservation.localNow()
                let hours = WorkHours.load(from: .standard)
                if let window = hours.window(on: observation.date, calendar: UsageDayContext.calendar(in: observation.timeZone)) {
                    print("Work hours: \(UsageFormat.time(window.start, timeZone: observation.timeZone))–\(UsageFormat.time(window.end, timeZone: observation.timeZone)) · \(observation.timeZone.identifier)")
                }
                switch snapshot.forecast(workHours: hours, at: observation) {
                case .projected(let total, let ended):
                    print("Projected today: ≈ \(UsageFormat.dollars(total))\(ended ? " · workday ended" : " · at today's pace")")
                case .waiting(let until):
                    print("Projected today: waiting until \(UsageFormat.time(until, timeZone: observation.timeZone)) (30-minute warm-up)")
                case .unavailable:
                    print("Projected today: unavailable for this local date/timezone")
                }
                if checkLayout { try await LayoutChecks.run(client: makeClient(), current: snapshot) }
            } catch {
                print("AI Usage: \(error.localizedDescription)")
                exit(1)
            }
            return
        }
        runApplication()
    }

    @MainActor
    private static func runApplication() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: UsageStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = UsageStore(client: makeClient())
        statusItem = UsageStatusItem(store: store)
        // Start at application launch, not when the dropdown is first opened.
        store.start()
    }
}
