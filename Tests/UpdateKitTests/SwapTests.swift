import Testing
import Foundation
@testable import UpdateKit

/// The last, irreversible step. Everything before it can be undone; this is where a
/// mistake leaves someone with no app at all, so each path is run for real against
/// bundle-shaped directories rather than reasoned about.
@Suite("the swap", .serialized)
struct SwapTests {
    private let temp = TempDir("swap")

    /// A directory that looks enough like an app to tell two apart by version.
    private func makeApp(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try (["CFBundleShortVersionString": version] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// A pid that is certainly not running: a child we started and reaped.
    private func exitedPID() throws -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    private func runBuiltIn(staged: URL, installed: URL) throws {
        let process = try BuiltInSwap.launch(pid: try exitedPID(), staged: staged,
                                             installed: installed, relaunch: false)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    // MARK: - Built-in

    @Test("the built-in swap puts the new app in place")
    func builtInSwapReplacesTheApp() throws {
        let dir = temp.child("ok")
        let installed = dir.appendingPathComponent("Example.app")
        let staged = dir.appendingPathComponent(".updatekit-staged-1.app")
        try makeApp(at: installed, version: "1.0")
        try makeApp(at: staged, version: "2.0")

        try runBuiltIn(staged: staged, installed: installed)

        #expect(AppUpdater.shortVersion(ofBundleAt: installed) == "2.0")
        #expect(!FileManager.default.fileExists(atPath: staged.path), "the staged copy was moved, not copied")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["Example.app"], "the old copy must be cleaned up: \(leftovers)")
    }

    /// The failure that matters: the new copy can't be moved in. The old one must be
    /// back exactly where it was, not left under its temporary name.
    @Test("a failed swap leaves the original in place")
    func builtInSwapRollsBack() throws {
        let dir = temp.child("fail")
        let installed = dir.appendingPathComponent("Example.app")
        let staged = dir.appendingPathComponent("missing.app")      // nothing to move in
        try makeApp(at: installed, version: "1.0")

        try runBuiltIn(staged: staged, installed: installed)

        #expect(AppUpdater.shortVersion(ofBundleAt: installed) == "1.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["Example.app"], "nothing may be left under a temporary name: \(leftovers)")
    }

    /// Paths reach the script as arguments, never as script text. A folder name full
    /// of shell syntax must be treated as a name.
    @Test("paths with shell syntax are just paths")
    func builtInSwapQuotesPaths() throws {
        let dir = temp.child("odd").appendingPathComponent("My $(touch pwned) \"Apps\" 'x'", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let installed = dir.appendingPathComponent("Example App.app")
        let staged = dir.appendingPathComponent(".staged app.app")
        try makeApp(at: installed, version: "1.0")
        try makeApp(at: staged, version: "2.0")

        try runBuiltIn(staged: staged, installed: installed)

        #expect(AppUpdater.shortVersion(ofBundleAt: installed) == "2.0")
        #expect(!FileManager.default.fileExists(atPath: "pwned"))
    }

    // MARK: - Helper

    @Test("helper arguments are read around a subcommand")
    func helperArgumentsParse() {
        let parsed = UpdateSwap.Arguments(["apply-update", "--pid", "42",
                                           "--staged", "/tmp/a.app", "--installed", "/Applications/B.app"])
        #expect(parsed?.pid == 42)
        #expect(parsed?.staged.path == "/tmp/a.app")
        #expect(parsed?.installed.path == "/Applications/B.app")
        #expect(UpdateSwap.Arguments(["--pid", "42", "--staged", "/tmp/a.app"]) == nil)
    }

    @Test("the helper's replace swaps the bundle")
    func helperReplaceSwaps() throws {
        let dir = temp.child("helper")
        let installed = dir.appendingPathComponent("Example.app")
        let staged = dir.appendingPathComponent(".staged.app")
        try makeApp(at: installed, version: "1.0")
        try makeApp(at: staged, version: "2.0")

        try UpdateSwap.replace(installed, with: staged)
        #expect(AppUpdater.shortVersion(ofBundleAt: installed) == "2.0")
    }

    @Test("waiting for an exited process returns at once")
    func waitForExitedProcess() throws {
        let pid = try exitedPID()
        let start = Date()
        UpdateSwap.waitForExit(of: pid, timeout: 5)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
