import AppKit
import Foundation

/// Bringing back what the user had open across the quit an update needs.
///
/// The update quits the app with `NSApp.terminate`, which AppKit treats as an ordinary
/// quit. With macOS's default "Close windows when quitting an application", an ordinary
/// quit discards the app's saved windows, so the relaunched build opened with nothing:
/// every document the user had open was gone. Seen in Vaelora's update from 0.9.14 to
/// 0.9.15: `discardAllPersistentStateAndClose` at the quit, `hasPersistentStateToRestore=0`
/// at the relaunch.
///
/// Two remedies, because one isn't enough:
///
/// * **Documents are reopened by UpdateKit.** Before the quit it records the file of every
///   open document; after the relaunch it opens them again. Measured in Vaelora (a
///   SwiftUI `DocumentGroup`): setting `NSQuitAlwaysKeepsWindows` from inside the app
///   right before `terminate` still discarded the state, so AppKit's restoration can't be
///   relied on for document windows.
/// * **Other windows keep AppKit's restoration.** `NSQuitAlwaysKeepsWindows` is set in the
///   app's own domain for the update's quit and removed at the next launch. A plain AppKit
///   window restored this way, even with the setting removed before `NSApplication`
///   started: restoration reads the state the quit saved, not the setting.
///
/// The quit after that follows the user's own setting again: only the update's quit
/// keeps anything. A marker records that UpdateKit set the value, so a user who keeps
/// windows anyway (the system setting off) is left as they were.
public enum WindowsAcrossUpdate {
    static let quitKeepsWindowsKey = "NSQuitAlwaysKeepsWindows"
    static let markerKey = "UpdateKit.keptWindowsForUpdate"
    static let documentsKey = "UpdateKit.documentsToReopen"

    /// Before the update's quit: remember the open documents, and keep other windows.
    @MainActor
    public static func keep(in defaults: UserDefaults = .standard) {
        keep(documents: NSDocumentController.shared.documents.compactMap(\.fileURL), in: defaults)
    }

    static func keep(documents: [URL], in defaults: UserDefaults) {
        let bookmarks = documents.compactMap { try? $0.bookmarkData() }
        if bookmarks.isEmpty {
            defaults.removeObject(forKey: documentsKey)
        } else {
            defaults.set(bookmarks, forKey: documentsKey)
        }
        guard !defaults.bool(forKey: quitKeepsWindowsKey) else { return }
        defaults.set(true, forKey: quitKeepsWindowsKey)
        defaults.set(true, forKey: markerKey)
    }

    /// If the quit was refused: its next quit is an ordinary one, and nothing is reopened.
    public static func cancel(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: documentsKey)
        restoreQuitBehaviour(in: defaults)
    }

    /// After the relaunch: quitting follows the user's own setting again. Only undoes
    /// what `keep` did.
    public static func restoreQuitBehaviour(in defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: markerKey) else { return }
        defaults.removeObject(forKey: quitKeepsWindowsKey)
        defaults.removeObject(forKey: markerKey)
    }

    /// The documents the update's quit recorded, once: reading them forgets them, so a
    /// later launch can't reopen them again.
    static func takeDocuments(from defaults: UserDefaults) -> [URL] {
        guard let bookmarks = defaults.array(forKey: documentsKey) as? [Data] else { return [] }
        defaults.removeObject(forKey: documentsKey)
        return bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// After the relaunch, once the app has finished launching: reopen the documents the
    /// update's quit recorded. One already open (restored by AppKit, or opened by the
    /// launch itself) is left as it is.
    @MainActor
    public static func reopenDocuments(in defaults: UserDefaults = .standard) {
        let urls = takeDocuments(from: defaults)
        guard !urls.isEmpty else { return }
        let controller = NSDocumentController.shared
        for url in urls where controller.document(for: url) == nil {
            controller.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// Everything a relaunched app needs, run when its launch has finished. Called from
    /// `UpdateChecker`'s initialiser, which every app runs at launch.
    @MainActor
    static func finishRelaunch() {
        restoreQuitBehaviour()
        guard UserDefaults.standard.object(forKey: documentsKey) != nil else { return }
        // Opening documents before the launch has finished races the app's own launch
        // (a SwiftUI document app is still deciding whether to show its Open panel).
        if NSRunningApplication.current.isFinishedLaunching {
            DispatchQueue.main.async { MainActor.assumeIsolated { reopenDocuments() } }
            return
        }
        let token = ObserverToken()
        token.value = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            if let value = token.value { NotificationCenter.default.removeObserver(value) }
            MainActor.assumeIsolated { reopenDocuments() }
        }
    }

    private final class ObserverToken: @unchecked Sendable { var value: NSObjectProtocol? }
}
