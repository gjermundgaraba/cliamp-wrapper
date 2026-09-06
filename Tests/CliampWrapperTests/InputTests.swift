import AppKit
import Carbon
import GhosttyKit
import XCTest
@testable import CliampWrapper

final class InputTests: XCTestCase {
    func testModifierChordsReleaseEachSideIndependently() {
        let modifiers: [(String, UInt16, UInt16, UInt, UInt, NSEvent.ModifierFlags)] = [
            ("shift", 0x38, 0x3C, UInt(NX_DEVICELSHIFTKEYMASK), UInt(NX_DEVICERSHIFTKEYMASK), .shift),
            ("control", 0x3B, 0x3E, UInt(NX_DEVICELCTLKEYMASK), UInt(NX_DEVICERCTLKEYMASK), .control),
            ("option", 0x3A, 0x3D, UInt(NX_DEVICELALTKEYMASK), UInt(NX_DEVICERALTKEYMASK), .option),
            ("command", 0x37, 0x36, UInt(NX_DEVICELCMDKEYMASK), UInt(NX_DEVICERCMDKEYMASK), .command),
        ]

        for (name, leftKey, rightKey, leftMask, rightMask, sharedFlag) in modifiers {
            let bothHeld = NSEvent.ModifierFlags(rawValue: sharedFlag.rawValue | leftMask | rightMask)
            XCTAssertEqual(Input.modifierAction(keyCode: leftKey, flags: bothHeld), GHOSTTY_ACTION_PRESS, name)
            XCTAssertEqual(Input.modifierAction(keyCode: rightKey, flags: bothHeld), GHOSTTY_ACTION_PRESS, name)

            let rightHeld = NSEvent.ModifierFlags(rawValue: sharedFlag.rawValue | rightMask)
            XCTAssertEqual(Input.modifierAction(keyCode: leftKey, flags: rightHeld), GHOSTTY_ACTION_RELEASE, name)
            XCTAssertEqual(Input.modifierAction(keyCode: rightKey, flags: rightHeld), GHOSTTY_ACTION_PRESS, name)

            let leftHeld = NSEvent.ModifierFlags(rawValue: sharedFlag.rawValue | leftMask)
            XCTAssertEqual(Input.modifierAction(keyCode: rightKey, flags: leftHeld), GHOSTTY_ACTION_RELEASE, name)
            XCTAssertEqual(Input.modifierAction(keyCode: leftKey, flags: leftHeld), GHOSTTY_ACTION_PRESS, name)

            XCTAssertEqual(Input.modifierAction(keyCode: leftKey, flags: []), GHOSTTY_ACTION_RELEASE, name)
            XCTAssertEqual(Input.modifierAction(keyCode: rightKey, flags: []), GHOSTTY_ACTION_RELEASE, name)
        }
    }

    func testCapsLockUsesToggleState() {
        XCTAssertEqual(Input.modifierAction(keyCode: 0x39, flags: [.capsLock, .shift]), GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(Input.modifierAction(keyCode: 0x39, flags: [.shift]), GHOSTTY_ACTION_RELEASE)
    }

    func testNonModifierKeyHasNoModifierAction() {
        XCTAssertNil(Input.modifierAction(keyCode: 0x00, flags: [.shift, .capsLock]))
    }
}
