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
                if checkLayout {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    for contentHeight: CGFloat in [80, 320, 740] {
                        let viewport = NSHostingController(rootView:
                            ContentFittingScrollView(maximumHeight: 370) {
                                Color.clear.frame(height: contentHeight)
                            }
                        )
                        let measured = viewport.sizeThatFits(in: CGSize(width: 404, height: 0)).height
                        let expected = min(contentHeight, 370)
                        guard abs(measured - expected) < 1 else {
                            print("FAIL: \(Int(contentHeight))-point content used \(Int(measured)) points; expected \(Int(expected)).")
                            exit(1)
                        }
                        print("PASS: \(Int(contentHeight))-point content fits a \(Int(measured))-point viewport.")
                    }
                    let snapshots: [(String, UsageSnapshot?)] = [
                        ("before the first refresh", nil), ("with the current report", snapshot),
                    ]
                    for (description, snapshot) in snapshots {
                        let store = UsageStore(client: makeClient(), snapshot: snapshot)
                        let popover = UsagePopover(store: store)
                        let controller = NSHostingController(rootView: UsageView(store: store))
                        // A popup can propose zero height during initial sizing.
                        let size = controller.sizeThatFits(in: CGSize(width: 440, height: 0))
                        guard popover.contentSize == size, size.width == 440, size.height > 0,
                              popover.behavior == .transient, !popover.isShown else {
                            print("FAIL: the popover does not fit its content offscreen.")
                            exit(1)
                        }
                        print("PASS: native popover \(description) fits \(Int(size.width)) × \(Int(size.height)) points.")
                    }
                    print("PASS: short lists fit their content and long lists scroll, even with a zero-height proposal (no screenshot taken).")
                }
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
