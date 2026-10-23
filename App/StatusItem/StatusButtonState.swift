import Foundation

/// What the menu bar item's button shows, remembered so that the button is touched only for what changed.
///
/// Giving the button an image, a title or a label makes AppKit redraw the item and commit a transaction, also when the
/// new value equals the old one, and a new `NSImage` always counts as different. The item is refreshed every 30
/// seconds to keep its countdown right, and nearly always nothing it shows has changed: touching it anyway cost 5 to
/// 13 ms and several wakeups a tick, around the clock, which was most of what the idle app used.
///
/// The three parts are compared by what they are made from, not by the objects: the image by the fraction and the
/// style it is drawn with, the title by its text and whether it is dimmed, the accessibility label and tooltip by their
/// string. The image position follows the title, because it only depends on whether there is text.
struct StatusButtonState {
    /// The parts of the button a presentation changes.
    struct Changes: OptionSet {
        let rawValue: Int

        /// The ring image.
        static let image = Changes(rawValue: 1 << 0)
        /// The percentage next to the ring, and where the image sits.
        static let title = Changes(rawValue: 1 << 1)
        /// The VoiceOver label and the tooltip.
        static let accessibility = Changes(rawValue: 1 << 2)

        static let all: Changes = [.image, .title, .accessibility]
    }

    private struct ImageKey: Equatable {
        var fraction: Double?
        var style: RingStyle
    }

    private struct TitleKey: Equatable {
        var text: String?
        var isDimmed: Bool
    }

    private var image: ImageKey?
    private var title: TitleKey?
    private var label: String?

    /// Records `presentation` as what the button now shows and returns the parts that differ from what it showed
    /// before: all of them for the first one. The caller updates exactly those parts.
    mutating func update(to presentation: StatusPresentation) -> Changes {
        // The renderer draws a NaN as an empty arc; for the comparison it must also equal itself.
        let newImage = ImageKey(
            fraction: presentation.fraction.map { $0.isNaN ? 0 : $0 }, style: presentation.style)
        let newTitle = TitleKey(text: presentation.text, isDimmed: presentation.isTextDimmed)
        let newLabel = presentation.accessibilityLabel

        var changes: Changes = []
        if newImage != image {
            changes.insert(.image)
            image = newImage
        }
        if newTitle != title {
            changes.insert(.title)
            title = newTitle
        }
        if newLabel != label {
            changes.insert(.accessibility)
            label = newLabel
        }
        return changes
    }
}
