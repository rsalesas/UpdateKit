import Testing
import Foundation
@testable import UpdateKit

/// Exercises the REAL `defaultFetch` — URLSession, HTTP status handling, decode —
/// against a local server. The stubbed tests never touch that code path, and the
/// status check in particular only matters against a real HTTP response.
///
/// Skips itself when the local fixture server isn't running, so it can't fail CI.
/// To run it, serve `Tests/Fixtures` on :8766 (`python3 -m http.server 8766`).
/// The probe lives outside the suite: a `@Suite` trait that referenced the type it is
/// attached to would be a circular macro reference.
enum UpdateFixtureServer {
    static let base = URL(string: "http://localhost:8766")!

    static func isUp() async -> Bool {
        (try? await UpdateChecker.defaultFetch(base.appendingPathComponent("appcast.json"))) != nil
    }
}

@MainActor
@Suite("live update fetch", .serialized,
       .enabled("the fixture server on :8766 is not running") { await UpdateFixtureServer.isUp() })
struct UpdateFetchLiveTests {
    private var base: URL { UpdateFixtureServer.base }

    @Test("real fetch decodes and offers update")
    func realFetchDecodesAndOffersUpdate() async throws {
        let data = try await UpdateChecker.defaultFetch(base.appendingPathComponent("appcast.json"))
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        #expect(manifest.version == "9.9.9")

        let configuration = UpdaterConfiguration(
            bundleIdentifier: "app.example", teamIdentifier: "ABCDE12345",
            manifestURL: base.appendingPathComponent("appcast.json"),
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        let checker = UpdateChecker(
            configuration: configuration,
            fetch: { _ in try await UpdateChecker.defaultFetch(self.base.appendingPathComponent("appcast.json")) },
            currentVersion: "0.2.5",
            systemVersion: .init(majorVersion: 14, minorVersion: 5, patchVersion: 0))
        await checker.check()

        guard case .available(let update) = checker.state else {
            Issue.record("expected an update, got \(checker.state)")
            return
        }
        #expect(update.version == "9.9.9")
        #expect(update.notes == "Local end-to-end check.")
    }

    /// A missing manifest must surface as a failure, not as decoded garbage.
    @Test("real fetch rejects HTTP error")
    func realFetchRejectsHTTPError() async throws {
        do {
            _ = try await UpdateChecker.defaultFetch(base.appendingPathComponent("missing.json"))
            Issue.record("a 404 should throw rather than return the error-page body")
        } catch let error as UpdateChecker.HTTPError {
            #expect(error.status == 404)
        }
    }
}
