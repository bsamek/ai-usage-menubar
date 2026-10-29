import AIUsageCore
import AppKit
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    private let client: CCUsageClient
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(client: CCUsageClient, snapshot: UsageSnapshot? = nil) {
        self.client = client
        self.snapshot = snapshot
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

    var isStale: Bool {
        lastError != nil || snapshot.map {
            Date().timeIntervalSince($0.fetchedAt) > 90
                || !Calendar.current.isDateInToday($0.fetchedAt)
        } == true
    }

    var label: String {
        guard let snapshot else { return isRefreshing ? "…" : "— !" }
        return "\(UsageFormat.dollars(snapshot.report.totals.totalCost))\(isStale ? " !" : "")"
    }
}
