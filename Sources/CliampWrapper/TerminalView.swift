import AppKit
import GhosttyKit

/// The NSView libghostty renders into. libghostty installs its own
/// CAMetalLayer on this view (it requires `wantsLayer`), runs its renderer
/// thread, and expects the embedder to forward input, focus, size and scale.
///
/// Input handling follows Ghostty's own SurfaceView_AppKit.swift so key
/// encoding, IME composition and dead keys behave the same as in Ghostty.
final class TerminalView: NSView, NSTextInputClient {
    private var host: GhosttyHost { .shared }
    private var surface: ghostty_surface_t? { host.surface }

    /// Cursor requested by libghostty via the mouse-shape action.
    var cursor: NSCursor = .iBeam {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// Non-nil while inside keyDown; collects text committed by
    /// interpretKeyEvents so it can be sent with the key event.
    private var keyTextAccumulator: [String]?

    /// Marked (preedit) text from the input method.
    private var markedText = NSMutableAttributedString()

    /// Lead half of a UTF-16 surrogate pair waiting for its trail half.
    /// Unicode Hex Input delivers astral characters as two separate
    /// insertText calls; bridging either half alone yields U+FFFD.
    private var pendingLeadSurrogate: UTF16Char?

    /// Timestamp of the last command-modified key seen in performKeyEquivalent.
    /// AppKit re-sends unhandled command keys through performKeyEquivalent
    /// with the same timestamp; the second time we route it to keyDown.
    private var lastPerformKeyEvent: TimeInterval?

    private var focused = false

    /// AppKit never delivers keyUp for command chords through the responder
    /// chain, so they are caught with a local event monitor.
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    // MARK: - Surface lifecycle

    /// Called once libghostty has created the surface for this view.
    func surfaceDidAttach() {
        guard let surface else { return }
        viewDidChangeBackingProperties()
        if let screen = window?.screen {
            ghostty_surface_set_display_id(surface, screen.displayID)
        }
        focusDidChange(window?.isKeyWindow ?? false && window?.firstResponder === self)
    }

    private func focusDidChange(_ focused: Bool) {
        guard let surface, self.focused != focused else { return }
        self.focused = focused
        if !focused {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: - Window integration

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.focused, event.modifierFlags.contains(.command) else { return event }
            self.keyUp(with: event)
            return nil
        }

        center.addObserver(self, selector: #selector(windowKeyStateDidChange(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyStateDidChange(_:)),
                           name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidChangeScreen(_:)),
                           name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidChangeOcclusion(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @objc private func windowKeyStateDidChange(_ notification: Notification) {
        focusDidChange((window?.isKeyWindow ?? false) && window?.firstResponder === self)
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let surface, let screen = window?.screen else { return }
        ghostty_surface_set_display_id(surface, screen.displayID)
        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    @objc private func windowDidChangeOcclusion(_ notification: Notification) {
        guard let surface, let window else { return }
        ghostty_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDidChange(window?.isKeyWindow ?? false) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Size and scale

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let backing = convertToBacking(newSize)
        if backing.width > 0 && backing.height > 0 {
            ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        if let window {
            // Keep Core Animation from scaling the layer; libghostty renders
            // at the backing resolution itself.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backingFrame = convertToBacking(frame)
        ghostty_surface_set_content_scale(
            surface,
            backingFrame.width / frame.width,
            backingFrame.height / frame.height)

        let backing = convertToBacking(frame.size)
        if backing.width > 0 && backing.height > 0 {
            ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
        }
    }

    // MARK: - Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        // Keybindings configured in ghostty.conf win over everything.
        var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass ctrl+return through verbatim instead of the default menu equivalent.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat ctrl+/ as ctrl+_ so macOS doesn't beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"

        default:
            // Ignore synthetic zero-timestamp events (e.g. cmd+period -> escape).
            if event.timestamp == 0 { return false }

            // Only command/control chords are key equivalents worth handling.
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            // Second pass for the same event: nobody else wanted it, encode it.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
        keyDown(with: finalEvent)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // libghostty may translate modifiers (macos-option-as-alt). Build an
        // event with the translated modifiers for text interpretation.
        let translated = Input.flags(from: ghostty_surface_key_translation_mods(surface, Input.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        lastPerformKeyEvent = nil

        // A keystroke that switches the input source (a layout shortcut)
        // belongs to the system, not the terminal. Composition keeps the
        // layout, so only check outside preedit.
        let layoutBefore = markedTextBefore ? nil : Input.keyboardLayoutID
        interpretKeyEvents([translationEvent])
        if !markedTextBefore && layoutBefore != Input.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        // Composing if we have preedit, or if this key just cleared preedit
        // (that key must not be encoded either).
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let texts = keyTextAccumulator, !texts.isEmpty {
            // The IME committed text while handling this key; send the text
            // on its own. The key that caused the commit is only replayed if
            // the program still needs to see it (navigation keys).
            for text in texts where !text.isEmpty && !(composing && Input.isControlText(text)) {
                _ = sendCommittedText(action, text: text)
            }
            if Self.shouldReplayCommittedPreeditKey(translationEvent) {
                _ = sendKey(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let texts = keyTextAccumulator, !texts.isEmpty {
            // An empty entry is a surrogate half held back by insertText;
            // the key that carried it must not be encoded on its own.
            for text in texts where !text.isEmpty && !(composing && Input.isControlText(text)) {
                _ = sendKey(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if composing && Input.isControlText(event.characters) { return }
            _ = sendKey(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        // Releases are never marked composing: the encoder drops composing
        // events, which would leave a key pressed under kitty release reporting.
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !hasMarkedText(),
              let action = Input.modifierAction(keyCode: event.keyCode, flags: event.modifierFlags) else { return }
        _ = sendKey(action, event: event)
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing
        if let text = text?.keyEventText {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    /// Arrow keys that commit a preedit still mean "move" to the program.
    /// Plain left-arrow is excluded because Korean IMEs already leave the
    /// caret in place after committing.
    private static func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7E, 0x7D, 0x7C: // up, down, right
            return true
        case 0x7B: // left
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    private func sendCommittedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        let value: NSString
        switch string {
        case let attributed as NSAttributedString: value = attributed.string as NSString
        case let plain as NSString: value = plain
        default: return
        }

        // Reassemble a surrogate pair delivered in two halves. A half on its
        // own becomes empty text rather than an early return: the key event
        // that carried it must still be accounted for below, otherwise
        // keyDown falls back to sending the raw keystroke. A lone lead that
        // is not followed by its trail is dropped, like Terminal.app.
        let unit = value.length == 1 ? value.character(at: 0) : nil
        let text: String
        if let unit, UTF16.isLeadSurrogate(unit) {
            pendingLeadSurrogate = unit
            text = ""
        } else if let unit, UTF16.isTrailSurrogate(unit) {
            text = pendingLeadSurrogate.map { String(decoding: [$0, unit], as: UTF16.self) } ?? ""
            pendingLeadSurrogate = nil
        } else {
            pendingLeadSurrogate = nil
            text = value as String
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }

        // Outside keyDown (IME candidate clicked, Character Viewer, dictation)
        // there is no key event to attach to. Still send it as a key event so
        // the program sees typed input rather than a paste.
        if !text.isEmpty {
            _ = sendCommittedText(GHOSTTY_ACTION_PRESS, text: text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // libghostty reports top-left origin view points; AppKit wants
        // bottom-left origin screen coordinates.
        let viewRect = NSRect(x: x, y: frame.height - y, width: width, height: height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// Reached for chords AppKit maps to editing commands (Cmd+Period ->
    /// cancel:) and for keys interpretKeyEvents cannot turn into text. The
    /// latter are already forwarded by keyDown; swallowing them here only
    /// prevents the beep. If performKeyEquivalent deferred this exact event,
    /// send it back through the event system so it reaches keyDown and is
    /// encoded.
    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    private func sendMousePosition(_ locationInWindow: NSPoint, mods: NSEvent.ModifierFlags) {
        guard let surface else { return }
        let point = convert(locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, Input.mods(mods))
    }

    override func mouseEntered(with event: NSEvent) {
        sendMousePosition(event.locationInWindow, mods: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        // Drags keep delivering events after leaving the view.
        guard NSEvent.pressedMouseButtons == 0, let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Input.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event.locationInWindow, mods: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    /// NSEvent.buttonNumber order: left, right, middle, back, forward, then
    /// the remaining buttons in Ghostty's numbering.
    private static let mouseButtons: [ghostty_input_mouse_button_e] = [
        GHOSTTY_MOUSE_LEFT, GHOSTTY_MOUSE_RIGHT, GHOSTTY_MOUSE_MIDDLE,
        GHOSTTY_MOUSE_EIGHT, GHOSTTY_MOUSE_NINE, GHOSTTY_MOUSE_SIX, GHOSTTY_MOUSE_SEVEN,
        GHOSTTY_MOUSE_FOUR, GHOSTTY_MOUSE_FIVE, GHOSTTY_MOUSE_TEN, GHOSTTY_MOUSE_ELEVEN,
    ]

    private func sendMouseButton(_ state: ghostty_input_mouse_state_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        let index = Int(event.buttonNumber)
        let button = Self.mouseButtons.indices.contains(index) ? Self.mouseButtons[index] : GHOSTTY_MOUSE_UNKNOWN
        return ghostty_surface_mouse_button(surface, state, button, Input.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, event) { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, event) { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, event) { super.otherMouseUp(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // Same subjective 2x multiplier Ghostty uses for trackpads.
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, Input.scrollMods(precision: precision, phase: event.momentumPhase))
    }
}
