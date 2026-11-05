// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import BazerCore
import Foundation
import Testing
@testable import BazerApp

@Suite("Keyboard focus contract — offline")
struct KeyboardFocusTests {
    @Test func arrowsBrowseWithinTheFocusedGroupWithoutActivation() {
        var dpiFocus = 0
        let rateFocus = 1
        var activations = [Int]()
        for key in [BazerKeyInput.Key.right, .right, .left, .left, .left] {
            switch PresetKeyboardInteraction.effect(input: .init(key: key), focusedIndex: dpiFocus, count: 3, canActivate: true) {
            case .moveFocus(let index): dpiFocus = index
            case .activate(let index): activations.append(index)
            case .consumed, .unhandled: break
            }
        }
        #expect(dpiFocus == 2)
        #expect(rateFocus == 1)
        #expect(activations.isEmpty)
        #expect(PresetKeyboardInteraction.effect(input: .init(key: .right), focusedIndex: nil, count: 3, canActivate: true) == .unhandled)
    }

    @Test func activationHonoursBusyOrDisconnectedGatesAndDoesNotRepeatHeldKeys() {
        #expect(PresetKeyboardInteraction.effect(input: .init(key: .activate), focusedIndex: 1, count: 3, canActivate: true) == .activate(1))
        #expect(PresetKeyboardInteraction.effect(input: .init(key: .activate, isRepeat: true), focusedIndex: 1, count: 3, canActivate: true) == .consumed)
        #expect(PresetKeyboardInteraction.effect(input: .init(key: .activate), focusedIndex: 1, count: 3, canActivate: false) == .consumed)
        #expect(PresetKeyboardInteraction.effect(input: .init(key: .activate), focusedIndex: 5, count: 3, canActivate: true) == .unhandled)
    }

    @MainActor @Test func nativeNavigationIgnoresKeypadFunctionAndCapsLockFlags() throws {
        let cases: [(UInt16, String, NSEvent.ModifierFlags, BazerKeyInput.Key, Bool)] = [
            (123, "\u{F702}", [.numericPad, .function], .left, false),
            (124, "\u{F703}", [.numericPad, .function, .capsLock], .right, false),
            (48, "\t", [.capsLock], .tab, false),
            (48, "\t", [.capsLock, .shift], .tab, true),
            (36, "\r", [.capsLock], .activate, false),
            (49, " ", [.capsLock], .activate, false),
            (76, "\u{3}", [.numericPad, .function, .capsLock], .activate, false)
        ]
        for (code, characters, modifiers, expected, reverse) in cases {
            let decoded = BazerKeyInput(try key(code, characters: characters, modifiers: modifiers))
            #expect(decoded.key == expected)
            #expect(decoded.reverse == reverse)
        }
    }

    @MainActor @Test func nativeSemanticShortcutCombinationsStayOutsideNavigation() throws {
        for semantic: NSEvent.ModifierFlags in [.command, .option, .control] {
            for code: UInt16 in [123, 124, 48, 36, 49, 76] {
                let decoded = BazerKeyInput(try key(code, characters: "", modifiers: semantic.union([.numericPad, .function, .capsLock])))
                #expect(decoded.key == .other)
            }
        }
    }

    @MainActor @Test func nativeKeyBridgeConsumesOnePresetConfirmationAndLeavesTextEditingAlone() throws {
        let bridge = BazerKeyEventBridge.KeyView()
        var focus = 0
        var intents = [Int]()
        bridge.onKey = { input in
            switch PresetKeyboardInteraction.effect(input: input, focusedIndex: focus, count: 3, canActivate: true) {
            case .unhandled: return false
            case .moveFocus(let index): focus = index
            case .activate(let index): intents.append(index)
            case .consumed: break
            }
            return true
        }
        let right = try key(124, characters: "\u{F703}", modifiers: [.numericPad, .function])
        #expect(bridge.consume(right))
        #expect(focus == 1)
        #expect(intents.isEmpty)
        #expect(bridge.consume(try key(76, characters: "\u{3}", modifiers: [.numericPad, .capsLock])))
        #expect(bridge.consume(try key(76, characters: "\u{3}", modifiers: [.numericPad, .capsLock], repeating: true)))
        #expect(intents == [1])
        #expect(!bridge.consume(try key(0, characters: "a", modifiers: .command)))
        #expect(!bridge.consume(try key(0, characters: "中")))
        bridge.isEnabled = false // The product sets this whenever a modal/native panel is open.
        #expect(!bridge.consume(right))
        #expect(focus == 1)
        #expect(intents == [1])
    }

    @MainActor @Test func nativeModalTabHarnessCyclesBothEndsAndDoesNotInterceptFieldArrowsOrIME() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 315, height: 340), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let background = NSTextField(string: "disabled background")
        background.isEnabled = false
        let first = NSTextField(string: "first modal field")
        let last = NSTextField(string: "last modal field")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 315, height: 340))
        for (index, field) in [background, first, last].enumerated() {
            field.frame = NSRect(x: 12, y: 220 - index * 35, width: 240, height: 24)
            container.addSubview(field)
        }
        window.contentView = container
        var focused: String? = "first"
        let bridge = BazerKeyEventBridge.KeyView()
        bridge.onKey = { input in
            guard input.key == .tab else { return false }
            focused = ModalKeyboardFocus.next(current: focused, order: ["first", "last"], reverse: input.reverse)
            return window.makeFirstResponder(focused == "first" ? first : last)
        }
        #expect(window.makeFirstResponder(first))
        #expect(first.currentEditor() != nil)
        #expect(bridge.consume(try key(48, characters: "\t", modifiers: [.shift, .capsLock])))
        #expect(focused == "last")
        #expect(last.currentEditor() != nil)
        #expect(bridge.consume(try key(48, characters: "\t", modifiers: .capsLock)))
        #expect(focused == "first")
        #expect(first.currentEditor() != nil)
        #expect(background.currentEditor() == nil)
        #expect(!bridge.consume(try key(123, characters: "\u{F702}", modifiers: [.numericPad, .function])))
        #expect(!bridge.consume(try key(76, characters: "\u{3}", modifiers: .numericPad))) // TextField's local onSubmit keeps ownership.
        #expect(!bridge.consume(try key(0, characters: "中")))
        #expect(!window.isVisible)
    }

    @Test func tabOrderCanRemoveDisabledOrDeletedFieldsWithoutEscapingTheModal() {
        #expect(ModalKeyboardFocus.next(current: "save", order: ["close", "field", "cancel"], reverse: false) == "close")
        #expect(ModalKeyboardFocus.next(current: nil, order: ["close", "cancel"], reverse: true) == "cancel")
        #expect(ModalKeyboardFocus.next(current: "close", order: ["close"], reverse: false) == "close")
    }

    @MainActor @Test func allModalDismissalPathsRestoreTheirRememberedTriggerAndNavigationCanFocusTheHeading() {
        let coordinator = BazerFocusCoordinator()
        let id = LogicalDeviceID(rawValue: "synthetic:keyboard-focus")
        let target = HomeDeviceTarget.logical(id)
        let triggers: [BazerFocusTarget] = [.presets(id, .dpi), .presets(id, .pollingRate), .onboard(id, .activeProfile), .onboard(id, .defaultDPI), .restore(id), .menu(target), .primaryPicker]
        for trigger in triggers {
            coordinator.remember(trigger)
            coordinator.modalDidOpen()
            coordinator.remember(.heading(target)) // Modal focus must not overwrite the captured return target.
            coordinator.modalDidOpen() // A modal re-render is not a new focus scope.
            coordinator.modalDidClose()
            #expect(coordinator.request?.target == trigger)
            let completedRequest = coordinator.request
            coordinator.modalDidClose()
            #expect(coordinator.request == completedRequest)
        }
        coordinator.move(to: .heading(target))
        #expect(coordinator.request?.target == .heading(target))
        coordinator.move(to: .card(target))
        #expect(coordinator.request?.target == .card(target))
    }

    @MainActor private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code))
    }
}
