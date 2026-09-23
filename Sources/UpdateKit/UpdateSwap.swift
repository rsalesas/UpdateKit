import Foundation

/// The swap step for an app that ships its own helper (`SwapStrategy.helper`).
///
/// Call `run(arguments:)` from the helper's entry point with the arguments it was
/// given. It waits for the app to exit, replaces the installed bundle with one atomic
/// `replaceItemAt`, and relaunches it.
///
/// Deliberately dumb. Every check that decides *whether* to install — checksum, code
/// signature, version — has already run in the app (see `AppUpdater`). By the time
/// this starts, the only questions left are "has the app exited" and "did the rename
/// succeed".
public enum UpdateSwap {

    public struct Arguments: Equatable, Sendable {
        public var pid: pid_t
        public var staged: URL
        public var installed: URL

        /// Reads `--pid`, `--staged` and `--installed`; anything else is ignored, so a
        /// helper can pass its own subcommand name through unchanged.
        public init?(_ arguments: [String]) {
            var pid: pid_t?
            var staged: String?
            var installed: String?
            var index = 0
            while index < arguments.count - 1 {
                switch arguments[index] {
                case "--pid": pid = pid_t(arguments[index + 1])
                case "--staged": staged = arguments[index + 1]
                case "--installed": installed = arguments[index + 1]
                default: break
                }
                index += 1
            }
            guard let pid, let staged, let installed else { return nil }
            self.pid = pid
            self.staged = URL(fileURLWithPath: staged)
            self.installed = URL(fileURLWithPath: installed)
        }
    }

    public static func run(arguments: [String]) -> Never {
        guard let parsed = Arguments(arguments) else {
            FileHandle.standardError.write(Data("apply-update: missing arguments\n".utf8))
            exit(2)
        }

        waitForExit(of: parsed.pid)

        do {
            try replace(parsed.installed, with: parsed.staged)
        } catch {
            FileHandle.standardError.write(
                Data("apply-update: \(error.localizedDescription)\n".utf8))
            // Relaunch the old copy regardless: the user asked for the app, and it is
            // still intact. Better a stale copy than none.
            relaunch(parsed.installed)
            exit(1)
        }
        relaunch(parsed.installed)
        exit(0)
    }

    /// One atomic directory replacement. If it throws, nothing has moved and the old
    /// app is still exactly where it was — so a failed update is a no-op rather than a
    /// half-installed bundle.
    public static func replace(_ installed: URL, with staged: URL) throws {
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
    }

    /// Poll until the process is gone. `kill(pid, 0)` reports reachability without
    /// signalling; we are not the parent, so `waitpid` isn't available to us.
    public static func waitForExit(of pid: pid_t, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }        // ESRCH: it has exited
            usleep(100_000)
        }
    }

    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", app.path]
        try? process.run()
        process.waitUntilExit()
    }
}

/// The swap for an app with no helper of its own (`SwapStrategy.builtIn`).
///
/// A shell script, because `/bin/sh` is on every Mac and lives outside the bundle
/// being replaced. It can't do `replaceItemAt`'s single atomic exchange, so it does
/// the next best thing: move the old bundle aside, move the new one in, and if that
/// second move fails, put the old one back. A failure leaves the original in place.
///
/// The paths reach the script as positional parameters, never spliced into its text,
/// so a folder name with quotes or `$` in it can't change what the script does.
enum BuiltInSwap {

    static let script = #"""
        pid="$1"; staged="$2"; installed="$3"; relaunch="$4"
        old="${installed%.app}.updatekit-old-$$.app"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
        if mv "$installed" "$old"; then
            if mv "$staged" "$installed"; then
                rm -rf "$old"
            else
                mv "$old" "$installed"
                rm -rf "$staged"
            fi
        else
            rm -rf "$staged"
        fi
        [ "$relaunch" = "1" ] && /usr/bin/open -n "$installed"
        exit 0
        """#

    /// Start the script and return without waiting; it waits for `pid` to exit.
    @discardableResult
    static func launch(pid: pid_t, staged: URL, installed: URL,
                       relaunch: Bool = true) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "updatekit-swap",
                             String(pid), staged.path, installed.path, relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
