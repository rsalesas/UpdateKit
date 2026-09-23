import Foundation

/// What the published `appcast.json` carries. `scripts/publish-update.sh` writes it.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public let version: String
    /// The disk image, for people who can't (or won't) update in place.
    public let url: URL
    /// Oldest macOS the new build runs on. A build that needs more than this Mac
    /// has is not offered — pointing someone at a download they can't run is worse
    /// than staying quiet.
    public var minimumSystemVersion: String?
    public var notes: String?

    /// The ZIP the in-app updater installs, and its SHA-256. Optional so a manifest
    /// published without one (or read by an older build) simply falls back to opening
    /// the DMG. Both or neither: an archive without a checksum must never be installed,
    /// so `installableArchive` only reports one when the hash is there too.
    public var archive: URL?
    public var sha256: String?
    public var archiveSize: Int?

    public init(version: String, url: URL, minimumSystemVersion: String? = nil,
                notes: String? = nil, archive: URL? = nil, sha256: String? = nil,
                archiveSize: Int? = nil) {
        self.version = version
        self.url = url
        self.minimumSystemVersion = minimumSystemVersion
        self.notes = notes
        self.archive = archive
        self.sha256 = sha256
        self.archiveSize = archiveSize
    }

    public var installableArchive: (url: URL, sha256: String)? {
        guard let archive, let sha256, sha256.count == 64 else { return nil }
        return (archive, sha256)
    }
}

extension Bundle {
    /// The marketing version ("0.2.5"), which is what the manifest is compared against.
    @usableFromInline var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
