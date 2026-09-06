import AppKit
import GhosttyKit

/// Clipboard callbacks for libghostty. Text only, standard pasteboard only.
///
/// Anything that would need a confirmation dialog is refused, so configure
/// `clipboard-read`, `clipboard-write` and `clipboard-paste-protection` in
/// ghostty.conf with definite values rather than `ask`.
enum Clipboard {
    private static let textMime = "text/plain"

    private static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        location == GHOSTTY_CLIPBOARD_STANDARD ? .general : nil
    }

    static func read(
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = GhosttyHost.shared.surface,
              let pasteboard = pasteboard(for: location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        let hasText = pasteboard.types?.contains(.string) ?? false
        var wantsText = false
        if let mimes {
            for i in 0..<mimesLen where mimes[i].map({ String(cString: $0) }) == textMime {
                wantsText = true
            }
        }

        let text = wantsText && hasText ? pasteboard.string(forType: .string) : nil
        if text == nil && !list {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        complete(surface, text: text, listText: list && hasText, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmRead(
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let surface = GhosttyHost.shared.surface else { return }
        WrapperConfig.log.info("denied clipboard request \(request.rawValue) that required confirmation")
        ghostty_surface_deny_clipboard_request(surface, state)
    }

    private static func complete(
        _ surface: ghostty_surface_t,
        text: String?,
        listText: Bool,
        state: UnsafeMutableRawPointer?
    ) {
        textMime.withCString { mime in
            let available: [UnsafePointer<CChar>?] = listText ? [mime] : []
            (text ?? "").withCString { bytes in
                let contents: [ghostty_clipboard_content_s] = text.map { text in
                    [ghostty_clipboard_content_s(mime: mime, data: bytes, len: text.utf8.count)]
                } ?? []
                contents.withUnsafeBufferPointer { contentsBuffer in
                    available.withUnsafeBufferPointer { availableBuffer in
                        var payload = ghostty_clipboard_complete_s(
                            contents: contentsBuffer.baseAddress,
                            contents_len: contentsBuffer.count,
                            available: availableBuffer.baseAddress,
                            available_len: availableBuffer.count,
                            confirmed: false,
                            remember: false)
                        ghostty_surface_complete_clipboard_request(surface, &payload, state)
                    }
                }
            }
        }
    }

    static func write(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        if confirm {
            WrapperConfig.log.info("ignored clipboard write that required confirmation")
            return
        }
        guard let pasteboard = pasteboard(for: location), let content, len > 0 else { return }

        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == textMime, let data = item.data else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }
    }
}
