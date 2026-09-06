import AppKit

/// macOS 26 leading-aligns window titles and offers no alignment control.
/// This hides the native title and shows it as a centered toolbar item
/// instead. AppKit still owns dragging, full screen and truncation.
final class TitleToolbar: NSObject, NSToolbarDelegate {
    private static let titleItem = NSToolbarItem.Identifier("title")

    private let label = NSTextField(labelWithString: "")
    private var titleObservation: NSKeyValueObservation?

    func attach(to window: NSWindow) {
        label.font = .titleBarFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        titleObservation = window.observe(\.title, options: [.initial, .new]) { [label] window, _ in
            label.stringValue = window.title
        }

        let toolbar = NSToolbar(identifier: "title")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleItem]
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.titleItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = label
        return item
    }
}
