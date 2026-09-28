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
                title: availableTitle(appName: appName, version: update.version),
                body: update.notes
                    ?? String(localized: "A newer version is available. \(appName) can install it and relaunch.",
                              bundle: #bundle,
                              comment: "Update dialog text when there are no release notes. The argument is the app's name."),
                buttons: [String(localized: "Update and Relaunch", bundle: #bundle,
                                 comment: "Button: install the update in place and reopen the app."),
                          String(localized: "Download", bundle: #bundle,
                                 comment: "Button: open the update's disk image in the browser instead."),
                          String(localized: "Later", bundle: #bundle,
                                 comment: "Button: close the update dialog without updating.")]) {
            case 0: install(with: checker)
            case 1: NSWorkspace.shared.open(update.url)
            default: break
            }
        case .download(let update):
            // Say what the button does. "Download" next to a version number reads as
            // "install it", and when the disk image appeared instead the honest
            // reaction was to wonder where the installer had gone.
            //
            // One whole sentence with the reason and one without, rather than the reason
            // glued to the front: word order and spacing are the translator's call.
            let howTo: String
            if let reason = checker.ineligibilityReason {
                howTo = String(localized: "\(reason) Downloading opens the disk image — drag \(appName) to your Applications folder to finish installing it.",
                               bundle: #bundle,
                               comment: "Update dialog. The first argument is a whole sentence saying why the app can't update itself; the second is the app's name.")
            } else {
                howTo = String(localized: "Downloading opens the disk image — drag \(appName) to your Applications folder to finish installing it.",
                               bundle: #bundle,
                               comment: "Update dialog. The argument is the app's name.")
            }
            let notes = update.notes
                ?? String(localized: "A newer version is available.", bundle: #bundle,
                          comment: "Update dialog text when there are no release notes.")
            if UpdateDialog.run(title: availableTitle(appName: appName, version: update.version),
                                body: notes + "\n\n" + howTo,
                                buttons: [String(localized: "Download Disk Image…", bundle: #bundle,
                                                 comment: "Button: open the update's disk image in the browser."),
                                          String(localized: "Later", bundle: #bundle,
                                                 comment: "Button: close the update dialog without updating.")]) == 0 {
                NSWorkspace.shared.open(update.url)
            }
        case .upToDate:
            let alert = NSAlert()
            alert.messageText = String(localized: "You're up to date", bundle: #bundle,
                                       comment: "Alert title after Check for Updates finds nothing newer.")
            alert.informativeText = String(localized: "\(appName) \(checker.currentVersion) is the latest version.",
                                           bundle: #bundle,
                                           comment: "Alert text after Check for Updates finds nothing newer. The arguments are the app's name and its version.")
            alert.runModal()
        case .failed(let message):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn't check for updates", bundle: #bundle,
                                       comment: "Alert title when Check for Updates fails.")
            alert.informativeText = message
            alert.runModal()
        case .none:
            break
        }
    }

    /// "Descarte 1.4 is available" — the dialog's title, and the banner's text.
    static func availableTitle(appName: String, version: String) -> String {
        String(localized: "\(appName) \(version) is available", bundle: #bundle,
               comment: "An update has been published. The arguments are the app's name and the new version number.")
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
            let appName = checker.configuration.appName
            alert.messageText = String(localized: "Couldn't install the update", bundle: #bundle,
                                       comment: "Alert title when an in-place update fails.")
            alert.informativeText = failure.errorDescription
                ?? String(localized: "The update couldn't be installed. Your copy of \(appName) is unchanged.",
                          bundle: #bundle,
                          comment: "Alert text when an in-place update fails for no stated reason. The argument is the app's name.")
            alert.addButton(withTitle: String(localized: "OK", bundle: #bundle, comment: "Button: close the alert."))
            // Nothing was changed, so the manual route is still open. Offer it here
            // rather than leaving the user at a dead end to go and find it.
            if diskImage != nil {
                alert.addButton(withTitle: String(localized: "Download Disk Image…", bundle: #bundle,
                                                  comment: "Button: open the update's disk image in the browser."))
            }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn, let diskImage {
                NSWorkspace.shared.open(diskImage)
            }
        }
    }
}
