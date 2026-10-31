import Foundation
import Darwin

// Watch the directory: atomic writes replace the snapshot's inode, and reset deletes it.
// The event is only an invalidation hint; callers always read the authoritative store.
final class SharedStateObserver {
    private let source: any DispatchSourceFileSystemObject

    init(directory: URL, onChange: @escaping @MainActor @Sendable () -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { Task { @MainActor in onChange() } }
        source.setRegistrationHandler { Task { @MainActor in onChange() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
