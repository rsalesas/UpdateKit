import Testing
import Foundation
@testable import UpdateKit

/// The checks added for apps whose bundle other programs depend on (Claunnector's
/// daemon is launched by path from MCP client configs), and the housekeeping around
/// staging. As elsewhere, weighted towards what must fail.
@MainActor
@Suite("what a download must be")
struct InstallChecksTests {
    private let temp = TempDir()

    /// A bundle-shaped directory with a version and, optionally, executables in it.
    private func makeBundle(version: String?, executables: [String] = []) throws -> URL {
        let app = temp.child("chk").appendingPathComponent("Fake.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "app.example"]
        if let version { plist["CFBundleShortVersionString"] = version }
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        for path in executables {
            let file = app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return app
    }

    // MARK: - The announced version

    @Test("the version offered is the version installed")
    func theVersionOfferedIsTheVersionInstalled() throws {
        let app = try makeBundle(version: "1.4.0")
        #expect(AppUpdater.checkAnnounced(candidate: app, version: "1.4.0") == nil)
        #expect(AppUpdater.checkAnnounced(candidate: app, version: "1.4") == nil,
                "1.4 and 1.4.0 are the same release")
    }

    /// Newer than the running copy is not enough: the user agreed to 1.4, not to
    /// whatever a tampered manifest pointed at.
    @Test("a different version than the one offered is refused")
    func aDifferentVersionIsRefused() throws {
        let app = try makeBundle(version: "3.0.0")
        guard case .signature(let why) = AppUpdater.checkAnnounced(candidate: app, version: "1.4.0") else {
            Issue.record("a download that isn't the announced version must be refused")
            return
        }
        #expect(why.contains("3.0.0") && why.contains("1.4.0"), "\(why)")
    }

    @Test("an unreadable announced or bundled version is refused")
    func unreadableVersionsAreRefused() throws {
        #expect(AppUpdater.checkAnnounced(candidate: try makeBundle(version: nil), version: "1.4.0") != nil)
        #expect(AppUpdater.checkAnnounced(candidate: try makeBundle(version: "1.4.0"), version: "latest") != nil)
    }

    // MARK: - Required executables

    @Test("a download with everything required passes")
    func everythingRequiredPasses() throws {
        let app = try makeBundle(version: "1.0", executables: ["Contents/Helpers/tool"])
        #expect(AppUpdater.checkRequiredExecutables(["Contents/Helpers/tool"], in: app) == nil)
        #expect(AppUpdater.checkRequiredExecutables([], in: app) == nil)
    }

    /// The case the check exists for: a validly signed release that moved something
    /// other programs launch by absolute path.
    @Test("a download missing a required executable is refused")
    func aMissingExecutableIsRefused() throws {
        let app = try makeBundle(version: "1.0", executables: ["Contents/MacOS/tool"])
        guard case .install(let why) = AppUpdater.checkRequiredExecutables(
            ["Contents/Helpers/tool"], in: app) else {
            Issue.record("a moved helper must be refused")
            return
        }
        #expect(why.contains("Contents/Helpers/tool"), "\(why)")
    }

    @Test("a required path that isn't executable is refused")
    func aNonExecutableIsRefused() throws {
        let app = try makeBundle(version: "1.0")
        let file = app.appendingPathComponent("Contents/Helpers/tool")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("text".utf8).write(to: file)
        #expect(AppUpdater.checkRequiredExecutables(["Contents/Helpers/tool"], in: app) != nil)
    }

    // MARK: - Preconditions

    /// Checked before the download, so a build missing its helper costs a moment rather
    /// than the whole transfer — and never reaches the hand-off at all.
    @Test("a missing swap helper is refused before downloading")
    func aMissingHelperIsRefusedUpFront() async throws {
        let app = try makeBundle(version: "1.0")
        var configuration = UpdaterConfiguration(
            appName: "Example", bundleIdentifier: "app.example", teamIdentifier: "ABCDE12345",
            manifestURL: URL(string: "https://dl.example.app/latest/appcast.json")!,
            swap: .helper(relativePath: "Contents/Helpers/missing"))
        configuration.requiredExecutables = []
        let manifest = UpdateManifest(
            version: "2.0", url: URL(string: "https://dl.example.app/2.0/x.dmg")!,
            // Unreachable on purpose: if the precondition didn't stop it, this would
            // fail as a download error instead.
            archive: URL(string: "https://invalid.invalid/x.zip")!,
            sha256: String(repeating: "a", count: 64))
        let failure = await AppUpdater.installUpdate(manifest, configuration: configuration,
                                                     runningVersion: "1.0", bundleURL: app)
        guard case .notEligible(let why) = failure else {
            Issue.record("expected .notEligible, got \(String(describing: failure))")
            return
        }
        #expect(why.contains("helper"), "\(why)")
        // Nothing left behind beside the bundle.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: app.deletingLastPathComponent().path)
        #expect(siblings == ["Fake.app"], "\(siblings)")
    }

    // MARK: - Staging housekeeping

    private func makeEntry(_ name: String, in dir: URL, age: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
        return url
    }

    @Test("stale staging is swept, and nothing else")
    func staleStagingIsSwept() throws {
        let dir = temp.child("sweep")
        let app = try makeEntry("Example.app", in: dir, age: 7200)
        let stale = try makeEntry(".updatekit-download-OLD", in: dir, age: 7200)
        let staleStaged = try makeEntry(".updatekit-staged-OLD.app", in: dir, age: 7200)
        let fresh = try makeEntry(".updatekit-download-NEW", in: dir, age: 60)
        let unrelated = try makeEntry(".something-else", in: dir, age: 7200)

        AppUpdater.sweepStaleStaging(besideBundle: app)

        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        #expect(!exists(stale) && !exists(staleStaged), "an hour-old staging directory must go")
        #expect(exists(fresh), "a young one may be another copy updating right now")
        #expect(exists(app) && exists(unrelated), "only the updater's own leftovers are touched")
    }

    /// An app adopting UpdateKit has leftovers under the names its own updater used.
    @Test("extra prefixes sweep an app's older leftovers")
    func extraPrefixesAreSwept() throws {
        let dir = temp.child("sweep")
        let app = try makeEntry("Example.app", in: dir, age: 7200)
        let legacy = try makeEntry(".example-update-OLD", in: dir, age: 7200)
        AppUpdater.sweepStaleStaging(besideBundle: app,
                                     prefixes: [AppUpdater.stagingPrefix, ".example-update-"])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}

/// What the checker exposes for surfaces other than the banner.
@MainActor
@Suite("the checker's offer")
struct CheckerOfferTests {
    private func checker(serving json: String) -> UpdateChecker {
        let suite = "updatekit-offer-\(UUID().uuidString)"
        return UpdateChecker(
            configuration: UpdaterConfiguration(
                appName: "Example", bundleIdentifier: "app.example", teamIdentifier: "ABCDE12345",
                manifestURL: URL(string: "https://dl.example.app/latest/appcast.json")!,
                defaults: UserDefaults(suiteName: suite)!),
            fetch: { _ in Data(json.utf8) },
            currentVersion: "1.0.0")
    }

    /// A dismissal hides the notice. It must not take the update away from a settings
    /// screen the user opened on purpose to find it.
    @Test("dismissing hides the notice but keeps the update available")
    func dismissingKeepsTheUpdateAvailable() async {
        let checker = checker(serving: #"{"version":"2.0.0","url":"https://dl.example.app/2.0.0/x.dmg"}"#)
        await checker.check()
        checker.dismissCurrent()
        #expect(checker.pendingUpdate == nil)
        #expect(checker.availableUpdate?.version == "2.0.0")
        #expect(checker.availableVersion == "2.0.0")
    }

    @Test("an update without an archive can't be installed in place")
    func noArchiveNoInstall() async throws {
        let checker = checker(serving: #"{"version":"2.0.0","url":"https://dl.example.app/2.0.0/x.dmg"}"#)
        await checker.check()
        let update = try #require(checker.availableUpdate)
        #expect(!checker.canInstallInPlace(update))
    }
}

/// The file-based download the install uses.
@MainActor
@Suite("downloading to disk")
struct DownloadToFileTests {
    private let temp = TempDir()

    @Test("the archive lands at the destination, byte for byte")
    func theArchiveLandsAtTheDestination() async throws {
        let dir = temp.child("dl")
        let source = dir.appendingPathComponent("source.zip")
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let destination = dir.appendingPathComponent("update.zip")

        try await AppUpdater.download(source, expecting: payload.count, to: destination, report: { _ in })
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test("a short download leaves nothing at the destination")
    func aShortDownloadLeavesNothing() async throws {
        let dir = temp.child("dl")
        let source = dir.appendingPathComponent("source.zip")
        try Data(count: 1000).write(to: source)
        let destination = dir.appendingPathComponent("update.zip")
        await #expect(throws: AppUpdater.Failure.self) {
            try await AppUpdater.download(source, expecting: 1001, to: destination, report: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
