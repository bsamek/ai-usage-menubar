import SwiftUI

/// Fits short breakdowns exactly, while keeping long lists scrollable.
struct ContentFittingScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ContentFittingScrollLayout(maximumHeight: maximumHeight) {
            // Measure the text at its natural height, independently of the
            // scroll view. This copy is neither visible nor accessible.
            content().hidden().accessibilityHidden(true)
            ScrollView { content() }
        }
    }
}

private struct ContentFittingScrollLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let contentSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        // Ignore zero-height proposals from MenuBarExtra, without reserving
        // empty space below short content or relying on a later state update.
        return CGSize(width: contentSize.width, height: min(contentSize.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origin = CGPoint(x: bounds.minX, y: bounds.minY)
        subviews[0].place(
            at: origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
        subviews[1].place(
            at: origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
