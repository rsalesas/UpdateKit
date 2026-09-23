import Testing
import Foundation
@testable import UpdateKit

@Suite("app version parsing")
struct AppVersionTests {
    @Test("parses dotted numbers")
    func parsesDottedNumbers() {
        #expect(AppVersion("0.2.5")?.components == [0, 2, 5])
        #expect(AppVersion("1")?.components == [1])
        #expect(AppVersion(" 0.2.5 ")?.components == [0, 2, 5], "should tolerate whitespace")
    }

    @Test("rejects non numeric")
    func rejectsNonNumeric() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("0.2.5-beta") == nil)
        #expect(AppVersion("v0.2.5") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("0..5") == nil)
    }

    /// The whole point of the type: string ordering gets this backwards.
    @Test("double digit components order numerically")
    func doubleDigitComponentsOrderNumerically() {
        #expect(AppVersion("0.2.10")! > AppVersion("0.2.9")!)
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        // …and the naive comparison it replaces would be wrong here.
        #expect("0.2.10" < "0.2.9")
    }

    @Test("missing components are zero")
    func missingComponentsAreZero() {
        #expect(AppVersion("0.2")! == AppVersion("0.2.0")!)
        #expect(AppVersion("0.2.1")! > AppVersion("0.2")!)
    }

    @Test("equal and ordering")
    func equalAndOrdering() {
        #expect(AppVersion("0.2.5")! == AppVersion("0.2.5")!)
        #expect(AppVersion("0.2.4")! < AppVersion("0.2.5")!)
        #expect(!(AppVersion("0.2.5")! < AppVersion("0.2.5")!))
    }
}

@MainActor
@Suite("the update checker")
struct UpdateCheckerTests {
    private func configuration() -> UpdaterConfiguration {
        UpdaterConfiguration(appName: "Example", bundleIdentifier: "app.example",
                             teamIdentifier: "ABCDE12345",
                             manifestURL: URL(string: "https://dl.example.app/latest/appcast.json")!,
                             defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    nonisolated private func manifestData(version: String, minimumSystem: String? = nil) -> Data {
        var json: [String: Any] = [
            "version": version,
            "url": "https://dl.example.app/\(version)/example-\(version).dmg",
        ]
        if let minimumSystem { json["minimumSystemVersion"] = minimumSystem }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func checker(current: String = "0.2.5",
                         serves: @escaping UpdateChecker.Fetch,
                         system: OperatingSystemVersion = .init(majorVersion: 14, minorVersion: 5, patchVersion: 0),
                         configuration config: UpdaterConfiguration? = nil) -> UpdateChecker {
        UpdateChecker(configuration: config ?? configuration(), fetch: serves,
                      currentVersion: current, systemVersion: system)
    }

    // MARK: - Outcomes

    @Test("newer version is offered")
    func newerVersionIsOffered() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0") })
        await c.check()

        guard case .available(let update) = c.state else { Issue.record("expected an update, got \(c.state)")
 return }
        #expect(update.version == "0.3.0")
        #expect(c.pendingUpdate?.version == "0.3.0")
    }

    @Test("same version is up to date")
    func sameVersionIsUpToDate() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.2.5") })
        await c.check()
        #expect(c.state == .upToDate)
        #expect(c.pendingUpdate == nil)
    }

    /// A rolled-back manifest must never downgrade anyone.
    @Test("older version is up to date")
    func olderVersionIsUpToDate() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.1.0") })
        await c.check()
        #expect(c.state == .upToDate)
    }

    @Test("network failure is reported not offered")
    func networkFailureIsReportedNotOffered() async {
        struct Boom: Error {}
        let c = checker(serves: { _ in throw Boom() })
        await c.check()

        guard case .failed = c.state else { Issue.record("expected failure, got \(c.state)")
 return }
        #expect(c.pendingUpdate == nil)
    }

    /// Garbage must not be read as "newer" — it should fail closed.
    @Test("malformed manifest is not an update")
    func malformedManifestIsNotAnUpdate() async {
        let c = checker(serves: { _ in Data("not json".utf8) })
        await c.check()
        guard case .failed = c.state else { Issue.record("expected failure, got \(c.state)")
 return }
        #expect(c.pendingUpdate == nil)
    }

    @Test("unparseable version is not an update")
    func unparseableVersionIsNotAnUpdate() async {
        let c = checker(serves: { _ in self.manifestData(version: "latest") })
        await c.check()
        guard case .failed = c.state else { Issue.record("expected failure, got \(c.state)")
 return }
        #expect(c.pendingUpdate == nil)
    }

    /// A 404 (manifest not published yet) must be a quiet failure, never an update.
    /// URLSession hands back the error-page body rather than throwing, so this is
    /// the case the explicit status check exists for.
    @Test("HTTP error status is a failure")
    func hTTPErrorStatusIsAFailure() async {
        let c = checker(serves: { _ in throw UpdateChecker.HTTPError(status: 404) })
        await c.check()
        guard case .failed(let message) = c.state else { Issue.record("expected failure, got \(c.state)")
 return }
        #expect(message.contains("404"), "message should name the status: \(message)")
        #expect(c.pendingUpdate == nil)
    }

    // MARK: - Minimum system version

    @Test("build needing newer mac osis not offered")
    func buildNeedingNewerMacOSIsNotOffered() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0", minimumSystem: "15.0") },
                        system: .init(majorVersion: 14, minorVersion: 5, patchVersion: 0))
        await c.check()
        #expect(c.state == .upToDate, "shouldn't offer a build this Mac can't run")
    }

    @Test("build within reach is offered")
    func buildWithinReachIsOffered() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0", minimumSystem: "14.0") },
                        system: .init(majorVersion: 14, minorVersion: 5, patchVersion: 0))
        await c.check()
        guard case .available = c.state else { Issue.record("expected an update, got \(c.state)")
 return }
    }

    // MARK: - Throttling

    @Test("automatic check is throttled")
    func automaticCheckIsThrottled() async {
        var calls = 0
        let s = configuration()
        let c = checker(serves: { _ in calls += 1; return self.manifestData(version: "0.3.0") }, configuration: s)

        let start = Date()
        await c.checkIfDue(now: start)
        #expect(calls == 1)

        await c.checkIfDue(now: start.addingTimeInterval(3600))   // an hour later
        #expect(calls == 1, "shouldn't check again within the interval")

        await c.checkIfDue(now: start.addingTimeInterval(s.checkInterval + 60))
        #expect(calls == 2, "should check again once a day has passed")
    }

    @Test("manual check ignores throttle and preference")
    func manualCheckIgnoresThrottleAndPreference() async {
        var calls = 0
        let s = configuration()
        let c = checker(serves: { _ in calls += 1; return self.manifestData(version: "0.3.0") }, configuration: s)
        c.automaticallyChecks = false

        await c.checkIfDue()
        #expect(calls == 0, "automatic check should respect the preference")

        await c.check()
        #expect(calls == 1, "an explicit check should run anyway")
    }

    @Test("preference off skips automatic check")
    func preferenceOffSkipsAutomaticCheck() async {
        var calls = 0
        let s = configuration()
        let c = checker(serves: { _ in calls += 1; return self.manifestData(version: "0.3.0") }, configuration: s)
        c.automaticallyChecks = false

        await c.checkIfDue()
        #expect(calls == 0)
        #expect(c.state == .idle)
    }

    // MARK: - Dismissal

    @Test("dismiss hides this version only")
    func dismissHidesThisVersionOnly() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0") })
        await c.check()
        #expect(c.pendingUpdate != nil)

        c.dismissCurrent()
        #expect(c.pendingUpdate == nil, "dismissed version should stay hidden")
        guard case .available = c.state else { Issue.record("state itself should still know about it")
 return }

        // A later release is a different version string, so it surfaces again.
        let c2 = checker(serves: { _ in self.manifestData(version: "0.4.0") })
        await c2.check()
        #expect(c2.pendingUpdate != nil)
    }
}

/// Guards the seam between `scripts/publish-update.sh` and the app: the manifest the script
/// writes must be exactly what `UpdateManifest` decodes. These two live in
/// different languages and different files, so nothing else would catch a drift.
@Suite("the update manifest format")
struct UpdateManifestFormatTests {
    /// The shape scripts/publish-update.sh emits.
    private let published = """
    {
      "version": "0.3.0",
      "url": "https://dl.example.app/0.3.0/example-0.3.0.dmg",
      "minimumSystemVersion": "14.0",
      "notes": "Agreement indents, per-document settings."
    }
    """

    @Test("decodes what the release script publishes")
    func decodesWhatTheReleaseScriptPublishes() throws {
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(published.utf8))
        #expect(manifest.version == "0.3.0")
        #expect(manifest.url.absoluteString == "https://dl.example.app/0.3.0/example-0.3.0.dmg")
        #expect(manifest.minimumSystemVersion == "14.0")
        #expect(manifest.notes == "Agreement indents, per-document settings.")
        #expect(AppVersion(manifest.version) != nil)
    }

    /// notes/minimumSystemVersion are omitted when unset — that must still decode.
    @Test("decodes minimal manifest")
    func decodesMinimalManifest() throws {
        let minimal = """
        {"version":"0.3.0","url":"https://dl.example.app/0.3.0/example-0.3.0.dmg"}
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(minimal.utf8))
        #expect(manifest.version == "0.3.0")
        #expect(manifest.notes == nil)
        #expect(manifest.minimumSystemVersion == nil)
    }

    /// The manifest must point at the immutable versioned path, never latest/ —
    /// a download in flight must not be swapped by the next release.
    @Test("urlis version pinned not latest")
    func uRLIsVersionPinnedNotLatest() throws {
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(published.utf8))
        #expect(manifest.url.path.contains(manifest.version))
        #expect(!manifest.url.path.contains("latest"))
    }
}
