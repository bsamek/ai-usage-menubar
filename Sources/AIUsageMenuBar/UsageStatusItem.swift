import AppKit
import Combine
import SwiftUI

/// Let AppKit draw a single popover surface, rather than layering a SwiftUI
/// MenuBarExtra window background behind the usage content.
@MainActor
final class UsagePopover: NSPopover {
    private let hostingController: NSHostingController<UsageView>

    init(store: UsageStore) {
        hostingController = NSHostingController(rootView: UsageView(store: store))
        super.init()
        behavior = .transient
        contentViewController = hostingController
        hostingController.sizingOptions = [.preferredContentSize]
        fitContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func fitContent() {
        contentSize = hostingController.sizeThatFits(in: CGSize(width: 440, height: 0))
    }
}

@MainActor
final class UsageStatusItem: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let item: NSStatusItem
    private let popover: UsagePopover
    private var subscription: AnyCancellable?

    init(store: UsageStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = UsagePopover(store: store)
        super.init()
        popover.delegate = self
        if let button = item.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = "Today's estimated AI API cost so far. Click for the breakdown and daily forecast."
            button.target = self
            button.action = #selector(togglePopover)
        }
        update()
        subscription = store.objectWillChange.sink { [weak self] _ in
            // @Published sends before the new value is stored. Read it on the
            // next main-actor turn, including when a refresh resizes open content.
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    private func update() {
        item.button?.title = store.label
        popover.fitContent()
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.fitContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            item.button?.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }
}
