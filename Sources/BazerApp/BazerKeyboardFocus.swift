// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import BazerCore
import SwiftUI

struct BazerKeyInput: Equatable {
    enum Key { case left, right, tab, activate, other }
    let key: Key
    var reverse = false
    var isRepeat = false
    init(key: Key, reverse: Bool = false, isRepeat: Bool = false) {
        self.key = key; self.reverse = reverse; self.isRepeat = isRepeat
    }
    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        reverse = flags.contains(.shift)
        isRepeat = event.isARepeat
        // Arrow/keypad events carry numericPad/function, and Caps Lock is a
        // persistent state flag. Only semantic shortcut modifiers change the key.
        guard flags.intersection([.command, .option, .control]).isEmpty else { key = .other; return }
        switch event.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 48: key = .tab
        case 36, 49, 76: key = .activate
        default: key = .other
        }
    }
}

/// Candidate movement is a focus effect, never a write. Only an activation effect
/// is routed to the existing session/capability/transaction guarded model action.
enum PresetKeyboardInteraction {
    enum Effect: Equatable { case unhandled, moveFocus(Int), activate(Int), consumed }
    static func effect(input: BazerKeyInput, focusedIndex: Int?, count: Int, canActivate: Bool) -> Effect {
        guard let index = focusedIndex, (0..<count).contains(index) else { return .unhandled }
        switch input.key {
        case .left: return .moveFocus((index + count - 1) % count)
        case .right: return .moveFocus((index + 1) % count)
        case .activate: return canActivate && !input.isRepeat ? .activate(index) : .consumed
        case .tab, .other: return .unhandled
        }
    }
}

enum ModalKeyboardFocus {
    static func next(current: String?, order: [String], reverse: Bool) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return reverse ? order.last : order.first }
        return order[(index + (reverse ? order.count - 1 : 1)) % order.count]
    }
}

/// A window-local monitor lets macOS 13 consume Tab/activation before an older
/// SwiftUI responder can dispatch it to a hidden background control.
struct BazerKeyEventBridge: NSViewRepresentable {
    var isEnabled = true
    let onKey: (BazerKeyInput) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.isEnabled = isEnabled; view.onKey = onKey; return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.isEnabled = isEnabled; view.onKey = onKey }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var isEnabled = true
        var onKey: ((BazerKeyInput) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow, event.window === window else { return event }
                return self.consume(event) ? nil : event
            }
        }
        /// Also exercised with native NSEvents by the offline harness.
        func consume(_ event: NSEvent) -> Bool { isEnabled && (onKey?(BazerKeyInput(event)) ?? false) }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}

struct BazerModalFocusScope: ViewModifier {
    let focus: FocusState<String?>.Binding
    let order: [String]
    let initial: String?
    @Namespace private var scope

    func body(content: Content) -> some View {
        content
            .focusScope(scope)
            .background(BazerKeyEventBridge { input in
                guard input.key == .tab else { return false }
                focus.wrappedValue = ModalKeyboardFocus.next(current: focus.wrappedValue, order: order, reverse: input.reverse)
                return true
            })
            .task {
                await Task.yield()
                focus.wrappedValue = initial ?? order.first
            }
            .onChange(of: order) { values in
                if let focused = focus.wrappedValue, !values.contains(focused) { focus.wrappedValue = initial ?? values.first }
            }
    }
}

struct BazerFocusTarget: Hashable {
    let key: String
    static func card(_ target: HomeDeviceTarget) -> Self { Self(key: "card:\(target.id)") }
    static func heading(_ target: HomeDeviceTarget) -> Self { Self(key: "heading:\(target.id)") }
    static func menu(_ target: HomeDeviceTarget) -> Self { Self(key: "menu:\(target.id)") }
    static func presets(_ id: LogicalDeviceID, _ tab: QuickPresetTab) -> Self { Self(key: "presets:\(id.rawValue):\(tab.rawValue)") }
    static func onboard(_ id: LogicalDeviceID, _ field: OnboardEditableField) -> Self { Self(key: "onboard:\(id.rawValue):\(field == .activeProfile ? "profile" : "dpi")") }
    static func restore(_ id: LogicalDeviceID) -> Self { Self(key: "restore:\(id.rawValue)") }
    static let primaryPicker = Self(key: "primary-picker")
}

@MainActor
final class BazerFocusCoordinator: ObservableObject {
    struct Request: Equatable { let id = UUID(); let target: BazerFocusTarget }
    @Published private(set) var request: Request?
    private(set) var current: BazerFocusTarget?
    private var modalReturnTarget: BazerFocusTarget?
    private var hasModal = false
    func reset() { request = nil; current = nil; modalReturnTarget = nil; hasModal = false }
    func remember(_ target: BazerFocusTarget) { current = target }
    func move(to target: BazerFocusTarget) { request = Request(target: target) }
    func modalDidOpen() {
        guard !hasModal else { return }
        hasModal = true; modalReturnTarget = current
    }
    func modalDidClose() {
        guard hasModal else { return }
        hasModal = false
        if let target = modalReturnTarget { move(to: target) }
        modalReturnTarget = nil
    }
}

private struct BazerFocusCoordinatorKey: EnvironmentKey { static let defaultValue: BazerFocusCoordinator? = nil }
extension EnvironmentValues {
    var bazerFocusCoordinator: BazerFocusCoordinator? {
        get { self[BazerFocusCoordinatorKey.self] }
        set { self[BazerFocusCoordinatorKey.self] = newValue }
    }
}
private struct BazerRestorableFocus: ViewModifier {
    let target: BazerFocusTarget
    @Environment(\.bazerFocusCoordinator) private var coordinator
    func body(content: Content) -> some View {
        if let coordinator { BazerFocusControl(content: content, target: target, coordinator: coordinator) }
        else { content }
    }
}
private struct BazerFocusControl<Content: View>: View {
    let content: Content
    let target: BazerFocusTarget
    @ObservedObject var coordinator: BazerFocusCoordinator
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        content
            .focusable()
            .focused($focused)
            .onChange(of: focused) { if $0 { coordinator.remember(target) } }
            .onChange(of: isEnabled) { if !$0 { focused = false } }
            .onChange(of: coordinator.request) { request in
                if request == nil { focused = false }
                else if request?.target == target { focused = true }
            }
            .onAppear { if coordinator.request?.target == target { focused = true } }
    }
}
extension View {
    func bazerRestorableFocus(_ target: BazerFocusTarget) -> some View { modifier(BazerRestorableFocus(target: target)) }
}
