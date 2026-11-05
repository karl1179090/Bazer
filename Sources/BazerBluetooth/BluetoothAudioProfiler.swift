// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import BazerCore

enum BluetoothAudioProfiler {
    static func read() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        let runner = BoundedBluetoothProfilerProcess()
        let data = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { runner.run() }.value
        } onCancel: { runner.cancel() }
        guard let data else { return .init(status: .failed, message: "蓝牙备用发现超时或不可用") }
        return parse(data)
    }
    static func parse(_ data: Data) -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return .init(status: .failed, message: "蓝牙备用报告格式无效")
        }
        var records: [BluetoothAudioDiscoveryRecord] = []
        for report in reports {
            for group in report["device_connected"] as? [[String: Any]] ?? [] {
                for (name, raw) in group {
                    guard let item = raw as? [String: Any], let address = item["device_address"] as? String,
                          let type = item["device_minorType"] as? String,
                          ["headset", "headphones", "hands-free"].contains(type.lowercased()) else { continue }
                    records.append(.init(key: BluetoothAudioOpaqueIdentity.discoveryKey(address: address), name: name))
                }
            }
        }
        return .init(records: records, status: .partial, message: "使用蓝牙备用发现，未出现的设备连接状态待确认")
    }
}

/// Fixed executable/arguments, 10-second wall deadline, 2 MiB output bound and cancellation.
/// A separate instance is owned by each coalesced discovery request, never by the HID scheduler.
private final class BoundedBluetoothProfilerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func run() -> Data? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "8"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        lock.lock(); self.process = process; let wasCancelled = cancelled; lock.unlock()
        guard !wasCancelled else { return nil }
        do { try process.run() } catch { return nil }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        var failed = false
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 2 * 1024 * 1024 { failed = true; break }
            } else if !process.isRunning { break }
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped || ProcessInfo.processInfo.systemUptime >= deadline { failed = true; break }
            if count <= 0 { usleep(10_000) }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        return !failed && process.terminationStatus == 0 ? data : nil
    }
}
