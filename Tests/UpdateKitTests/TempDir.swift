import Foundation

/// A throwaway directory that removes itself when the suite instance holding it is
/// released — Swift Testing's stand-in for `addTeardownBlock`.
final class TempDir: @unchecked Sendable {
    let url: URL

    init(_ label: String = "updatekit") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A fresh child directory.
    func child(_ label: String) -> URL {
        let child = url.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
