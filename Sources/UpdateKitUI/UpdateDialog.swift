import SwiftUI
import AppKit
import UpdateKit

/// The "an update is available" dialog.
///
/// Not an `NSAlert`, which sets its title a little below the top of the 64pt icon and
/// offers no way to change that. On a one-line "Are you sure?" nobody notices; beside
/// three paragraphs of release notes the eye has a long left edge to compare the two
/// against, and the title reads as hanging off a floating icon.
///
/// Hosted the same way `UpdateProgressWindow` is, and for the same reason: "Check for
/// Updates…" can be used with no document window open, so there is no live view to
/// present a sheet from. Run modally so the caller can still just ask and get an answer.
@MainActor
public enum UpdateDialog {

    /// Shows the dialog and returns the index of the button pressed. `buttons[0]` is the
    /// default (rightmost, Return); the last also answers to Escape, and is what a closed
    /// window counts as.
    public static func run(title: String, body: String, buttons: [String]) -> Int {
        var choice = buttons.count - 1

        // A hosting *controller* rather than a hosting view: it sizes the window to the
        // SwiftUI content. Setting a content view and a size separately leaves the window
        // taller than the layout, and SwiftUI then centres the content in the slack.
        let controller = NSHostingController(rootView: UpdateDialogView(
            title: title, message: body, buttons: buttons,
            choose: { index in
                choice = index
                NSApp.stopModal()
            }))
        // The mask goes on at construction: assigning it afterwards leaves the controller
        // laid out for the old one, which shows up as a titlebar's worth of dead space
        // above the icon.
        // The window has no visible titlebar, so the content should not keep clear of
        // where one would be. Told to the controller rather than the view: `.ignoresSafeArea()`
        // moves the content up but leaves the inset in the size it reports, so the window
        // keeps the height and the slack reappears under the buttons.
        controller.safeAreaRegions = []

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller

        window.title = title              // what VoiceOver and the Window menu read
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The way out is a button, so that the caller always gets a real answer.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        controller.view.layoutSubtreeIfNeeded()
        window.setContentSize(controller.view.fittingSize)
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return choice
    }
}

/// Icon beside the text, buttons under it — the shape `NSAlert` uses, with the title's
/// top on the icon's top.
struct UpdateDialogView: View {
    let title: String
    let message: String
    let buttons: [String]
    let choose: (Int) -> Void

    var body: some View {
        // `.top` is the whole reason this is hand-built: the icon and the heading share
        // an edge because they are laid out to, not because a value was tuned until they
        // looked like they did.
        HStack(alignment: .top, spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    // Three buttons is the platform's "two actions and a way out": the way
                    // out goes to the left, apart from the choice being offered, so it
                    // cannot be hit by someone aiming for the one next to it.
                    if buttons.count > 2, let last = buttons.last {
                        button(last, at: buttons.count - 1)
                    }
                    Spacer()
                    // Rightmost is the default, matching the platform.
                    ForEach(Array(buttons.enumerated()).reversed(), id: \.offset) { index, label in
                        if buttons.count <= 2 || index != buttons.count - 1 {
                            button(label, at: index)
                        }
                    }
                }
                .padding(.top, 10)
            }
            .frame(width: 400, alignment: .leading)
            // A macOS app icon is drawn inside its canvas with a margin, so matching the
            // two frames leaves the title a few points above the artwork it is meant to
            // line up with. This is that margin.
            .padding(.top, 6)
        }
        .padding(20)
    }

    @ViewBuilder private func button(_ label: String, at index: Int) -> some View {
        let action = { choose(index) }
        if index == 0 {
            Button(label, action: action)
                .keyboardShortcut(.defaultAction)
        } else if index == buttons.count - 1 {
            Button(label, action: action)
                .keyboardShortcut(.cancelAction)
        } else {
            Button(label, action: action)
        }
    }
}

