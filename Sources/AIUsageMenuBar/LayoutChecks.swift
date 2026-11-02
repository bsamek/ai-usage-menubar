import AIUsageCore
import AppKit
import SwiftUI

/// Deterministic UI/model checks, without showing a window or changing saved settings.
@MainActor
enum LayoutChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Clock {
        var observation: UsageObservation
        init(_ observation: UsageObservation) { self.observation = observation }
    }

    static func run(client: CCUsageClient, current: UsageSnapshot) async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let cap: CGFloat = 370
        for contentHeight: CGFloat in [80, 320, 740] {
            let viewport = NSHostingController(rootView:
                ContentFittingScrollView(maximumHeight: cap) { Color.clear.frame(height: contentHeight) }
            )
            let measured = viewport.sizeThatFits(in: CGSize(width: 404, height: 0)).height
            try require(abs(measured - min(contentHeight, cap)) < 1, "Scroll viewport cap \(cap), content \(contentHeight), measured \(measured)")
            print("PASS: \(Int(contentHeight))-point content fits a \(Int(measured))-point viewport (cap \(Int(cap))).")
        }

        // Simulate previously saved custom hours without changing real preferences.
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var legacyArguments = arguments
        legacyArguments["forecast.workHours"] = Data(#"{"startMinute":600,"endMinute":1080}"#.utf8)
        defaults.setVolatileDomain(legacyArguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let zone = TimeZone(identifier: "America/New_York")!
        let noon = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00-05:00")!
        let clock = Clock(UsageObservation(date: noon, timeZone: zone))
        let failedClient = CCUsageClient(executable: URL(fileURLWithPath: "/does-not-exist/ccusage"))
        let longReport = try report(period: clock.observation.context.period, modelCount: 30)
        let report = try report(period: clock.observation.context.period, modelCount: 1)
        let emptyReport = try UsageReport.decode(Data(#"{"daily":[],"totals":{"totalCost":0,"totalTokens":0}}"#.utf8))
        func snapshot(_ date: Date, report: UsageReport) -> UsageSnapshot {
            UsageSnapshot(report: report, fetchedAt: date, warnings: nil,
                          context: UsageDayContext(date: date, timeZone: zone))
        }
        func store(_ snapshot: UsageSnapshot?) -> UsageStore {
            UsageStore(client: failedClient, snapshot: snapshot, observe: { clock.observation })
        }

        let initial = store(nil)
        try measure("before the first refresh", store: initial)
        await initial.refresh()
        try require(initial.snapshot == nil && initial.forecast == .unavailable, "Initial failure must not invent usage")
        try measure("after an initial refresh failure", store: initial)
        try measure("with the real current report", store: UsageStore(client: client, snapshot: current))
        let fresh = store(snapshot(noon, report: report))
        try require(fresh.forecast == .projected(total: 18, workdayEnded: false), "Noon forecast must use fixed 9–6 hours, ignoring legacy preferences")
        try require(fresh.label == "$6.00", "Menu bar must remain spend so far")
        try measure("with a projected total", store: fresh)
        try measure("with no usage", store: store(snapshot(noon, report: emptyReport)))
        try measure("with many models", store: store(snapshot(noon, report: longReport)))

        let early = noon.addingTimeInterval(-3 * 3600 + 10 * 60)
        clock.observation = UsageObservation(date: early, timeZone: zone)
        let warming = store(snapshot(early, report: report))
        try require(warming.forecast == .waiting(until: early.addingTimeInterval(20 * 60)), "Warm-up")
        try measure("during the warm-up", store: warming)
        let ended = noon.addingTimeInterval(6 * 3600)
        clock.observation = UsageObservation(date: ended, timeZone: zone)
        let evening = store(snapshot(ended, report: report))
        try require(evening.forecast == .projected(total: 6, workdayEnded: true), "End-of-day forecast")
        try measure("after work hours", store: evening)

        clock.observation = UsageObservation(date: noon.addingTimeInterval(3600), timeZone: zone)
        await fresh.refresh()
        try require(fresh.lastError != nil && fresh.isStale, "Failed refresh must mark cache stale")
        try require(fresh.snapshot?.fetchedAt == noon && fresh.label == "$6.00 !", "Failed refresh must preserve total")
        try require(fresh.forecast == .projected(total: 18, workdayEnded: false), "Failed refresh must freeze forecast")
        try measure("with a failed refresh and cached forecast", store: fresh)
        let longCached = store(snapshot(noon, report: longReport))
        await longCached.refresh()
        try measure("with many models and a cached forecast", store: longCached)

        clock.observation = UsageObservation(date: noon.addingTimeInterval(86400), timeZone: zone)
        try require(fresh.forecast == .unavailable && fresh.isStale, "Yesterday's forecast must be hidden")
        try measure("with a previous-date cache", store: fresh)
        clock.observation = UsageObservation(date: noon, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        try require(fresh.forecast == .unavailable, "Previous-timezone forecast must be hidden")
        try measure("after a timezone change", store: fresh)

        clock.observation = UsageObservation(date: noon, timeZone: zone)
        let reloaded = store(snapshot(noon, report: report))
        try require(reloaded.forecast == .projected(total: 18, workdayEnded: false), "New stores must keep the fixed workday")
        try require(reloaded.label == "$6.00", "Fixed work hours must not change menu-bar total")
        print("PASS: fixed 9–6 hours ignore legacy settings; cache retention, forecast states and menu-bar spend are unchanged (no window shown).")
    }

    private static func measure(_ description: String, store: UsageStore) throws {
        let popover = UsagePopover(store: store)
        let controller = NSHostingController(rootView: UsageView(store: store))
        let size = controller.sizeThatFits(in: CGSize(width: 440, height: 0))
        try require(abs(popover.contentSize.width - size.width) < 1 && abs(popover.contentSize.height - size.height) < 1
                    && size.width == 440 && size.height > 0 && size.height < 900
                    && popover.behavior == .transient && !popover.isShown,
                    "Popover \(description) does not fit content: \(size), native \(popover.contentSize)")
        print("PASS: native popover \(description) fits \(Int(size.width)) × \(Int(size.height)) points.")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private static func report(period: String, modelCount: Int) throws -> UsageReport {
        let models = (0..<modelCount).map { index in
            ["modelName": "example-model-\(index)", "cost": 6.0 / Double(modelCount),
             "inputTokens": 10, "outputTokens": 0, "cacheReadTokens": 0, "cacheCreationTokens": 0] as [String: Any]
        }
        let json: [String: Any] = [
            "daily": [["period": period, "agents": [["agent": "pi", "totalCost": 6,
                                                        "totalTokens": modelCount * 10, "modelBreakdowns": models]]]],
            "totals": ["totalCost": 6, "totalTokens": modelCount * 10],
        ]
        return try UsageReport.decode(JSONSerialization.data(withJSONObject: json))
    }
}
