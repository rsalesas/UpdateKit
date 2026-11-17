import Darwin
import Dispatch
import Foundation

/// Reads a line-based protocol on stdin (MCP's stdio transport) and switches the process
/// to a newer build at the one moment that costs the client nothing.
///
/// That moment is "between requests with nothing unread": the last reply has been sent
/// and nothing the client wrote is sitting in this process's buffer, where it would
/// vanish at exec. Bytes still in the pipe are safe, because the pipe outlives the exec
/// and the new image reads them. So this reader owns its buffer (C's `readLine` hides
/// one) and checks for a replacement only when that buffer is empty.
///
/// It checks at two moments, and only those:
///
/// * **Before reading each request.** It waits until input is readable without reading
///   it, then checks. A request that arrives after an update is left in the pipe and
///   answered by the new code. Vaelora's first version checked only after replying, so
///   the first request after every update was answered by the old code, and that is the
///   request that hit the withdrawn folder access.
/// * **When signalled** (`SIGUSR1` by default, sent by `HelperNudge`). An idle helper
///   switches straight away instead of waiting for a request, which matters for a helper
///   that works in the background, as Claunnector's does.
///
/// A helper that serves requests concurrently adds a condition, not a moment: a build that
/// is ready waits until no request is in flight, and the last one to finish wakes the
/// reader to switch (see `nextRequest()`).
///
/// There is no timer. An idle helper sleeps in `poll` until input or the signal arrives.
/// The one exception is an install still settling (see `ExecutableWatch`): then it wakes
/// once, when the settle time is up.
///
/// A helper reads in one of two ways, and must pick one:
///
/// * **One request at a time:** `nextLine()`, called only after the previous request's
///   reply has been sent. Nothing else to do: between two calls nothing is in flight.
/// * **Several at once:** `nextRequest()`, and `finish()` on each request once its reply
///   (if any) has been sent. The switch then also waits until no request is in flight.
///   While an installed build waits for that, nothing more is read: whatever the client
///   sends meanwhile stays in the pipe for the new build, as it would for a serial helper,
///   so the requests after an update still reach the new code. The cost is that new
///   requests wait for the slowest one in flight, which is no worse than serving them
///   one at a time.
///
/// Read from one thread. Send everything through `send(_:)`, from any thread, so a
/// switch never cuts a message short.
public final class StdioHandOver: @unchecked Sendable {
    /// A line read by `nextRequest()`, counted as in flight until `finish()`.
    public final class Request: @unchecked Sendable {
        /// The line, without its newline.
        public let line: Data
        private weak var owner: StdioHandOver?
        private let lock = NSLock()
        private var finished = false

        init(line: Data, owner: StdioHandOver) {
            self.line = line
            self.owner = owner
        }

        /// Ends the request: call once its reply has been sent, or when it needs none.
        /// From any thread; calls after the first do nothing. Keep the request until
        /// then: one that is released unfinished counts as finished, so a forgotten
        /// request can't hold an update back for good.
        public func finish() {
            let first = lock.withLock { () -> Bool in
                defer { finished = true }
                return !finished
            }
            if first { owner?.requestFinished() }
        }

        deinit { finish() }
    }

    private let inputFD: Int32
    private let outputFD: Int32
    private let watch: ExecutableWatch?
    private let arguments: [String]
    private let outputLock = NSLock()
    private var buffer = Data()
    private var atEOF = false
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var signalSource: DispatchSourceSignal?
    /// Guards the three below, which `Request.finish()` touches from other threads.
    private let flightLock = NSLock()
    private var inFlight = 0
    /// A build is ready and waits for `inFlight` to reach zero; the last finish wakes
    /// the reader.
    private var waitingForIdle = false
    private var signalled = false

    /// Told what happened, for a helper's own log. Never written to the client.
    public var log: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - watch: what to switch to. Nil reads lines and never switches.
    ///   - arguments: passed to the new image; normally this process's own.
    ///   - signal: the signal that asks for a switch, or nil for none. It is ignored as a
    ///     signal and watched through a dispatch source, and `HelperNudge` only sends it
    ///     to processes that ignore or catch it, so it never ends a helper by accident.
    public init(watch: ExecutableWatch?,
                inputFD: Int32 = STDIN_FILENO, outputFD: Int32 = STDOUT_FILENO,
                arguments: [String] = CommandLine.arguments,
                signal: Int32? = SIGUSR1) {
        self.inputFD = inputFD
        self.outputFD = outputFD
        self.watch = watch
        self.arguments = arguments
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            wakeRead = fds[0]
            wakeWrite = fds[1]
            for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        }
        if let signal, wakeWrite >= 0 {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
            let wake = wakeWrite
            source.setEventHandler { [weak self] in
                self?.flightLock.withLock { self?.signalled = true }
                var byte: UInt8 = 1
                _ = Darwin.write(wake, &byte, 1)
            }
            source.resume()
            signalSource = source
        }
    }

    deinit {
        signalSource?.cancel()
        if wakeRead >= 0 { close(wakeRead) }
        if wakeWrite >= 0 { close(wakeWrite) }
    }

    /// The next newline-terminated line, without its newline, or nil at end of input.
    /// Blank lines are skipped. May become a newer build instead of returning; the new
    /// image then reads the same line. For a helper that serves one request at a time:
    /// call it only once the previous reply has been sent.
    public func nextLine() -> Data? {
        readLine()
    }

    /// The next request, counted as in flight until its `finish()`, or nil at end of
    /// input. For a helper that serves requests concurrently: it may call this again
    /// straight away. Like `nextLine()` it may become a newer build instead of
    /// returning, but only with no request in flight.
    public func nextRequest() -> Request? {
        guard let line = readLine() else { return nil }
        // Counted before returning, on the reading thread: the only switches happen in
        // `readLine`, on this thread, so none can come between the read and the count.
        flightLock.withLock { inFlight += 1 }
        return Request(line: line, owner: self)
    }

    /// How many requests from `nextRequest()` have not yet finished.
    public var requestsInFlight: Int {
        flightLock.withLock { inFlight }
    }

    private func requestFinished() {
        let wake = flightLock.withLock { () -> Bool in
            inFlight -= 1
            guard inFlight == 0, waitingForIdle else { return false }
            waitingForIdle = false
            return true
        }
        if wake, wakeWrite >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
        }
    }

    private func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.allSatisfy(Self.isWhitespace) { continue }
                return line
            }
            if atEOF {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer.allSatisfy(Self.isWhitespace) ? nil : buffer
            }

            // Nothing buffered: the safe moment, if no request is in flight.
            var timeout: Int32 = -1
            switch watch?.check() {
            case .ready:
                if !switchWhenIdle() {
                    waitUntilIdle()
                    continue
                }
            case .settling(let until):
                timeout = Self.milliseconds(until: until)
            default:
                break
            }

            var fds = [pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)]
            if wakeRead >= 0 { fds.append(pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                atEOF = true
                continue
            }
            if ready == 0 { continue }       // the settle time is up: check again

            if fds.count > 1, fds[1].revents != 0 {
                drainWake()
                if flightLock.withLock({ () -> Bool in defer { signalled = false }; return signalled }) {
                    log?("Asked to switch to the installed build")
                }
                continue                     // checked at the top of the loop
            }
            guard fds[0].revents != 0 else { continue }

            // A request is waiting, still in the pipe: the check before reading it. The
            // check at the top of the loop ran before the wait, when nothing had been
            // installed yet, so it doesn't count. If a new build is settling, wait for it,
            // so the new code answers this request rather than the old.
            switch watch?.check() {
            case .ready:
                // Returns only if the switch failed, or requests are still in flight;
                // then the top of the loop waits for them, leaving this one unread.
                if !switchWhenIdle() { continue }
            case .settling(let until):
                let wait = until.timeIntervalSinceNow
                if wait > 0 { usleep(useconds_t(min(wait, 10) * 1_000_000)) }
                continue
            default:
                break
            }
            readChunk()
        }
    }

    /// Writes one message and its newline, whole. Every write to the client goes through
    /// here, so a switch can wait for a message in progress and none is cut short.
    public func send(_ line: Data) throws {
        var data = line
        data.append(0x0A)
        try outputLock.withLock { try writeAll(data) }
    }

    // MARK: - Switching

    /// Switches if no request is in flight, and returns true having tried (it returns at
    /// all only if the exec failed). Otherwise records that the last request to finish
    /// must wake the reader, and returns false.
    private func switchWhenIdle() -> Bool {
        let busy = flightLock.withLock { () -> Int in
            if inFlight > 0 { waitingForIdle = true }
            return inFlight
        }
        guard busy == 0 else { return false }
        switchNow()
        return true
    }

    /// Sleeps until the last request in flight finishes (or a nudge arrives), without
    /// reading input: what the client sends now is for the new build.
    private func waitUntilIdle() {
        let busy = flightLock.withLock { inFlight }
        guard busy > 0 else { return }
        log?("An update installed a new build; switching once \(busy) request(s) in flight finish")
        guard wakeRead >= 0 else {
            // No pipe to be woken through: look again shortly.
            usleep(50_000)
            return
        }
        var fds = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while poll(&fds, 1, -1) < 0, errno == EINTR {}
        drainWake()
        flightLock.withLock { signalled = false }
    }

    private func switchNow() {
        guard let watch else { return }
        outputLock.withLock {
            log?("An update installed a new build; switching to it")
            var environment = ProcessInfo.processInfo.environment
            environment[HandOver.generationKey] = String(HandOver.generation + 1)
            let error = HandOver.exec(path: watch.path, arguments: arguments,
                                      environment: environment)
            // Only reached if the exec was refused: carry on as this build, and don't try
            // the same file again.
            watch.refuseCurrent()
            log?("Could not switch to the new build (\(String(cString: strerror(error)))); continuing")
        }
    }

    // MARK: - Reading and writing

    private func readChunk() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(inputFD, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
            atEOF = true
        }
    }

    private func drainWake() {
        var scratch = [UInt8](repeating: 0, count: 64)
        while read(wakeRead, &scratch, scratch.count) > 0 {}
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(outputFD, pointer, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                remaining -= written
                pointer += written
            }
        }
    }

    private static func milliseconds(until date: Date) -> Int32 {
        Int32(max(0, min(date.timeIntervalSinceNow, 60)) * 1000) + 1
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }
}
