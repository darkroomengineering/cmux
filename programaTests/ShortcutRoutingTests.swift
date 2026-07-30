import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Table-driven tests for `ShortcutRouting`, the pure keyboard shortcut matching logic
/// extracted from `AppDelegate.matchShortcutStroke(event:stroke:)` and
/// `AppDelegate.matchShortcut(event:shortcut:)`.
///
/// These tests build `NSEvent`/`ShortcutStroke`/`StoredShortcut` values directly and never
/// touch `NSApp`, `UserDefaults`, `KeyboardShortcutSettings`, or any real AppKit window — they
/// exercise `ShortcutRouting` as a free, injectable function over an explicit
/// `layoutCharacterProvider` closure.
final class ShortcutRoutingTests: XCTestCase {
    private func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }

    /// A layout character provider that never resolves a layout-aware character,
    /// forcing `ShortcutRouting.matchStroke` down the ANSI keyCode fallback path.
    private let nilLayoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = { _, _ in nil }

    // MARK: - matchStroke table

    private struct StrokeCase {
        let name: String
        let stroke: ShortcutStroke
        let modifierFlags: NSEvent.ModifierFlags
        let characters: String
        let charactersIgnoringModifiers: String
        let keyCode: UInt16
        let layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
        let expected: Bool
    }

    private func stroke(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> ShortcutStroke {
        ShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
    }

    func testMatchStrokeMatrix() {
        let cases: [StrokeCase] = [
            // MARK: Plain modifier combinations
            StrokeCase(
                name: "cmd-f plain match",
                stroke: stroke(key: "f", command: true),
                modifierFlags: [.command],
                characters: "f",
                charactersIgnoringModifiers: "f",
                keyCode: 3,
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "cmd-shift-g plain match",
                stroke: stroke(key: "g", command: true, shift: true),
                modifierFlags: [.command, .shift],
                characters: "G",
                charactersIgnoringModifiers: "g",
                keyCode: 5,
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "modifier mismatch does not match (missing shift)",
                stroke: stroke(key: "g", command: true, shift: true),
                modifierFlags: [.command],
                characters: "g",
                charactersIgnoringModifiers: "g",
                keyCode: 5,
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: false
            ),
            StrokeCase(
                name: "return key matches keyCode 36",
                stroke: stroke(key: "\r", command: true),
                modifierFlags: [.command],
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                keyCode: 36,
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "return key matches keypad enter keyCode 76",
                stroke: stroke(key: "\r", command: true),
                modifierFlags: [.command],
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                keyCode: 76,
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),

            // MARK: Digit / ANSI-keycode fallback path
            StrokeCase(
                name: "AZERTY symbol-first digit falls back to keyCode (cmd-& on ANSI 1)",
                stroke: stroke(key: "1", command: true),
                modifierFlags: [.command],
                characters: "&",
                charactersIgnoringModifiers: "&",
                keyCode: 18, // kVK_ANSI_1
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "unshifted symbol on non-digit physical key does not match digit shortcut",
                stroke: stroke(key: "8", command: true),
                modifierFlags: [.command],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 30, // kVK_ANSI_RightBracket, not a digit keyCode
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: false
            ),
            StrokeCase(
                name: "shift-digit symbol matches shifted digit key (cmd-shift-* on ANSI 8)",
                stroke: stroke(key: "8", command: true, shift: true),
                modifierFlags: [.command, .shift],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 28, // kVK_ANSI_8
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "shift-symbol from non-digit key does not match shifted digit shortcut",
                stroke: stroke(key: "8", command: true, shift: true),
                modifierFlags: [.command, .shift],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 30, // kVK_ANSI_RightBracket
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: false
            ),
            StrokeCase(
                name: "Ctrl+H ANSI fallback matches backspace control character",
                stroke: stroke(key: "h", control: true),
                modifierFlags: [.control],
                characters: "\u{8}",
                charactersIgnoringModifiers: "\u{8}",
                keyCode: 4, // kVK_ANSI_H
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "cmd-shift-RightBracket ANSI fallback on non-US layout symbol",
                stroke: stroke(key: "]", command: true, shift: true),
                modifierFlags: [.command, .shift],
                characters: "*",
                charactersIgnoringModifiers: "*",
                keyCode: 30, // kVK_ANSI_RightBracket
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "ISO angle bracket does not fall back to comma shortcut via ANSI keyCode",
                stroke: stroke(key: ",", command: true, shift: true),
                modifierFlags: [.command, .shift],
                characters: "<",
                charactersIgnoringModifiers: "<",
                keyCode: 10, // kVK_ISO_Section
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: false
            ),

            // MARK: Non-Latin input (Russian) falling back to keyCode
            StrokeCase(
                name: "Russian layout resolves ASCII via injected layout provider",
                stroke: stroke(key: "t", command: true),
                modifierFlags: [.command],
                characters: "t",
                charactersIgnoringModifiers: "\u{0435}", // Cyrillic е
                keyCode: 17, // kVK_ANSI_T
                layoutCharacterProvider: { keyCode, _ in keyCode == 17 ? "t" : nil },
                expected: true
            ),
            StrokeCase(
                name: "Russian layout falls back to ANSI keyCode when layout translation also fails",
                stroke: stroke(key: "t", command: true),
                modifierFlags: [.command],
                characters: "",
                charactersIgnoringModifiers: "\u{0435}", // Cyrillic е, non-ASCII
                keyCode: 17, // kVK_ANSI_T
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),

            // MARK: Dvorak layout via injected fake layoutCharacterProvider
            StrokeCase(
                name: "Dvorak physical I producing 'c' does not trigger Cmd+I letter shortcut",
                stroke: stroke(key: "i", command: true),
                modifierFlags: [.command],
                characters: "c",
                charactersIgnoringModifiers: "c",
                keyCode: 34, // kVK_ANSI_I
                layoutCharacterProvider: { _, _ in "i" }, // even if layout claims "i", char match wins/loses first
                expected: false
            ),
            StrokeCase(
                name: "Dvorak physical O producing 'r' matches semantic Cmd+R via direct character",
                stroke: stroke(key: "r", command: true),
                modifierFlags: [.command],
                characters: "r",
                charactersIgnoringModifiers: "r",
                keyCode: 31, // kVK_ANSI_O
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "Dvorak physical T producing 'y' does not match Cmd+Option+T letter shortcut",
                stroke: stroke(key: "t", command: true, option: true),
                modifierFlags: [.command, .option],
                characters: "y",
                charactersIgnoringModifiers: "y",
                keyCode: 17, // kVK_ANSI_T
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: false
            ),

            // MARK: Shift-symbol normalization
            StrokeCase(
                name: "shift-symbol normalization maps '?' to '/' shortcut",
                stroke: stroke(key: "/", command: true, shift: true),
                modifierFlags: [.command, .shift],
                characters: "?",
                charactersIgnoringModifiers: "?",
                keyCode: 44, // kVK_ANSI_Slash
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            ),
            StrokeCase(
                name: "shift-symbol normalization maps '{' to '[' shortcut",
                stroke: stroke(key: "[", command: true, shift: true),
                modifierFlags: [.command, .shift],
                characters: "{",
                charactersIgnoringModifiers: "{",
                keyCode: 33, // kVK_ANSI_LeftBracket
                layoutCharacterProvider: nilLayoutCharacterProvider,
                expected: true
            )
        ]

        for testCase in cases {
            let event = makeKeyEvent(
                modifierFlags: testCase.modifierFlags,
                characters: testCase.characters,
                charactersIgnoringModifiers: testCase.charactersIgnoringModifiers,
                keyCode: testCase.keyCode
            )
            let result = ShortcutRouting.matchStroke(
                event: event,
                stroke: testCase.stroke,
                layoutCharacterProvider: testCase.layoutCharacterProvider
            )
            XCTAssertEqual(result, testCase.expected, "Row failed: \(testCase.name)")
        }
    }

    // MARK: - match(event:shortcut:) chord rejection

    func testMatchRejectsChordedShortcutsEvenWhenFirstStrokeWouldMatch() {
        let chordedShortcut = StoredShortcut(
            key: "n",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "t"
        )
        XCTAssertTrue(chordedShortcut.hasChord, "Precondition: shortcut must have a chord")

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "n",
            charactersIgnoringModifiers: "n",
            keyCode: 45 // kVK_ANSI_N
        )

        // The first stroke alone would match...
        XCTAssertTrue(
            ShortcutRouting.matchStroke(
                event: event,
                stroke: chordedShortcut.firstStroke,
                layoutCharacterProvider: nilLayoutCharacterProvider
            )
        )

        // ...but `match` must reject any shortcut with a chord outright.
        XCTAssertFalse(
            ShortcutRouting.match(
                event: event,
                shortcut: chordedShortcut,
                layoutCharacterProvider: nilLayoutCharacterProvider
            )
        )
    }

    func testMatchAcceptsNonChordedShortcutMatchingFirstStroke() {
        let plainShortcut = StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        XCTAssertFalse(plainShortcut.hasChord)

        let event = makeKeyEvent(
            modifierFlags: [.command],
            characters: "n",
            charactersIgnoringModifiers: "n",
            keyCode: 45
        )

        XCTAssertTrue(
            ShortcutRouting.match(
                event: event,
                shortcut: plainShortcut,
                layoutCharacterProvider: nilLayoutCharacterProvider
            )
        )
    }
}
