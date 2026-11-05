// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

public enum LocalPrivateFileError: Error, Equatable, Sendable { case invalidPath, notRegularFile, tooLarge }

/// Shared local backup/evidence boundary: no overwrite, private mode and no final symlink following.
public struct LocalPrivateFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func writeNew(_ data: Data) throws {
        let parent = try openParent(create: true); defer { Darwin.close(parent) }
        let descriptor = url.lastPathComponent.withCString { Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR)) }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }
    public func read(maximumBytes: Int = 1_048_576) throws -> Data {
        guard maximumBytes > 0 && maximumBytes <= 32 * 1_048_576 else { throw LocalPrivateFileError.tooLarge }
        let parent = try openParent(create: false); defer { Darwin.close(parent) }
        // Inspect the opened object before reading without waiting for a FIFO writer.
        // O_NONBLOCK has no effect on regular-file reads; every other kind is rejected below.
        let descriptor = url.lastPathComponent.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG else { throw LocalPrivateFileError.notRegularFile }
        guard status.st_size >= 0 && status.st_size <= maximumBytes else { throw LocalPrivateFileError.tooLarge }
        var data = Data()
        while data.count <= maximumBytes {
            let chunk = try handle.read(upToCount: min(65536, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw LocalPrivateFileError.tooLarge
    }
    private func openParent(create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
              !url.lastPathComponent.contains("/"), url.lastPathComponent != ".", url.lastPathComponent != ".." else { throw LocalPrivateFileError.invalidPath }
        var existing = url.standardizedFileURL.deletingLastPathComponent()
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0); existing.deleteLastPathComponent()
        }
        guard let canonical = Darwin.realpath(existing.path, nil) else { throw posixError() }
        let canonicalPath = String(cString: canonical); Darwin.free(canonical)
        let components = URL(fileURLWithPath: canonicalPath).pathComponents.filter { $0 != "/" } + missing
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        do {
            for component in components {
                var next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                if next < 0, errno == ENOENT, create {
                    let created = component.withCString { Darwin.mkdirat(descriptor, $0, mode_t(S_IRWXU)) }
                    guard created == 0 || errno == EEXIST else { throw posixError() }
                    next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                }
                guard next >= 0 else { throw posixError() }
                Darwin.close(descriptor); descriptor = next
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
