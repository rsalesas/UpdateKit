import SwiftUI
import AppKit
import UpdateKit

/// Feedback for an explicit "Check for Updates…" — unlike the automatic check, the
/// user asked, so every outcome gets an answer.
///
/// A menu command is typically:
///
///     Button("Check for Updates…") {
///         Task {
///             await checker.check()
///             UpdateAlert.present(for: checker)
///         }
///     }
@MainActor
public enum UpdateAlert {

    /// What to offer for a given check result.
    ///
    /// A value rather than a branch inside `present`, for two reasons. The alert is a
    /// modal, so the choice can only be tested if it is separable from showing it. And
    /// the banner asks the same question — when the two asked it separately, the banner
    /// gained the in-place install and the menu quietly kept sending people to the DMG.
    public enum Offer: Equatable {
        /// Installable in place; the download stays as a second choice.
        case install(UpdateManifest)
        case download(UpdateManifest)
        case upToDate
        case failed(String)
        case none
    }

    public static func offer(for state: UpdateChecker.State, canInstallInPlace: Bool) -> Offer {
        switch state {
        case .available(let update):
            return update.installableArchive != nil && canInstallInPlace
                ? .install(update) : .download(update)
        case .upToDate: return .upToDate
        case .failed(let why): return .failed(why)
        case .idle, .checking: return .none
        }
    }

    public static func offer(for checker: UpdateChecker) -> Offer {
        offer(for: checker.state, canInstallInPlace: checker.ineligibilityReason == nil)
    }

    public static func present(for checker: UpdateChecker) {
        let appName = checker.configuration.appName
        switch offer(for: checker) {
        case .install(let update):
            switch UpdateDialog.run(
                title: "\(appName) \(update.version) is available",
                body: update.notes
                    ?? "A newer version is available. \(appName) can install it and relaunch.",
                buttons: ["Update and Relaunch", "Download", "Later"]) {
            case 0: install(with: checker)
            case 1: NSWorkspace.shared.open(update.url)
            default: break
            }
        case .download(let update):
            // Say what the button does. "Download" next to a version number reads as
            // "install it", and when the disk image appeared instead the honest
            // reaction was to wonder where the installer had gone.
            var text = update.notes ?? "A newer version is available."
            text += "\n\n" + (checker.ineligibilityReason.map { "\($0) " } ?? "")
                + "Downloading opens the disk image — drag \(appName) to your Applications "
                + "folder to finish installing it."
            if UpdateDialog.run(title: "\(appName) \(update.version) is available", body: text,
                                buttons: ["Download Disk Image…", "Later"]) == 0 {
                NSWorkspace.shared.open(update.url)
            }
        case .upToDate:
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "\(appName) \(checker.currentVersion) is the latest version."
            alert.runModal()
        case .failed(let message):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.runModal()
        case .none:
            break
        }
    }

    /// Start an install, from wherever it was asked for.
    ///
    /// One entry point for the banner and the menu alike, so both get the progress
    /// window and neither can quietly go without one. A failure still gets its own
    /// alert: the menu can be used with no document window open, and then there is no
    /// banner to put it in either.
    public static func install(with checker: UpdateChecker) {
        // Taken now: the disk image is what the user was offered alongside the install,
        // so it is what the fallback opens.
        let diskImage = checker.availableUpdate?.url
        UpdateProgressWindow.shared.show(checker: checker)
        Task {
            let failure = await checker.installAvailableUpdate()
            UpdateProgressWindow.shared.close()
            // Cancelling reports nothing: the user asked for it and already knows.
            guard let failure, failure != .cancelled else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the update"
            alert.informativeText = failure.errorDescription
                ?? "The update couldn't be installed. Your copy of \(checker.configuration.appName) is unchanged."
            alert.addButton(withTitle: "OK")
            // Nothing was changed, so the manual route is still open. Offer it here
            // rather than leaving the user at a dead end to go and find it.
            if diskImage != nil { alert.addButton(withTitle: "Download Disk Image…") }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn, let diskImage {
                NSWorkspace.shared.open(diskImage)
            }
        }
    }
}
