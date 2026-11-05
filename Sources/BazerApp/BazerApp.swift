// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI

@main
struct BazerApplication: App {
    @NSApplicationDelegateAdaptor(BazerAppDelegate.self) private var delegate

    var body: some Scene {
        // AppKit owns the only inserted status item and anchored popover.
        // A Settings scene would register Cmd-, and open an empty standard window.
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            EmptyView()
        }
    }
}

/// AppKit owns the status item and its popover so the arrow is anchored to the
/// actual menu-bar button, including when AppKit clamps it at a screen edge.
@MainActor
final class BazerStatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var lifecycle = PanelOpenSessionTracker()
    private var modelObservation: AnyCancellable?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var reduceMotionObserver: NSObjectProtocol?
    private var auditEvents: [[String: Any]] = []

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .applicationDefined
        popover.delegate = self
        updateAnimationPreference()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            // ObservableObject emits before its values change.
            DispatchQueue.main.async { [weak self] in self?.updateStatusItem() }
        }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnimationPreference() }
        }
        updateStatusItem()
    }

    @objc func togglePanel() {
        if popover.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard !popover.isShown, let button = statusItem.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let size = BazerPanelMetrics.size(visibleScreenHeight: screen?.visibleFrame.height ?? 800)
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView:
                BazerPanel(model: model, panelSize: size, onClosePanel: { [weak self] in self?.closePanel() }, presentationID: UUID())
            )
        } else if let host = popover.contentViewController as? NSHostingController<BazerPanel> {
            host.rootView = BazerPanel(model: model, panelSize: size, onClosePanel: { [weak self] in self?.closePanel() }, presentationID: UUID())
        }
        popover.contentSize = size
        updateAnimationPreference()
        // A narrow positioning rect places the native arrow exactly on the icon
        // centre. NSPopover chooses/clamps its frame against the owning screen.
        let anchor = BazerPanelMetrics.positioningRect(buttonBounds: button.bounds, imageRect: button.cell?.imageRect(forBounds: button.bounds))
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let openSessionID = lifecycle.didShow() else { return }
        model.handlePanelDidOpen(openSessionID: openSessionID)
        recordAudit(event: "didShow", sessionID: openSessionID)
        installClickMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        removeClickMonitors()
        let closedSession = lifecycle.openSessionID
        if lifecycle.didClose() {
            model.handlePanelDidClose()
            recordAudit(event: "didClose", sessionID: closedSession)
        }
    }

    private var isNativeOperationPresented: Bool {
        model.isPresentingNativeModal || model.notifications.isChanging || NSApp.modalWindow != nil
    }

    func applicationDidResignActive() {
        guard !isNativeOperationPresented else { return }
        closePanel()
    }

    func stop() {
        removeClickMonitors()
        modelObservation = nil
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Opt-in development evidence only. The recorder observes delegate events;
    /// it never opens the panel or registers a refresh on its own.
    private func recordAudit(event: String, sessionID: UUID?) {
        guard let path = ProcessInfo.processInfo.environment["BAZER_UI_AUDIT_PATH"], !path.isEmpty else { return }
        func rect(_ value: NSRect?) -> [String: Double]? {
            value.map { ["x": $0.origin.x, "y": $0.origin.y, "width": $0.width, "height": $0.height] }
        }
        let button = statusItem.button
        let buttonRect = button.flatMap { view in view.window?.convertToScreen(view.convert(view.bounds, to: nil)) }
        let anchorFrame = button.flatMap { view in
            let anchor = BazerPanelMetrics.positioningRect(buttonBounds: view.bounds, imageRect: view.cell?.imageRect(forBounds: view.bounds))
            return view.window?.convertToScreen(view.convert(anchor, to: nil))
        }
        let now = Date()
        let audioSummary: [[String: Any]] = model.bluetoothAudioDevices.map { device in
            [
                "name": device.name,
                "connection": device.connection.rawValue,
                "currentPercent": device.currentPercent(at: now) as Any? ?? NSNull(),
                "identityQuality": device.identityQuality.rawValue,
                "readStatus": device.readStatus.rawValue,
                "sessionGeneration": device.session.generation,
                "observedAt": (device.batteryReadings + device.lastReadings).map(\.observedAt).max()?.timeIntervalSince1970 as Any? ?? NSNull()
            ]
        }
        let entry: [String: Any] = [
            "event": event,
            "panelOpenRefreshIntentCount": model.panelOpenRefreshIntentCount,
            "menuBarTitle": model.menuBarTitle,
            "menuBarTooltip": model.menuBarTooltip,
            "connectedCount": model.connectedHomeDevices.count,
            "historyCount": model.historyHomeDevices.count,
            "audioDevices": audioSummary,
            "sessionID": sessionID?.uuidString ?? "",
            "time": Date().timeIntervalSince1970,
            "contentWidth": popover.contentSize.width,
            "contentHeight": popover.contentSize.height,
            "buttonFrame": rect(buttonRect) as Any? ?? NSNull(),
            "anchorFrame": rect(anchorFrame) as Any? ?? NSNull(),
            "windowFrame": rect(popover.contentViewController?.view.window?.frame) as Any? ?? NSNull(),
            "screenVisibleFrame": rect(button?.window?.screen?.visibleFrame) as Any? ?? NSNull(),
            "animates": popover.animates,
            "isNativeModalPresented": isNativeOperationPresented
        ]
        auditEvents.append(entry)
        auditEvents = Array(auditEvents.suffix(100))
        guard let data = try? JSONSerialization.data(withJSONObject: ["processID": ProcessInfo.processInfo.processIdentifier, "events": auditEvents], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: model.menuBarSymbol, accessibilityDescription: nil)
        button.image?.isTemplate = true
        button.imagePosition = model.showMenuBarPercentage ? .imageLeading : .imageOnly
        button.title = model.showMenuBarPercentage ? " \(model.menuBarTitle)" : ""
        button.toolTip = model.menuBarAccessibilityLabel
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)
    }

    private func updateAnimationPreference() {
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func installClickMonitors() {
        removeClickMonitors()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let shouldDismiss = PanelOpenSessionTracker.shouldDismissForOutsideClick(
                    isNativeModalPresented: self.isNativeOperationPresented,
                    isInsidePanel: event.window === self.popover.contentViewController?.view.window,
                    isStatusItem: event.window === self.statusItem.button?.window,
                    isMenu: event.window.map { $0.level >= .popUpMenu } ?? false
                )
                if shouldDismiss { self.closePanel() }
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isNativeOperationPresented else { return }
                self.closePanel()
            }
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
    }
}

@MainActor
final class BazerAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusController: BazerStatusItemController?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = BazerStatusItemController(model: model)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.systemDidWake() }
            }
        ]
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        statusController?.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        Task {
            await model.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.applicationDidBecomeActive() }
    func applicationDidResignActive(_ notification: Notification) { statusController?.applicationDidResignActive() }
}
