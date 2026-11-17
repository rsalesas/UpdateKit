import Darwin
import Foundation
import Security
import Testing
@testable import UpdateKitHandOver

/// A throwaway directory, removed when the suite instance holding it is released.
final class Scratch: @unchecked Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handover-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class BundleToken {}

/// `HandOverDemo`, built beside this test bundle.
func demoBinary() throws -> URL {
    let products = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
    let url = products.appendingPathComponent("HandOverDemo")
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "HandOverDemo was not built")
    return url
}

/// Puts a fresh copy of `source` at `destination` the way an update does: written
/// beside it, then renamed over it, so the path names a new file.
func install(_ source: URL, at destination: URL, corrupt: Bool = false) throws {
    let staged = destination.deletingLastPathComponent()
        .appendingPathComponent(".staged-\(UUID().uuidString)")
    var bytes = try Data(contentsOf: source)
    if corrupt { bytes[bytes.count / 2] ^= 0xFF }
    try bytes.write(to: staged)
    chmod(staged.path, 0o755)
    #expect(rename(staged.path, destination.path) == 0)
}

func inode(_ url: URL) -> UInt64 {
    var info = stat()
    return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : 0
}

// MARK: - ExecutableWatch

@Suite("Noticing a replaced executable")
struct ExecutableWatchTests {
    let scratch = Scratch()

    private func file(_ name: String = "helper") throws -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try Data("one".utf8).write(to: url)
        return url
    }

    private func replace(_ url: URL) throws {
        let staged = url.appendingPathExtension("new")
        try Data("two".utf8).write(to: staged)
        #expect(rename(staged.path, url.path) == 0)
    }

    @Test("the file it was launched from is unchanged")
    func unchanged() throws {
        let url = try file()
        let watch = ExecutableWatch(path: url.path, settle: 0, isAcceptable: { _ in true })
        #expect(watch.check() == .unchanged)
    }

    @Test("rewriting the same file is not a replacement; only a new file is")
    func identityNotContents() throws {
        let url = try file()
        let watch = ExecutableWatch(path: url.path, settle: 0, isAcceptable: { _ in true })
        try Data("changed in place".utf8).write(to: url, options: [])
        // `Data.write` without `.atomic` writes into the same inode.
        #expect(watch.check() == .unchanged)
        try replace(url)
        #expect(watch.check() == .ready)
    }

    @Test("a new file waits out the settle time, counted from when it was put there")
    func settles() throws {
        let url = try file()
        let watch = ExecutableWatch(path: url.path, settle: 60, isAcceptable: { _ in true })
        try replace(url)
        guard case .settling(let until) = watch.check() else {
            Issue.record("expected settling, got \(watch.check())")
            return
        }
        #expect(until.timeIntervalSinceNow > 50)
        // Long after the install, it is ready the first time anyone asks: no waiting
        // counted from the moment this process happened to look.
        #expect(watch.check(now: until.addingTimeInterval(1)) == .ready)
    }

    @Test("a file that isn't acceptable is refused once, and not checked again")
    func refusesOnce() throws {
        let url = try file()
        let calls = Counter()
        let watch = ExecutableWatch(path: url.path, settle: 0, isAcceptable: { _ in calls.add(); return false })
        try replace(url)
        #expect(watch.check() == .refused)
        #expect(watch.check() == .refused)
        #expect(calls.value == 1)
        // A later install is a different file, and gets its own check.
        try replace(url)
        #expect(watch.check() == .refused)
        #expect(calls.value == 2)
    }

    @Test("a missing file is not a replacement")
    func missing() throws {
        let url = try file()
        let watch = ExecutableWatch(path: url.path, settle: 0, isAcceptable: { _ in true })
        try FileManager.default.removeItem(at: url)
        #expect(watch.check() == .unchanged)
    }

    @Test("only a build signed like the running one meets its requirement")
    func signature() throws {
        let demo = try demoBinary()
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(demo as CFURL, [], &code) == errSecSuccess)
        var requirement: SecRequirement?
        try #require(SecCodeCopyDesignatedRequirement(try #require(code), [], &requirement) == errSecSuccess)
        let required = try #require(requirement)

        let copy = scratch.url.appendingPathComponent("copy")
        try install(demo, at: copy)
        #expect(ExecutableWatch.satisfies(copy.path, required))

        let damaged = scratch.url.appendingPathComponent("damaged")
        try install(demo, at: damaged, corrupt: true)
        #expect(!ExecutableWatch.satisfies(damaged.path, required))

        let other = scratch.url.appendingPathComponent("other")
        try install(URL(fileURLWithPath: "/bin/ls"), at: other)
        #expect(!ExecutableWatch.satisfies(other.path, required))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Reading lines

@Suite("Reading requests")
struct LineReadingTests {
    private func reader(_ input: String, close: Bool = true) -> (StdioHandOver, Int32) {
        var fds: [Int32] = [-1, -1]
        pipe(&fds)
        _ = input.utf8CString.withUnsafeBufferPointer { write(fds[1], $0.baseAddress, input.utf8.count) }
        if close { Darwin.close(fds[1]) }
        return (StdioHandOver(watch: nil, inputFD: fds[0], outputFD: STDERR_FILENO, signal: nil), fds[1])
    }

    private func lines(_ handOver: StdioHandOver) -> [String] {
        var out: [String] = []
        while let line = handOver.nextLine() { out.append(String(decoding: line, as: UTF8.self)) }
        return out
    }

    @Test("lines come back one at a time, blank ones skipped")
    func splits() {
        let (handOver, _) = reader("one\n\n  \ntwo\nthree")
        #expect(lines(handOver) == ["one", "two", "three"])
    }

    @Test("requests sent together are all answered")
    func pipelined() {
        let (handOver, _) = reader(String(repeating: "x\n", count: 5000))
        #expect(lines(handOver).count == 5000)
    }

    @Test("a request counts as in flight from its reading until it finishes, once")
    func countsInFlight() {
        let (handOver, _) = reader("one\ntwo\nthree\n")
        let one = handOver.nextRequest()
        let two = handOver.nextRequest()
        #expect(handOver.requestsInFlight == 2)
        one?.finish()
        one?.finish()
        #expect(handOver.requestsInFlight == 1, "a second finish must not count again")
        #expect(two.map { String(decoding: $0.line, as: UTF8.self) } == "two")
        do {
            // Released without finishing: counted as finished, so it can't hold an
            // update back for good.
            _ = handOver.nextRequest()
        }
        #expect(handOver.requestsInFlight == 1)
        two?.finish()
        #expect(handOver.requestsInFlight == 0)
        #expect(handOver.nextRequest() == nil)
    }

    @Test("reading one line at a time counts nothing as in flight")
    func serialCountsNothing() {
        let (handOver, _) = reader("one\ntwo\n")
        _ = handOver.nextLine()
        #expect(handOver.requestsInFlight == 0)
    }
}

// MARK: - The real thing

/// Talks to a running `HandOverDemo` over pipes, as an MCP client would.
final class DemoClient {
    let process = Process()
    private let toChild = Pipe()
    private let fromChild = Pipe()
    private var buffer = Data()

    init(executable: URL, settle: Double = 0, handlesSignal: Bool = true,
         concurrent: Bool = false) throws {
        process.executableURL = executable
        var extra = ["HANDOVER_DEMO_SETTLE": String(settle)]
        if !handlesSignal { extra["HANDOVER_DEMO_NO_SIGNAL"] = "1" }
        if concurrent { extra["HANDOVER_DEMO_CONCURRENT"] = "1" }
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        process.standardInput = toChild
        process.standardOutput = fromChild
        try process.run()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    func send(_ text: String) {
        toChild.fileHandleForWriting.write(Data((text + "\n").utf8))
    }

    func closeInput() throws {
        try toChild.fileHandleForWriting.close()
    }

    /// The next line the helper writes, or nil if none comes within `timeout`.
    func line(timeout: TimeInterval = 10) -> String? {
        let fd = fromChild.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(left * 1000)) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Sends a request and reads its answer, skipping the `resumed` line a new build
    /// announces itself with.
    func ask(_ request: String) -> [String: String] {
        send(request)
        while let line = line() {
            if line.hasPrefix("resumed") { continue }
            return Self.fields(line)
        }
        return [:]
    }

    static func fields(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        let parts = line.split(separator: " ")
        out["request"] = parts.first.map(String.init)
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { out[String(pair[0])] = String(pair[1]) }
        }
        return out
    }
}

@Suite("Handing over to a new build", .serialized)
struct HandOverTests {
    let scratch = Scratch()

    /// A copy of the demo at a path of its own, under a short name unique to this test so
    /// a nudge finds only it (process names are cut to 16 characters).
    private func helper() throws -> URL {
        let name = "hod" + UUID().uuidString.prefix(8).lowercased()
        let url = scratch.url.appendingPathComponent(name)
        try install(try demoBinary(), at: url)
        return url
    }

    @Test("the first request after an update is answered by the new build, in the same process")
    func firstRequestAfterUpdate() throws {
        let url = try helper()
        let client = try DemoClient(executable: url)
        let before = client.ask("one")
        #expect(before["generation"] == "0")
        let pid = before["pid"]

        try install(try demoBinary(), at: url)
        let after = client.ask("two")
        #expect(after["request"] == "two")
        #expect(after["pid"] == pid, "the process must stay the same, or its client loses the pipe")
        #expect(after["generation"] == "1")
        #expect(after["inode"] == String(inode(url)))
        #expect(after["inode"] != before["inode"])
    }

    @Test("a nudge switches an idle helper without waiting for a request")
    func nudgeSwitchesIdle() throws {
        let url = try helper()
        let client = try DemoClient(executable: url)
        let before = client.ask("one")
        try install(try demoBinary(), at: url)

        let nudged = HelperNudge.nudge(helper: url)
        #expect(nudged.map(String.init) == [before["pid"]])
        // The new build announces itself on its own: nothing was asked of it.
        #expect(client.line(timeout: 10) == "resumed generation=1")
        #expect(client.ask("two")["generation"] == "1")
    }

    @Test("a nudge with nothing installed changes nothing")
    func nudgeWithoutUpdate() throws {
        let url = try helper()
        let client = try DemoClient(executable: url)
        _ = client.ask("one")
        #expect(HelperNudge.nudge(helper: url).count == 1)
        #expect(client.line(timeout: 1) == nil, "nothing to switch to, so nothing to announce")
        #expect(client.ask("two")["generation"] == "0")
    }

    @Test("a process that doesn't handle the signal is never sent it, since it would end")
    func leavesOldHelpersAlone() throws {
        let url = try helper()
        let client = try DemoClient(executable: url, handlesSignal: false)
        let before = client.ask("one")
        let pid = client.process.processIdentifier
        try install(try demoBinary(), at: url)

        #expect(HelperNudge.processes(named: url.lastPathComponent) == [pid])
        #expect(!HelperNudge.handles(SIGUSR1, pid: pid))
        #expect(HelperNudge.nudge(helper: url).isEmpty)
        usleep(200_000)
        #expect(client.process.isRunning)
        // It still switches at its next request, as Vaelora's helpers already did.
        let after = client.ask("two")
        #expect(after["pid"] == before["pid"])
        #expect(after["generation"] == "1")
    }

    @Test("a damaged build is refused, and the old code goes on serving")
    func refusesDamaged() throws {
        let url = try helper()
        let client = try DemoClient(executable: url)
        let before = client.ask("one")
        try install(try demoBinary(), at: url, corrupt: true)
        let after = client.ask("two")
        #expect(after["generation"] == "0")
        #expect(after["inode"] == before["inode"])
        #expect(after["pid"] == before["pid"])
        // A good build installed later is still taken.
        try install(try demoBinary(), at: url)
        #expect(client.ask("three")["generation"] == "1")
    }

    @Test("a request already read is answered before switching, never lost")
    func bufferedRequestIsKept() throws {
        let url = try helper()
        let client = try DemoClient(executable: url)
        _ = client.ask("one")
        // Both lines in one write: the old build reads them together, so "next" is in
        // its buffer when the update lands, and only it can answer it.
        client.send("pause\nnext")
        usleep(100_000)
        try install(try demoBinary(), at: url)
        let paused = DemoClient.fields(try #require(client.line()))
        let next = DemoClient.fields(try #require(client.line()))
        #expect(paused["request"] == "pause")
        #expect(next["request"] == "next")
        #expect(next["generation"] == "0")
        #expect(client.ask("after")["generation"] == "1")
    }

    @Test("a request that arrives while an install settles waits for the new build")
    func waitsForSettling() throws {
        let url = try helper()
        let client = try DemoClient(executable: url, settle: 1)
        _ = client.ask("one")
        try install(try demoBinary(), at: url)
        let started = Date()
        let answer = client.ask("two")
        #expect(answer["generation"] == "1")
        #expect(Date().timeIntervalSince(started) > 0.5)
    }

    @Test("the helper ends when its client closes the pipe")
    func endsOnEOF() throws {
        let url = try helper()
        let client = try DemoClient(executable: url)
        _ = client.ask("one")
        try install(try demoBinary(), at: url)
        _ = client.ask("two")
        try client.process.standardInput.flatMap { $0 as? Pipe }?.fileHandleForWriting.close()
        client.process.waitUntilExit()
        #expect(client.process.terminationStatus == 0)
    }

    // MARK: Helpers that serve requests concurrently

    @Test("requests are served at once: a quick one isn't held up by a slow one")
    func concurrentRequestsOverlap() throws {
        let url = try helper()
        let client = try DemoClient(executable: url, concurrent: true)
        client.send("slow")
        client.send("quick")
        #expect(DemoClient.fields(try #require(client.line()))["request"] == "quick")
        #expect(DemoClient.fields(try #require(client.line()))["request"] == "slow")
    }

    @Test("an update waits for the request in flight, and the next request reaches the new build")
    func updateWaitsForRequestInFlight() throws {
        let url = try helper()
        let client = try DemoClient(executable: url, concurrent: true)
        let before = client.ask("one")
        client.send("slow")
        usleep(200_000)                      // read, and in flight
        try install(try demoBinary(), at: url)
        client.send("next")

        // The slow request is answered by the build that read it, and nothing is lost.
        let slow = DemoClient.fields(try #require(client.line()))
        #expect(slow["request"] == "slow")
        #expect(slow["generation"] == "0")
        // "next" arrived with the update ready but a request in flight: it was left in
        // the pipe, so the new build answers it, in the same process.
        var next: [String: String] = [:]
        while let line = client.line() {
            if line.hasPrefix("resumed") { continue }
            next = DemoClient.fields(line)
            break
        }
        #expect(next["request"] == "next")
        #expect(next["generation"] == "1")
        #expect(next["pid"] == before["pid"])
    }

    @Test("a nudge while a request is in flight switches only once it is answered")
    func nudgeWaitsForRequestInFlight() throws {
        let url = try helper()
        let client = try DemoClient(executable: url, concurrent: true)
        let before = client.ask("one")
        client.send("slow")
        usleep(200_000)
        try install(try demoBinary(), at: url)
        #expect(HelperNudge.nudge(helper: url).map(String.init) == [before["pid"]])

        let first = DemoClient.fields(try #require(client.line()))
        #expect(first["request"] == "slow", "the switch must not come before the answer it owes")
        #expect(first["generation"] == "0")
        #expect(client.line(timeout: 10) == "resumed generation=1")
        #expect(client.ask("two")["generation"] == "1")
    }

    @Test("closing the pipe with a request in flight still gets its answer")
    func eofWithRequestInFlight() throws {
        let url = try helper()
        let client = try DemoClient(executable: url, concurrent: true)
        client.send("slow")
        try client.closeInput()
        #expect(DemoClient.fields(try #require(client.line()))["request"] == "slow")
        client.process.waitUntilExit()
        #expect(client.process.terminationStatus == 0)
    }
}
