// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import BazerCore
import BazerDrivers
import BazerBluetooth
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// UI owns value snapshots only. BatteryMonitor owns the one live HID transport.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = DeviceStoreSnapshot(
        capturedAt: Date(), devices: [], primaryDeviceID: nil, isMonitoring: false,
        isSuspended: false, discoveryFailure: nil, preferencesFailure: nil
    )
    @Published private(set) var isTerminating = false
    let notifications: NotificationService
    let loginItem: LoginItemService
    private let monitor: BatteryMonitor
    private let audioMonitor: BluetoothAudioMonitor
    @Published private(set) var bluetoothAudioSnapshot = BluetoothAudioSnapshot()
    @Published private(set) var menuBarDisplay = MenuBarDisplayState()
    @Published private(set) var isRefreshingAllInformation = false
    @Published private(set) var showRefreshProgress = false
    private var audioObservationTask: Task<Void, Never>?
    private var allRefreshTask: Task<Void, Never>?
    private var refreshProgressTask: Task<Void, Never>?
    private var handledPanelOpenSessionIDs: Set<UUID> = []
    private(set) var panelOpenRefreshIntentCount = 0
    private var hasPendingPanelOpenRefresh = false
    private var hasPendingAllSettingsRefresh = false
    private var sessionFoldIdentityOverrides: [String: Bool] = [:]
    private var targetSessionKeys: [HomeDeviceTarget: String] = [:]
    private var stableProjectionOrder: [String] = []
    private var lastConnectedUIIDs: Set<String> = []
    private var retainedHomeDevices: [String: HomeDeviceProjection] = [:]
    private var quickPresetDraftSessions: [LogicalDeviceID: LogicalDeviceSessionID] = [:]
    private var activeOverlaySession: LogicalDeviceSessionID?
    private let controller: DeviceController
    @Published private(set) var settingsBusy: Set<LogicalDeviceID> = []
    @Published private(set) var settingsErrors: [LogicalDeviceID: String] = [:]
    @Published private(set) var settingsBackupPaths: [LogicalDeviceID: String] = [:]
    private var settingsTasks: [LogicalDeviceID: Task<Void, Never>] = [:]
    @Published private(set) var logicalDiscoveryBusy: Set<PhysicalDeviceID> = []
    @Published private(set) var logicalDiscoveryErrors: [PhysicalDeviceID: String] = [:]
    @Published private(set) var logicalDiscoveryMessages: [PhysicalDeviceID: String] = [:]
    private var logicalDiscoveryTasks: [PhysicalDeviceID: Task<Void, Never>] = [:]
    private var observationTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private var integrationStartupTask: Task<Void, Never>?
    private var hasStarted = false

    // MARK: - Redesigned UI Navigation, Folding, Presets & Transaction State

    @Published private(set) var route: BazerRoute = .home
    @Published private(set) var routeDirection: RouteTransitionDirection = .none
    @Published private(set) var routeVersion: Int = 0
    @Published var activeOverlay: BazerOverlay? {
        didSet {
            switch activeOverlay {
            case .quickPresetEditor(let id, _), .onboardFieldPicker(let id, _):
                activeOverlaySession = snapshot.logicalDevices.first { $0.id == id }?.sessionID
            case .restorePreview(_, let preview): activeOverlaySession = preview.request.target
            case .primaryDevicePicker, nil: activeOverlaySession = nil
            }
        }
    }
    @Published var isFoldedSectionExpanded = false
    @Published var lastVisitedDeviceTarget: HomeDeviceTarget?
    @Published var isPresentingNativeModal = false

    /// Stable session ordering of Home device targets; telemetry changes never re-sort cards (Spec §3.2).
    @Published private(set) var stableHomeOrder: [HomeDeviceTarget] = []
    /// Session-level folded targets (initialized from persisted `foldedIdentities` when `rememberFoldedDevices` is enabled).
    @Published private(set) var sessionFoldedTargets: Set<HomeDeviceTarget> = []
    private var hasInitializedFoldedFromPreferences = false
    @Published private(set) var foldUndoBanner: FoldUndoBannerState?
    private var foldUndoTask: Task<Void, Never>?
    @Published var isFoldUndoHovered = false {
        didSet {
            if isFoldUndoHovered { foldUndoTask?.cancel() }
            else if foldUndoBanner != nil { scheduleFoldUndoDismiss() }
        }
    }
    @Published var isFoldUndoFocused = false {
        didSet {
            if isFoldUndoFocused {
                foldUndoTask?.cancel()
            } else if foldUndoBanner != nil {
                scheduleFoldUndoDismiss()
            }
        }
    }

    /// Session-only quick presets for devices without a stable `preferenceIdentity`, plus unsaved modal drafts.
    @Published private(set) var sessionQuickPresets: [LogicalDeviceID: DeviceQuickPresets] = [:]
    @Published var sessionQuickPresetDrafts: [LogicalDeviceID: QuickPresetModalDraft] = [:]

    /// Per-device onboard draft (preserved when navigating to Settings and back, invalidated on session/revision change).
    @Published var onboardDrafts: [LogicalDeviceID: DeviceSettingsDraft] = [:]

    /// Active parameter switch / onboard write phase per logical device.
    @Published private(set) var pendingParameterSwitches: [LogicalDeviceID: PendingParameterSwitch] = [:]
    /// Short-lived 1.5s verified banner message per logical device (Spec §4.3).
    @Published private(set) var verifiedBannerMessages: [LogicalDeviceID: String] = [:]
    private var verifiedBannerTasks: [LogicalDeviceID: Task<Void, Never>] = [:]
    /// Inline rejection messages when a user selects an unsupported option before/during preflight.
    @Published var parameterRejectionMessages: [LogicalDeviceID: String] = [:]
    /// Devices whose last write ended in `.outcomeUnknown` and require a readback check before new writes.
    @Published private(set) var requiresReadbackCheck: Set<LogicalDeviceID> = []
    /// Last exported user backup URL per logical device for "在 Finder 中显示" (Spec §6.3).
    @Published private(set) var exportedBackupURLs: [LogicalDeviceID: URL] = [:]
    @Published private(set) var backupStatusMessages: [LogicalDeviceID: String] = [:]

    init(monitor: BatteryMonitor = .live(), notifications: NotificationService = NotificationService(),
        loginItem: LoginItemService = LoginItemService(), audioMonitor: BluetoothAudioMonitor = BluetoothAudioMonitor()) {
        self.monitor = monitor; self.audioMonitor = audioMonitor; controller = DeviceController(monitor: monitor)
        self.notifications = notifications; self.loginItem = loginItem
    }

    var presentDevices: [DeviceState] {
        let directHosts = Set(managedLogicalDevices.compactMap { device -> PhysicalDeviceID? in
            if case .direct = device.descriptor.address.target { return device.sessionID.address.hostSessionID.physicalDeviceID }; return nil
        })
        return snapshot.devices.filter { $0.hostPresence == .present && !directHosts.contains($0.id) }
    }
    var removedDevices: [DeviceState] { snapshot.devices.filter { $0.hostPresence == .removed } }
    var receiverChildren: [LogicalDeviceState] {
        snapshot.logicalDevices.filter { if case .receiver = $0.descriptor.address.target { return $0.hostPresence == .present }; return false }
    }
    var logicalDiscoveryHosts: [DeviceState] {
        snapshot.devices.filter { $0.hostPresence == .present && $0.managesLogicalTargets }
    }
    func canRediscoverLogicalDevices(_ hostID: PhysicalDeviceID) -> Bool {
        snapshot.isMonitoring && !snapshot.isSuspended && !isTerminating
        && !logicalDiscoveryBusy.contains(hostID) && logicalDiscoveryHosts.contains { $0.id == hostID }
    }
    var managedLogicalDevices: [LogicalDeviceState] {
        snapshot.logicalDevices.filter { child in
            guard child.hostPresence == .present else { return false }
            if case .receiver = child.descriptor.address.target { return true }
            return snapshot.devices.contains { $0.id == child.sessionID.address.hostSessionID.physicalDeviceID && $0.managesLogicalTargets }
        }
    }
    func managedDirectLogicalDevice(for host: PhysicalDeviceID) -> LogicalDeviceState? {
        guard snapshot.devices.contains(where: { $0.id == host && $0.managesLogicalTargets }) else { return nil }
        return snapshot.logicalDevices.first { child in
            if case .direct = child.descriptor.address.target { return child.sessionID.address.hostSessionID.physicalDeviceID == host }; return false
        }
    }
    /// Resolves the logical settings/telemetry state for any direct or receiver logical device.
    func associatedLogicalDevice(for target: HomeDeviceTarget) -> LogicalDeviceState? {
        switch target {
        case .logical(let id):
            return snapshot.logicalDevices.first { $0.id == id } ?? homeDevices.first { $0.target == target }?.logical
        case .bluetoothAudio: return nil
        case .physical(let hostID):
            if let managed = managedDirectLogicalDevice(for: hostID) { return managed }
            return snapshot.logicalDevices.first { $0.id == .direct(hostID) }
        }
    }
    func associatedPhysicalDevice(for target: HomeDeviceTarget) -> DeviceState? {
        switch target {
        case .bluetoothAudio: return nil
        case .physical(let id):
            return snapshot.devices.first { $0.id == id } ?? homeDevices.first { $0.target == target }?.physical
        case .logical(let id):
            guard let logical = associatedLogicalDevice(for: .logical(id)) else { return nil }
            let session = logical.sessionID.address.hostSessionID
            return (snapshot.devices + snapshot.historicalDevices).first { $0.sessionID == session }
        }
    }

    var bluetoothAudioDevices: [BluetoothAudioDevice] {
        bluetoothAudioSnapshot.devices.map { device in
            var presented = device
            if let key = device.preferenceIdentity, let alias = snapshot.preferences.aliases[key], !alias.isEmpty { presented.name = alias }
            return presented
        }
    }
    func associatedBluetoothAudioDevice(for target: HomeDeviceTarget) -> BluetoothAudioDevice? {
        guard case .bluetoothAudio(let id) = target else { return nil }
        return bluetoothAudioDevices.first { $0.id == id } ?? homeDevices.first { $0.target == target }?.audio
    }
    var homeDevices: [HomeDeviceProjection] {
        let all = projectedHomeDevices()
        let ranks = Dictionary(uniqueKeysWithValues: stableProjectionOrder.enumerated().map { ($0.element, $0.offset) })
        return all.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
    }
    var connectedHomeDevices: [HomeDeviceProjection] { homeDevices.filter { !$0.isHistory } }
    var historyHomeDevices: [HomeDeviceProjection] { homeDevices.filter(\.isHistory) }
    func homeDeviceProjection(for target: HomeDeviceTarget) -> HomeDeviceProjection? { homeDevices.first { $0.target == target } }
    var isRefreshing: Bool { isRefreshingAllInformation || !logicalDiscoveryBusy.isEmpty || presentDevices.contains(where: \.isRefreshing) || managedLogicalDevices.contains(where: \.isRefreshing) }
    var canRefresh: Bool { snapshot.isMonitoring && !snapshot.isSuspended && !isTerminating }
    var showMenuBarPercentage: Bool { snapshot.preferences.showMenuBarPercentage }
    var rememberFoldedDevices: Bool { snapshot.preferences.rememberFoldedDevices }
    var appearanceMode: BazerAppearanceMode { snapshot.preferences.appearanceMode }
    var menuBarTitle: String { menuBarDisplay.title }
    var menuBarSymbol: String { isTerminating ? "hourglass" : menuBarDisplay.symbol }
    var menuBarAccessibilityLabel: String { menuBarDisplay.accessibilityLabel }
    var menuBarTooltip: String { menuBarAccessibilityLabel }
    var menuBarSelectedDeviceName: String { menuBarDisplay.selectedUIID == nil ? "自动选择" : menuBarDisplay.name }

    // MARK: - Home Card List & Folding Logic (Spec §3)

    /// Current active devices to display on the Home screen in stable discovery order.
    var currentHomeTargets: [HomeDeviceTarget] { connectedHomeDevices.map(\.target) }

    var regularHomeTargets: [HomeDeviceTarget] {
        currentHomeTargets.filter { !isDeviceFolded($0) }
    }

    var foldedHomeTargets: [HomeDeviceTarget] {
        currentHomeTargets.filter { isDeviceFolded($0) }
    }

    func preferenceIdentity(for target: HomeDeviceTarget) -> DevicePreferenceIdentity? {
        switch target {
        case .bluetoothAudio:
            return associatedBluetoothAudioDevice(for: target)?.preferenceIdentity.map { DevicePreferenceIdentity(kind: .verifiedBluetoothAudio, rawValue: $0) }
        case .logical(let id):
            guard let device = associatedLogicalDevice(for: .logical(id)),
                  !device.descriptor.isIdentityAmbiguous else { return nil }
            return device.descriptor.preferenceIdentity
        case .physical(let id):
            if let logical = associatedLogicalDevice(for: .physical(id)), !logical.descriptor.isIdentityAmbiguous,
               let identity = logical.descriptor.preferenceIdentity {
                return identity
            }
            return snapshot.devices.first(where: { $0.id == id })?.preferenceIdentity
        }
    }

    func displayName(for target: HomeDeviceTarget) -> String {
        switch target {
        case .bluetoothAudio: return associatedBluetoothAudioDevice(for: target)?.name ?? "耳机"
        case .logical(let id):
            return associatedLogicalDevice(for: .logical(id))?.displayName ?? "设备"
        case .physical(let id):
            if let logical = associatedLogicalDevice(for: .physical(id)), let alias = logical.alias, !alias.isEmpty {
                return alias
            }
            return snapshot.devices.first(where: { $0.id == id })?.displayName ?? homeDeviceProjection(for: target)?.name ?? "设备"
        }
    }

    func isPrimary(for target: HomeDeviceTarget) -> Bool { menuBarDisplay.selectedTarget == target }

    func isDeviceFolded(_ target: HomeDeviceTarget) -> Bool {
        if let key = preferenceIdentity(for: target)?.rawValue, let override = sessionFoldIdentityOverrides[key] { return override }
        if sessionFoldedTargets.contains(target) { return true }
        if snapshot.preferences.rememberFoldedDevices,
           let key = preferenceIdentity(for: target)?.rawValue,
           snapshot.preferences.foldedIdentities.contains(key) {
            return true
        }
        return false
    }

    func toggleDeviceFolded(_ target: HomeDeviceTarget, showUndo: Bool = true) {
        setDeviceFolded(!isDeviceFolded(target), for: target, showUndo: showUndo)
    }

    func setDeviceFolded(_ folded: Bool, for target: HomeDeviceTarget, showUndo: Bool = true) {
        guard !isTerminating else { return }
        if folded {
            sessionFoldedTargets.insert(target)
        } else {
            sessionFoldedTargets.remove(target)
        }
        let identity = preferenceIdentity(for: target)
        if let key = identity?.rawValue {
            sessionFoldIdentityOverrides[key] = folded
        }
        if let key = identity?.rawValue, snapshot.preferences.rememberFoldedDevices {
            Task { _ = await monitor.setDeviceFolded(folded, identityKey: key) }
        }
        if !folded && foldedHomeTargets.isEmpty {
            isFoldedSectionExpanded = false
        }
        if showUndo {
            let banner = FoldUndoBannerState(
                target: target,
                deviceName: displayName(for: target),
                wasFolded: folded,
                isSessionOnly: identity == nil || !snapshot.preferences.rememberFoldedDevices
            )
            foldUndoBanner = banner
            scheduleFoldUndoDismiss()
        }
    }

    func undoLastFoldAction() {
        guard let banner = foldUndoBanner else { return }
        foldUndoTask?.cancel()
        foldUndoBanner = nil
        setDeviceFolded(!banner.wasFolded, for: banner.target, showUndo: false)
    }

    private func scheduleFoldUndoDismiss() {
        foldUndoTask?.cancel()
        guard let currentID = foldUndoBanner?.id else { return }
        foldUndoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.isFoldUndoFocused && !self.isFoldUndoHovered && self.foldUndoBanner?.id == currentID {
                self.foldUndoBanner = nil
            }
        }
    }

    func setRememberFoldedDevices(_ remember: Bool) {
        guard !isTerminating else { return }
        // Sync current folded state into sessionFoldedTargets so turning off persistence keeps current session grouping.
        for target in currentHomeTargets where isDeviceFolded(target) {
            sessionFoldedTargets.insert(target)
        }
        let activeKeys = Set(sessionFoldedTargets.compactMap { preferenceIdentity(for: $0)?.rawValue })
        Task { _ = await monitor.setRememberFoldedDevices(remember, activeFoldedKeys: activeKeys) }
    }

    func setShowMenuBarPercentage(_ show: Bool) {
        guard !isTerminating else { return }
        Task { [weak self, monitor] in
            _ = await monitor.setShowMenuBarPercentage(show)
            self?.consume(await monitor.snapshot())
        }
    }

    func setAppearanceMode(_ mode: BazerAppearanceMode) {
        guard !isTerminating else { return }
        Task { [weak self, monitor] in
            _ = await monitor.setAppearanceMode(mode)
            self?.consume(await monitor.snapshot())
        }
    }

    // MARK: - Navigation Actions (Spec §2.1 & §9.1–§9.3)

    func navigateToDevice(_ target: HomeDeviceTarget) {
        lastVisitedDeviceTarget = target
        routeDirection = .forwardHorizontal
        activeOverlay = nil
        routeVersion += 1
        route = .device(target)
        if let logical = associatedLogicalDevice(for: target),
           logical.capabilities.canReadSettings,
           logical.settings == nil,
           !logical.isReadingSettings,
           !settingsBusy.contains(logical.id),
           logical.settingsFailure == nil {
            readSettings(logical.id)
        }
    }

    func navigateToHome() {
        guard !route.isHome else { return }
        routeDirection = route.isSettings ? .exitVertical : .backwardHorizontal
        activeOverlay = nil
        routeVersion += 1
        route = .home
    }

    func navigateToSettings() {
        guard !route.isSettings else { return }
        let origin: BazerSettingsOrigin
        if case .device(let target) = route {
            origin = .device(target)
        } else {
            origin = .home
        }
        routeDirection = .enterVertical
        activeOverlay = nil
        routeVersion += 1
        route = .settings(origin: origin)
    }

    func navigateBackFromSettings() {
        guard case .settings(let origin) = route else {
            navigateToHome()
            return
        }
        routeDirection = .exitVertical
        activeOverlay = nil
        routeVersion += 1
        switch origin {
        case .home:
            route = .home
        case .device(let target):
            route = .device(target)
        }
    }

    func navigateFromSettingsToDeviceList() {
        routeDirection = .exitVertical
        activeOverlay = nil
        routeVersion += 1
        route = .home
    }

    /// Returns `true` if an overlay consumed the Escape key, or `false` if the outer panel should close.
    func handleEscapeKey() -> Bool {
        if activeOverlay != nil {
            activeOverlay = nil
            return true
        }
        return false
    }

    /// Called when the outer MenuBarExtra window closes. Native file panels or system alerts do not reset session state.
    func handlePanelDidClose() {
        guard !isPresentingNativeModal else { return }
        route = .home
        routeDirection = .none
        lastVisitedDeviceTarget = nil
        activeOverlay = nil
        isFoldedSectionExpanded = false
        sessionQuickPresetDrafts.removeAll(); quickPresetDraftSessions.removeAll()
        foldUndoTask?.cancel()
        foldUndoBanner = nil
    }

    // MARK: - Quick Presets Management (Spec §5)

    func dpiPresets(for device: LogicalDeviceState) -> [DPISetting] {
        if !device.descriptor.isIdentityAmbiguous,
           let key = device.descriptor.preferenceIdentity?.rawValue,
           let saved = snapshot.preferences.quickPresets[key]?.dpiPresets,
           !saved.isEmpty {
            return Array(saved.prefix(QuickPresetModalDraft.maxCount))
        }
        if let sessionSaved = sessionQuickPresets[device.id]?.dpiPresets, !sessionSaved.isEmpty {
            return Array(sessionSaved.prefix(QuickPresetModalDraft.maxCount))
        }
        return Self.defaultDPIPresets(for: device)
    }

    func pollingRatePresets(for device: LogicalDeviceState) -> [Int] {
        if !device.descriptor.isIdentityAmbiguous,
           let key = device.descriptor.preferenceIdentity?.rawValue,
           let saved = snapshot.preferences.quickPresets[key]?.pollingRatePresets,
           !saved.isEmpty {
            return Array(saved.prefix(QuickPresetModalDraft.maxCount))
        }
        if let sessionSaved = sessionQuickPresets[device.id]?.pollingRatePresets, !sessionSaved.isEmpty {
            return Array(sessionSaved.prefix(QuickPresetModalDraft.maxCount))
        }
        return Self.defaultPollingRatePresets(for: device)
    }

    static func defaultDPIPresets(for device: LogicalDeviceState) -> [DPISetting] {
        let base = [400, 800, 1600, 3200]
        if let constraints = QuickPresetModalDraft.effectiveDPIConstraints(device.capabilities) {
            let valid = base.filter { constraints.accepts($0) }.map { DPISetting(UInt16($0)) }
            if !valid.isEmpty { return valid }
            if !constraints.allowedValues.isEmpty {
                return Array(constraints.allowedValues.prefix(4)).map { DPISetting(UInt16($0)) }
            }
        }
        if let stages = device.settings?.settings.stages?.stages, !stages.isEmpty {
            var unique: [DPISetting] = []
            for stage in stages where !unique.contains(stage.dpi) {
                unique.append(stage.dpi)
            }
            if !unique.isEmpty { return Array(unique.prefix(4)) }
        }
        return base.map { DPISetting(UInt16($0)) }
    }

    static func defaultPollingRatePresets(for device: LogicalDeviceState) -> [Int] {
        if let constraints = QuickPresetModalDraft.effectiveRateConstraints(device.capabilities),
           !constraints.allowedValues.isEmpty {
            return Array(constraints.allowedValues.prefix(4))
        }
        return [125, 500, 1000]
    }

    func openQuickPresetEditor(for device: LogicalDeviceState, tab: QuickPresetTab) {
        guard isCurrentLogicalSession(device.sessionID) else {
            sessionQuickPresetDrafts.removeValue(forKey: device.id); quickPresetDraftSessions.removeValue(forKey: device.id)
            activeOverlay = nil; return
        }
        if quickPresetDraftSessions[device.id] != device.sessionID { sessionQuickPresetDrafts.removeValue(forKey: device.id) }
        quickPresetDraftSessions[device.id] = device.sessionID
        if var existing = sessionQuickPresetDrafts[device.id] {
            existing.activeTab = tab
            existing.saveError = nil
            sessionQuickPresetDrafts[device.id] = existing
        } else {
            sessionQuickPresetDrafts[device.id] = QuickPresetModalDraft(
                activeTab: tab,
                dpiPresets: dpiPresets(for: device),
                ratePresets: pollingRatePresets(for: device)
            )
        }
        activeOverlay = .quickPresetEditor(deviceID: device.id, initialTab: tab)
    }

    func cancelQuickPresetEditor(for deviceID: LogicalDeviceID) {
        quickPresetDraftSessions.removeValue(forKey: deviceID)
        sessionQuickPresetDrafts.removeValue(forKey: deviceID)
        if case .quickPresetEditor(let activeID, _) = activeOverlay, activeID == deviceID {
            activeOverlay = nil
        }
    }

    func closeQuickPresetEditorKeepingDraft(for deviceID: LogicalDeviceID) {
        if case .quickPresetEditor(let activeID, _) = activeOverlay, activeID == deviceID {
            activeOverlay = nil
        }
    }

    /// Saves only Bazer's local quick-preset preferences; never switches current device parameters or writes onboard.
    func saveQuickPresetDraft(for device: LogicalDeviceState) async -> Bool {
        guard isCurrentLogicalSession(device.sessionID), quickPresetDraftSessions[device.id] == device.sessionID,
              var draft = sessionQuickPresetDrafts[device.id] else { return false }
        let savedDPI = dpiPresets(for: device)
        let savedRates = pollingRatePresets(for: device)
        guard draft.canSave(comparedTo: savedDPI, savedRates: savedRates, capabilities: device.capabilities),
              let newDPI = draft.parsedDPIs,
              let newRates = draft.parsedRates else {
            return false
        }
        let presets = DeviceQuickPresets(dpiPresets: newDPI, pollingRatePresets: newRates)
        if !device.descriptor.isIdentityAmbiguous, let key = device.descriptor.preferenceIdentity?.rawValue {
            let ok = await monitor.setQuickPresets(presets, for: key)
            if !ok {
                draft.saveError = "选项未能保存"
                sessionQuickPresetDrafts[device.id] = draft
                return false
            }
        }
        guard isCurrentLogicalSession(device.sessionID), quickPresetDraftSessions[device.id] == device.sessionID else { return false }
        sessionQuickPresets[device.id] = presets
        sessionQuickPresetDrafts.removeValue(forKey: device.id)
        if case .quickPresetEditor(let activeID, _) = activeOverlay, activeID == device.id {
            activeOverlay = nil
        }
        return true
    }

    // MARK: - Single-Select Radio Switching & Onboard Transactions (Spec §4.2, §4.3, §6)

    func canWriteDPI(for device: LogicalDeviceState) -> Bool {
        guard isCurrentLogicalSession(device.sessionID), device.hostPresence == .present, !device.descriptor.isIdentityAmbiguous else { return false }
        return device.capabilities.permits(.dpiWrite)
            || device.capabilities.permits(.stageSelect)
            || (device.capabilities.permits(.stagesWrite) && device.capabilities.permits(.onboardPersist))
    }

    func dpiWriteScope(for device: LogicalDeviceState) -> SettingPersistence? {
        guard canWriteDPI(for: device) else { return nil }
        if device.capabilities.permits(.dpiWrite) {
            let scopes = device.capabilities[.dpiWrite].constraints.persistenceScopes
            if scopes.contains(.runtime) { return .runtime }
            if scopes.contains(.onboard) && device.capabilities.permits(.onboardPersist) { return .onboard }
        }
        if device.capabilities.permits(.stageSelect),
           device.capabilities[.stageSelect].constraints.persistenceScopes.contains(.runtime) {
            return .runtime
        }
        if device.capabilities.permits(.stagesWrite),
           device.capabilities[.stagesWrite].constraints.persistenceScopes.contains(.onboard),
           device.capabilities.permits(.onboardPersist) {
            return .onboard
        }
        return nil
    }

    func canWritePollingRate(for device: LogicalDeviceState) -> Bool {
        guard isCurrentLogicalSession(device.sessionID), device.hostPresence == .present, !device.descriptor.isIdentityAmbiguous else { return false }
        guard device.capabilities.permits(.pollingRateWrite) else { return false }
        let scopes = device.capabilities[.pollingRateWrite].constraints.persistenceScopes
        return scopes.contains(.runtime) || (scopes.contains(.onboard) && device.capabilities.permits(.onboardPersist))
    }

    func pollingRateWriteScope(for device: LogicalDeviceState) -> SettingPersistence? {
        guard canWritePollingRate(for: device) else { return nil }
        let scopes = device.capabilities[.pollingRateWrite].constraints.persistenceScopes
        if scopes.contains(.runtime) { return .runtime }
        if scopes.contains(.onboard) && device.capabilities.permits(.onboardPersist) { return .onboard }
        return nil
    }

    func selectDPIPreset(_ targetDPI: DPISetting, for device: LogicalDeviceState) {
        guard device.hostPresence == .present,
              !isTerminating,
              !snapshot.isSuspended,
              !settingsBusy.contains(device.id),
              !device.isReadingSettings,
              !requiresReadbackCheck.contains(device.id),
              let settings = device.settings else { return }

        // Rule 1: Clicking already-confirmed DPI is a no-op (never sends duplicate write).
        if settings.settings.currentDPI == targetDPI { return }

        parameterRejectionMessages.removeValue(forKey: device.id)
        settingsErrors.removeValue(forKey: device.id)

        var candidateRequest: SettingChangeRequest?

        if device.capabilities.permits(.dpiWrite), let scope = dpiWriteScope(for: device) {
            let change = DeviceSettingsChange(currentDPI: targetDPI, persistence: scope)
            let issues = change.validate(capabilities: device.capabilities)
            if issues.isEmpty {
                candidateRequest = SettingChangeRequest(target: settings.session, expectedRevision: settings.revision, change: change)
            } else {
                parameterRejectionMessages[device.id] = issues.first?.reason ?? "当前设备不支持此 DPI 值"
                return
            }
        } else if device.capabilities.permits(.stageSelect),
                  let table = settings.settings.stages,
                  let matchingStage = table.stages.first(where: { $0.dpi == targetDPI }),
                  device.capabilities[.stageSelect].constraints.accepts(Int(matchingStage.id)) {
            let change = DeviceSettingsChange(persistence: .runtime, currentStageID: matchingStage.id)
            if change.validate(capabilities: device.capabilities).isEmpty {
                candidateRequest = SettingChangeRequest(target: settings.session, expectedRevision: settings.revision, change: change)
            }
        }

        if candidateRequest == nil,
           device.capabilities.permits(.stagesWrite),
           device.capabilities.permits(.onboardPersist),
           let table = settings.settings.stages,
           !table.stages.isEmpty,
           !table.opaqueBytes.isEmpty {
            let updatedStages = table.stages.map { stage in
                stage.id == table.activeStageID ? DPIStage(id: stage.id, dpi: targetDPI) : stage
            }
            let newTable = DPIStageTable(
                stages: updatedStages,
                activeStageID: table.activeStageID,
                opaqueBytes: table.opaqueBytes,
                defaultStageID: table.defaultStageID
            )
            let change = DeviceSettingsChange(stages: newTable, persistence: .onboard)
            let issues = change.validate(capabilities: device.capabilities)
            if issues.isEmpty {
                candidateRequest = SettingChangeRequest(target: settings.session, expectedRevision: settings.revision, change: change)
            } else {
                parameterRejectionMessages[device.id] = issues.first?.reason ?? "当前设备不支持此 DPI 值"
                return
            }
        }

        guard let request = candidateRequest else {
            parameterRejectionMessages[device.id] = "当前设备不支持切换到 \(QuickPresetRowDraft.formatDPI(targetDPI)) DPI"
            return
        }

        pendingParameterSwitches[device.id] = PendingParameterSwitch(
            sessionID: settings.session,
            kind: .dpi(targetDPI),
            startedAt: Date()
        )
        applySettings(request)
    }

    func selectPollingRatePreset(_ targetHz: Int, for device: LogicalDeviceState) {
        guard device.hostPresence == .present,
              !isTerminating,
              !snapshot.isSuspended,
              !settingsBusy.contains(device.id),
              !device.isReadingSettings,
              !requiresReadbackCheck.contains(device.id),
              let settings = device.settings else { return }

        // Rule 1: Clicking already-confirmed polling rate is a no-op.
        if settings.settings.pollingRateHz == targetHz { return }

        parameterRejectionMessages.removeValue(forKey: device.id)
        settingsErrors.removeValue(forKey: device.id)

        guard let scope = pollingRateWriteScope(for: device) else {
            parameterRejectionMessages[device.id] = "当前设备不支持修改回报率"
            return
        }

        let change = DeviceSettingsChange(pollingRateHz: targetHz, persistence: scope)
        let issues = change.validate(capabilities: device.capabilities)
        guard issues.isEmpty else {
            parameterRejectionMessages[device.id] = issues.first?.reason ?? "当前设备不支持 \(targetHz) Hz"
            return
        }

        let request = SettingChangeRequest(target: settings.session, expectedRevision: settings.revision, change: change)
        pendingParameterSwitches[device.id] = PendingParameterSwitch(
            sessionID: settings.session,
            kind: .pollingRate(targetHz),
            startedAt: Date()
        )
        applySettings(request)
    }

    func onboardDraft(for device: LogicalDeviceState) -> DeviceSettingsDraft? {
        guard let settings = device.settings else { return nil }
        if let existing = onboardDrafts[device.id],
           existing.snapshot.session == device.sessionID,
           existing.snapshot.revision == settings.revision {
            return existing
        }
        return DeviceSettingsDraft(settings, scope: .onboard)
    }

    func updateOnboardDraft(_ draft: DeviceSettingsDraft, for deviceID: LogicalDeviceID) {
        guard draft.snapshot.session.deviceID == deviceID, isCurrentLogicalSession(draft.snapshot.session) else { return }
        onboardDrafts[deviceID] = draft
    }

    func saveOnboardDraft(for device: LogicalDeviceState) {
        guard let draft = onboardDraft(for: device),
              draft.snapshot.session == device.sessionID,
              draft.snapshot.revision == device.settings?.revision else { return }
        let scope: SettingPersistence = device.capabilities.permits(.onboardPersist) ? .onboard : .runtime
        guard let request = draft.request(capabilities: device.capabilities, scope: scope) else { return }
        pendingParameterSwitches[device.id] = PendingParameterSwitch(
            sessionID: device.sessionID,
            kind: .onboardSave(.backingUp),
            startedAt: Date()
        )
        applySettings(request)
    }

    // MARK: - Backup & Restore Workflows (Spec §6.3)

    func exportBackupByUser(for device: LogicalDeviceState) {
        guard !isTerminating,
              !snapshot.isSuspended,
              device.hostPresence == .present,
              !device.descriptor.isIdentityAmbiguous,
              !settingsBusy.contains(device.id) else { return }

        let deviceID = device.id
        let safeName = device.displayName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultFilename = "Bazer-\(safeName)-\(formatter.string(from: Date())).json"

        isPresentingNativeModal = true
        let panel = NSSavePanel()
        panel.title = "备份设备配置"
        panel.message = "保存 \(device.displayName) 的当前可验证配置备份"
        panel.nameFieldStringValue = defaultFilename
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        let response = panel.runModal()
        isPresentingNativeModal = false
        guard response == .OK, let destinationURL = panel.url else { return }

        // LocalPrivateFile requires a new file path; if NSSavePanel chose an existing path to overwrite, remove it first.
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let reference = device.capabilities.permits(.stagesWrite) ? device.capabilities[.stagesWrite].source : nil
        startSettingsAction(deviceID, expectedSession: device.sessionID) { [weak self, controller] in
            _ = try await controller.exportProfile(
                logicalDeviceID: deviceID,
                saveTo: destinationURL,
                hardwareEvidenceReference: reference, expectedSession: device.sessionID
            )
            await MainActor.run {
                guard self?.isCurrentLogicalSession(device.sessionID) == true else { return }
                self?.exportedBackupURLs[deviceID] = destinationURL
                self?.backupStatusMessages[deviceID] = "已保存备份：\(destinationURL.lastPathComponent)"
            }
        }
    }

    func revealBackupInFinder(for deviceID: LogicalDeviceID) {
        if let url = exportedBackupURLs[deviceID], FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let path = settingsBackupPaths[deviceID], FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    func beginRestoreBackupByUser(for device: LogicalDeviceState) {
        guard !isTerminating,
              !snapshot.isSuspended,
              device.hostPresence == .present,
              !device.descriptor.isIdentityAmbiguous,
              !settingsBusy.contains(device.id) else { return }

        isPresentingNativeModal = true
        let panel = NSOpenPanel()
        panel.title = "选择要恢复的备份文件"
        panel.message = "将核对设备身份、备份格式、完整性与当前连接"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let response = panel.runModal()
        isPresentingNativeModal = false
        guard response == .OK, let backupURL = panel.url else { return }

        let deviceID = device.id
        let deviceName = device.displayName
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let rollbackURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bazer/Backups", isDirectory: true)
            .appendingPathComponent("pre-restore-\(formatter.string(from: Date()))-\(UUID().uuidString).json")
        let reference = device.capabilities.permits(.stagesWrite) ? device.capabilities[.stagesWrite].source : nil

        startSettingsAction(deviceID, expectedSession: device.sessionID) { [weak self, controller] in
            let loadedBackup = try FileProfileBackup(url: backupURL).load()
            let request = try await controller.prepareProfileRestore(
                backupURL: backupURL,
                rollbackBackupURL: rollbackURL,
                logicalDeviceID: deviceID,
                hardwareEvidenceReference: reference, expectedSession: device.sessionID
            )
            await MainActor.run {
                guard let self, self.isCurrentLogicalSession(device.sessionID) else { return }
                self.didSaveBackup(rollbackURL.path, for: deviceID, session: device.sessionID)
                let currentSettings = self.snapshot.logicalDevices.first(where: { $0.id == deviceID })?.settings?.settings
                let items = Self.buildRestorePreviewItems(current: currentSettings, change: request.change)
                let preview = RestorePreviewModel(
                    deviceID: deviceID,
                    deviceName: deviceName,
                    backupFileName: backupURL.lastPathComponent,
                    backupCapturedAt: loadedBackup.capturedAt,
                    formatSummary: "\(loadedBackup.identity.formatID) v\(loadedBackup.identity.formatVersion)",
                    rollbackURL: rollbackURL,
                    request: request,
                    items: items
                )
                self.activeOverlay = .restorePreview(deviceID: deviceID, preview: preview)
            }
        }
    }

    func confirmRestorePreview(_ preview: RestorePreviewModel) {
        guard isCurrentLogicalSession(preview.request.target) else { activeOverlay = nil; return }
        let deviceID = preview.deviceID
        if case .restorePreview(let activeID, _) = activeOverlay, activeID == deviceID {
            activeOverlay = nil
        }
        pendingParameterSwitches[deviceID] = PendingParameterSwitch(
            sessionID: preview.request.target,
            kind: .restoreBackup(.writing),
            startedAt: Date()
        )
        startSettingsAction(deviceID, expectedSession: preview.request.target) { [weak self, controller] in
            let result = await controller.apply(preview.request)
            await MainActor.run {
                self?.handleSettingChangeCompletion(result, for: deviceID)
            }
        }
    }

    private static func buildRestorePreviewItems(current: DeviceSettings?, change: DeviceSettingsChange) -> [RestorePreviewItem] {
        var items: [RestorePreviewItem] = []
        if let targetDPI = change.currentDPI {
            let cur = current?.currentDPI.map { $0.x == $0.y ? "\($0.x) DPI" : "X \($0.x) / Y \($0.y) DPI" } ?? "--"
            let next = targetDPI.x == targetDPI.y ? "\(targetDPI.x) DPI" : "X \(targetDPI.x) / Y \(targetDPI.y) DPI"
            items.append(RestorePreviewItem(id: "currentDPI", label: "当前 DPI", currentValue: cur, backupValue: next))
        }
        if let targetHz = change.pollingRateHz {
            let cur = current?.pollingRateHz.map { "\($0) Hz" } ?? "--"
            items.append(RestorePreviewItem(id: "pollingRate", label: "回报率", currentValue: cur, backupValue: "\(targetHz) Hz"))
        }
        if let targetStages = change.stages {
            let curStages = current?.stages?.stages.map { "档位 \($0.id): \(QuickPresetRowDraft.formatDPI($0.dpi))" }.joined(separator: " · ") ?? "--"
            let nextStages = targetStages.stages.map { "档位 \($0.id): \(QuickPresetRowDraft.formatDPI($0.dpi))" }.joined(separator: " · ")
            items.append(RestorePreviewItem(id: "stages", label: "板载 DPI 档位", currentValue: curStages, backupValue: nextStages))
            if let defID = targetStages.defaultStageID {
                let curDef = current?.stages?.defaultStageID.map { "档位 \($0)" } ?? "--"
                items.append(RestorePreviewItem(id: "defaultStage", label: "默认 DPI 档位", currentValue: curDef, backupValue: "档位 \(defID)"))
            }
        }
        if let targetProfile = change.activeProfileID {
            let curProf = current?.activeProfileID.map { "配置 \($0)" } ?? "--"
            items.append(RestorePreviewItem(id: "activeProfile", label: "板载配置档", currentValue: curProf, backupValue: "配置 \(targetProfile)"))
        }
        return items
    }

    // MARK: - Core Lifecycle & Monitor Bridge

    func start() {
        guard !hasStarted, !isTerminating else { return }
        hasStarted = true
        loginItem.refresh()
        integrationStartupTask = Task { await notifications.start() }
        let audioMonitor = audioMonitor
        audioObservationTask = Task { [weak self] in
            await audioMonitor.start { [weak self] value in await self?.consumeBluetoothAudio(value) }
        }
        let monitor = monitor
        observationTask = Task { [weak self] in
            let stream = await monitor.snapshots()
            await monitor.start()
            Task { [weak self] in
                _ = await monitor.initialDiscoveryReady()
                await self?.refreshReadableLogicalSettings()
            }
            for await value in stream {
                guard !Task.isCancelled else { break }
                self?.consume(value)
            }
        }
    }

    func consume(_ value: DeviceStoreSnapshot) {
        let previous = homeDevices, previousLogical = snapshot.logicalDevices
        snapshot = value
        reconcileProjectionState(previous: previous, previousLogical: previousLogical)
        notifications.consume(value)
        reconcileUIStateWithSnapshot(value)
        if hasPendingPanelOpenRefresh, canRefresh {
            hasPendingPanelOpenRefresh = false
            refreshAllDeviceInformation(reason: .manual)
        }
    }

    func consumeBluetoothAudio(_ value: BluetoothAudioSnapshot) {
        guard !isTerminating, value.epoch > bluetoothAudioSnapshot.epoch || (value.epoch == bluetoothAudioSnapshot.epoch && value.requestID >= bluetoothAudioSnapshot.requestID) else { return }
        let previous = homeDevices
        bluetoothAudioSnapshot = value
        reconcileProjectionState(previous: previous)
        notifications.consumeBluetoothAudio(value)
    }
    private func projectedHomeDevices() -> [HomeDeviceProjection] {
        let current = HomeDeviceProjector.project(snapshot, audio: bluetoothAudioDevices, at: max(snapshot.capturedAt, bluetoothAudioSnapshot.finishedAt))
        return current + retainedHomeDevices.values.filter { old in !current.contains { $0.representsSamePeripheral(as: old) } }
    }
    private func reconcileProjectionState(previous: [HomeDeviceProjection], previousLogical: [LogicalDeviceState] = []) {
        let current = HomeDeviceProjector.project(snapshot, audio: bluetoothAudioDevices, at: max(snapshot.capturedAt, bluetoothAudioSnapshot.finishedAt))
        for old in previous where !current.contains(where: { $0.representsSamePeripheral(as: old) }) {
            retainedHomeDevices[old.sessionKey] = old.historicalSnapshot()
        }
        retainedHomeDevices = retainedHomeDevices.filter { _, old in !current.contains { $0.representsSamePeripheral(as: old) } }
        let all = projectedHomeDevices()
        reconcileDeviceIntents(previous: previous, current: all, previousLogical: previousLogical)
        for item in all {
            if !stableProjectionOrder.contains(item.id) { stableProjectionOrder.append(item.id) }
            if let oldSession = targetSessionKeys[item.target], oldSession != item.sessionKey {
                sessionFoldedTargets.remove(item.target)
                sessionQuickPresets.removeValue(forKey: item.logical?.id ?? LogicalDeviceID(rawValue: ""))
            }
            targetSessionKeys[item.target] = item.sessionKey
        }
        let connected = all.filter { !$0.isHistory }
        if connected.contains(where: { !lastConnectedUIIDs.contains($0.id) && isDeviceFolded($0.target) }) { isFoldedSectionExpanded = false }
        lastConnectedUIIDs = Set(connected.map(\.id))
        if connected.allSatisfy({ !isDeviceFolded($0.target) }) { isFoldedSectionExpanded = false }
        menuBarDisplay.reconcile(all, preferredIdentity: snapshot.preferences.primaryIdentity,
            fallback: snapshot.primaryLogicalDeviceID.map(HomeDeviceTarget.logical) ?? snapshot.primaryDeviceID.map(HomeDeviceTarget.physical))
        if snapshot.isSuspended { menuBarDisplay.markUncertain("系统休眠，状态待确认") }
    }

    private func isCurrentLogicalSession(_ session: LogicalDeviceSessionID) -> Bool {
        !snapshot.isSuspended && snapshot.logicalDevices.contains {
            $0.sessionID == session && $0.hostPresence == .present && $0.peerPresence != .unreachable
        }
    }
    /// Transport IDs can be reused. Deferred UI intent follows a proven unit or
    /// the original session's frozen history, never a replacement in the same slot.
    private func reconcileDeviceIntents(previous: [HomeDeviceProjection], current: [HomeDeviceProjection], previousLogical: [LogicalDeviceState]) {
        func migrated(_ target: HomeDeviceTarget) -> HomeDeviceTarget? {
            guard let original = previous.first(where: { $0.target == target }) else {
                return current.first { $0.target == target }?.target
            }
            return current.first { $0.representsSamePeripheral(as: original) }?.target
        }
        switch route {
        case .device(let target): route = migrated(target).map(BazerRoute.device) ?? .home
        case .settings(origin: .device(let target)):
            route = .settings(origin: migrated(target).map(BazerSettingsOrigin.device) ?? .home)
        case .home, .settings(origin: .home): break
        }
        if let target = lastVisitedDeviceTarget { lastVisitedDeviceTarget = migrated(target) }
        if var banner = foldUndoBanner {
            if let target = migrated(banner.target) { banner.target = target; foldUndoBanner = banner }
            else { foldUndoTask?.cancel(); foldUndoBanner = nil }
        }
        switch activeOverlay {
        case .quickPresetEditor, .onboardFieldPicker, .restorePreview:
            if activeOverlaySession.map({ isCurrentLogicalSession($0) }) != true { activeOverlay = nil }
        case .primaryDevicePicker, nil: break
        }
        for (id, session) in quickPresetDraftSessions where !isCurrentLogicalSession(session) {
            sessionQuickPresetDrafts.removeValue(forKey: id); quickPresetDraftSessions.removeValue(forKey: id)
        }
        for old in previousLogical where old.hostPresence == .present && old.peerPresence != .unreachable && !isCurrentLogicalSession(old.sessionID) {
            let id = old.id
            sessionQuickPresetDrafts.removeValue(forKey: id); quickPresetDraftSessions.removeValue(forKey: id)
            sessionQuickPresets.removeValue(forKey: id); onboardDrafts.removeValue(forKey: id)
            pendingParameterSwitches.removeValue(forKey: id); requiresReadbackCheck.remove(id)
            parameterRejectionMessages.removeValue(forKey: id); settingsErrors.removeValue(forKey: id)
            settingsBackupPaths.removeValue(forKey: id); exportedBackupURLs.removeValue(forKey: id)
            backupStatusMessages.removeValue(forKey: id)
            verifiedBannerTasks[id]?.cancel(); verifiedBannerTasks.removeValue(forKey: id)
            verifiedBannerMessages.removeValue(forKey: id)
            settingsTasks[id]?.cancel()
        }
    }

    private func reconcileUIStateWithSnapshot(_ value: DeviceStoreSnapshot) {
        let currentTargets = currentHomeTargets
        for target in currentTargets where !stableHomeOrder.contains(target) { stableHomeOrder.append(target) }
        // Sync initial persisted folded preferences
        if value.preferences.rememberFoldedDevices {
            for target in currentTargets {
                if let key = preferenceIdentity(for: target)?.rawValue,
                   value.preferences.foldedIdentities.contains(key) {
                    sessionFoldedTargets.insert(target)
                }
            }
            hasInitializedFoldedFromPreferences = true
        } else if !hasInitializedFoldedFromPreferences {
            hasInitializedFoldedFromPreferences = true
        }

        // Invalidate stale onboard drafts or pending indicators if session changed
        for (logicalID, draft) in onboardDrafts {
            if let live = value.logicalDevices.first(where: { $0.id == logicalID }) {
                if live.sessionID != draft.snapshot.session || live.hostPresence == .removed {
                    onboardDrafts.removeValue(forKey: logicalID)
                } else if let rev = live.settings?.revision, rev != draft.snapshot.revision,
                          let settings = live.settings, draft.request(capabilities: live.capabilities, scope: .onboard) == nil {
                    onboardDrafts[logicalID] = DeviceSettingsDraft(settings, scope: .onboard)
                }
            }
        }
        for (logicalID, pending) in pendingParameterSwitches {
            if let live = value.logicalDevices.first(where: { $0.id == logicalID }) {
                if live.sessionID != pending.sessionID || live.hostPresence == .removed {
                    pendingParameterSwitches.removeValue(forKey: logicalID)
                }
            }
        }
    }

    func applicationDidBecomeActive() {
        guard hasStarted, !isTerminating else { return }
        loginItem.refresh()
        Task { await notifications.refreshAuthorization() }
    }

    func refresh(_ deviceID: PhysicalDeviceID? = nil) {
        guard canRefresh else { return }
        if let deviceID {
            Task { [weak self, monitor] in
                await monitor.refresh(deviceID: deviceID)
                await self?.refreshReadableLogicalSettings(forHost: deviceID)
            }
        }
        else { refreshAllDeviceInformation(reason: .manual) }
    }
    enum RefreshReason: Sendable { case manual, panelOpen(UUID), polling }
    func handlePanelDidOpen(openSessionID: UUID) {
        guard !isTerminating, handledPanelOpenSessionIDs.insert(openSessionID).inserted else { return }
        panelOpenRefreshIntentCount += 1
        refreshAllDeviceInformation(reason: .panelOpen(openSessionID))
    }
    func refreshAllDeviceInformation(reason: RefreshReason = .manual) {
        guard canRefresh else {
            if case .panelOpen = reason, !isTerminating, !snapshot.isSuspended { hasPendingPanelOpenRefresh = true }
            return
        }
        let monitor = monitor, audioMonitor = audioMonitor
        if allRefreshTask != nil {
            hasPendingAllSettingsRefresh = true
            // Forward every intent to each actor, whose single queued pass coalesces it.
            Task { await monitor.refreshAllDeviceInformation() }
            Task { _ = await audioMonitor.refresh() }
            return
        }
        isRefreshingAllInformation = true
        refreshProgressTask?.cancel()
        refreshProgressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.showRefreshProgress = true
        }
        allRefreshTask = Task { [weak self] in
            let audioTask = Task { await audioMonitor.refresh() }
            await monitor.refreshAllDeviceInformation()
            await self?.refreshReadableLogicalSettings()
            _ = await audioTask.value
            guard let self else { return }
            while self.hasPendingAllSettingsRefresh && !self.isTerminating && !self.snapshot.isSuspended {
                self.hasPendingAllSettingsRefresh = false
                await self.refreshReadableLogicalSettings()
            }
            self.refreshProgressTask?.cancel(); self.showRefreshProgress = false
            self.isRefreshingAllInformation = false; self.allRefreshTask = nil
        }
    }
    func waitForAllDeviceInformationRefresh() async { await allRefreshTask?.value }
    private func refreshReadableLogicalSettings(forHost hostID: PhysicalDeviceID? = nil) async {
        let latest = await monitor.snapshot()
        consume(latest)
        guard !isTerminating, !snapshot.isSuspended else { return }
        var targetIDs: [LogicalDeviceID] = []
        for logical in snapshot.logicalDevices where logical.hostPresence == .present && logical.peerPresence != .unreachable && logical.canRefreshSettings {
            if let hostID, logical.sessionID.address.hostSessionID.physicalDeviceID != hostID { continue }
            guard !settingsBusy.contains(logical.id) else { continue }
            if await monitor.settingsAdapter(for: logical.id) != nil {
                targetIDs.append(logical.id)
            }
        }
        for id in targetIDs {
            readSettings(id)
        }
        for id in targetIDs {
            await waitForSettingsAction(id)
        }
    }
    func setPrimaryTarget(_ target: HomeDeviceTarget?) {
        guard let target else {
            menuBarDisplay = MenuBarDisplayState()
            Task {
                await monitor.setPrimary(nil)
                consume(await monitor.snapshot())
            }
            return
        }
        switch target {
        case .physical(let id): setPrimary(id)
        case .logical(let id): setPrimaryLogical(id)
        case .bluetoothAudio(let id): setPrimaryBluetoothAudio(id)
        }
    }
    func setAlias(_ alias: String, forAudioDevice id: BluetoothAudioDeviceID) {
        guard !isTerminating, let key = associatedBluetoothAudioDevice(for: .bluetoothAudio(id))?.preferenceIdentity else { return }
        Task { await monitor.setAliasIdentity(alias, identityKey: key) }
    }
    func setPrimaryBluetoothAudio(_ id: BluetoothAudioDeviceID) {
        guard !isTerminating else { return }
        menuBarDisplay.select(homeDevices.first { $0.audio?.id == id })
        let key = associatedBluetoothAudioDevice(for: .bluetoothAudio(id))?.preferenceIdentity
        Task { await monitor.setPrimaryIdentity(key) }
    }
    func setAlias(_ alias: String, for deviceID: PhysicalDeviceID) {
        guard !isTerminating else { return }
        Task { await monitor.setAlias(alias, for: deviceID) }
    }
    func setPrimary(_ deviceID: PhysicalDeviceID?) {
        guard !isTerminating else { return }
        menuBarDisplay.select(deviceID.flatMap { id in homeDevices.first { $0.physical?.id == id || $0.logical?.sessionID.address.hostSessionID.physicalDeviceID == id } })
        Task { await monitor.setPrimary(deviceID) }
    }
    func setAlias(_ alias: String, for deviceID: LogicalDeviceID) {
        guard !isTerminating else { return }
        Task { await monitor.setAlias(alias, for: deviceID) }
    }
    func setPrimaryLogical(_ deviceID: LogicalDeviceID) {
        guard !isTerminating else { return }
        menuBarDisplay.select(homeDevices.first { $0.logical?.id == deviceID })
        Task { await monitor.setPrimaryLogical(deviceID) }
    }
    func refreshLogical(_ deviceID: LogicalDeviceID) {
        guard !isTerminating, !snapshot.isSuspended else { return }
        Task { [weak self, monitor] in
            await monitor.refresh(logicalDeviceID: deviceID)
            guard let self else { return }
            let latest = await monitor.snapshot()
            self.consume(latest)
            guard !self.isTerminating, !self.snapshot.isSuspended else { return }
            if let logical = self.snapshot.logicalDevices.first(where: { $0.id == deviceID }),
               logical.hostPresence == .present,
               logical.peerPresence != .unreachable,
               logical.canRefreshSettings,
               !self.settingsBusy.contains(deviceID),
               await monitor.settingsAdapter(for: deviceID) != nil {
                self.readSettings(deviceID)
            }
        }
    }
    /// Discovery is a read-only action independent of a placeholder's telemetry capability.
    /// Each host joins one real monitor operation; it never replays settings requests.
    func rediscoverLogicalDevices(_ hostID: PhysicalDeviceID) {
        guard canRediscoverLogicalDevices(hostID), let host = logicalDiscoveryHosts.first(where: { $0.id == hostID }) else { return }
        let session = host.sessionID, monitor = monitor
        logicalDiscoveryBusy.insert(hostID)
        logicalDiscoveryErrors.removeValue(forKey: hostID); logicalDiscoveryMessages.removeValue(forKey: hostID)
        logicalDiscoveryTasks[hostID] = Task { [weak self] in
            await monitor.refreshLogicalDiscovery(deviceID: hostID)
            let value = await monitor.snapshot()
            guard let self else { return }
            self.consume(value)
            if self.isTerminating || !value.isMonitoring || value.isSuspended {
                self.logicalDiscoveryMessages[hostID] = "发现请求已结束；监控已暂停或停止。"
            } else if !value.devices.contains(where: { $0.id == hostID && $0.sessionID == session && $0.hostPresence == .present }) {
                self.logicalDiscoveryMessages[hostID] = "连接已变化，请在当前连接上重新发现设备。"
            } else if let error = value.discoveryFailure {
                // The monitor retains a global discovery failure, which may predate this
                // action. Keep it visible without claiming a successful fresh discovery.
                self.logicalDiscoveryErrors[hostID] = error
                self.logicalDiscoveryMessages[hostID] = "重新发现已结束；监测仍有诊断信息。"
            } else {
                let count = value.logicalDevices.filter { $0.hostPresence == .present && $0.sessionID.address.hostSessionID == session }.count
                self.logicalDiscoveryMessages[hostID] = "只读发现请求已结束，当前列表含 \(count) 个外设条目；在线状态见各条目。"
            }
            self.logicalDiscoveryBusy.remove(hostID); self.logicalDiscoveryTasks.removeValue(forKey: hostID)
        }
    }
    func waitForLogicalDiscovery(_ hostID: PhysicalDeviceID) async { await logicalDiscoveryTasks[hostID]?.value }
    func readSettings(_ deviceID: LogicalDeviceID) {
        guard let expected = snapshot.logicalDevices.first(where: { $0.id == deviceID })?.sessionID, isCurrentLogicalSession(expected) else { return }
        startSettingsAction(deviceID, expectedSession: expected) { [weak self, controller] in
            let snap = try await controller.readSettings(logicalDeviceID: deviceID, expectedSession: expected)
            await MainActor.run {
                guard snap.session == expected, self?.isCurrentLogicalSession(expected) == true else { return }
                self?.requiresReadbackCheck.remove(deviceID)
                self?.parameterRejectionMessages.removeValue(forKey: deviceID)
                self?.onboardDrafts[deviceID] = DeviceSettingsDraft(snap, scope: .onboard)
            }
        }
    }
    func applySettings(_ request: SettingChangeRequest) {
        guard isCurrentLogicalSession(request.target) else { return }
        let deviceID = request.target.deviceID
        if request.change.persistence == .onboard {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Bazer/Backups", isDirectory: true)
                .appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString).json")
            startSettingsAction(deviceID, expectedSession: request.target) { [weak self, controller] in
                await MainActor.run {
                    if case .onboardSave = self?.pendingParameterSwitches[deviceID]?.kind {
                        self?.pendingParameterSwitches[deviceID]?.kind = .onboardSave(.backingUp)
                    }
                }
                let prepared = try await controller.prepareOnboardChange(request, saveBackupTo: backup)
                await self?.didSaveBackup(backup.path, for: deviceID, session: request.target)
                try Task.checkCancellation()
                await MainActor.run {
                    if case .onboardSave = self?.pendingParameterSwitches[deviceID]?.kind {
                        self?.pendingParameterSwitches[deviceID]?.kind = .onboardSave(.writing)
                    }
                }
                let result = await controller.apply(prepared)
                await MainActor.run {
                    self?.handleSettingChangeCompletion(result, for: deviceID)
                }
            }
        } else {
            startSettingsAction(deviceID, expectedSession: request.target) { [weak self, controller] in
                let result = await controller.apply(request)
                await MainActor.run {
                    self?.handleSettingChangeCompletion(result, for: deviceID)
                }
            }
        }
    }
    func cancelSettings(_ deviceID: LogicalDeviceID) { settingsTasks[deviceID]?.cancel() }
    private func didSaveBackup(_ path: String, for deviceID: LogicalDeviceID, session: LogicalDeviceSessionID) {
        guard isCurrentLogicalSession(session) else { return }
        settingsBackupPaths[deviceID] = path
    }
    // Deterministic tests can await the real action drain without polling timers.
    func waitForSettingsAction(_ deviceID: LogicalDeviceID) async { await settingsTasks[deviceID]?.value }
    private func startSettingsAction(_ deviceID: LogicalDeviceID, expectedSession: LogicalDeviceSessionID? = nil, action: @escaping @Sendable () async throws -> Void) {
        guard !isTerminating, settingsTasks[deviceID] == nil,
              let session = snapshot.logicalDevices.first(where: { $0.id == deviceID })?.sessionID,
              isCurrentLogicalSession(session), expectedSession == nil || expectedSession == session else { return }
        settingsBusy.insert(deviceID); settingsErrors.removeValue(forKey: deviceID)
        settingsTasks[deviceID] = Task { [weak self] in
            do {
                guard self?.isCurrentLogicalSession(session) == true else { throw CancellationError() }
                try await action()
            }
            catch is CancellationError {
                if self?.isCurrentLogicalSession(session) == true { self?.settingsErrors[deviceID] = "请求已取消；已发送的设备操作不会撤销，请读取当前值确认。" }
            }
            catch { if self?.isCurrentLogicalSession(session) == true { self?.settingsErrors[deviceID] = String(describing: error) } }
            if self?.isCurrentLogicalSession(session) == true { self?.pendingParameterSwitches.removeValue(forKey: deviceID) }
            self?.settingsBusy.remove(deviceID); self?.settingsTasks.removeValue(forKey: deviceID)
        }
    }

    private func handleSettingChangeCompletion(_ result: SettingChangeResult, for deviceID: LogicalDeviceID) {
        guard isCurrentLogicalSession(result.request.target) else { return }
        pendingParameterSwitches.removeValue(forKey: deviceID)
        switch result.status {
        case .verified:
            requiresReadbackCheck.remove(deviceID)
            parameterRejectionMessages.removeValue(forKey: deviceID)
            if let observed = result.observed {
                onboardDrafts[deviceID] = DeviceSettingsDraft(observed, scope: .onboard)
            }
            let summary: String
            if let dpi = result.request.change.currentDPI {
                summary = "已切换至 \(QuickPresetRowDraft.formatDPI(dpi)) DPI"
            } else if result.request.change.currentStageID != nil, let dpi = result.observed?.settings.currentDPI {
                summary = "已切换至 \(QuickPresetRowDraft.formatDPI(dpi)) DPI"
            } else if let hz = result.request.change.pollingRateHz, result.request.change.fields == [.pollingRate] {
                summary = "已切换至 \(hz) Hz"
            } else {
                summary = result.persistence == .onboard ? "已写入并读回当前配置" : "设置已读回确认"
            }
            showVerifiedBanner(summary, for: deviceID)
        case .outcomeUnknown:
            requiresReadbackCheck.insert(deviceID)
        case .partialFailure:
            if result.fields.contains(where: { $0.status == .outcomeUnknown }) {
                requiresReadbackCheck.insert(deviceID)
            }
        case .rejected, .readbackMismatch, .superseded:
            break
        }
    }

    private func showVerifiedBanner(_ text: String, for deviceID: LogicalDeviceID) {
        verifiedBannerTasks[deviceID]?.cancel()
        verifiedBannerMessages[deviceID] = text
        verifiedBannerTasks[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.verifiedBannerMessages.removeValue(forKey: deviceID)
        }
    }

    func systemWillSleep() { notifications.setSuspended(true); enqueueWorkspaceEvent(sleeping: true) }
    func systemDidWake() { enqueueWorkspaceEvent(sleeping: false) }
    private func enqueueWorkspaceEvent(sleeping: Bool) {
        guard !isTerminating else { return }
        let previous = workspaceTask, monitor = monitor, audioMonitor = audioMonitor
        workspaceTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            if sleeping {
                async let hid: Void = monitor.suspend()
                async let audio: Void = audioMonitor.suspend()
                _ = await (hid, audio)
            } else {
                async let hid: Void = monitor.wake()
                async let audio: Void = audioMonitor.resume()
                _ = await (hid, audio)
                notifications.setSuspended(false)
            }
        }
    }

    func stop() async {
        isTerminating = true
        allRefreshTask?.cancel(); refreshProgressTask?.cancel()
        audioObservationTask?.cancel()
        await audioMonitor.stop()
        await allRefreshTask?.value
        await audioObservationTask?.value
        foldUndoTask?.cancel(); foldUndoTask = nil
        for task in verifiedBannerTasks.values { task.cancel() }
        verifiedBannerTasks.removeAll()
        let pendingSettings = Array(settingsTasks.values)
        for task in pendingSettings { task.cancel() }
        for task in pendingSettings { await task.value }
        let pendingDiscovery = Array(logicalDiscoveryTasks.values)
        for task in pendingDiscovery { task.cancel() }
        integrationStartupTask?.cancel()
        await integrationStartupTask?.value
        integrationStartupTask = nil
        await notifications.stop()
        workspaceTask?.cancel()
        await workspaceTask?.value
        await monitor.stop()
        for task in pendingDiscovery { await task.value }
        observationTask?.cancel()
        await observationTask?.value
        observationTask = nil; workspaceTask = nil
    }
}
