import AppKit
import SwiftUI

/// How much room a window's content has on screen.
@MainActor
enum VisibleScreen {
    private static let margin: CGFloat = 40
    private static let minimum: CGFloat = 240

    /// The height scrolling content may take: the visible height of the main screen (without menu bar and Dock) minus
    /// `chrome` (title bar, toolbar and any fixed controls around the content) and a margin.
    static func contentHeight(
        reserving chrome: CGFloat,
        visibleHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800
    ) -> CGFloat {
        max(minimum, visibleHeight - chrome - margin)
    }
}

extension View {
    /// Takes the height of its content like any other view, but scrolls once that would exceed `maxHeight`, so a window
    /// built around it never grows past the visible screen.
    func scrollsBeyond(_ maxHeight: CGFloat) -> some View {
        ScrollsBeyond(maxHeight: maxHeight, content: self)
    }
}

private struct ScrollsBeyond<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content
    @State private var overflows = false

    var body: some View {
        // Content that fits is shown as it is (no scroll view, so no scroller gutter on Macs that always show scroll
        // bars, and the window sizes itself to it). A scroll view does not report its content's height to the window,
        // so once the content overflows the scroll view gets an explicit height instead.
        if overflows {
            ScrollView { measured }
                .frame(height: maxHeight)
        } else {
            measured
        }
    }

    /// The content at its natural height, which it reports to decide between the two cases above.
    private var measured: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                overflows = $0 > maxHeight
            }
    }
}
