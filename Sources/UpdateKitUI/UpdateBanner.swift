import SwiftUI
import AppKit
import UpdateKit

/// A slim notice across the top of a document window when a newer build has been
/// published. Passive by design: automatic checks never interrupt with a dialog,
/// they just surface this, and it can be set aside for that version.
///
/// Where it can, "Update and Relaunch" installs in place (see `AppUpdater`);
/// otherwise it falls back to opening the DMG in the browser.
public struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker
    let accent: Color
    let hairline: Color
    let transition: AnyTransition

    /// - Parameters:
    ///   - accent: the colour of the download glyph.
    ///   - hairline: the divider under the bar.
    ///   - transition: how the bar arrives and leaves. It is applied inside, because
    ///     the banner decides for itself whether it has anything to show.
    public init(checker: UpdateChecker,
                accent: Color = .accentColor,
                hairline: Color = Color.primary.opacity(0.10),
                transition: AnyTransition = .move(edge: .top).combined(with: .opacity)) {
        self.checker = checker
        self.accent = accent
        self.hairline = hairline
        self.transition = transition
    }

    public var body: some View {
        if let update = checker.pendingUpdate {
            // Bar and divider as one view, so they arrive and leave together — this
            // banner decides for itself whether it has anything to show, so the
            // transition has to live here rather than at the call site.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(accent)
                    Text(UpdateAlert.availableTitle(appName: checker.configuration.appName,
                                                    version: update.version))
                        .font(.system(size: 12, weight: .medium))
                    if let failure = checker.installFailure {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .lineLimit(1)
                            .help(failure)
                    } else if let notes = update.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // No inline progress here. The update reports itself in its own window
                    // (see UpdateProgressWindow), which is the only place that can show it
                    // when the install was started from the menu with no document open. Two
                    // indicators for one operation is how they drift apart.
                    if checker.isInstalling {
                        Text("Updating…", bundle: #bundle,
                             comment: "Update banner, while an update installs.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if case .install = UpdateAlert.offer(for: checker) {
                        // In place, and only when we know we can finish: an archive with a
                        // checksum and a writable location. The same decision the menu
                        // makes, so the two can't drift apart again.
                        Button(String(localized: "Update and Relaunch", bundle: #bundle,
                                      comment: "Button: install the update in place and reopen the app.")) {
                            UpdateAlert.install(with: checker)
                        }
                            .controlSize(.small)
                    } else {
                        // Everything else keeps the old route — opening the DMG in the
                        // browser — rather than offering a button that would fail. Labelled
                        // for what it does: next to a version number, a bare "Download"
                        // reads as "install".
                        Button(String(localized: "Download Disk Image…", bundle: #bundle,
                                      comment: "Button: open the update's disk image in the browser.")) {
                            NSWorkspace.shared.open(update.url)
                        }
                        .controlSize(.small)
                        .help(downloadHelp)
                    }
                    Button {
                        checker.dismissCurrent()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Dismiss until the next version", bundle: #bundle,
                                 comment: "Tooltip on the update banner's close button."))
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(.thinMaterial)
                Divider().overlay(hairline)
            }
            .transition(transition)
        }
    }

    /// The download button's tooltip: one whole sentence with the reason the app can't
    /// update itself and one without, rather than the reason glued to the front.
    private var downloadHelp: String {
        let appName = checker.configuration.appName
        if let reason = checker.ineligibilityReason {
            return String(localized: "\(reason) Drag \(appName) to your Applications folder to install it.",
                          bundle: #bundle,
                          comment: "Tooltip on the Download Disk Image button. The first argument is a whole sentence saying why the app can't update itself; the second is the app's name.")
        }
        return String(localized: "Drag \(appName) to your Applications folder to install it.", bundle: #bundle,
                      comment: "Tooltip on the Download Disk Image button. The argument is the app's name.")
    }
}
