import AppKit
import Carbon
import GhosttyKit

/// Translation helpers between AppKit input and libghostty's input types.
/// Mirrors the logic in Ghostty's own macOS app (NSEvent+Extension.swift and
/// Ghostty.Input.swift) so key encoding behaves identically.
enum Input {
    /// Device-specific bits distinguish releasing one side while the other
    /// remains held. Caps Lock reports its toggle state instead.
    static func modifierAction(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ghostty_input_action_e? {
        let mask: UInt
        switch keyCode {
        case 0x39: mask = NSEvent.ModifierFlags.capsLock.rawValue
        case 0x38: mask = UInt(NX_DEVICELSHIFTKEYMASK)
        case 0x3C: mask = UInt(NX_DEVICERSHIFTKEYMASK)
        case 0x3B: mask = UInt(NX_DEVICELCTLKEYMASK)
        case 0x3E: mask = UInt(NX_DEVICERCTLKEYMASK)
        case 0x3A: mask = UInt(NX_DEVICELALTKEYMASK)
        case 0x3D: mask = UInt(NX_DEVICERALTKEYMASK)
        case 0x37: mask = UInt(NX_DEVICELCMDKEYMASK)
        case 0x36: mask = UInt(NX_DEVICERCMDKEYMASK)
        default: return nil
        }
        return flags.rawValue & mask != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        let raw = flags.rawValue

        if flags.contains(.shift) {
            mods |= GHOSTTY_MODS_SHIFT.rawValue
            if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        }
        if flags.contains(.control) {
            mods |= GHOSTTY_MODS_CTRL.rawValue
            if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        }
        if flags.contains(.option) {
            mods |= GHOSTTY_MODS_ALT.rawValue
            if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        }
        if flags.contains(.command) {
            mods |= GHOSTTY_MODS_SUPER.rawValue
            if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        }
        if flags.contains(.capsLock) {
            mods |= GHOSTTY_MODS_CAPS.rawValue
        }

        return ghostty_input_mods_e(mods)
    }

    static func flags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { flags.insert(.capsLock) }
        return flags
    }

    /// `ghostty_input_scroll_mods_t` is a packed struct: bit 0 = precision,
    /// bits 1-3 = momentum phase.
    static func scrollMods(precision: Bool, phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if precision { value |= 0b1 }
        let momentum: Int32
        switch phase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        value |= momentum << 1
        return value
    }

    /// Identifier of the active keyboard input source. Some keystrokes only
    /// switch the input source and must not reach the terminal.
    static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    /// True when `text` is a lone ASCII control character. Such text must
    /// not be forwarded while an IME composition is active.
    static func isControlText(_ text: String?) -> Bool {
        guard let text, text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }
}

extension NSEvent {
    /// Builds the libghostty key struct for this event. `text` is left nil;
    /// callers attach it inside a `withCString` scope.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.mods = Input.mods(modifierFlags)

        // Control and command never contribute to text translation; assume
        // everything else did.
        key.consumed_mods = Input.mods(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))

        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key.unshifted_codepoint = codepoint.value
            }
        }
        return key
    }

    /// Text to attach to a key event. Control characters are re-derived
    /// without the control modifier (libghostty encodes them itself) and
    /// private-use-area function keys are dropped.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}

extension String {
    /// Text safe to pass as `ghostty_input_key_s.text`: non-empty and not
    /// starting with an ASCII control character.
    var keyEventText: String? {
        guard let first = unicodeScalars.first else { return nil }
        if first.value < 0x20 || first.value == 0x7F { return nil }
        return self
    }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
