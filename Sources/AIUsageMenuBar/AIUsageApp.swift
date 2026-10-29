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
                if checkLayout && !snapshot.report.agents.isEmpty {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    let store = UsageStore(client: makeClient(), snapshot: snapshot)
                    let controller = NSHostingController(rootView: UsageView(store: store))
                    // A menu-bar popup can propose zero height during initial sizing.
                    let size = controller.sizeThatFits(in: CGSize(width: 440, height: 0))
                    print("Dropdown layout: \(Int(size.width)) × \(Int(size.height)) points")
                    guard size.height >= 420 else {
                        print("FAIL: the dropdown's breakdown area has collapsed.")
                        exit(1)
                    }
                    print("PASS: the dropdown reserves space for the breakdown (no screenshot taken).")
                }
            } catch {
                print("AI Usage: \(error.localizedDescription)")
                exit(1)
            }
            return
        }
        AIUsageApplication.main()
    }
}

@MainActor
struct AIUsageApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: UsageStore

    init() {
        let store = UsageStore(client: makeClient())
        _store = StateObject(wrappedValue: store)
        // Start at application launch, not when the dropdown is first opened.
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            UsageView(store: store)
        } label: {
            Text(store.label).monospacedDigit()
                .help("Today's estimated AI API cost. Click for the harness and model breakdown.")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
