import Foundation
import Combine

/// Checks whether a newer build has been published, and runs the install.
///
/// One per app, shared by every window and the "Check for Updates…" command: an
/// install can be started from either, and the second can happen with no document
/// window open at all, so the state has to live somewhere neither owns.
@MainActor
public final class UpdateChecker: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    /// Set aside by the user for this version; cleared when a newer one appears.
    @Published public private(set) var dismissedVersion: String?

    public let configuration: UpdaterConfiguration
    /// The marketing version of the running copy.
    public let currentVersion: String

    /// Not `@Sendable`: the checker is main-actor isolated, so the closure is stored
    /// and awaited there. Keeping it un-sendable lets tests use a plain stub.
    public typealias Fetch = (URL) async throws -> Data

    public struct HTTPError: LocalizedError {
        public let status: Int
        public init(status: Int) { self.status = status }
        public var errorDescription: String? { "The update server returned status \(status)." }
    }

    /// `URLSession.data(for:)` does NOT throw on an HTTP error status — it hands back
    /// the error page's body. Without this check a 404 or a captive-portal login page
    /// would be fed to the JSON decoder, so the status is validated up front.
    nonisolated public static func defaultFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        return data
    }

    private let fetch: Fetch
    private let systemVersion: OperatingSystemVersion

    public init(configuration: UpdaterConfiguration,
                fetch: @escaping Fetch = UpdateChecker.defaultFetch,
                currentVersion: String = Bundle.main.shortVersionString,
                systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.configuration = configuration
        self.fetch = fetch
        self.currentVersion = currentVersion
        self.systemVersion = systemVersion
    }

    // MARK: - Preferences

    /// Whether the launch-time check runs. Read from `UserDefaults` every time rather
    /// than cached, so an app that binds its own settings UI to the same key stays in
    /// step with this.
    public var automaticallyChecks: Bool {
        get {
            let defaults = configuration.defaults
            let key = configuration.automaticChecksKey
            return defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        }
        set {
            objectWillChange.send()
            configuration.defaults.set(newValue, forKey: configuration.automaticChecksKey)
        }
    }

    /// When the last check ran, so automatic checks can be throttled.
    public var lastCheck: Date? {
        get {
            let t = configuration.defaults.double(forKey: configuration.lastCheckKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            configuration.defaults.set(newValue?.timeIntervalSince1970 ?? 0,
                                       forKey: configuration.lastCheckKey)
        }
    }

    // MARK: - What's on offer

    /// The update to show, if there is one the user hasn't set aside.
    public var pendingUpdate: UpdateManifest? {
        guard case .available(let manifest) = state,
              manifest.version != dismissedVersion else { return nil }
        return manifest
    }

    /// The update on offer, whether or not the banner is showing it.
    ///
    /// Read from `state` rather than `pendingUpdate`, which goes nil once the notice has
    /// been set aside. Two callers need that distinction: an install started before the
    /// dismissal would otherwise lose the number it is installing halfway through, and a
    /// settings screen should keep offering the update — dismissing the notice means
    /// "stop interrupting me", not "never mention this again".
    public var availableUpdate: UpdateManifest? {
        if case .available(let manifest) = state { return manifest }
        return nil
    }

    /// The version on offer, whether or not the banner is showing it.
    public var availableVersion: String? { availableUpdate?.version }

    /// Stop showing the banner for this version. A later version brings it back.
    public func dismissCurrent() {
        if case .available(let manifest) = state { dismissedVersion = manifest.version }
    }

    /// Why this copy can't update itself in place, or nil if it can.
    public var ineligibilityReason: String? {
        AppUpdater.ineligibilityReason(appName: configuration.appName)
    }

    /// Whether `manifest` can be installed in place, as opposed to needing the disk
    /// image. One answer for every surface that offers the update, so they can't differ.
    public func canInstallInPlace(_ manifest: UpdateManifest) -> Bool {
        manifest.installableArchive != nil && ineligibilityReason == nil
    }

    // MARK: - Installing

    /// What the running install is doing, or nil when none is.
    ///
    /// Held here rather than in a view because an install can be started from the
    /// banner or from "Check for Updates…", and the second can happen with no document
    /// window open at all — which is how the first real in-place update ran to
    /// completion with nothing on screen to say so.
    @Published public private(set) var installStage: AppUpdater.InstallStage?
    /// The last install failure, shown in the banner.
    @Published public private(set) var installFailure: String?

    public var isInstalling: Bool { installStage != nil }

    /// The running install, kept so it can be cancelled. Everything before the hand-off
    /// is reversible — nothing is staged and the installed copy is untouched — so
    /// cancelling is safe right up to the last step.
    private var installTask: Task<AppUpdater.Failure?, Never>?

    public func cancelInstall() { installTask?.cancel() }

    /// Download, verify and install the available update in place.
    ///
    /// On success this never returns — the app quits and the new copy is relaunched.
    /// Returns the failure otherwise, for a caller that has nowhere to show
    /// `installFailure`.
    @discardableResult
    public func installAvailableUpdate() async -> AppUpdater.Failure? {
        guard case .available(let manifest) = state, installStage == nil else { return nil }
        installFailure = nil
        installStage = .downloading(receivedBytes: 0, totalBytes: manifest.archiveSize)

        let configuration = configuration
        let runningVersion = currentVersion
        let task = Task { @MainActor [weak self] in
            await AppUpdater.installUpdate(manifest, configuration: configuration,
                                           runningVersion: runningVersion) { stage in
                self?.installStage = stage
            }
        }
        installTask = task
        let failure = await task.value
        installTask = nil
        installStage = nil
        // Cancelling is the user's own instruction, not a fault to report back at them.
        installFailure = failure == .cancelled ? nil : failure?.errorDescription
        return failure
    }

    // MARK: - Checking

    /// The launch-time check: skipped when the user has turned it off, when we
    /// already looked recently, or while an install is under way.
    public func checkIfDue(now: Date = Date()) async {
        guard automaticallyChecks, !isInstalling else { return }
        if let last = lastCheck,
           now.timeIntervalSince(last) < configuration.checkInterval { return }
        await check(now: now)
    }

    /// An explicit "Check for Updates…" — ignores both the interval and the
    /// preference, since the user just asked for it directly.
    ///
    /// Does nothing while an install is running. A check replaces `state`, and the
    /// install reads the version it is installing from there — a periodic check landing
    /// mid-download would leave the progress window without a version, and one that
    /// failed would take the offer away while it was being taken up.
    public func check(now: Date = Date()) async {
        guard !isInstalling else { return }
        state = .checking
        do {
            let data = try await fetch(configuration.manifestURL)
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            lastCheck = now
            state = resolve(manifest)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Decide what a fetched manifest means for this copy of the app.
    private func resolve(_ manifest: UpdateManifest) -> State {
        guard let offered = AppVersion(manifest.version) else {
            return .failed("Unreadable version in the update manifest.")
        }
        guard let running = AppVersion(currentVersion) else {
            return .failed("Unreadable version in this build.")
        }
        guard offered > running else { return .upToDate }
        guard meetsMinimumSystem(manifest) else { return .upToDate }
        // A dismissal is keyed to its version string, so a newer release surfaces
        // on its own without needing to clear anything here.
        return .available(manifest)
    }

    /// A build that needs a newer macOS than this Mac runs isn't an update we can offer.
    private func meetsMinimumSystem(_ manifest: UpdateManifest) -> Bool {
        guard let required = manifest.minimumSystemVersion,
              let needed = AppVersion(required) else { return true }
        let running = AppVersion("\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)")
        guard let running else { return true }
        return running >= needed
    }
}
