import Foundation

/// Everything that makes an updater belong to one app.
///
/// The security-relevant fields — `bundleIdentifier` and `teamIdentifier` — have no
/// defaults worth trusting, so they are required. Everything else defaults to what a
/// typical direct-download app wants.
///
/// `@unchecked` only because of `defaults`: `UserDefaults` is documented as
/// thread-safe but is not marked `Sendable`. Every other field is a value.
public struct UpdaterConfiguration: @unchecked Sendable {
    /// The name the UI and error messages use ("Vaelora 1.2 is available").
    public var appName: String
    /// The identifier a downloaded bundle must carry. Part of the signing requirement.
    public var bundleIdentifier: String
    /// Your Developer ID team. Pinned deliberately: a signature check that accepts
    /// *any* valid Developer ID accepts every paid developer account, which is not a
    /// meaningful gate.
    public var teamIdentifier: String
    /// Where the JSON manifest lives, e.g. `https://dl.example.app/latest/appcast.json`.
    /// Serve it with `no-cache`: a cached manifest is a release nobody hears about.
    public var manifestURL: URL
    /// How long an automatic check waits before looking again. Manual checks ignore it.
    public var checkInterval: TimeInterval
    /// Who performs the final swap once the app has quit.
    public var swap: SwapStrategy
    /// Where the "check automatically" preference and the last-check time are kept.
    public var defaults: UserDefaults
    /// Bool, absent reads as `true`.
    public var automaticChecksKey: String
    /// Seconds since 1970 as a Double; 0 or absent means "never".
    public var lastCheckKey: String

    public init(appName: String = UpdaterConfiguration.mainBundleName,
                bundleIdentifier: String,
                teamIdentifier: String,
                manifestURL: URL,
                checkInterval: TimeInterval = 24 * 60 * 60,
                swap: SwapStrategy = .builtIn,
                defaults: UserDefaults = .standard,
                automaticChecksKey: String = "UpdateKit.automaticChecks",
                lastCheckKey: String = "UpdateKit.lastCheck") {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.manifestURL = manifestURL
        self.checkInterval = checkInterval
        self.swap = swap
        self.defaults = defaults
        self.automaticChecksKey = automaticChecksKey
        self.lastCheckKey = lastCheckKey
    }

    /// `CFBundleDisplayName`, else `CFBundleName`, else the process name.
    public static var mainBundleName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }
}

/// How the installed bundle gets replaced after the app quits.
///
/// A bundle cannot replace itself while its own code is mapped, so something outside
/// it has to wait for the app to exit and do the swap.
public enum SwapStrategy: Sendable, Equatable {
    /// A short `/bin/sh` script: wait for the app to exit, move the old bundle aside,
    /// move the new one in (putting the old one back if that fails), relaunch. Needs
    /// nothing bundled.
    case builtIn
    /// An executable inside the app bundle, at `relativePath` from the bundle root
    /// (e.g. `"Contents/Helpers/mytool"`). It is copied out of the bundle before it
    /// runs, then invoked as `helper <arguments…> --pid P --staged S --installed I`.
    /// Have it call `UpdateSwap.run(arguments:)`, which replaces the bundle with one
    /// atomic `replaceItemAt`.
    case helper(relativePath: String, arguments: [String] = [])

    /// Where a `.helper` lives inside `bundleURL`; nil for `.builtIn`.
    public func helperURL(inBundle bundleURL: URL) -> URL? {
        guard case let .helper(relativePath, _) = self else { return nil }
        return bundleURL.appendingPathComponent(relativePath)
    }
}
