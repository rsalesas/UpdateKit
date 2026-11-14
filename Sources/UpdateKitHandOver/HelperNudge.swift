import Darwin
import Foundation

/// The app's side of a hand-over: tell the helpers still running that a new build is in
/// place, so an idle one switches now rather than at its next request.
///
/// Call it when the app launches. That covers both ways a new build arrives: the in-app
/// updater relaunches the app after its swap, and a user who installs from the disk image
/// opens the app afterwards. A helper that is never nudged still switches before its
/// next request (`StdioHandOver`); the nudge only makes it sooner.
public enum HelperNudge {
    /// Signals every process of this user named like `helper` that handles `signal`,
    /// other than this one. Returns the pids signalled.
    ///
    /// Only processes that ignore or catch the signal are sent it. `SIGUSR1`'s default
    /// action ends a process, and a helper from before this hand-over existed has the
    /// default: signalling it would close its client's connection, which is the thing
    /// this whole mechanism exists to avoid. Such a helper is left alone.
    ///
    /// Matched by name rather than path. A helper running a deleted file has no path to
    /// ask for, and one whose bundle went to the Trash reports the Trash. Signalling a
    /// same-named helper of some other copy of the app is harmless: it checks its own
    /// launch path and finds nothing to do.
    @discardableResult
    public static func nudge(helper: URL, signal: Int32 = SIGUSR1) -> [pid_t] {
        let name = helper.lastPathComponent
        var nudged: [pid_t] = []
        for pid in processes(named: name) where pid != getpid() {
            guard handles(signal, pid: pid), kill(pid, signal) == 0 else { continue }
            nudged.append(pid)
        }
        return nudged
    }

    /// This user's processes whose name is `name`.
    static func processes(named name: String) -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let user = getuid()
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0 else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == user else { return false }
            return processName(info) == name || commandName(info) == String(name.prefix(Int(MAXCOMLEN)))
        }
    }

    /// Whether `pid` ignores or catches `signal`, as the kernel records it.
    static func handles(_ signal: Int32, pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let bit = sigset_t(1) << (signal - 1)
        return (info.kp_proc.p_sigignore | info.kp_proc.p_sigcatch) & bit != 0
    }

    private static func processName(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func commandName(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
