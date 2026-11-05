// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// Pure guidance projection; the caller supplies the current app's bundle URL.
enum HIDAccessGuidance {
    static func message(for failure: TelemetryFailure, runningBundleURL: URL) -> String? {
        guard failure.operation == "open", let code = failure.ioReturn,
              UInt32(bitPattern: code) == 0xE00002E2 else { return nil }
        return "系统 HID 访问被拒绝（kIOReturnNotPermitted）。请在“系统设置 → 隐私与安全性 → 输入监控”中检查下方当前运行的应用。升级后可能需要重新授权，并按系统提示退出重开。\n当前运行的应用：\(runningBundleURL.path)"
    }
}
