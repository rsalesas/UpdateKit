import SwiftUI
import AppKit
import UpdateKit

/// A small window reporting an in-place update while it runs.
///
/// It exists because the first real in-place update ran to completion with nothing on
/// screen to say so. Progress lived in the document window's banner, and "Check for
/// Updates…" can be used with no document open — which is exactly what happened: the
/// alert dismissed, the open panel sat there, and the app quietly downloaded, verified
/// and replaced itself before vanishing to relaunch.
///
/// Built in AppKit rather than as a SwiftUI `Window` scene. A scene has to be opened through `openWindow` from a live view, and
/// the case this is for is precisely the one where no such view exists.
@MainActor
public final class UpdateProgressWindow: NSObject, NSWindowDelegate {
    public static let shared = UpdateProgressWindow()

    private var window: NSWindow?

    /// Show the window for `checker`, or bring it forward if it is already up.
    public func show(checker: UpdateChecker) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = UpdateProgressView(checker: checker) { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Updating \(checker.configuration.appName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        // No close button: the way out is Cancel, which stops the download rather than
        // leaving it running behind a shut window.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    public func close() {
        window?.orderOut(nil)
        window = nil
    }
}

/// The window's contents: what it is doing, how far along, and a way out.
struct UpdateProgressView: View {
    @ObservedObject var checker: UpdateChecker
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The app's own icon, sized and stacked as the standard About panel does it:
            // 64pt, centred, with the name beneath. It is the same question being asked
            // — which app is this? — so it should look like the same answer.
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .padding(.bottom, 12)
            }

            Text("Updating \(checker.configuration.appName)")
                .font(.system(size: 14, weight: .medium))

            if let version = checker.availableVersion {
                Text("Version \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Spacer().frame(height: 18)

            // Determinate while bytes are arriving, indeterminate for the checks after,
            // which have no measurable length and would otherwise show a bar frozen at
            // 100% — which reads as stuck rather than busy.
            if let fraction = checker.installStage?.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }

            Text(checker.installStage?.text ?? "Finishing…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 10)

            // Gone once the hand-off starts: from there the helper is already waiting on
            // this process to exit, and there is nothing left to call off.
            if checker.installStage != .relaunching {
                Button("Cancel") {
                    checker.cancelInstall()
                    dismiss()
                }
                .controlSize(.small)
                .padding(.top, 16)
            } else {
                // Said out loud: an app that vanishes without warning is alarming, and
                // for an app with no Dock icon there is nothing else on screen to say
                // it is coming back.
                Text("\(checker.configuration.appName) will reopen in a moment.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 340)
        // The install ends by relaunching, so this normally never runs — it is the
        // path for a cancel or a failure, where the window must not be left behind.
        .onChange(of: checker.isInstalling) { _, installing in
            if !installing { dismiss() }
        }
    }
}
