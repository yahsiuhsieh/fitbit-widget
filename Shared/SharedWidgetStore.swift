import Foundation
import Darwin

enum SharedConfiguration {
    static let appGroupIdentifier = "group.com.yahsiu.FitbitWidget"
    static let keychainAccessGroupInfoKey = "SharedKeychainAccessGroup"
    static let widgetKind = "FitbitHealthWidgetLarge"

    // API source dates use Gregorian civil days; rendering still follows the user's locale.
    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }
}

struct SharedWidgetStore: Sendable {
    let fileURL: URL

    init(containerURL: URL) {
        fileURL = containerURL.appendingPathComponent("widget-state.json", isDirectory: false)
    }

    init?(appGroupIdentifier: String = SharedConfiguration.appGroupIdentifier) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }

        self.init(containerURL: containerURL)
    }

    func load() -> SharedWidgetState {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? Self.decoder.decode(StoredEnvelope.self, from: data),
              envelope.schemaVersion == StoredEnvelope.currentSchemaVersion else {
            return .initial
        }

        return envelope.state
    }

    func save(_ state: SharedWidgetState) throws {
        try withStateLock { try write(state) }
    }

    // Transform and persist under one short cross-process lock. Never await inside this closure.
    @discardableResult
    func update(_ transform: (inout SharedWidgetState) throws -> Void) throws -> SharedWidgetState {
        try withStateLock {
            let previous = load()
            var current = previous
            try transform(&current)
            if current != previous { try write(current) }
            return current
        }
    }

    func acquireSyncLease() throws -> SharedSyncLease? {
        try SharedSyncLease(directory: fileURL.deletingLastPathComponent(), name: "sync.lock", wait: false)
    }

    private func withStateLock<T>(_ operation: () throws -> T) throws -> T {
        guard let lease = try SharedSyncLease(directory: fileURL.deletingLastPathComponent(), name: "state.lock", wait: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { withExtendedLifetime(lease) {} }
        return try operation()
    }

    private func write(_ state: SharedWidgetState) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let envelope = StoredEnvelope(
            schemaVersion: StoredEnvelope.currentSchemaVersion,
            state: state
        )
        let data = try Self.encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var savedFileURL = fileURL
        try savedFileURL.setResourceValues(resourceValues)
    }

    func clear(removingTokens: () throws -> Void = {}) throws {
        try withStateLock {
            var failure: Error?
            do { try removingTokens() } catch { failure = error }
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch { if failure == nil { failure = error } }
            if let failure { throw failure }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

private struct StoredEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let state: SharedWidgetState
}

// flock is released by the kernel on process termination; no persisted lease can become stuck.
final class SharedSyncLease: @unchecked Sendable {
    private let descriptor: Int32

    init?(directory: URL, name: String, wait: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(name)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        if flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            let busy = errno == EWOULDBLOCK
            Darwin.close(fd)
            if busy { return nil }
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = fd
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
