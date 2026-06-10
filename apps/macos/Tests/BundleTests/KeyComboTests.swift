@testable import Bundle
import XCTest

final class KeyComboTests: XCTestCase {
    func testDefaultComboIsCmdShiftB() {
        let combo = KeyCombo.defaultCombo
        // kVK_ANSI_B = 11
        XCTAssertEqual(combo.keyCode, 11)
        XCTAssertTrue(combo.displayString.contains("⌘"))
        XCTAssertTrue(combo.displayString.contains("⇧"))
        XCTAssertTrue(combo.displayString.contains("B"))
    }

    func testDisplayStringModifierOrder() {
        // Control + Option + Shift + Command + A
        let allMods = KeyCombo(
            keyCode: 0, // kVK_ANSI_A
            modifiers: UInt(
                (1 << 18) | // control
                (1 << 19) | // option
                (1 << 17) | // shift
                (1 << 20)   // command
            )
        )
        let display = allMods.displayString
        // Order should be ⌃ ⌥ ⇧ ⌘ A
        guard let controlIdx = display.firstIndex(of: "⌃"),
              let optionIdx = display.firstIndex(of: "⌥"),
              let shiftIdx = display.firstIndex(of: "⇧"),
              let commandIdx = display.firstIndex(of: "⌘") else {
            XCTFail("Missing modifier symbols in display string: \(display)")
            return
        }
        XCTAssertTrue(controlIdx < optionIdx)
        XCTAssertTrue(optionIdx < shiftIdx)
        XCTAssertTrue(shiftIdx < commandIdx)
    }

    func testCmdCDetectedAsConflict() {
        let cmdC = KeyCombo(
            keyCode: 8, // kVK_ANSI_C
            modifiers: UInt(1 << 20) // command
        )
        let conflicts = cmdC.potentialConflicts
        XCTAssertFalse(conflicts.isEmpty)
        XCTAssertTrue(conflicts.contains { $0.contains("Copy") })
    }

    func testDefaultComboHasNoConflicts() {
        let conflicts = KeyCombo.defaultCombo.potentialConflicts
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testCmdShift4DetectedAsScreenshotConflict() {
        let cmdShift4 = KeyCombo(
            keyCode: 21, // kVK_ANSI_4
            modifiers: UInt((1 << 20) | (1 << 17)) // command + shift
        )
        let conflicts = cmdShift4.potentialConflicts
        XCTAssertFalse(conflicts.isEmpty)
        XCTAssertTrue(conflicts.contains { $0.contains("Screenshot") })
    }

    func testCodableRoundTrip() throws {
        let original = KeyCombo(keyCode: 11, modifiers: 0x180000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEquality() {
        let a = KeyCombo(keyCode: 11, modifiers: 0x180000)
        let b = KeyCombo(keyCode: 11, modifiers: 0x180000)
        let c = KeyCombo(keyCode: 12, modifiers: 0x180000)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
