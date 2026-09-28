import Testing
import Foundation
import CryptoKit
@testable import UpdateKit
@testable import UpdateKitUI

/// The gate on installing a downloaded update.
///
/// Replacing our own bundle bypasses the Gatekeeper check the user would otherwise
/// get on a downloaded app, so these checks ARE the security boundary — a hole here
/// turns "someone can serve bytes at our download URL" into "someone can run code as
/// the user". Every one of them is tested against something that should fail, not
/// only against the happy path.
@MainActor
@Suite("the app updater")
struct AppUpdaterTests {
    private let temp = TempDir()
    private let strict = AppUpdater.requirementString(bundleIdentifier: "app.example",
                                                      teamIdentifier: "ABCDE12345")
    private let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private func tempDir() throws -> URL {
        temp.child("upd")
    }

    /// A minimal bundle-shaped directory with a version, for the version checks.
    private func makeBundle(version: String?) throws -> URL {
        let dir = try tempDir().appendingPathComponent("Fake.app", isDirectory: true)
        let contents = dir.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "app.example"]
        if let version { plist["CFBundleShortVersionString"] = version }
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return dir
    }

    // MARK: - Checksum

    @Test("hash matches only for the exact bytes")
    func hashMatchesOnlyForTheExactBytes() {
        let data = Data("the update payload".utf8)
        let digest = AppUpdater.sha256(of: data)
        #expect(digest.count == 64, "a SHA-256 is 64 hex characters")
        #expect(AppUpdater.hashMatches(data, expected: digest))
        #expect(AppUpdater.hashMatches(data, expected: digest.uppercased()), "published hashes shouldn't be case-sensitive")
        #expect(AppUpdater.hashMatches(data, expected: "  \(digest)\n"), "surrounding whitespace in the manifest shouldn't matter")

        #expect(!AppUpdater.hashMatches(Data("the update payloae".utf8), expected: digest), "one changed byte must fail")
    }

    /// A manifest with no hash, an empty hash, or a truncated one must never be
    /// treated as a match — "no checksum" cannot mean "checksum passed".
    @Test("malformed hashes never match")
    func malformedHashesNeverMatch() {
        let data = Data("payload".utf8)
        let digest = AppUpdater.sha256(of: data)
        for bogus in ["", "   ", "0", String(digest.dropLast()), digest + "0", "not a hash"] {
            #expect(!AppUpdater.hashMatches(data, expected: bogus), "\"\(bogus)\" must not pass as a checksum")
        }
    }

    // MARK: - Signing requirement

    /// The requirement must pin OUR team, not merely "some valid Developer ID" —
    /// which would accept any paid developer account on earth.
    @Test("requirement pins team and identifier")
    func requirementPinsTeamAndIdentifier() {
        let requirement = AppUpdater.requirementString(bundleIdentifier: "app.example", teamIdentifier: "ABCDE12345")
        #expect(requirement.contains("anchor apple generic"), "must require Apple's chain: \(requirement)")
        #expect(requirement.contains("ABCDE12345"), "must pin the team: \(requirement)")
        #expect(requirement.contains("app.example"), "must pin the bundle id: \(requirement)")
        // Team alone is not enough: an Apple Development certificate carries the same
        // team, so without these the requirement accepts a development-signed build.
        #expect(requirement.contains("1.2.840.113635.100.6.2.6"), "must require the Developer ID CA: \(requirement)")
        #expect(requirement.contains("1.2.840.113635.100.6.1.13"), "must require a Developer ID Application leaf: \(requirement)")
    }

    /// An unsigned bundle must be refused. This is the case an attacker gets for free.
    @Test("an unsigned bundle is refused")
    func anUnsignedBundleIsRefused() throws {
        let fake = try makeBundle(version: "9.9.9")
        let failure = AppUpdater.verifySignature(of: fake, requirement: strict)
        #expect(failure != nil, "an unsigned bundle must not pass")
        if case .signature = failure {} else {
            Issue.record("expected a signature failure, got \(String(describing: failure))")
        }
    }

    @Test("a nonexistent bundle is refused")
    func aNonexistentBundleIsRefused() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotThere-\(UUID().uuidString).app")
        #expect(AppUpdater.verifySignature(of: missing, requirement: strict) != nil)
    }

    /// A validly signed app that isn't ours must be refused. Calculator is signed by
    /// Apple itself — a perfectly good signature, just not a Developer ID one for this
    /// team. (The sharper version of this — a *development*-signed build of your OWN
    /// team — needs a signed test host, so it belongs in the app's own tests.)
    @Test("a validly signed app from someone else is refused")
    func aValidlySignedAppFromSomeoneElseIsRefused() {
        #expect(AppUpdater.verifySignature(of: calculator, requirement: strict) != nil)
    }

    /// …and a requirement that only asks for its identifier IS satisfied by it, so the
    /// failure above is the requirement doing its job, not the API always failing.
    @Test("the same app passes a weaker requirement")
    func theSameAppPassesAWeakerRequirement() {
        #expect(AppUpdater.verifySignature(of: calculator,
                                           requirement: "identifier \"com.apple.calculator\"") == nil)
    }

    // MARK: - Version must move forward

    @Test("only a newer version is accepted")
    func onlyANewerVersionIsAccepted() throws {
        let newer = try makeBundle(version: "0.3.0")
        #expect(AppUpdater.checkNewer(candidate: newer, than: "0.2.23") == nil)

        let same = try makeBundle(version: "0.2.23")
        #expect(AppUpdater.checkNewer(candidate: same, than: "0.2.23") == .notNewer("0.2.23"))

        let older = try makeBundle(version: "0.2.9")
        #expect(AppUpdater.checkNewer(candidate: older, than: "0.2.23")
                == .notNewer("0.2.9"), "0.2.9 is older than 0.2.23 — the comparison must be numeric, not textual")
    }

    @Test("a bundle with no version is refused")
    func aBundleWithNoVersionIsRefused() throws {
        let anonymous = try makeBundle(version: nil)
        #expect(AppUpdater.checkNewer(candidate: anonymous, than: "0.2.23") != nil)
    }

    @Test("short version is read from the bundle")
    func shortVersionIsReadFromTheBundle() throws {
        let bundle = try makeBundle(version: "1.2.3")
        #expect(AppUpdater.shortVersion(ofBundleAt: bundle) == "1.2.3")
    }

    // MARK: - The swap helper

    /// The lookup that was wrong first time round in Vaelora. `url(forAuxiliaryExecutable:)`
    /// searches Contents/MacOS and `url(forResource:subdirectory:)` searches
    /// Contents/Resources; a helper in Contents/Helpers is in neither, so both found
    /// nothing and the update would have failed at its last step.
    @Test("a helper path is resolved from the bundle root")
    func aHelperPathIsResolvedFromTheBundleRoot() {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        let swap = SwapStrategy.helper(relativePath: "Contents/Helpers/example")
        #expect(swap.helperURL(inBundle: bundle)?.path == "/Applications/Example.app/Contents/Helpers/example")
        #expect(SwapStrategy.builtIn.helperURL(inBundle: bundle) == nil)
    }

    // MARK: - Eligibility

    /// A translocated copy runs from a randomised read-only path; it cannot replace
    /// itself and the user needs telling to move it.
    @Test("a translocated copy is not eligible")
    func aTranslocatedCopyIsNotEligible() {
        let translocated = URL(fileURLWithPath:
            "/private/var/folders/xx/AppTranslocation/ABC-123/d/Example.app")
        let reason = AppUpdater.ineligibilityReason(appName: "Example", bundleURL: translocated)
        #expect(reason != nil)
        #expect(reason!.contains("Applications"), "\(reason!)")
    }

    @Test("a writable location is eligible")
    func aWritableLocationIsEligible() throws {
        let dir = try tempDir()
        let app = dir.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(AppUpdater.ineligibilityReason(appName: "Example", bundleURL: app) == nil, "a normal writable folder should be updatable in place")
    }

    @Test("an unwritable location is not eligible")
    func anUnwritableLocationIsNotEligible() {
        // /usr is root-owned and not writable by the user.
        let app = URL(fileURLWithPath: "/usr/Example.app")
        let reason = AppUpdater.ineligibilityReason(appName: "Example", bundleURL: app)
        #expect(reason != nil)
        #expect(reason!.contains("can't write"), "\(reason!)")
    }
}

/// The manifest contract between the publish script and the installer.
@MainActor
@Suite("update manifest archives")
struct UpdateManifestArchiveTests {
    private let sixtyFour = String(repeating: "a", count: 64)

    private func manifest(archive: String?, sha: String?) throws -> UpdateManifest {
        var json: [String: Any] = [
            "version": "0.3.0",
            "url": "https://dl.example.app/0.3.0/example-0.3.0.dmg",
        ]
        if let archive { json["archive"] = archive }
        if let sha { json["sha256"] = sha }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    /// An older build, or one published before the updater existed, must still read the
    /// manifest and fall back to the DMG rather than failing to parse it.
    @Test("a manifest without an archive still decodes")
    func aManifestWithoutAnArchiveStillDecodes() throws {
        let m = try manifest(archive: nil, sha: nil)
        #expect(m.version == "0.3.0")
        #expect(m.installableArchive == nil, "no archive means no in-place install")
    }

    @Test("an archive and checksum together are installable")
    func anArchiveAndChecksumTogetherAreInstallable() throws {
        let m = try manifest(archive: "https://dl.example.app/0.3.0/example-0.3.0.zip",
                             sha: sixtyFour)
        #expect(m.installableArchive != nil)
        #expect(m.installableArchive?.sha256 == sixtyFour)
    }

    /// The important one. An archive URL with no checksum — or a malformed one — must
    /// NOT be installable: the checksum is the only thing between fetching bytes and
    /// executing them, so "missing" cannot degrade to "unchecked".
    @Test("an archive without a usable checksum is not installable")
    func anArchiveWithoutAUsableChecksumIsNotInstallable() throws {
        #expect(try manifest(archive: "https://dl.example.app/x.zip", sha: nil)
            .installableArchive == nil, "an archive with no checksum must be refused")
        #expect(try manifest(archive: "https://dl.example.app/x.zip", sha: "")
            .installableArchive == nil)
        #expect(try manifest(archive: "https://dl.example.app/x.zip", sha: "deadbeef")
            .installableArchive == nil, "a truncated checksum must be refused")
    }

    @Test("a checksum without an archive is not installable")
    func aChecksumWithoutAnArchiveIsNotInstallable() throws {
        #expect(try manifest(archive: nil, sha: sixtyFour).installableArchive == nil)
    }
}

/// What each entry point OFFERS, which is where 0.2.24 fell down: the banner grew an
/// in-place install and "Check for Updates…" was left behind, so anyone who used the
/// menu — the obvious way to ask — was sent to the DMG and had to install it by hand.
/// The alert is a modal and can't be driven from a test, so the decision it makes is
/// a value; these tests are about that value.
@MainActor
@Suite("update offers")
struct UpdateOfferTests {
    private let sixtyFour = String(repeating: "a", count: 64)

    private func available(archive: Bool) -> UpdateChecker.State {
        var m = UpdateManifest(version: "0.3.0",
                               url: URL(string: "https://dl.example.app/0.3.0/x.dmg")!)
        if archive {
            m.archive = URL(string: "https://dl.example.app/0.3.0/x.zip")!
            m.sha256 = sixtyFour
        }
        return .available(m)
    }

    /// The regression. Everything needed is present — an archive with a checksum, and a
    /// copy that can replace itself — so the menu must offer the install, not a download.
    @Test("the menu offers to install when it can")
    func theMenuOffersToInstallWhenItCan() {
        #expect(UpdateAlert.offer(for: available(archive: true), canInstallInPlace: true)
                == .install(available(archive: true).manifest!), "an installable update reached through the menu must offer to install")
    }

    /// Both fallbacks stay: neither an un-installable copy nor a manifest published
    /// without an archive may offer a button that would fail.
    @Test("it falls back to download when it cannot install")
    func itFallsBackToDownloadWhenItCannotInstall() {
        guard case .download = UpdateAlert.offer(for: available(archive: true),
                                                 canInstallInPlace: false) else {
            Issue.record("a read-only copy must be offered the download")
            return
        }
        guard case .download = UpdateAlert.offer(for: available(archive: false),
                                                 canInstallInPlace: true) else {
            Issue.record("a manifest with no archive must be offered the download")
            return
        }
    }

    @Test("the other states are unchanged")
    func theOtherStatesAreUnchanged() {
        #expect(UpdateAlert.offer(for: .upToDate, canInstallInPlace: true) == .upToDate)
        #expect(UpdateAlert.offer(for: .failed("no network"), canInstallInPlace: true)
                == .failed("no network"))
        #expect(UpdateAlert.offer(for: .idle, canInstallInPlace: true) == .none)
        #expect(UpdateAlert.offer(for: .checking, canInstallInPlace: true) == .none)
    }
}

private extension UpdateChecker.State {
    var manifest: UpdateManifest? {
        if case .available(let m) = self { return m }
        return nil
    }
}

/// The gate that was missed, and could only be missed from outside a sandbox.
///
/// Vaelora once shipped sandboxed. From inside a container
/// `isWritableFile("/Applications")` is false and the write fails outright — so the
/// in-place update was refused every time and silently became a manual download. The
/// original check was "verified" with an unsandboxed script, which reports
/// /Applications as writable, and the unit tests used a temporary directory, which is
/// writable from inside a container too. Both agreed, and both were asking the wrong
/// process.
@MainActor
@Suite("the updater under the sandbox")
struct AppUpdaterSandboxTests {
    private let temp = TempDir()

    @Test("a sandboxed app cannot replace itself in applications")
    func aSandboxedAppCannotReplaceItselfInApplications() {
        let reason = AppUpdater.ineligibilityReason(
            appName: "Example",
            bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
            isSandboxed: true)
        #expect(reason != nil, "a sandboxed build cannot write to /Applications")
        #expect(reason?.contains("sandboxed") == true, "the reason must name the sandbox rather than read as a stray permissions problem: \(reason ?? "nil")")
    }

    /// Un-sandboxed, the same location is fine — so the refusal above is the sandbox
    /// and not the path.
    @Test("the same location is fine without the sandbox")
    func theSameLocationIsFineWithoutTheSandbox() throws {
        let dir = temp.child("unsb")
        #expect(AppUpdater.ineligibilityReason(
            appName: "Example",
            bundleURL: dir.appendingPathComponent("Example.app"),
            isSandboxed: false) == nil)
    }

    /// A sandboxed copy inside its own container could replace itself, so the rule is
    /// about reaching outside the container — not about the sandbox alone.
    @Test("a sandboxed app may still write inside its own container")
    func aSandboxedAppMayStillWriteInsideItsOwnContainer() {
        let inside = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Example.app")
        #expect(AppUpdater.ineligibilityReason(appName: "Example", bundleURL: inside,
                                                    isSandboxed: true) == nil)
    }
}

/// What the update tells the user while it runs.
///
/// The first in-place update to actually work did so invisibly: progress lived in the
/// document window's banner, "Check for Updates…" was used with no document open, and
/// the app downloaded, verified and replaced itself with nothing on screen but the
/// open panel it had left behind.
@MainActor
@Suite("the install stage")
struct InstallStageTests {

    @Test("downloading reports how far along it is")
    func downloadingReportsHowFarAlongItIs() {
        let stage = AppUpdater.InstallStage.downloading(receivedBytes: 2_621_440,
                                                        totalBytes: 5_242_880)
        #expect(abs((stage.fraction ?? 0) - 0.5) < 0.001)
        // Sizes in the user's own units and number format, so compare like with like.
        let received = Int64(2_621_440).formatted(.byteCount(style: .file))
        let total = Int64(5_242_880).formatted(.byteCount(style: .file))
        #expect(stage.text == "Downloading — \(received) of \(total)")
    }

    /// A server that doesn't say how big the file is leaves nothing to measure. The bar
    /// has to go indeterminate rather than sit at zero, which reads as stalled.
    @Test("an unknown download size has no fraction")
    func anUnknownDownloadSizeHasNoFraction() {
        let stage = AppUpdater.InstallStage.downloading(receivedBytes: 1_048_576, totalBytes: nil)
        #expect(stage.fraction == nil)
        #expect(stage.text == "Downloading — \(Int64(1_048_576).formatted(.byteCount(style: .file)))")
    }

    /// The checks after the download have no measurable length; a bar frozen at 100%
    /// looks stuck rather than busy.
    @Test("the stages after downloading are indeterminate")
    func theStagesAfterDownloadingAreIndeterminate() {
        #expect(AppUpdater.InstallStage.verifying.fraction == nil)
        #expect(AppUpdater.InstallStage.relaunching.fraction == nil)
        #expect(AppUpdater.InstallStage.verifying.text == "Verifying the download…")
    }

    /// Said out loud because the app is about to disappear, and an app vanishing with
    /// no warning is alarming even when it is about to come straight back.
    @Test("relaunching announces itself")
    func relaunchingAnnouncesItself() {
        #expect(AppUpdater.InstallStage.relaunching.text == "Relaunching…")
    }

    /// Cancelling is the user's own instruction. Reporting it back as a failure would
    /// be telling them something went wrong when they made it happen.
    @Test("cancelling is not an error to show")
    func cancellingIsNotAnErrorToShow() {
        #expect(AppUpdater.Failure.cancelled.errorDescription == nil)
        #expect(AppUpdater.Failure.hashMismatch.errorDescription != nil)
    }
}

/// The archive download itself. Exercised against a real `URLSession` over a local
/// file URL, because the bug this guards against was invisible to every stubbed test:
/// the code was correct, it was just ninety-five times too slow.
@MainActor
@Suite("update downloads")
struct AppUpdaterDownloadTests {

    private func makePayload(bytes: Int) throws -> (URL, Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-\(UUID()).zip")
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 512) { data[i] = UInt8(i % 251) }
        try data.write(to: url)
        return (url, data)
    }

    @Test("download returns the exact bytes")
    func downloadReturnsTheExactBytes() async throws {
        let (url, expected) = try makePayload(bytes: 256 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let got = try await AppUpdater.download(url, expecting: expected.count, report: { _ in })
        #expect(got == expected)
    }

    /// The regression guard. Reading the archive a byte at a time measured 34s for a
    /// 5 MB update against 0.36s for a plain fetch — roughly 6.5 seconds per megabyte.
    ///
    /// So the property is COST PER BYTE, and this measures that rather than a stopwatch on
    /// one download. It used to assert that 2 MB finished within three seconds, which is a
    /// statement about the machine as much as about the code: it failed whenever anything
    /// else was busy, and passed again on a quiet machine with nothing changed.
    ///
    /// Two sizes, and the difference between them. Whatever the fixed cost of a download
    /// happens to be that second — and here it is large and variable, which is what made the
    /// old bound flaky — it is in both measurements and subtracts out. The minimum of a few
    /// runs, because the fastest one is the least disturbed; a slow sample says the machine
    /// was busy, and only the floor says anything about the code.
    @Test("download does not cost per byte")
    func downloadDoesNotCostPerByte() async throws {
        let small = 512 * 1024, large = 4 * 1024 * 1024

        func fastestSeconds(bytes: Int) async throws -> Double {
            let (url, payload) = try makePayload(bytes: bytes)
            defer { try? FileManager.default.removeItem(at: url) }
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<3 {
                let started = Date()
                let got = try await AppUpdater.download(url, expecting: payload.count,
                                                        report: { _ in })
                best = min(best, Date().timeIntervalSince(started))
                #expect(got.count == payload.count)
            }
            return best
        }

        let perMegabyte = (try await fastestSeconds(bytes: large)
                           - (try await fastestSeconds(bytes: small)))
            / (Double(large - small) / 1_048_576)

        // Measured on this machine: 0.001 s/MB idle, 0.06 while the rest of the suite is
        // running — disk contention scales with bytes, so even the marginal cost moves under
        // load, just far less than the old stopwatch did. The bound sits an order of
        // magnitude above the worst of those and an order below the 6.5 s/MB the shipped
        // regression cost.
        //
        // Worth saying what this does NOT catch: a per-byte loop without the await costs
        // 0.038, which is inside the noise of a loaded machine. This guards the form that
        // actually shipped and made a 5 MB update take 34 seconds.
        #expect(perMegabyte < 0.5, Comment(rawValue:
                "\(String(format: "%.4f", perMegabyte))s per megabyte — a buffered read costs "
                + "about 0.001 and up to 0.06 under load; the byte-at-a-time read cost 6.5"))
    }

    /// A short read is truncation. The checksum would catch it too, but this says so
    /// in terms of what actually went wrong.
    @Test("a short download is rejected")
    func aShortDownloadIsRejected() async throws {
        let (url, expected) = try makePayload(bytes: 64 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await AppUpdater.download(url, expecting: expected.count + 1, report: { _ in })
            Issue.record("a size mismatch must not be accepted")
        } catch let failure as AppUpdater.Failure {
            guard case .download = failure else { Issue.record("expected .download, got \(failure)")
 return }
        }
    }
}
