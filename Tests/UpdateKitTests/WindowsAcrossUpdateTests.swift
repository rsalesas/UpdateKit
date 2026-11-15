import Foundation
import Testing
@testable import UpdateKit

@Suite("windows across the update's quit")
struct WindowsAcrossUpdateTests {
    private let suite = "updatekit-windows-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    private func document(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("# \(name)\n".utf8).write(to: url)
        return url
    }

    @Test("the update's quit keeps windows, and the next launch undoes it")
    func keepsThenRestores() {
        let defaults = self.defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        WindowsAcrossUpdate.keep(documents: [], in: defaults)
        #expect(defaults.bool(forKey: WindowsAcrossUpdate.quitKeepsWindowsKey))
        WindowsAcrossUpdate.restoreQuitBehaviour(in: defaults)
        #expect(defaults.object(forKey: WindowsAcrossUpdate.quitKeepsWindowsKey) == nil,
                "an ordinary quit must follow the user's own setting again")
        #expect(defaults.object(forKey: WindowsAcrossUpdate.markerKey) == nil)
    }

    @Test("an app that already keeps windows is left as it was")
    func leavesOwnSettingAlone() {
        let defaults = self.defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: WindowsAcrossUpdate.quitKeepsWindowsKey)
        WindowsAcrossUpdate.keep(documents: [], in: defaults)
        WindowsAcrossUpdate.restoreQuitBehaviour(in: defaults)
        #expect(defaults.bool(forKey: WindowsAcrossUpdate.quitKeepsWindowsKey),
                "restoring must not remove a value UpdateKit didn't set")
    }

    @Test("a launch with no update behind it changes nothing")
    func ordinaryLaunch() {
        let defaults = self.defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: WindowsAcrossUpdate.quitKeepsWindowsKey)
        WindowsAcrossUpdate.restoreQuitBehaviour(in: defaults)
        #expect(defaults.object(forKey: WindowsAcrossUpdate.quitKeepsWindowsKey) as? Bool == false)
        #expect(WindowsAcrossUpdate.takeDocuments(from: defaults).isEmpty)
    }

    @Test("the open documents come back once, and only those still there")
    func documentsComeBackOnce() throws {
        let defaults = self.defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        let kept = try document("kept.md"), gone = try document("gone.md")
        WindowsAcrossUpdate.keep(documents: [kept, gone], in: defaults)
        try FileManager.default.removeItem(at: gone)
        #expect(WindowsAcrossUpdate.takeDocuments(from: defaults).map(\.standardizedFileURL.path)
                == [kept.standardizedFileURL.path])
        #expect(WindowsAcrossUpdate.takeDocuments(from: defaults).isEmpty,
                "a second launch must not reopen them again")
        try? FileManager.default.removeItem(at: kept)
    }

    @Test("a refused quit forgets the documents and restores quitting")
    func refusedQuit() throws {
        let defaults = self.defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = try document("open.md")
        WindowsAcrossUpdate.keep(documents: [file], in: defaults)
        WindowsAcrossUpdate.cancel(in: defaults)
        #expect(WindowsAcrossUpdate.takeDocuments(from: defaults).isEmpty)
        #expect(defaults.object(forKey: WindowsAcrossUpdate.quitKeepsWindowsKey) == nil)
        try? FileManager.default.removeItem(at: file)
    }
}
