import Darwin
import Foundation
import Security

/// Whether the executable this process was launched from has been replaced by a build
/// that is complete and signed like this one.
///
/// "Replaced" is by file identity, not by date or version: the path now names a
/// different inode from the one this process started from. An update allocates a new one
/// (`replaceItemAt` swaps the whole bundle), and so does any installer that doesn't
/// corrupt running code, because writing into the old inode would get the running
/// process killed by code signing. Versions can't do this job: Vaelora compared the
/// version in the bundle's Info.plist with its own, and a bundle whose helper wasn't
/// re-stamped made it hand over to itself forever. Modification dates can't either:
/// `ditto` keeps the build's, which is older than the install.
///
/// "Complete and signed like this one" before anything runs it:
///
/// * The file must have been in place for `settle` seconds, by its status-change time.
///   A Finder drag-install writes a bundle a file at a time. Measured from the file's own
///   ctime rather than from when this process first noticed it, so a request that
///   arrives long after an install switches at once instead of waiting.
/// * It must meet this process's own designated requirement: the same signing identity,
///   intact. Read at launch, while this process's file still exists. A development build
///   signed ad hoc has a requirement only a byte-identical copy meets, so it effectively
///   never switches.
public final class ExecutableWatch: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        /// The path still names the file this process was launched from (or nothing).
        case unchanged
        /// A different file is there, but too new to trust yet.
        case settling(until: Date)
        /// A different, settled, acceptable file is there: become it.
        case ready
        /// A different file is there and it is not acceptable. Checked once per file.
        case refused
    }

    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let changed: Date
    }

    public let path: String
    private let original: FileIdentity?
    private let settle: TimeInterval
    private let isAcceptable: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var refused: (dev_t, ino_t)?

    /// - Parameters:
    ///   - path: the executable this process was launched from, read at launch
    ///     (`HandOver.currentExecutablePath()`).
    ///   - isAcceptable: whether a file may be run in this process's place. Defaults to
    ///     the designated-requirement check; tests pass their own.
    public init(path: String, settle: TimeInterval = 2,
                isAcceptable: (@Sendable (String) -> Bool)? = nil) {
        self.path = path
        self.original = Self.identity(of: path)
        self.settle = settle
        if let isAcceptable {
            self.isAcceptable = isAcceptable
        } else {
            let requirement = Self.ownRequirement()
            self.isAcceptable = { path in
                guard let requirement else { return false }
                return ExecutableWatch.satisfies(path, requirement.value)
            }
        }
    }

    /// A watch on the file this process is running, or nil if it can't be told.
    public static func forThisProcess(settle: TimeInterval = 2) -> ExecutableWatch? {
        HandOver.currentExecutablePath().map { ExecutableWatch(path: $0, settle: settle) }
    }

    /// What is at `path` now. One `stat` when nothing has changed, which macOS answers
    /// from memory.
    public func check(now: Date = Date()) -> Status {
        lock.withLock {
            guard let original, let current = Self.identity(of: path),
                  (current.device, current.inode) != (original.device, original.inode)
            else { return .unchanged }
            if let refused, refused == (current.device, current.inode) { return .refused }
            let settled = current.changed.addingTimeInterval(settle)
            guard now >= settled else { return .settling(until: settled) }
            guard isAcceptable(path) else {
                refused = (current.device, current.inode)
                return .refused
            }
            return .ready
        }
    }

    /// Marks the file now at `path` as not to be tried again: an exec of it failed.
    func refuseCurrent() {
        lock.withLock {
            if let current = Self.identity(of: path) { refused = (current.device, current.inode) }
        }
    }

    static func identity(of path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let changed = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec)
            + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000)
        return FileIdentity(device: info.st_dev, inode: info.st_ino, changed: changed)
    }

    /// `SecRequirement` isn't `Sendable`; it is immutable once created.
    struct Requirement: @unchecked Sendable { let value: SecRequirement }

    /// The designated requirement of the code running this process.
    static func ownRequirement() -> Requirement? {
        var current: SecCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current else { return nil }
        var currentStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess,
              let currentStatic else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        return Requirement(value: requirement)
    }

    /// The file at `path` is executable, validly signed, and meets `requirement`.
    static func satisfies(_ path: String, _ requirement: SecRequirement) -> Bool {
        guard access(path, X_OK) == 0 else { return false }
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &candidate)
                == errSecSuccess, let candidate else { return false }
        return SecStaticCodeCheckValidity(
            candidate, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}
