import Darwin
import Foundation

/// Turning a running helper into the build an update installed, without ending it.
///
/// A helper an MCP client launched (`vaelora mcp`, Claunnector's daemon) lives as long
/// as that client, which is days. An update swaps the app bundle underneath it and leaves
/// the process alone, so it keeps running the code it mapped at launch. That is worse
/// than out of date: macOS checks the code on disk again when a protected service
/// reconnects, finds it gone, and withdraws access. Claunnector measured calendar access
/// going to zero within two seconds of calaccessd restarting. Vaelora then had a folder
/// read refused, from the first export after an update.
///
/// Ending the helper is no remedy: the client is left with a dead pipe and has to be
/// restarted, which is the thing everyone was trying to avoid.
///
/// The remedy is `exec`. It replaces the program a process runs and keeps the process:
/// the same pid, the same parent (so the same responsible app for privacy checks), the
/// same stdin and stdout. The client sees no disconnection because there is none, and its
/// next request is answered by the new code. If the exec fails, nothing has changed and
/// the old code carries on serving.
///
/// The pieces:
///
/// * `ExecutableWatch` tells whether the file this process was launched from now holds a
///   different build, complete and signed like this one.
/// * `StdioHandOver` reads requests and switches at the safe moment: nothing in flight,
///   nothing the client sent left unread, no reply half-written. It checks before reading
///   each request, so the first request after an update reaches the new code, and when
///   the app signals it, so an idle helper switches without waiting for one. There is no
///   timer: an idle helper sleeps until one of those two things happens.
/// * `HelperNudge` is the app's side: after an update, signal the helpers still running.
public enum HandOver {
    /// Carried from each image to the next: how many times this process has handed over.
    /// Zero, or absent, in a process its client launched.
    public static let generationKey = "UPDATEKIT_HANDOVER_GENERATION"

    /// How many times this process has become a newer build. A helper that finds this
    /// above zero is serving a client that connected to an earlier build, and has listed
    /// that build's tools.
    public static var generation: Int {
        ProcessInfo.processInfo.environment[generationKey].flatMap(Int.init) ?? 0
    }

    /// Whether this image took over from an earlier one in the same process.
    public static var resumed: Bool { generation > 0 }

    /// The file this process is running, as an absolute path, at the time of the call.
    /// Ask at launch: once an update deletes the file there is no path to ask for.
    public static func currentExecutablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Becomes the program at `path`, keeping this process. Returns only if that failed,
    /// with the error; on success nothing after the call runs.
    ///
    /// Every descriptor except stdin, stdout and stderr is closed
    /// (`POSIX_SPAWN_CLOEXEC_DEFAULT`): sockets, database handles, the wake pipe. Left
    /// open, the new image would inherit descriptors it knows nothing about, and SQLite can
    /// drop its own locks when a stray descriptor on the same database is closed. Every
    /// signal goes back to its default disposition and none stays blocked, so the new
    /// image starts the way a fresh launch does.
    ///
    /// `posix_spawn` with `POSIX_SPAWN_SETEXEC` rather than `execve`, for those two
    /// attributes: `execve` keeps every descriptor not marked close-on-exec, and keeps
    /// ignored signals ignored.
    public static func exec(path: String, arguments: [String], environment: [String: String]) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&actions, fd)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, &actions, &attributes, argv, envp)
    }
}
