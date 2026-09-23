import Foundation
import CryptoKit
import Security
import AppKit

/// Installs a published update in place, so "Update" replaces the app rather than
/// opening a disk image and leaving the user to drag it.
///
/// On macOS an app bundle is a directory, so updating is replacing one directory
/// with another. What that gains in simplicity it owes back in trust: downloading and
/// swapping a bundle ourselves *bypasses* the Gatekeeper check the user would
/// otherwise get, so this has to do Gatekeeper's job. Anyone who can serve bytes at
/// the download URL — a stolen storage token, a bad DNS answer — would otherwise get
/// code execution as the user.
///
/// So an archive is installed only if all of these hold:
///   • its SHA-256 matches the hash in the manifest fetched over HTTPS,
///   • the app inside is validly signed by YOUR Developer ID team, and
///   • it really is a newer version than the running copy.
///
/// The swap itself is done outside the bundle — a bundle cannot replace itself while
/// its own code is mapped — by something that waits for this process to exit. See
/// `SwapStrategy`.
public enum AppUpdater {

    /// What the update is doing, for the window that reports it.
    ///
    /// Stages rather than a bare fraction, because most of the wait isn't downloading:
    /// a 5MB archive arrives quickly and the checks that follow are what the user is
    /// actually waiting through. And the last one has to be announced — an app that
    /// vanishes without warning to relaunch itself is alarming.
    public enum InstallStage: Equatable, Sendable {
        case downloading(receivedBytes: Int, totalBytes: Int?)
        case verifying
        case relaunching

        /// 0…1 while downloading; nil once the bar should go indeterminate.
        public var fraction: Double? {
            guard case let .downloading(received, total) = self,
                  let total, total > 0 else { return nil }
            return min(1, Double(received) / Double(total))
        }

        public var text: String {
            switch self {
            case let .downloading(received, total):
                let mb = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
                guard let total, total > 0 else { return "Downloading — \(mb(received))" }
                return "Downloading — \(mb(received)) of \(mb(total))"
            case .verifying: return "Verifying the download…"
            case .relaunching: return "Relaunching…"
            }
        }
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case cancelled
        case notEligible(String)
        case download(String)
        case hashMismatch
        case unreadableArchive
        case noAppInArchive
        case signature(String)
        case notNewer(String)
        case install(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return nil   // the user asked; nothing to report back
            case .notEligible(let why): return why
            case .download(let why): return "Couldn't download the update: \(why)"
            case .hashMismatch:
                return "The download didn't match its published checksum, so it wasn't installed."
            case .unreadableArchive: return "The downloaded archive couldn't be expanded."
            case .noAppInArchive: return "The download didn't contain an app."
            case .signature(let why): return "The download isn't correctly signed: \(why)"
            case .notNewer(let v): return "The download is version \(v), which isn't newer."
            case .install(let why): return "Couldn't replace the installed app: \(why)"
            }
        }
    }

    /// Apple's marker OID for the Developer ID Certification Authority (intermediate).
    private static let developerIDCA = "1.2.840.113635.100.6.2.6"
    /// Apple's marker OID for a Developer ID **Application** leaf certificate.
    private static let developerIDApplicationLeaf = "1.2.840.113635.100.6.1.13"

    /// The requirement a downloaded copy must satisfy.
    ///
    /// Pinning the team alone is not enough, and a test caught it: a Debug build is
    /// signed "Apple Development" with the SAME team, so a team-only requirement
    /// accepted a development-signed bundle — anything anyone on the team could
    /// produce, notarized or not. The two OID clauses below are Apple's documented
    /// markers for the Developer ID chain, and they are what makes this mean
    /// "the distribution identity we actually ship with".
    public static func requirementString(bundleIdentifier: String, teamIdentifier: String) -> String {
        "anchor apple generic"
            + " and identifier \"\(bundleIdentifier)\""
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            + " and certificate 1[field.\(developerIDCA)]"
            + " and certificate leaf[field.\(developerIDApplicationLeaf)]"
    }

    public static func requirementString(for configuration: UpdaterConfiguration) -> String {
        requirementString(bundleIdentifier: configuration.bundleIdentifier,
                          teamIdentifier: configuration.teamIdentifier)
    }

    // MARK: - Eligibility

    /// True when this process is confined to an App Sandbox container.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            || NSHomeDirectory().contains("/Library/Containers/")
    }

    /// Why this copy can't update itself in place, or nil if it can.
    ///
    /// Read as a precondition rather than a capability probe: each of these would
    /// otherwise fail late, half-way through, with the app already quitting.
    public static func ineligibilityReason(appName: String,
                                           bundleURL: URL = Bundle.main.bundleURL,
                                           isSandboxed: Bool = AppUpdater.isSandboxed,
                                           fileManager: FileManager = .default) -> String? {
        // The sandbox is the real gate, and it was missed because it cannot be seen
        // from outside one: an unsandboxed probe reports /Applications as perfectly
        // writable, and so does a unit test writing to a temporary directory. From
        // inside a container `isWritableFile` answers false and the write fails with
        // NSFileWriteNoPermissionError, so every in-place update was refused at the
        // last moment and quietly replaced by the manual download.
        //
        // Checked explicitly rather than left to the writability test below so the
        // reason names the cause instead of reading as a stray permissions problem.
        if isSandboxed, !bundleURL.path.hasPrefix(NSHomeDirectory()) {
            return "This build of \(appName) is sandboxed, so it cannot replace itself in "
                + "\(bundleURL.deletingLastPathComponent().lastPathComponent)."
        }
        // Translocated or read-only: the bundle isn't where the user thinks it is, and
        // in the DMG case the volume can't be written at all.
        if RunLocation.isUnsuitable(bundleURL) {
            return "Move \(appName) to your Applications folder to update it in place."
        }
        let parent = bundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            return "\(appName) can't write to \(parent.lastPathComponent), so it can't replace itself."
        }
        return nil
    }

    public static func canUpdateInPlace(appName: String,
                                        bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        ineligibilityReason(appName: appName, bundleURL: bundleURL) == nil
    }

    // MARK: - Verification

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Case-insensitive comparison of the published hash.
    public static func hashMatches(_ data: Data, expected: String) -> Bool {
        let want = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard want.count == 64 else { return false }
        return sha256(of: data) == want
    }

    /// Whether the app bundle at `url` satisfies `requirement`.
    ///
    /// `SecStaticCodeCheckValidity` walks the whole bundle, so a tampered resource or
    /// a re-signed helper fails here too — not only a swapped main executable.
    public static func verifySignature(of appURL: URL, requirement: String) -> Failure? {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            return .signature("the bundle couldn't be read (OSStatus \(created))")
        }
        var requirementRef: SecRequirement?
        let compiled = SecRequirementCreateWithString(requirement as CFString, [], &requirementRef)
        guard compiled == errSecSuccess, let requirementRef else {
            return .signature("the requirement couldn't be compiled (OSStatus \(compiled))")
        }
        // .checkAllArchitectures so a fat binary can't carry an unsigned slice.
        let flags: SecCSFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirementRef)
        guard status == errSecSuccess else {
            return .signature(describe(status))
        }
        return nil
    }

    private static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecCSUnsigned: return "it isn't signed"
        case errSecCSReqFailed: return "it isn't signed by the expected developer certificate"
        case errSecCSSignatureFailed, errSecCSSignatureInvalid:
            return "its signature is invalid — the download may be damaged or altered"
        case errSecCSBadResource, errSecCSBadObjectFormat:
            return "its contents don't match its signature"
        default:
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "OSStatus \(status)"
        }
    }

    /// The short version string inside a bundle, for the "is it actually newer" check.
    public static func shortVersion(ofBundleAt url: URL) -> String? {
        guard let plist = NSDictionary(contentsOf:
                url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// A downloaded bundle is only installed when it is strictly newer, so a replayed
    /// or rolled-back manifest can't walk the user backwards.
    public static func checkNewer(candidate: URL, than running: String) -> Failure? {
        guard let raw = shortVersion(ofBundleAt: candidate), let offered = AppVersion(raw) else {
            return .signature("the download has no readable version")
        }
        guard let current = AppVersion(running) else { return nil }   // can't judge; allow
        guard offered > current else { return .notNewer(raw) }
        return nil
    }
}

// MARK: - Downloading and installing

extension AppUpdater {

    /// Download, verify and stage an update, then hand the swap off and quit.
    ///
    /// Everything up to the hand-off is reversible: on any failure the installed app is
    /// untouched and the user still has the "open the DMG" route. The hand-off is the
    /// only irreversible step, and by then the archive has been checksummed, its
    /// signature checked against the configured Developer ID, and its version confirmed
    /// newer.
    @MainActor
    public static func installUpdate(_ manifest: UpdateManifest,
                                     configuration: UpdaterConfiguration,
                                     runningVersion: String = Bundle.main.shortVersionString,
                                     bundleURL: URL = Bundle.main.bundleURL,
                                     report: @MainActor @escaping (InstallStage) -> Void = { _ in }) async -> Failure? {
        // Preconditions first, before the download rather than at the hand-off, so a
        // problem costs a moment instead of the whole transfer.
        if let reason = ineligibilityReason(appName: configuration.appName, bundleURL: bundleURL) {
            return .notEligible(reason)
        }
        guard let (archiveURL, expectedHash) = manifest.installableArchive else {
            return .notEligible("This update doesn't publish an archive the app can install.")
        }
        if let helper = configuration.swap.helperURL(inBundle: bundleURL),
           !FileManager.default.isExecutableFile(atPath: helper.path) {
            return .notEligible("The updater helper is missing from this build.")
        }

        // Staged INSIDE the install directory, not /tmp: the swap needs the
        // replacement on the same volume, and /Applications is often a different one.
        let installDirectory = bundleURL.deletingLastPathComponent()
        let staging = installDirectory
            .appendingPathComponent("\(stagingPrefix)download-\(UUID().uuidString)", isDirectory: true)
        // Covers every failure path. NOT the success path: that ends in terminate, and
        // the process is gone before this runs — see `handOff`.
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return .install(error.localizedDescription)
        }

        // --- Download ---
        //
        // Streamed to disk inside staging. The bytes are inert until they are checked
        // and expanded below.
        let archiveFile = staging.appendingPathComponent("update.zip")
        do {
            try await download(archiveURL, expecting: manifest.archiveSize, to: archiveFile, report: report)
        } catch Failure.cancelled {
            // The user asked to stop. Without this the catch below turned it into
            // "Couldn't download the update: …" — an error alert for doing as told.
            return .cancelled
        } catch let failure as Failure {
            return failure
        } catch {
            return .download(error.localizedDescription)
        }

        // --- Verify the bytes before they become code ---
        report(.verifying)
        guard let data = try? Data(contentsOf: archiveFile, options: .mappedIfSafe) else {
            return .install("the downloaded archive couldn't be read back")
        }
        guard hashMatches(data, expected: expectedHash) else { return .hashMismatch }

        // --- Expand ---
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
        guard expand(archiveFile, into: expanded) else { return .unreadableArchive }
        guard let staged = findApp(in: expanded) else { return .noAppInArchive }

        // --- Verify what we are about to run ---
        if let failure = verifySignature(of: staged, requirement: requirementString(for: configuration)) {
            return failure
        }
        if let failure = checkNewer(candidate: staged, than: runningVersion) { return failure }
        if let failure = checkAnnounced(candidate: staged, version: manifest.version) { return failure }
        if let failure = checkRequiredExecutables(configuration.requiredExecutables, in: staged) {
            return failure
        }

        // --- Hand off and quit ---
        if Task.isCancelled { return .cancelled }
        report(.relaunching)
        do {
            try handOff(staged: staged, clearing: staging, replacing: bundleURL, swap: configuration.swap)
        } catch let failure as Failure {
            return failure
        } catch {
            return .install(error.localizedDescription)
        }
        NSApp.terminate(nil)
        return nil
    }

    /// Progress for `download(_:expecting:to:report:)`.
    ///
    /// A delegate rather than iterating `URLSession.bytes`, which is what this used to
    /// do. That sequence yields ONE BYTE per async iteration: measured against a plain
    /// fetch of the same 5 MB update it took 34.28s versus 0.36s — ninety-five times
    /// slower — and because the loop was `@MainActor`, every one of those five million
    /// hops ran on the main thread, so the window sat frozen for the whole download.
    /// URLSession reports progress here at its own cadence instead, off the main actor.
    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Int, Int?) -> Void
        /// Guards `lastFraction` only — the callback arrives on URLSession's queue.
        private let lock = NSLock()
        private var lastFraction = 0.0

        init(onProgress: @escaping @Sendable (Int, Int?) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite) : nil
            guard let total else { return onProgress(Int(totalBytesWritten), nil) }
            // At most one report per percent, so a fast download doesn't push hundreds
            // of view updates through for a bar that only has so many pixels.
            let fraction = Double(totalBytesWritten) / Double(total)
            lock.lock()
            let worthReporting = fraction - lastFraction >= 0.01
            if worthReporting { lastFraction = fraction }
            lock.unlock()
            if worthReporting { onProgress(Int(totalBytesWritten), total) }
        }

        /// Required by the protocol; the async `download(from:delegate:)` takes the
        /// finished file itself, so there is nothing to do here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    /// Download `url` to `destination`, reporting progress.
    ///
    /// Left on disk rather than read into memory: the install only ever needs the file
    /// (it is checksummed through a mapping and expanded by `ditto`), and holding a
    /// whole archive in a `Data` for the length of the install costs its full size in
    /// memory for nothing.
    @MainActor
    public static func download(_ url: URL, expecting size: Int?, to destination: URL,
                                report: @MainActor @escaping (InstallStage) -> Void) async throws {
        report(.downloading(receivedBytes: 0, totalBytes: size))
        let progress = DownloadProgress { received, total in
            Task { @MainActor in report(.downloading(receivedBytes: received, totalBytes: total)) }
        }

        let fileURL: URL
        let response: URLResponse
        do {
            (fileURL, response) = try await URLSession.shared.download(from: url, delegate: progress)
        } catch is CancellationError {
            // Cancelling is safe for the whole download: nothing has been staged, and
            // the installed copy has not been touched.
            throw Failure.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw Failure.cancelled
        }
        // The async API hands over a temp file we now own. Removed on every path; after
        // a successful move there is nothing left at this URL to remove.
        defer { try? FileManager.default.removeItem(at: fileURL) }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.download("the server returned \(http.statusCode)")
        }
        // A published size is part of the contract; a short read means truncation,
        // which the checksum would also catch but this says so more clearly.
        let written = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        if let size, let written, written != size {
            throw Failure.download("expected \(size) bytes, received \(written)")
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)
        } catch {
            throw Failure.install(error.localizedDescription)
        }
    }

    /// Download `url` and return its bytes. For callers that want them in memory; the
    /// install itself uses `download(_:expecting:to:report:)`.
    @MainActor
    public static func download(_ url: URL, expecting size: Int?,
                                report: @MainActor @escaping (InstallStage) -> Void) async throws -> Data {
        let file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("updatekit-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: file) }
        try await download(url, expecting: size, to: file, report: report)
        return try Data(contentsOf: file)
    }

    /// `ditto -x -k` rather than an unzip library: it restores the symlinks, resource
    /// forks and extended attributes an app bundle's own signature is computed over.
    private static func expand(_ archive: URL, into directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func findApp(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension == "app" }
    }

    /// The version the user was offered must be the version in the box.
    ///
    /// `checkNewer` alone would let a manifest announcing 1.4 deliver 3.0 — newer, so
    /// it passes, but not what anyone agreed to install. Compared as `AppVersion`s so
    /// "1.4" and "1.4.0" are the same release.
    public static func checkAnnounced(candidate: URL, version announced: String) -> Failure? {
        guard let raw = shortVersion(ofBundleAt: candidate), let actual = AppVersion(raw) else {
            return .signature("the download has no readable version")
        }
        guard let expected = AppVersion(announced), actual == expected else {
            return .signature("the download is version \(raw), not the \(announced) offered")
        }
        return nil
    }

    /// Every path in `relativePaths` must be an executable inside `bundle`. See
    /// `UpdaterConfiguration.requiredExecutables`.
    public static func checkRequiredExecutables(_ relativePaths: [String], in bundle: URL) -> Failure? {
        for path in relativePaths
        where !FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent(path).path) {
            return .install("the download has no \(path)")
        }
        return nil
    }

    /// The prefix of everything the updater leaves beside the installed bundle.
    public static let stagingPrefix = ".updatekit-"

    /// Remove staging left behind by a force-quit mid-download, or by a helper that
    /// refused to swap. Without this a killed update leaks a hidden directory the size
    /// of the app into whatever folder the app lives in.
    ///
    /// Call it at launch. Anything younger than `age` is left alone, in case another
    /// copy of the app is updating right now.
    ///
    /// - Parameter prefixes: what to sweep. Pass the updater's own prefix plus any an
    ///   app used before adopting UpdateKit, so its older leftovers go too.
    public static func sweepStaleStaging(besideBundle bundleURL: URL = Bundle.main.bundleURL,
                                         prefixes: [String] = [stagingPrefix],
                                         olderThan age: TimeInterval = 3600,
                                         now: Date = Date()) {
        let manager = FileManager.default
        let parent = bundleURL.deletingLastPathComponent()
        let entries = (try? manager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let created, now.timeIntervalSince(created) > age else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    /// Start whatever performs the swap. It waits for this process to exit before
    /// touching anything; the caller quits straight after.
    private static func handOff(staged: URL, clearing staging: URL,
                                replacing installed: URL, swap: SwapStrategy) throws {
        // Move the staged app somewhere the staging cleanup won't remove it, still on
        // the install volume so the swap stays a rename.
        let keep = installed.deletingLastPathComponent()
            .appendingPathComponent("\(stagingPrefix)staged-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.moveItem(at: staged, to: keep)

        // Tear staging down HERE, now that the only thing worth keeping is out of it.
        //
        // The `defer` in installUpdate can't be relied on for this: the caller quits
        // straight after, and the process is gone before that function returns — so
        // staging (the archive plus its expanded copy, twice the app's size) survived
        // every successful update. The launch-time sweep couldn't collect it either: it
        // skips anything under an hour old, and the one launch guaranteed to follow an
        // update is the one where staging is seconds old.
        try? FileManager.default.removeItem(at: staging)

        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            switch swap {
            case .builtIn:
                _ = try BuiltInSwap.launch(pid: pid, staged: keep, installed: installed)
            case let .helper(_, arguments):
                try launchHelper(swap.helperURL(inBundle: installed)!,
                                 arguments: arguments, pid: pid, staged: keep, installed: installed)
            }
        } catch {
            // Nothing has been replaced; don't leave the staged copy lying beside it.
            try? FileManager.default.removeItem(at: keep)
            throw error
        }
    }

    /// Copy the bundled helper OUT of the bundle and start it. It cannot run from
    /// inside the bundle it is about to replace — it would be deleted from under
    /// itself.
    private static func launchHelper(_ helper: URL, arguments: [String],
                                     pid: pid_t, staged: URL, installed: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw Failure.install("the updater helper is missing from this build")
        }
        // Private to this user: the helper is about to be run, and a world-writable
        // parent would let anyone swap it between the copy and the launch.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("updatekit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let helperCopy = scratch.appendingPathComponent(helper.lastPathComponent)
        try FileManager.default.copyItem(at: helper, to: helperCopy)
        // copyItem carries extended attributes across. A quarantined binary executed
        // directly, rather than through LaunchServices, can trigger a Gatekeeper
        // assessment that wants the network — at the exact moment the app is quitting.
        helperCopy.withUnsafeFileSystemRepresentation { path in
            if let path { _ = removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
        }

        let process = Process()
        process.executableURL = helperCopy
        process.arguments = arguments + ["--pid", String(pid),
                                         "--staged", staged.path,
                                         "--installed", installed.path]
        do {
            try process.run()
        } catch {
            throw Failure.install("the updater helper wouldn't start: \(error.localizedDescription)")
        }
    }
}
