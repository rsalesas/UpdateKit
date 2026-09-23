import Foundation

/// Whether an app bundle is somewhere it cannot update itself from.
public enum RunLocation {

    /// True for a bundle the app should not run (or update) from:
    ///
    /// - **App Translocation** — a quarantined app opened outside a trusted location
    ///   (Applications). macOS runs it from a randomized, read-only path under
    ///   `/AppTranslocation/`, so `Bundle.main.bundleURL` is not where the user
    ///   thinks the app lives. This is what happens when you double-click the app
    ///   inside a freshly downloaded DMG, or run it from ~/Downloads.
    /// - **A read-only volume** — the mounted disk image itself (a compressed DMG is
    ///   read-only), caught for the case where translocation doesn't apply, e.g.
    ///   quarantine was stripped.
    public static func isUnsuitable(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") { return true }
        if let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return true
        }
        return false
    }
}
