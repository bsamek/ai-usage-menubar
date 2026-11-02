import AIUsageCore
import AppKit
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var workHours: WorkHours
    private let defaults: UserDefaults
    private let observe: () -> UsageObservation
    private let client: CCUsageClient
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(client: CCUsageClient, snapshot: UsageSnapshot? = nil,
         workHours: WorkHours? = nil, defaults: UserDefaults = .standard,
         observe: @escaping () -> UsageObservation = { .localNow() }) {
        self.client = client
        self.snapshot = snapshot
        self.defaults = defaults
        self.workHours = workHours ?? WorkHours.load(from: defaults)
        self.observe = observe
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await client.fetch()
            lastError = nil
        } catch {
            // Preserve the last successful total rather than displaying a false zero.
            lastError = error.localizedDescription
        }
    }

    func setWorkHours(_ hours: WorkHours) {
        workHours = hours
        hours.save(to: defaults)
    }

    var isStale: Bool {
        lastError != nil || snapshot.map { $0.isStale(at: observe()) } == true
    }

    var forecast: DailySpendForecast {
        snapshot?.forecast(workHours: workHours, at: observe()) ?? .unavailable
    }

    var workHoursLabel: String {
        let observation = observe()
        guard let window = workHours.window(on: observation.date,
                                           calendar: UsageDayContext.calendar(in: observation.timeZone)) else { return "" }
        return "\(UsageFormat.time(window.start, timeZone: observation.timeZone))–\(UsageFormat.time(window.end, timeZone: observation.timeZone))"
    }

    var timeZone: TimeZone { observe().timeZone }

    var label: String {
        guard let snapshot else { return isRefreshing ? "…" : "— !" }
        return "\(UsageFormat.dollars(snapshot.report.totals.totalCost))\(isStale ? " !" : "")"
    }
}
