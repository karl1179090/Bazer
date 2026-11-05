// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ServiceManagement
import SwiftUI

enum LoginItemStatus: Equatable {
    case unknown, notRegistered, enabled, requiresApproval, notFound
    var text: String {
        switch self {
        case .unknown: "尚未读取系统状态"
        case .notRegistered: "已关闭"
        case .enabled: "已启用"
        case .requiresApproval: "需要在系统设置中批准"
        case .notFound: "系统未找到此登录项"
        }
    }
    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemBackend: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
final class SystemLoginItemBackend: LoginItemBackend {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var status: LoginItemStatus = .unknown
    @Published private(set) var errorMessage: String?
    private let backend: any LoginItemBackend
    init(backend: any LoginItemBackend = SystemLoginItemBackend()) { self.backend = backend }
    func refresh() { status = backend.status }
    func setEnabledByUser(_ enabled: Bool) {
        defer { refresh() }
        do {
            if enabled { try backend.register() } else { try backend.unregister() }
            errorMessage = nil
        } catch { errorMessage = NotificationService.describe(error) }
    }
    func openSettingsByUser() { backend.openSettings() }
}
